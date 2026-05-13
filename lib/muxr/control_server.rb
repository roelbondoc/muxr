require "json"
require "socket"
require "set"
require "muxr/key_parser"

module Muxr
  # ControlServer is the second listener on the muxr server: it accepts
  # multiple concurrent JSON-RPC clients over a Unix socket at
  # ~/.muxr/sockets/<name>.ctrl.sock and lets them inspect or drive the
  # session. The primary client of this socket is the MCP bridge
  # (bin/muxr-mcp) that exposes the methods as MCP tools for Claude Code,
  # but anything that can read/write NDJSON can drive a session — `nc` is
  # enough for poking around by hand.
  #
  # Wire format: one JSON object per line. Requests carry an `id`; responses
  # echo it back. Server-pushed events (used by `pane.subscribe`) have no
  # `id` and instead set a `method` of `"event.<topic>"`.
  #
  #   --> {"id":1,"method":"panes.list"}
  #   <-- {"id":1,"result":{"panes":[...]}}
  #   <-- {"method":"event.pane.output","params":{"pane":"a3f9b2","data":"..."}}
  #
  # The TTY socket (.sock) and the control socket (.ctrl.sock) are deliberately
  # separate: the TTY socket is single-client (only one human attaches at a
  # time), the control socket is multi-client, and a connected control client
  # never counts as "attached" — Renderer is unaffected.
  class ControlServer
    # JSON-RPC error code conventions.
    PARSE_ERROR      = -32700
    INVALID_REQUEST  = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS   = -32602
    INTERNAL_ERROR   = -32603

    READ_CHUNK = 64 * 1024

    def initialize(app, socket_path)
      @app = app
      @socket_path = socket_path
      @server = nil
      @clients = {}        # io => { read_buffer:, write_buffer: }
      @subscriptions = {}  # io => Set[pane_id]  (populated in step 3)
      @pending_runs  = []  # in-flight pane.run waiters (populated in step 3)
      @dispatcher = Dispatcher.new(app, self)
    end

    attr_reader :app, :socket_path

    def start
      File.unlink(@socket_path) if File.exist?(@socket_path)
      @server = UNIXServer.new(@socket_path)
      File.chmod(0o600, @socket_path) rescue nil
    end

    def stop
      @clients.each_key { |c| c.close rescue nil }
      @clients.clear
      @subscriptions.clear
      @pending_runs.clear
      if @server
        @server.close rescue nil
        @server = nil
      end
      File.unlink(@socket_path) if File.exist?(@socket_path)
    end

    # IO arrays the Application splices into its IO.select read/write sets.
    def read_ios
      return [] unless @server
      ios = [@server]
      ios.concat(@clients.keys)
      ios
    end

    def write_ios
      @clients.each_with_object([]) do |(io, state), acc|
        acc << io unless state[:write_buffer].empty?
      end
    end

    def owns?(io)
      io == @server || @clients.key?(io)
    end

    def handle_read(io)
      if io == @server
        accept_client
      else
        consume_client(io)
      end
    end

    def handle_write(io)
      drain_client(io)
    end

    # --- Hooks the Application invokes when interesting things happen. ---

    # Called whenever a pane's PTY emits output. Drives pane.run idle
    # detection and pane.subscribe streams.
    def on_pane_output(pane_id, _data)
      pid = pane_id.to_s
      now = monotonic_now
      unless @pending_runs.empty?
        @pending_runs.each do |run|
          next unless run[:pane_id] == pid
          run[:last_output_at] = now
          run[:had_output] = true
        end
      end
      unless @subscriptions.empty?
        pane = pane_by_id(pid)
        return unless pane
        text = pane.terminal.dump_text
        cursor = { "row" => pane.terminal.cursor_row, "col" => pane.terminal.cursor_col }
        @subscriptions.each do |io, ids|
          next unless ids.include?(pid)
          emit_event(io, "event.pane.output", { "pane" => pid, "text" => text, "cursor" => cursor })
        end
      end
    end

    # Called once per IO.select tick. Resolves any pane.run waiters whose
    # idle window has elapsed or whose timeout has fired.
    def tick
      return if @pending_runs.empty?
      now = monotonic_now
      completed = []
      @pending_runs.each do |run|
        if now >= run[:deadline_at]
          complete_run(run, timed_out: true, now: now)
          completed << run
        elsif run[:had_output] && (now - run[:last_output_at]) >= run[:idle_seconds]
          complete_run(run, timed_out: false, now: now)
          completed << run
        end
      end
      @pending_runs -= completed unless completed.empty?
    end

    # Called from the Dispatcher when a pane.run request arrives. Registers a
    # waiter that #tick later resolves.
    def register_pending_run(client_io:, request_id:, pane_id:, idle_seconds:, timeout_seconds:)
      now = monotonic_now
      @pending_runs << {
        client_io: client_io,
        request_id: request_id,
        pane_id: pane_id.to_s,
        idle_seconds: idle_seconds,
        timeout_seconds: timeout_seconds,
        last_output_at: now,
        had_output: false,
        deadline_at: now + timeout_seconds,
        started_at: now
      }
    end

    def add_subscription(client_io, pane_id)
      @subscriptions[client_io] ||= Set.new
      @subscriptions[client_io].add(pane_id.to_s)
    end

    def remove_subscription(client_io, pane_id)
      set = @subscriptions[client_io]
      return false unless set
      removed = set.delete?(pane_id.to_s)
      @subscriptions.delete(client_io) if set.empty?
      !removed.nil?
    end

    # ----- internals -----

    def accept_client
      sock = @server.accept
      @clients[sock] = { read_buffer: +"", write_buffer: +"".b }
    rescue StandardError
      # Accept may transiently fail on a closed peer; ignore.
    end

    def consume_client(io)
      state = @clients[io]
      return unless state
      begin
        chunk = io.read_nonblock(READ_CHUNK)
      rescue IO::WaitReadable
        return
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError
        drop_client(io)
        return
      end
      state[:read_buffer] << chunk
      loop do
        nl = state[:read_buffer].index("\n")
        break unless nl
        line = state[:read_buffer].slice!(0..nl)
        line.chomp!
        next if line.empty?
        process_message(io, line)
      end
    end

    def drain_client(io)
      state = @clients[io]
      return unless state
      buf = state[:write_buffer]
      return if buf.empty?
      loop do
        n = io.write_nonblock(buf)
        if n >= buf.bytesize
          buf.clear
          break
        else
          # write_nonblock returns the count actually written; slice the rest.
          state[:write_buffer] = buf.byteslice(n..-1) || +"".b
          buf = state[:write_buffer]
        end
      end
    rescue IO::WaitWritable
      # Kernel send buffer full; remainder stays queued.
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      drop_client(io)
    end

    def drop_client(io)
      @clients.delete(io)
      @subscriptions.delete(io)
      # Any pane.run waiters owned by this client are silently abandoned —
      # there's nobody to respond to.
      @pending_runs.reject! { |r| r[:client_io] == io } unless @pending_runs.empty?
      io.close rescue nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def pane_by_id(id)
      @app.session.window.panes.find { |p| p.id.to_s == id.to_s }
    end

    def complete_run(run, timed_out:, now:)
      pane = pane_by_id(run[:pane_id])
      unless pane
        respond_error(run[:client_io], id: run[:request_id],
                      code: INVALID_PARAMS,
                      message: "pane #{run[:pane_id]} no longer exists")
        return
      end
      term = pane.terminal
      respond_result(run[:client_io], id: run[:request_id], result: {
        "pane"       => pane.id.to_s,
        "timed_out"  => timed_out,
        "had_output" => run[:had_output],
        "elapsed_ms" => ((now - run[:started_at]) * 1000).round,
        "text"       => term.dump_text,
        "cursor"     => { "row" => term.cursor_row, "col" => term.cursor_col }
      })
    end

    def process_message(io, line)
      msg = JSON.parse(line)
    rescue JSON::ParserError => e
      respond_error(io, id: nil, code: PARSE_ERROR, message: "Parse error: #{e.message}")
      return
    else
      id = msg["id"]
      method = msg["method"]
      params = msg["params"] || {}
      unless method.is_a?(String)
        respond_error(io, id: id, code: INVALID_REQUEST, message: "missing method")
        return
      end
      begin
        # The dispatcher may either return a Hash (synchronous result) or the
        # symbol :deferred (it will later push a response when ready — used
        # by pane.run / pane.subscribe in step 3).
        result = @dispatcher.call(method: method, params: params, client_io: io, request_id: id)
        respond_result(io, id: id, result: result) if id && result != :deferred
      rescue Dispatcher::Error => e
        respond_error(io, id: id, code: e.code, message: e.message)
      rescue StandardError => e
        respond_error(io, id: id, code: INTERNAL_ERROR, message: "#{e.class}: #{e.message}")
      end
    end

    public

    def respond_result(io, id:, result:)
      write_json(io, { "id" => id, "result" => result })
    end

    def respond_error(io, id:, code:, message:, data: nil)
      err = { "code" => code, "message" => message }
      err["data"] = data unless data.nil?
      write_json(io, { "id" => id, "error" => err })
    end

    def emit_event(io, method, params)
      write_json(io, { "method" => method, "params" => params })
    end

    def write_json(io, hash)
      return unless @clients.key?(io)
      line = JSON.generate(hash) + "\n"
      @clients[io][:write_buffer] << line.b
      drain_client(io)
    end
  end

  # Dispatcher dispatches a single JSON-RPC method name to one of the
  # Application's read/mutate operations. Read-only methods land here in
  # step 2; mutating methods (pane.send_input, layout.set, …) and the
  # asynchronous pane.run / pane.subscribe land in step 3.
  class Dispatcher
    class Error < StandardError
      attr_reader :code
      def initialize(message, code: ControlServer::INVALID_PARAMS)
        super(message)
        @code = code
      end
    end

    def initialize(app, server)
      @app = app
      @server = server
    end

    BRACKET_PASTE_START = "\e[200~".b
    BRACKET_PASTE_END   = "\e[201~".b

    DEFAULT_IDLE_MS    = 500
    DEFAULT_TIMEOUT_MS = 30_000
    MAX_TIMEOUT_MS     = 5 * 60 * 1000  # 5 min cap so a runaway wait can't hold a slot forever.

    def call(method:, params:, client_io:, request_id:)
      case method
      when "ping"             then { "pong" => true }
      when "session.get"      then session_get
      when "session.save"     then session_save
      when "panes.list"       then panes_list
      when "pane.read"        then pane_read(params)
      when "pane.send_input"  then pane_send_input(params)
      when "pane.focus"       then pane_focus(params)
      when "pane.new"         then pane_new(params)
      when "pane.kill"        then pane_kill(params)
      when "pane.promote"     then pane_promote(params)
      when "pane.run"         then pane_run(params, client_io, request_id)
      when "pane.subscribe"   then pane_subscribe(params, client_io)
      when "pane.unsubscribe" then pane_unsubscribe(params, client_io)
      when "layout.set"       then layout_set(params)
      when "layout.cycle"     then layout_cycle
      when "drawer.toggle"    then drawer_action(:toggle_drawer)
      when "drawer.show"      then drawer_action(:show_drawer)
      when "drawer.hide"      then drawer_action(:hide_drawer)
      when "drawer.reset"     then drawer_action(:reset_drawer)
      when "drawer.send_input" then drawer_send_input(params)
      when "drawer.read"      then drawer_read(params)
      else
        raise Error.new("unknown method: #{method}", code: ControlServer::METHOD_NOT_FOUND)
      end
    end

    private

    def session_get
      session = @app.session
      win = session.window
      drawer = session.drawer
      {
        "name"            => session.name,
        "width"           => session.width,
        "height"          => session.height,
        "layout"          => win.layout.to_s,
        "available_layouts" => Window::LAYOUTS.map(&:to_s),
        "pane_count"      => win.panes.length,
        "focused_pane"    => focused_pane_id(session),
        "focused_slot"    => focused_pane_slot(session),
        "master_slot"     => win.panes.empty? ? nil : win.master_index + 1,
        "focus_drawer"    => !!session.focus_drawer,
        "drawer"          => {
          "present" => !drawer.nil?,
          "visible" => drawer&.visible? || false
        }
      }
    end

    def panes_list
      win = @app.session.window
      focused_idx = win.focused_index
      master_idx  = win.master_index
      panes = win.panes.each_with_index.map do |pane, i|
        private_pane = pane_private?(pane)
        entry = {
          "id"      => pane.id.to_s,
          "slot"    => i + 1,
          "focused" => i == focused_idx,
          "master"  => i == master_idx,
          "alive"   => pane.alive?,
          "private" => private_pane
        }
        # On a private pane: don't leak cwd or the screen size (a writeable
        # surface anyone with the MCP could probe). Id+slot are kept so
        # Claude can name the pane in a refusal ("I can't read pane #2,
        # it's private").
        unless private_pane
          entry["cwd"] = safe_cwd(pane)
          entry["rows"] = pane.terminal.rows
          entry["cols"] = pane.terminal.cols
        end
        entry
      end
      { "panes" => panes }
    end

    def pane_read(params)
      pane = find_pane(params)
      ensure_not_private!(pane, "pane.read")
      term = pane.terminal
      {
        "id"     => pane.id.to_s,
        "rows"   => term.rows,
        "cols"   => term.cols,
        "cursor" => { "row" => term.cursor_row, "col" => term.cursor_col },
        "scrollback_size" => term.scrollback_size,
        "scrolled_back"   => term.scrolled_back?,
        "text"   => term.dump_text
      }
    end

    def drawer_read(_params)
      drawer = @app.session.drawer
      pane = drawer&.pane
      unless pane
        return { "present" => false, "visible" => false, "rows" => 0, "cols" => 0, "text" => "" }
      end
      term = pane.terminal
      {
        "present" => true,
        "visible" => drawer.visible?,
        "rows"    => term.rows,
        "cols"    => term.cols,
        "cursor"  => { "row" => term.cursor_row, "col" => term.cursor_col },
        "text"    => term.dump_text
      }
    end

    # ---- mutating methods ----

    def session_save
      path = @app.session.save
      { "saved_to" => path }
    end

    def pane_send_input(params)
      pane = find_pane(params)
      ensure_not_private!(pane, "pane.send_input")
      raw, payload = build_input_payload(params, text_key: "data", required: true, bracketed: !!params["bracketed"])
      pane.write(payload)
      { "pane" => pane.id.to_s, "bytes" => raw.bytesize }
    end

    def pane_focus(params)
      pane = find_pane(params)
      idx = @app.session.window.panes.index(pane)
      @app.session.focus_drawer = false
      @app.session.window.focus_index(idx)
      @app.invalidate
      { "pane" => pane.id.to_s, "slot" => idx + 1 }
    end

    def pane_new(params)
      cwd = params["cwd"]
      pane = @app.new_pane(cwd: cwd.is_a?(String) ? cwd : nil)
      { "pane" => pane.id.to_s, "slot" => @app.session.window.panes.index(pane) + 1 }
    end

    def pane_kill(params)
      pane = find_pane(params)
      ensure_not_private!(pane, "pane.kill")
      @app.session.window.remove_pane(pane)
      @app.invalidate
      { "pane" => pane.id.to_s }
    end

    def pane_promote(params)
      pane = find_pane(params)
      idx = @app.session.window.panes.index(pane)
      # Window#promote_to_master operates on the currently focused pane, so
      # focus the requested pane first to keep the semantics aligned with the
      # human keybinding (Ctrl-a Enter).
      @app.session.window.focus_index(idx)
      @app.session.window.promote_to_master
      @app.invalidate
      { "pane" => pane.id.to_s, "slot" => @app.session.window.panes.index(pane) + 1 }
    end

    # pane.run is asynchronous: it sends input (optionally) and registers a
    # waiter that the ControlServer's #tick resolves when output goes idle.
    # Returns :deferred so ControlServer skips the synchronous response path;
    # the resolution arrives later via ControlServer#complete_run.
    def pane_run(params, client_io, request_id)
      raise Error.new("pane.run: missing request id (notifications cannot wait)") unless request_id
      pane = find_pane(params)
      ensure_not_private!(pane, "pane.run")
      append_enter = params.fetch("append_enter", true)
      bracketed = !!params["bracketed"]
      idle_ms = clamp_int(params["idle_ms"], min: 50, max: 60_000, default: DEFAULT_IDLE_MS)
      timeout_ms = clamp_int(params["timeout_ms"], min: 100, max: MAX_TIMEOUT_MS, default: DEFAULT_TIMEOUT_MS)

      _raw, body = build_input_payload(params, text_key: "input", required: false, bracketed: bracketed)
      payload = +"".b
      payload << body
      payload << "\r".b if append_enter
      pane.write(payload) unless payload.empty?

      @server.register_pending_run(
        client_io: client_io,
        request_id: request_id,
        pane_id: pane.id.to_s,
        idle_seconds: idle_ms / 1000.0,
        timeout_seconds: timeout_ms / 1000.0
      )
      :deferred
    end

    def pane_subscribe(params, client_io)
      pane = find_pane(params)
      ensure_not_private!(pane, "pane.subscribe")
      @server.add_subscription(client_io, pane.id.to_s)
      { "pane" => pane.id.to_s, "subscribed" => true }
    end

    def pane_unsubscribe(params, client_io)
      pane = find_pane(params)
      removed = @server.remove_subscription(client_io, pane.id.to_s)
      { "pane" => pane.id.to_s, "subscribed" => false, "was_subscribed" => removed }
    end

    def layout_set(params)
      name = params["layout"].to_s
      sym = name.to_sym
      unless Window::LAYOUTS.include?(sym)
        raise Error.new("layout: unknown layout #{name.inspect}; want one of #{Window::LAYOUTS.map(&:to_s).join(', ')}")
      end
      @app.session.window.set_layout(sym)
      @app.invalidate
      { "layout" => sym.to_s }
    end

    def layout_cycle
      @app.session.window.cycle_layout
      @app.invalidate
      { "layout" => @app.session.window.layout.to_s }
    end

    def drawer_action(method_name)
      @app.public_send(method_name)
      drawer = @app.session.drawer
      {
        "present" => !drawer.nil?,
        "visible" => drawer&.visible? || false
      }
    end

    def drawer_send_input(params)
      drawer = @app.session.drawer
      raise Error.new("drawer.send_input: no drawer (toggle one open first)") unless drawer&.pane
      raw, payload = build_input_payload(params, text_key: "data", required: true, bracketed: !!params["bracketed"])
      drawer.pane.write(payload)
      { "bytes" => raw.bytesize }
    end

    def require_string(params, key)
      v = params[key]
      raise Error.new("missing #{key}") unless v.is_a?(String)
      v
    end

    def wrap_bracketed(data, bracketed)
      return data.b unless bracketed
      BRACKET_PASTE_START + data.b + BRACKET_PASTE_END
    end

    # Build the bytes to write to a PTY from either a `keys` array (mixed
    # literal text + vim-style named keys) or a plain text field. Returns
    # [raw_bytes, wire_bytes]: raw is the unwrapped concatenation (used for
    # reporting back `bytes`); wire is the same stream with bracketed-paste
    # markers wrapped around literal segments only (named keys are never
    # bracketed — they aren't paste content).
    #
    # text_key — which scalar param to fall back to ("data" or "input").
    # required — when true, raise if both `keys` and text_key are missing.
    def build_input_payload(params, text_key:, required:, bracketed:)
      if params.key?("keys")
        raise Error.new("provide either `#{text_key}` or `keys`, not both") if params[text_key]
        segments = KeyParser.translate(params["keys"])
        raw  = +"".b
        wire = +"".b
        segments.each do |kind, bytes|
          raw  << bytes
          wire << (kind == :literal && bracketed ? BRACKET_PASTE_START + bytes + BRACKET_PASTE_END : bytes)
        end
        [raw, wire]
      elsif params[text_key].is_a?(String)
        text = params[text_key]
        [text.b, wrap_bracketed(text, bracketed)]
      elsif required
        raise Error.new("missing #{text_key} (or `keys`)")
      else
        ["".b, "".b]
      end
    end

    def clamp_int(value, min:, max:, default:)
      v = value.is_a?(Integer) ? value : default
      v.clamp(min, max)
    end

    # ----- helpers shared with step-3 methods -----

    def find_pane(params)
      id_or_slot = params["pane"] || params["id"] || params["slot"]
      raise Error.new("pane: missing pane id or slot") if id_or_slot.nil?

      win = @app.session.window
      if id_or_slot.is_a?(Integer)
        idx = id_or_slot - 1
        unless idx >= 0 && idx < win.panes.length
          raise Error.new("pane: no pane at slot #{id_or_slot}")
        end
        win.panes[idx]
      else
        id = id_or_slot.to_s
        pane = win.panes.find { |p| p.id.to_s == id }
        raise Error.new("pane: no pane with id #{id.inspect}") unless pane
        pane
      end
    end

    def safe_cwd(pane)
      pane.respond_to?(:cwd) ? pane.cwd : nil
    rescue StandardError
      nil
    end

    def pane_private?(pane)
      pane.respond_to?(:private?) && pane.private?
    end

    # Raise a structured error pointing the MCP client at the user gesture
    # that would un-mark the pane. The skill teaches Claude to surface this
    # to the human rather than retry.
    def ensure_not_private!(pane, method_name)
      return unless pane_private?(pane)
      raise Error.new(
        "#{method_name}: pane #{pane.id} is private; the user must press Ctrl-a P (or type `:private`) on it to expose to MCP"
      )
    end

    def focused_pane_id(session)
      pane = session.window.focused_pane
      pane&.id&.to_s
    end

    def focused_pane_slot(session)
      return nil if session.window.panes.empty?
      session.window.focused_index + 1
    end
  end
end
