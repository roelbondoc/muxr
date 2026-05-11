# Changelog

All notable changes to muxr are documented here. The format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/roelbondoc/muxr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.0
