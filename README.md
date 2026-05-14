# muxr

A keyboard-driven terminal multiplexer in pure Ruby. `muxr` (Ruby + Unix)
combines the familiar keybindings of **GNU Screen**, the automatic tiling
of **xmonad**, and a **Quake-style drop-down drawer**. Panes are treated
like tiling-window-manager clients — you never resize them by hand;
the active layout decides geometry.

```
┌ #1 a3f9b2 ★ (tall) ───────┬ #2 c2e810 ───────────────────┐
│ master pane               │ stacked slave pane           │
│                           │                              │
│                           ├──────────────────────────────┤
│                           │ #3 9b1d04 [P]                │
│                           │ private pane (MCP-hidden)    │
└───────────────────────────┴──────────────────────────────┘
┌ Drawer ─────────────────────────────────────────────────┐
│ persistent overlay shell, opens from the bottom         │
└─────────────────────────────────────────────────────────┘
 [default] panes:3 layout:tall focused:#1 drawer:shown     muxr ^a ?
```

Each pane shows its slot (`#1`, `#2`, …) plus a stable 6-hex id
(`a3f9b2`). The slot is positional and shifts when panes are created,
killed, or promoted; the id is generated once and survives layout
changes, detach/reattach, and cold-restart from the session JSON. `[P]`
marks a private pane that the MCP control surface refuses to read or
drive (see [MCP control surface](#mcp-control-surface) below).

## Screenshots

The three built-in layouts (cycle with `C-a Tab`):

<table>
  <tr>
    <td align="center"><strong>tall</strong><br/>master + stacked slaves</td>
    <td align="center"><strong>grid</strong><br/>even tiling</td>
    <td align="center"><strong>monocle</strong><br/>focused pane fullscreen</td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/01-layout-tall.png" alt="tall layout"></td>
    <td><img src="docs/screenshots/02-layout-grid.png" alt="grid layout"></td>
    <td><img src="docs/screenshots/03-layout-monocle.png" alt="monocle layout"></td>
  </tr>
</table>

The Quake-style drawer overlay (`C-a ~`):

![drawer overlay](docs/screenshots/04-drawer.png)

## Install / run

```bash
gem install muxr
muxr                     # attach the "default" session (auto-spawn if needed)
muxr work                # attach (or start) a named session
muxr --list              # list running sessions and exit
muxr --install-skill     # install the MCP skill into ~/.claude/skills
muxr --help
```

Requires **Ruby ≥ 3.4**. No runtime gems — just `PTY`, `IO.console`, `JSON`,
`Socket`, and `FileUtils` from stdlib.

`muxr` is the client. The first invocation for a session daemonizes a
server in the background; subsequent invocations attach to it over a Unix
socket. `Ctrl-a d` detaches the client and leaves the server (and every
shell it owns) running, so reattaching gives you back the exact same panes
with their full history.

### From source

To run the latest unreleased code or hack on muxr locally, clone the repo
and use `bin/muxr` directly — it puts `lib/` on `$LOAD_PATH` itself:

```bash
git clone https://github.com/roelbondoc/muxr
cd muxr
bin/muxr                 # same flags as the installed `muxr` executable
```

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
| `C-a ~`        | toggle drawer (shell)                                   |
| `C-a C`        | toggle Claude Code drawer (MCP-aware)                   |
| `C-a P`        | toggle private flag on focused pane (hides from MCP)    |
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
claude                         # toggle the Claude Code drawer
private                        # toggle private flag on focused pane
save                           # persist session to ~/.muxr/sessions/<name>.json
restore                        # show path to saved session
sessions | ls                  # list saved sessions
new | close | next | prev | master
detach | quit                  # quit asks for y/n confirmation
```

## MCP control surface

muxr exposes a second listener at `~/.muxr/sockets/<name>.ctrl.sock`
that accepts multiple concurrent NDJSON clients over a small JSON-RPC
surface (`session.get`, `panes.list`, `pane.read`, `pane.send_input`,
`pane.run`, `pane.subscribe`, `pane.kill`, `layout.set`, `drawer.*`,
…). The control socket is independent of TTY attach — programmatic
clients never count as "attached", so a Claude Code session and a human
can drive the multiplexer concurrently.

`pane.run` waits for the PTY to go idle before responding: it sends the
input, polls for output, and returns once no bytes have arrived for
`idle_ms` (default 500). Server-side idle detection avoids the
send-then-poll race that plagues naive client-side automation.

`pane.send_input`, `pane.run`, and `drawer.send_input` accept a `keys`
array of vim-style `<name>` tokens (`<esc>`, `<c-c>`, `<cr>`, arrows,
etc.) interleaved with literal text — callers don't have to remember
that Escape is `"\e"` and Ctrl-C is `"\x03"`. Bracketed-paste wrapping
still applies to literal segments only.

### Claude Code integration

```bash
muxr --install-skill            # copies skills/muxr-control into ~/.claude/skills
                                # and prints the `claude mcp add` registration line
```

`bin/muxr-mcp` is the standalone MCP-over-stdio bridge that translates
Claude Code tool calls into NDJSON requests on the control socket. It
auto-detects the target session from `MUXR_CONTROL_SOCKET` or
`MUXR_SESSION` env vars.

`Ctrl-a C` (also `:claude`) opens a drawer whose shell is `claude`, with
`MUXR_SESSION`, `MUXR_CONTROL_SOCKET`, `MUXR_FOCUSED_PANE`, and
`MUXR_DRAWER_SELF=1` injected into its environment. The bridge picks
those up automatically; you get a Quake-style Claude Code overlay that
already knows what session it's in. `MUXR_DRAWER_SELF` makes the bridge
refuse `drawer.*` methods, so a claude drawer can't recurse into its
own PTY.

### Private panes

`Ctrl-a P` (or `:private`) flips the private flag on the focused pane.
Private panes are hidden from programmatic callers: `panes.list` strips
cwd/rows/cols, and `pane.read`, `pane.send_input`, `pane.run`,
`pane.subscribe`, and `pane.kill` refuse with an error message pointing
the human at `Ctrl-a P` to expose it. The flag is persisted in session
JSON and shown as `[P]` in the pane title bar. The MCP surface
intentionally has no method to flip the flag — only a human at the TTY
can mark a pane public again.

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
     ◄── BYE ───────────── disconnect_client     ├─ UNIXServer (TTY socket, one client at a time)
                                                 └─ UNIXServer (.ctrl.sock, many NDJSON clients)
```

Frames are length-prefixed (`[1-byte type][4-byte BE length][payload]`):
`H` hello, `I` input, `R` resize, `B` bye, `O` output.

A second listener at `~/.muxr/sockets/<name>.ctrl.sock` accepts
multiple concurrent NDJSON clients for the MCP control surface (see
above). The two sockets are independent — programmatic clients never
count as "attached", so they don't lock out the human's TTY client.

The server's event loop is single-threaded `IO.select` over the
listening sockets, the attached client (when present), every pane PTY,
the drawer PTY, and every connected control client. Layouts are pure
— `LayoutManager` has no mutable state, so the renderer recomputes
geometry on every tick after a resize or pane add/remove without
bookkeeping.

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
  "panes":  [
    {"id": "a3f9b2", "cwd": "/home/me/code", "private": false},
    {"id": "c2e810", "cwd": "/tmp", "private": true}
  ],
  "drawer": {"visible": true, "cwd": "/home/me/code"}
}
```

Pane ids and the private flag are persisted, so the same ids survive
cold-restart from the JSON snapshot and a pane that was marked private
stays private.

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
 ├─ sessions/<name>.json        structural snapshot written by `:save`
 ├─ sockets/<name>.sock         TTY client listener (auto-managed)
 ├─ sockets/<name>.ctrl.sock    MCP control listener (auto-managed)
 └─ logs/<name>.log             server stdout/stderr
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
