# Changelog

All notable changes to muxr are documented here. The format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-05-13

### Fixed
- Render flicker on large screens and during fzf-style redraws. Each
  Renderer frame is now wrapped in DEC 2026 synchronized output (with
  the cursor hidden for the duration of the diff), so terminals that
  support it (Ghostty, kitty, iTerm2 ≥3.5, WezTerm, Alacritty ≥0.13,
  foot) present the frame atomically instead of repainting cell by
  cell. `Pane#read_from_pty` now drains the PTY to `EAGAIN` per tick,
  collapsing multi-chunk bursts (vim cursor+status redraw, fzf
  candidate list) into a single render, and the event loop caps
  repaints at ~60 Hz while trimming `IO.select`'s timeout so deferred
  frames still land on time. The Terminal emulator also honors
  `\e[?2026h` / `\e[?2026l` from inner programs (fzf ≥0.41, neovim,
  helix) as a render-timing hint — the outer paint is held until the
  close sequence arrives or a 200 ms safety timeout expires.

## [0.1.3] - 2026-05-11

### Fixed
- Large pastes into a pane no longer hang the server. PTY writes are now
  non-blocking and buffered per pane, with the writer fd added to the
  event loop's `IO.select` write set so back-pressure from a slow reader
  (e.g. Claude Code processing a multi-KB paste) can't deadlock the
  single-threaded server. Idle pass-through input is also batched into a
  single `send_to_focused` chunk instead of one call per byte.
- Client↔server socket writes are now non-blocking too, with per-side
  outgoing buffers and the socket added to `IO.select`'s write set when
  there's queued data. The previous blocking `Protocol.write` could
  deadlock both ends when a paste produced enough redraw traffic to fill
  both directions of the unix-socket kernel buffer at once (vim and
  Claude Code both reproduced this).

### Added
- Enable bracketed paste mode (`\e[?2004h`) on the outer terminal when
  the client attaches. The terminal emulator now wraps pastes with
  `\e[200~...\e[201~`, those markers flow through muxr to the focused
  pane, and apps that opt in (Claude Code, vim, modern readline) again
  recognise the input as a paste — Claude Code collapses it to
  `[Pasted text +N lines]` instead of typing the whole thing out.

## [0.1.2] - 2026-05-11

### Added
- Vim-style word and viewport motions in copy-mode selection cursor:
  `w`/`W`/`e`/`E`/`b`/`B` walk word and WORD boundaries, `^` jumps to
  the first non-blank on the line, and `H`/`M`/`L` land on the visible
  top/middle/bottom rows. Yanking now drops straight back to the live
  shell (matching vim's `v…y` returning to normal mode); the tmux-style
  `b` alias for page-back is now `Ctrl-b` only.

### Fixed
- Honor SGR 2 (dim) so faint text actually renders faint. The emulator
  was silently dropping the attribute, which left Claude Code's
  suggested-prompt placeholder rendering at normal intensity. SGR 22
  now correctly clears both bold and dim per spec.

## [0.1.1] - 2026-05-11

### Fixed
- `muxr --list` now reports sessions whose server is actually running
  (live sockets in `~/.muxr/sockets/`) instead of `~/.muxr/sessions/*.json`,
  which only exist after an explicit `:save` and so missed every live
  session. The saved-snapshot enumeration is still available internally
  via `Muxr::Session.list`.

## [0.1.0] - 2026-05-11

Initial release.

### Added
- Client/server architecture over a Unix domain socket at
  `~/.muxr/sockets/<name>.sock`. `Ctrl-a d` detaches the client; the
  server (and every shell it owns) keeps running, so reattaching gives
  back the exact same panes with full history.
- Ctrl-a prefix keybindings: `c` (new pane), `n`/`p` (next/prev),
  `a` (toggle last pane), `1`..`9` (jump to pane by label), `k` (close),
  `Tab` (cycle layout), `Enter` (promote to master), `~` (toggle drawer),
  `d` (detach), `q` (kill session with `y/n` confirm), `:` (command
  prompt), `?` (help), `C-a` (send literal `C-a`).
- Three layouts (`tall`, `grid`, `monocle`) implemented as pure functions
  of pane count and screen area.
- Quake-style drawer overlay with a persistent shell PTY that survives
  hide/toggle; `drawer reset` is the only way to kill it.
- Per-pane scrollback (bounded 5000-row ring) with `Ctrl-a [` copy-mode
  and vi-style navigation (`j`/`k`/`d`/`u`/`f`/`b`/Space/`g`/`G`).
- Visual selection inside scrollback: `v` for character, `C-v` for
  block; `y`/Enter yanks into an internal buffer and pipes to `pbcopy`.
  `Ctrl-a ]` pastes the yank buffer into the focused pane.
- Command prompt (`Ctrl-a :`): `layout`, `drawer`, `save`, `restore`,
  `sessions`/`ls`, `new`, `close`, `next`, `prev`, `master`, `detach`,
  `quit`.
- CLI flags: `--list`, `--version`, `--help`, `-s <name>`.
- Session persistence to `~/.muxr/sessions/<name>.json` as cold-storage
  fallback (the live session lives in the running server between
  detaches).
- Real VT100 emulator per pane: cursor movement, SGR (16-color,
  256-color, truecolor, underline subparameters and underline color),
  erase/insert/delete, autowrap, scroll regions, UTF-8 across PTY read
  boundaries.
- Renderer that composes one frame and diff-emits ANSI to STDOUT.

[Unreleased]: https://github.com/roelbondoc/muxr/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.4
[0.1.3]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.3
[0.1.2]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.2
[0.1.1]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.1
[0.1.0]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.0
