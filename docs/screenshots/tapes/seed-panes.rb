require "socket"
require "json"

PANES = {
  "api" => [
    "printf '\\e]2;✳ Refactor the protocol framing\\a\\e]9;4;3\\a'; clear; echo 'reading protocol.rb…'; sleep 3600",
    "wc -l *.rb | sort -rn | head -12",
    "ls"
  ],
  "notes" => [
    "printf '\\e]777;notify;Claude Code;Claude is waiting for your input\\a'; clear; cat release.md"
  ]
}.freeze

socket_path, session = ARGV
sock = UNIXSocket.new(socket_path)
call = lambda do |method, params = {}|
  sock.puts(JSON.generate(id: 1, method: method, params: params))
  sock.gets
end

PANES.fetch(session).each_with_index do |command, i|
  call.("pane.new") if i.positive?
  sleep 0.8
  call.("pane.send_input", pane: i + 1, data: "#{command}\r")
end
sock.close
