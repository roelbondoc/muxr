# muxr

A keyboard-driven terminal multiplexer in pure Ruby. `muxr` (Ruby + Unix)
combines the familiar keybindings of **GNU Screen**, the automatic tiling
of **xmonad**, and a **Quake-style drop-down drawer**. Panes are treated
like tiling-window-manager clients — you never resize them by hand;
the active layout decides geometry.

```
┌ #1 ★ (tall) ──────────────┬ #2 ──────────────────────────┐
│ master pane               │ stacked slave pane           │
│                           │                              │
│                           ├──────────────────────────────┤
│                           │ stacked slave pane           │
│                           │                              │
└───────────────────────────┴──────────────────────────────┘
┌ Drawer ─────────────────────────────────────────────────┐
│ persistent overlay shell, opens from the bottom         │
└─────────────────────────────────────────────────────────┘
 [default] panes:3 layout:tall focused:#1 drawer:shown     muxr ^a ?
```

## Install / run

```bash
git clone https://github.com/roelbondoc/muxr
cd muxr
bin/muxr                 # attach the "default" session (auto-spawn if needed)
bin/muxr work            # attach (or start) a named session
bin/muxr --list          # list saved sessions and exit
bin/muxr --help
```

Requires **Ruby ≥ 3.4**. No runtime gems — just `PTY`, `IO.console`, `JSON`,
`Socket`, and `FileUtils` from stdlib.

`bin/muxr` is the client. The first invocation for a session daemonizes a
server in the background; subsequent invocations attach to it over a Unix
socket. `Ctrl-a d` detaches the client and leaves the server (and every
shell it owns) running, so reattaching gives you back the exact same panes
with their full history.

## Keybindings (Ctrl-a prefix)

| Keys           | Action                                                  |
|----------------|---------------------------------------------------------|
| `C-a c`        | new pane                                                |
| `C-a n` / `p`  | focus next / previous pane                              |
| `C-a a`        | toggle last (previously focused) pane                   |
| `C-a 1` … `9`  | jump to pane by its label                               |
| `C-a k`        | close focused pane (or hide drawer)                     |
| `C-a Tab`      | cycle layout (`tall` → `grid` → `monocle`)              |
| `C-a Enter`    | promote focused pane to master                          |
| `C-a ~`        | toggle drawer                                           |
| `C-a [`        | enter scrollback / copy-mode                            |
| `C-a ]`        | paste internal yank buffer into focused pane            |
| `C-a d`        | detach (server keeps running)                           |
| `C-a q`        | kill session (asks `kill session? (y/n)`)               |
| `C-a :`        | command prompt                                          |
| `C-a ?`        | help                                                    |
| `C-a C-a`      | send literal `C-a` to focused pane                      |

### Scrollback and copy-mode

Each pane keeps a bounded (5000-row) scrollback ring. `C-a [` enters
scrollback with vi-style navigation; the status bar shows a key hint and
the pane title gains `[scrollback N/M]`.

| Keys                    | Action                              |
|-------------------------|-------------------------------------|
| `j` / `k`               | scroll one line                     |
| `d` / `u` (or `C-d`/`C-u`) | half page                        |
| `f` / Space (or `C-f`/`C-b`) | full page                      |
| `g` / `G`               | top / bottom                        |
| `q` / `Esc` / `C-c`     | exit back to live view              |

Press `v` inside scrollback to enter a movable-cursor selection mode.
Vim-style motions are supported:

| Keys                    | Action                              |
|-------------------------|-------------------------------------|
| `h` / `j` / `k` / `l`   | left / down / up / right            |
| `0` / `^` / `$`         | line start / first non-blank / line end |
| `w` / `W`               | next word / WORD start              |
| `e` / `E`               | next word / WORD end                |
| `b` / `B`               | previous word / WORD start          |
| `g` / `G`               | top / bottom of timeline            |
| `H` / `M` / `L`         | top / middle / bottom of viewport   |
| `C-d`/`C-u`, `C-f`/`C-b`, Space | half / full page             |
| `v` / `C-v`             | anchor char / block selection (toggle) |
| `y` or Enter            | yank and exit to live shell         |
| `q` / `Esc` / `C-c`     | cancel back to scrollback           |

`v` and `C-v` toggle between character and block (rectangular) selection
— switching between the two preserves the anchor. `y` or Enter yanks the
selection into an internal buffer, pipes it to `pbcopy` in the background
(silent no-op when `pbcopy` is unavailable), and drops you straight back
to the live shell. `C-a ]` writes the yank buffer back into the focused
pane.

## Commands (typed after `C-a :`)

```
layout {tall|grid|monocle}     # also: layout (no arg) → cycle
drawer {toggle|show|hide|reset}
save                           # persist session to ~/.muxr/sessions/<name>.json
restore                        # show path to saved session
sessions | ls                  # list saved sessions
new | close | next | prev | master
detach | quit                  # quit asks for y/n confirmation
```

## Architecture

muxr runs as **two processes** that talk over a Unix domain socket at
`~/.muxr/sockets/<name>.sock`. The server owns the PTYs and all session
state; the client is a thin TTY front-end that comes and goes across
detach/reattach.

```
Client (foreground, owns the TTY)              Server (daemon, owns the PTYs)
 ├─ STDIN in raw mode + alt screen              Application (event loop, lifecycle)
 ├─ SIGWINCH → RESIZE frame                      ├─ Session ─ Window ─ Pane[ ] ─ Terminal + PTYProcess
 │                                               │      └─ Drawer ─ Pane
 └─ Protocol                                     ├─ Renderer        – diff-emits ANSI as OUTPUT frames
     ◄── OUTPUT bytes ──── Renderer ◄────────────┤   InputHandler    – Ctrl-a state machine
     ──── INPUT bytes ───► InputHandler          ├─ CommandDispatcher – parses ":"-prefixed commands
     ──── HELLO/RESIZE ──► apply_size            ├─ LayoutManager    – pure (layout, count, area) → [Rect]
     ◄── BYE ───────────── disconnect_client     └─ UNIXServer listener (one client at a time)
```

Frames are length-prefixed (`[1-byte type][4-byte BE length][payload]`):
`H` hello, `I` input, `R` resize, `B` bye, `O` output.

The server's event loop is single-threaded `IO.select` over the listening
socket, the attached client (when present), every pane PTY, and the
drawer PTY. Layouts are pure — `LayoutManager` has no mutable state, so
the renderer recomputes geometry on every tick after a resize or
pane add/remove without bookkeeping.

`Ctrl-a d` detaches the client but leaves the server (and its shells)
running; reattaching gives you back the same panes with their full
history. `Ctrl-a q` and `:quit` flash `kill session? (y/n)` in the status
bar and only tear the server down on `y` — there is no "kill without
confirm" keybinding by design.

The drawer's PTY is **never torn down** when the drawer is hidden — its
shell process keeps running so the next toggle restores the previous
session. Its initial working directory is inherited from whatever pane
was focused when the drawer was first created; only `drawer reset` kills
the PTY.

The per-pane `Terminal` is a real VT100 emulator (cursor movement, SGR
including 256-color/truecolor and underline subparameters, erase/insert/
delete, autowrap, scroll regions). Scrollback is composited into the
visible grid through a view-offset that auto-tracks new rows while
scrolled back, so reviewed content stays frozen.

## Session persistence

Sessions live in `~/.muxr/sessions/<name>.json`:

```json
{
  "name": "default",
  "layout": "tall",
  "focused_index": 0,
  "master_index": 0,
  "panes":  [{"cwd": "/home/me/code"}, {"cwd": "/tmp"}],
  "drawer": {"visible": true, "cwd": "/home/me/code"}
}
```

The JSON file is mainly a **cold-storage fallback**. Between detaches the
live session lives inside the running server process, so `Ctrl-a d` then
`bin/muxr <name>` reattaches to the exact same shells with their full
history. The JSON only matters once the server is gone (after `Ctrl-a q`
or a reboot): re-launching `muxr <name>` rebuilds pane and drawer shells
using the saved working directories. Shell command history within those
panes is **not** persisted — that's the job of your shell's own history
file. Run `:save` from inside muxr to write the snapshot.

## Development

```bash
bundle install      # only minitest and rake
rake test           # full suite (100+ unit tests)

# Run a single file or test
ruby -Ilib -Itest test/test_layout_manager.rb
ruby -Ilib -Itest test/test_terminal.rb -n test_csi_cursor_position
```

Tests cover the layout algorithms, drawer state machine, window pane
ordering, session JSON round-trip, the client/server framing protocol,
the input-handler state machine (including scrollback and selection
modes), the renderer's diff-emit, and the VT100 emulator's cursor
movement, SGR (including colon-subparameter and underline-color forms),
erase, scroll-region, and autowrap handling. PTY-dependent code paths
are exercised via dependency injection so tests don't spawn shells.

On-disk layout:

```
~/.muxr/
 ├─ sessions/<name>.json   structural snapshot written by `:save`
 ├─ sockets/<name>.sock    server's Unix listener (auto-managed)
 └─ logs/<name>.log        server stdout/stderr
```

## Contributing

Contributions are welcome from anyone, with one requirement: **the code
must be generated by a frontier LLM** (e.g. Claude, GPT, Gemini at their
current top-tier model). Hand-written patches will not be accepted.

When you open a PR, please:

- State which model produced the change in the PR description.
- Include the prompt(s) you used, or a short summary of the conversation
  that produced the diff.
- Drive the model yourself — review, push back, iterate. You are
  responsible for the patch: it should pass `rake test`, follow the
  conventions in `CLAUDE.md`, and not regress existing behavior.

Bug reports, feature requests, and design discussion in issues are
welcome regardless of how they're written.
