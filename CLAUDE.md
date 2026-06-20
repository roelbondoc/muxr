# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`muxr` is a keyboard-driven terminal multiplexer written in pure Ruby — Screen-style keybindings, xmonad-style automatic tiling, and a Quake-style drawer overlay. It is a **standalone Ruby gem**, not a Rails app. Unlike the other projects in this workspace, **muxr does not use Docker** — run Ruby commands directly. Like `slimmetry-ruby`, it follows the gem exception in the workspace CLAUDE.md.

Runtime depends only on Ruby ≥ 3.4 stdlib (`PTY`, `IO.console`, `JSON`, `FileUtils`). Dev-only gems: `minitest`, `rake`.

## Commands

```bash
# Run the multiplexer (bin/muxr puts lib/ on $LOAD_PATH itself, no -I needed)
bin/muxr                          # start the "default" session
bin/muxr work                     # start (or restore) a named session

# Tests — no Rakefile dependency needed for the file-loader form
rake test                                                              # full suite
ruby -Ilib -Itest test/test_layout_manager.rb                          # single file
ruby -Ilib -Itest test/test_terminal.rb -n test_csi_cursor_position    # single test
```

There is no lint config, no CI, and no build step (no bundler/asset/transpile).

## Architecture (the parts you have to read multiple files to see)

muxr runs as **two processes** talking over a Unix domain socket at `~/.muxr/sockets/<name>.sock`. PTYs and Session state live in the long-running server; the client is a thin TTY front-end that comes and goes during detach/reattach.

```
Client (foreground, owns the TTY)              Server (daemon, owns the PTYs)
 ├─ STDIN raw + alt screen                      Application (event loop, lifecycle)
 ├─ SIGWINCH → RESIZE frame                      ├─ Session (Window + Drawer + dimensions)
 │                                               │   ├─ Window  – panes[], focused_index, ...
 └─ Protocol                                     │   ├─ Pane[]  – Terminal + PTYProcess
     ◄── OUTPUT bytes ──── Renderer ◄────────────┤   └─ Drawer  – persistent PTY, toggleable
     ──── INPUT bytes ───► InputHandler          ├─ Renderer        – frame composer, diff-emits ANSI
     ──── HELLO/RESIZE ──► apply_size            ├─ InputHandler    – Ctrl-a state machine
     ◄── BYE ───────────── disconnect_client     ├─ CommandDispatcher
                                                 ├─ LayoutManager   – pure functions
                                                 └─ UNIXServer listener (accepts one client)
```

A few things that are not obvious until you've debugged them:

- **Two processes.** `bin/muxr <name>` always runs as the *client*. If no socket exists at `~/.muxr/sockets/<name>.sock` (or the existing one is stale), bin/muxr fork-execs itself with `--server <name>`, polls up to 3s for the socket to appear, then connects. Server logs go to `~/.muxr/logs/<name>.log`. Only one client may attach at a time — newcomers get a `BYE busy`.

- **Detach vs. quit.** `Ctrl-a d` closes the client socket but leaves the server (and all its PTYs) running. `Ctrl-a q` and `:quit` both flash `kill session? (y/n)` in the status bar and only tear the server down on `y`. There is no "kill without confirm" keybinding by design.

- **Protocol framing (`lib/muxr/protocol.rb`).** Every message is `[1-byte type][4-byte BE length][payload]`. Types: `H` hello, `I` input, `R` resize, `B` bye, `O` output. The HELLO and RESIZE payloads are `"ROWS COLS"` ASCII; INPUT/OUTPUT carry raw terminal bytes; BYE carries an optional reason string. HELLO can carry trailing `key=val` capability tokens from the width probe (e.g. `"48 200 ambiguous=2 glyphs=23fa:2,273b:1"`); `decode_size` reads only the first two integers so the size still parses, and `decode_caps` pulls the rest.

- **`FramedOutput` (nested in `Application`)** is the Renderer's `out:` sink. It packages each Renderer `write` as one `OUTPUT` frame on the attached client. When no client is attached, render is skipped entirely — PTY data still gets drained so Terminal grids stay current, and the first frame after re-attach is forced to be a full repaint via `Renderer#reset_frame!`.

- **Event loop is single-threaded `IO.select`** over the listening socket, the attached client socket (when present), every pane PTY, and the drawer PTY (when present). All PTY reads feed into the destination pane's `Terminal#feed`. The only off-main-thread work is `Application#start_foreground_poller`, which polls each pane's foreground command every `FOREGROUND_POLL_INTERVAL` (~750ms) and writes the result back to `pane.foreground_command`. Atomic pointer writes under the GVL mean the renderer's per-frame read needs no lock.

- **`Terminal` is a real VT100 emulator**, not a line buffer. It maintains a `rows × cols` grid of `Cell` (char + fg + bg + attrs) plus cursor and scroll region. It handles CSI cursor movement, SGR (16-color, 256-color, truecolor), erase/insert/delete, autowrap, and scroll regions. UTF-8 bytes are buffered across PTY read boundaries via `@feed_remainder`.

- **`Terminal` does NOT translate `\n` → `\r\n`** (line-discipline ONLCR is the kernel's job in a real PTY). When writing tests that feed multi-line input directly, use `\r\n`. This is a real footgun that bit the initial test suite.

- **Wide / combining characters use a continuation-cell convention.** `Terminal.char_width(cp)` returns 0 (combining marks, variation selectors, zero-width formatters), 2 (East Asian wide + emoji), or 1 (everything else); the ASCII/Latin-1 fast path short-circuits at `cp < 0x300`. A width-2 glyph is stored in its **lead cell** with a **continuation cell whose `char` is `""`** immediately to its right reserving the second column; a width-0 mark is folded onto the preceding cell's `char` (so `"e" + ◌́` becomes one cell holding `"é"`). This invariant is load-bearing across four readers: the `Renderer` skips `""` cells when emitting (the lead already spans both columns) and advances its emit cursor by `char_width`, not codepoint count; `dump_text` and `extract_selection_text` treat `""` as a no-op join; and `collect_matches`/`detect_urls!` build a codepoint→column (or →cell) map because the old 1:1 char-index↔column assumption no longer holds on rows containing wide/combining glyphs. If you add a fifth consumer that walks the grid, honor the same convention. Known gap: a resize that splits a wide pair, or DCH/ICH/ECH landing between the halves, can orphan a lead — cosmetic, self-heals on the next program redraw (or `r` / `Ctrl-a r` refresh).

- **`Renderer` forces an absolute cursor move after width-ambiguous glyphs.** The diff-emit only writes `\e[y;xH` when a cell isn't contiguous with the previously-emitted one (tracked via `last_x`/`last_y`). That contiguity shortcut is only sound when the outer terminal advances its cursor exactly as far as we predict. For East Asian Ambiguous symbols (`·`, `…`, `●`, arrows, the `⏺`/`✻`/`❯` glyphs Claude Code's UI is full of), CJK, and emoji, the outer terminal may draw 1 *or* 2 columns and we can't know which — so `Renderer#contiguous_after?` returns false for anything non-ASCII except the box-drawing/block band `0x2500–0x259F`, forcing a fresh CUP for the next cell. Without this, one width disagreement cascades and shifts the entire rest of the line (the classic "text doesn't line up, but resizing fixes it" bug — resize only *appeared* to fix it because the SIGWINCH made the inner program clear-with-spaces and repaint). Verified against `pyte` as a reference emulator: muxr's grid is byte-identical for steady-state and scrolling, and the incremental diff-emit produces the same outer display as a full re-render. A second, related guard: after emitting a glyph muxr models as **one** column but whose real width is uncertain (`Terminal.char_width == 1` but not contiguous-safe), the diff also **force-repaints the next cell even if unchanged** — otherwise an in-place animation (Claude Code's spinner) lets a 2-wide draw's phantom second half sit on the skipped neighbour until a manual refresh.

- **Inner cursor visibility is honored (DECTCEM, DEC private mode 25).** `Terminal` tracks `\e[?25h`/`\e[?25l` in `@cursor_visible` (alongside 2026/2004 in the same `?`-prefixed branch). `Renderer#cursor_position` returns a bare `\e[?25l` for the focused pane when its inner program has hidden the cursor, instead of painting muxr's block at the inner cursor's last write position. This matters for Claude Code and other Ink UIs: they hide the cursor for the whole render and only show it at a text-input prompt, so without this a phantom block smears across the animating progress line. (The command/search/selection prompt cursors are handled earlier in `cursor_position` and are unaffected.)

- **Notification passthrough (bell + OSC 9 / OSC 777).** These aren't grid state — they're things the inner program emits to get the *user's* attention, and a multiplexer that swallows them silently breaks "Claude finished in a background pane." `Terminal` collects them into `@pending_notifications` (a bare BEL in ground state; an `\e]9;…` or `\e]777;…` OSC, re-wrapped with a BEL terminator since the parser consumed the original ST). `Application#consume_pane_io` drains every pane's (and the drawer's) queue via `forward_notifications` and ships the bytes to the outer terminal as their own `OUTPUT` frame — out of band from the rendered frame, so a *non-focused* pane still rings/notifies. Bell/OSC don't move the cursor or touch the screen, so interleaving them between render frames is safe. When detached the queue is still drained (and dropped) and is capped at `NOTIFY_MAX` so a never-attached session can't grow it without bound. Window-title OSC 0/1/2 and palette OSC 4 are still silently consumed — propagating a background pane's title would fight muxr's own status bar; left as a deliberate non-goal.

- **Width probe (`lib/muxr/width_probe.rb`).** The deeper fix for width disagreement: instead of guessing, *measure*. On attach the client (it owns the TTY) prints test glyphs and reads the cursor column back via DSR-CPR (`\e[6n` → `\e[r;cR`); the column delta is each glyph's real display width. It votes on the East Asian Ambiguous class (→ `Terminal.ambiguous_wide`, covering the long tail in `Terminal::AMBIGUOUS_RANGES`) and records exact per-codepoint widths for emoji-presentation glyphs no class predicts — `⏺`/`✻`/`❯` (→ `Terminal.width_overrides`, which win over every heuristic). The verdict rides to the server in HELLO and `Application#apply_caps` installs it process-wide (the server hosts one outer terminal at a time). Falls back to defaults when the terminal doesn't answer CPR (timeout) or STDIN/STDOUT isn't a TTY. The probe is why HELLO moved from `Client#connect` into `Client#run` — it needs raw mode first.

- **`Renderer` diff-emits cells.** It compares the new frame against `@prev` and only emits `\e[y;xH<sgr><char>` for cells that changed. Consequence: searching the raw output stream for a contiguous string like `"layout:grid"` will FAIL when only the differing glyphs changed position (e.g. `tall → grid` emits just `grid` at the position where `tall` was). Use targeted character checks or compose chunks before searching.

- **`LayoutManager` is pure** — `compute(layout, count, area, focused_index:, master_index:)` is the only entry point. Adding a new layout means adding a method here and an entry to `LAYOUTS`. No bookkeeping elsewhere; the Renderer calls `compute` on every render tick.

- **Drawer PTY is never torn down on hide.** `toggle/show/hide` only flip `@visible`; the shell process keeps running so its scrollback survives. Only `drawer reset` actually kills the PTY. The drawer (like every new pane) starts in the **session origin cwd** — the directory `bin/muxr` was launched from, captured once in `Application#initialize` (`@origin_cwd`).

- **`InputHandler` state machine:** `:idle` → (Ctrl-a) → `:prefix` → dispatches single key → `:idle`, OR `:prefix` + `:` → `:command` (buffered until Enter). `:confirm_quit` is a one-shot state entered by `:quit` / `Ctrl-a q`; it consumes one key and either calls `confirm_quit` (on `y`/`Y`) or `cancel_quit` (anything else). `:help` is the same shape — one-shot, cleared on any key. `Ctrl-a Ctrl-a` sends a literal Ctrl-a byte through to the focused pane.

- **`Window#promote_to_master`** does NOT just swap indices — it moves the focused pane to position 0 in `@panes` and resets both indices to 0. This keeps tall/grid layouts visually stable (master is always `panes[0]`).

- **`PTYProcess#cwd`** uses `/proc/<pid>/cwd` on Linux and falls back to `lsof -a -p PID -d cwd` on macOS/BSD. The lsof path is **synchronous and slow** (~100–300ms on macOS) — it runs on the event-loop thread when saving a session. Don't add new callers without thinking about it. (New panes no longer call it — they start in the session origin cwd, not the focused pane's.)

- **`ForegroundCommand.lookup(pid)`** is the moral cousin of `PTYProcess#cwd`: Linux reads `/proc/<pid>/stat` cheaply; macOS shells out to `ps -o tpgid=,pgid= -p <pid>` (and another `ps -o comm= -p <tpgid>`). Each macOS call is ~10–20ms × every pane × 750ms tick. It runs on `@foreground_poller` so the event loop is unaffected, but don't move it back to the main thread.

## Testing patterns

- PTY-spawning code paths are **dependency-injected**: `Pane.new` accepts `process:`, `Drawer.new` accepts `pane:`. Unit tests pass fakes (see `test_drawer.rb`, `test_session.rb`, `test_window.rb`) and never spawn a real shell.
- `test_helper.rb` deliberately loads only the pure pieces (`layout_manager`, `window`, `drawer`, `terminal`, `session`). Tests that need the full stack should `require "muxr"` themselves.
- `test_session.rb` swaps `Session::SESSIONS_DIR` in/out via `remove_const`/`const_set` around an `mktmpdir` block — copy this pattern if you add tests that touch the filesystem.

## Session file format

`~/.muxr/sessions/<name>.json` — only structural state is persisted (layout, indices, per-pane cwd, drawer visibility/cwd). Shell scrollback, command history, and process state are **not** restored; on restore, fresh shells are spawned with the saved cwds.

Note: the JSON file is now mainly a *cold-storage* fallback — between detaches the live session lives inside the running server process, so reattaching after `Ctrl-a d` gives you back the exact same shells with their full history. The JSON only matters if the server is killed (`Ctrl-a q`, machine reboot, etc.) and you want to spawn fresh shells in the saved layout next time. Run `:save` from inside muxr to write it.

## On-disk layout

```
~/.muxr/
 ├─ sessions/<name>.json   structural snapshot (manual `:save`)
 ├─ sockets/<name>.sock    server's Unix listener (created on server start, removed on shutdown)
 └─ logs/<name>.log        server stderr/stdout (appended on each spawn)
```
