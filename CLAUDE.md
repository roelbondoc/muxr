# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`rux` is a keyboard-driven terminal multiplexer written in pure Ruby — Screen-style keybindings, xmonad-style automatic tiling, and a Quake-style drawer overlay. It is a **standalone Ruby gem**, not a Rails app. Unlike the other projects in this workspace, **rux does not use Docker** — run Ruby commands directly. Like `slimmetry-ruby`, it follows the gem exception in the workspace CLAUDE.md.

Runtime depends only on Ruby ≥ 3.4 stdlib (`PTY`, `IO.console`, `JSON`, `FileUtils`). Dev-only gems: `minitest`, `rake`.

## Commands

```bash
# Run the multiplexer (bin/rux puts lib/ on $LOAD_PATH itself, no -I needed)
bin/rux                          # start the "default" session
bin/rux work                     # start (or restore) a named session

# Tests — no Rakefile dependency needed for the file-loader form
rake test                                                              # full suite
ruby -Ilib -Itest test/test_layout_manager.rb                          # single file
ruby -Ilib -Itest test/test_terminal.rb -n test_csi_cursor_position    # single test
```

There is no lint config, no CI, and no build step (no bundler/asset/transpile).

## Architecture (the parts you have to read multiple files to see)

```
Application (event loop, lifecycle)
 ├─ Session (Window + Drawer + dimensions; JSON save/restore)
 │   ├─ Window  – panes[], focused_index, master_index, layout
 │   ├─ Pane[]  – Terminal (VT100 buffer) + PTYProcess (shell)
 │   └─ Drawer  – wraps one Pane; visibility flag; persistent PTY
 ├─ Renderer        – composites a frame, diff-emits ANSI
 ├─ InputHandler    – Ctrl-a state machine
 ├─ CommandDispatcher – ":cmd" prompt parser
 └─ LayoutManager   – pure functions (no state)
```

A few things that are not obvious until you've debugged them:

- **Event loop is single-threaded `IO.select`** over STDIN plus every pane PTY plus the drawer PTY (when present). All PTY reads feed into the focused/destination pane's `Terminal#feed`. Nothing happens off the main thread.

- **`Terminal` is a real VT100 emulator**, not a line buffer. It maintains a `rows × cols` grid of `Cell` (char + fg + bg + attrs) plus cursor and scroll region. It handles CSI cursor movement, SGR (16-color, 256-color, truecolor), erase/insert/delete, autowrap, and scroll regions. UTF-8 bytes are buffered across PTY read boundaries via `@feed_remainder`.

- **`Terminal` does NOT translate `\n` → `\r\n`** (line-discipline ONLCR is the kernel's job in a real PTY). When writing tests that feed multi-line input directly, use `\r\n`. This is a real footgun that bit the initial test suite.

- **`Renderer` diff-emits cells.** It compares the new frame against `@prev` and only emits `\e[y;xH<sgr><char>` for cells that changed. Consequence: searching the raw output stream for a contiguous string like `"layout:grid"` will FAIL when only the differing glyphs changed position (e.g. `tall → grid` emits just `grid` at the position where `tall` was). Use targeted character checks or compose chunks before searching.

- **`LayoutManager` is pure** — `compute(layout, count, area, focused_index:, master_index:)` is the only entry point. Adding a new layout means adding a method here and an entry to `LAYOUTS`. No bookkeeping elsewhere; the Renderer calls `compute` on every render tick.

- **Drawer PTY is never torn down on hide.** `toggle/show/hide` only flip `@visible`; the shell process keeps running so its scrollback survives. Only `drawer reset` actually kills the PTY. cwd inheritance happens **once at first creation** from the focused pane's `cwd`.

- **`InputHandler` state machine:** `:idle` → (Ctrl-a) → `:prefix` → dispatches single key → `:idle`, OR `:prefix` + `:` → `:command` (buffered until Enter). `Ctrl-a Ctrl-a` sends a literal Ctrl-a byte through to the focused pane. Help mode is a one-shot `:help` state cleared on any key.

- **`Window#promote_to_master`** does NOT just swap indices — it moves the focused pane to position 0 in `@panes` and resets both indices to 0. This keeps tall/grid layouts visually stable (master is always `panes[0]`).

- **`PTYProcess#cwd`** uses `/proc/<pid>/cwd` on Linux and falls back to `lsof -a -p PID -d cwd` on macOS/BSD. The lsof path is **synchronous and slow** (~100–300ms on macOS) — it runs on the event-loop thread when creating a new pane or saving a session. Don't add new callers without thinking about it.

## Testing patterns

- PTY-spawning code paths are **dependency-injected**: `Pane.new` accepts `process:`, `Drawer.new` accepts `pane:`. Unit tests pass fakes (see `test_drawer.rb`, `test_session.rb`, `test_window.rb`) and never spawn a real shell.
- `test_helper.rb` deliberately loads only the pure pieces (`layout_manager`, `window`, `drawer`, `terminal`, `session`). Tests that need the full stack should `require "rux"` themselves.
- `test_session.rb` swaps `Session::SESSIONS_DIR` in/out via `remove_const`/`const_set` around an `mktmpdir` block — copy this pattern if you add tests that touch the filesystem.

## Session file format

`~/.rux/sessions/<name>.json` — only structural state is persisted (layout, indices, per-pane cwd, drawer visibility/cwd). Shell scrollback, command history, and process state are **not** restored; on restore, fresh shells are spawned with the saved cwds.
