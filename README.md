# rux

A keyboard-driven terminal multiplexer in pure Ruby. `rux` (Ruby + Unix)
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
 [default] panes:3 layout:tall focused:#1 drawer:shown     rux ^a ?
```

## Install / run

```bash
git clone https://github.com/roelbondoc/rux
cd rux
bin/rux                 # start the "default" session
bin/rux work            # start (or restore) a named session
bin/rux --help
```

Requires **Ruby ≥ 3.4**. No runtime gems — just `PTY`, `IO.console`, `JSON`,
and `FileUtils` from stdlib.

## Keybindings (Ctrl-a prefix)

| Keys           | Action                                  |
|----------------|-----------------------------------------|
| `C-a c`        | new pane                                |
| `C-a n` / `p`  | focus next / previous pane              |
| `C-a k`        | close focused pane (or hide drawer)     |
| `C-a Tab`      | cycle layout (`tall` → `grid` → `monocle`) |
| `C-a Enter`    | promote focused pane to master          |
| `C-a ~`        | toggle drawer                           |
| `C-a d`        | detach                                  |
| `C-a :`        | command prompt                          |
| `C-a ?`        | help                                    |
| `C-a C-a`      | send literal `C-a` to focused pane      |

## Commands (typed after `C-a :`)

```
layout {tall|grid|monocle}     # also: layout (no arg) → cycle
drawer {toggle|show|hide|reset}
save                           # persist session to ~/.rux/sessions/<name>.json
restore                        # show path to saved session
new | close | next | prev | master
detach | quit
```

## Architecture

```
Application
 ├─ Session ──── Window ── Pane[ ] ─ Terminal (VT100 emulator) + PTYProcess
 │     └─ Drawer ─ Pane
 ├─ Renderer ── composes one frame, diff-emits ANSI to STDOUT
 ├─ InputHandler ── Ctrl-a state machine (:idle → :prefix → :idle | :command)
 ├─ CommandDispatcher ── parses ":"-prefixed commands
 └─ LayoutManager ── pure functions: (layout, count, area) → [Rect]
```

The event loop is single-threaded using `IO.select` over all pane PTYs,
the drawer PTY (when present), and STDIN. Layouts are pure — the
LayoutManager has no mutable state, so the renderer can re-compute geometry
on every tick after a resize or pane add/remove without bookkeeping.

The drawer's PTY is **never torn down** when the drawer is hidden — its
shell process keeps running so the next toggle restores the previous
session. Its initial working directory is inherited from whatever pane was
focused when the drawer was first created.

## Session persistence

Sessions live in `~/.rux/sessions/<name>.json`:

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

Re-launching `rux <name>` rebuilds pane and drawer shells using the saved
working directories. Shell history within those panes is **not** persisted
(that's the job of your shell's own history file).

## Development

```bash
bundle install      # only minitest and rake
rake test           # runs ~37 unit tests
```

Tests cover the layout algorithms, drawer state machine, window pane
ordering, session JSON round-trip, and the VT100 emulator's cursor
movement, SGR, erase, and autowrap handling. PTY-dependent code paths
are exercised via dependency injection so tests don't spawn shells.
