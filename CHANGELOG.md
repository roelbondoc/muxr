# Changelog

All notable changes to muxr are documented here. The format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- A flash is visible again in the modes that actually raise one. The status
  bar's message branch was the last `elsif` in a chain starting with the
  command prompt and running through scrollback, search and selection, so any
  mode with a full-row overlay painted the row and the message never drew.
  "not found: <query>" from a failed search and "yanked N bytes" from a
  selection both land back in scrollback, where neither had ever been seen;
  the scroll-source work added four more that only fire there, which is why
  `Tab` on a pane with no scroll of its own read as a dead key rather than a
  refusal with a reason. The message now draws after the chain, right-aligned
  over the overlay — transient and specific beats a static key hint.

### Added
- A config file at `~/.muxr/config.json` (or wherever `MUXR_CONFIG`
  points) sets `layout`, `scrollback`, `master_ratio`, `master_count`,
  `auto_spiral_min` (`{"cols": 180, "rows": 30}`), `prefix` (`"C-b"` to use
  Ctrl-b instead of Ctrl-a), and `keys`, which remaps normal-mode and
  prefix-mode keys onto existing actions (`{"normal": {"Z": "toggle_zoom",
  "q": null}}`; `null` unbinds a key). Settings that don't make sense are
  skipped and reported: the first one is flashed when you attach, and all of
  them go to the session log. A saved session's layout still wins over the
  configured default, and `MUXR_SCROLLBACK` still wins over `scrollback`.
  `:reload` re-reads the file without restarting the server.
- `:rename <name>` gives the focused pane a label, shown in its title in
  place of the hex id (`#1 api`). A bare `:rename` clears it. Names are saved
  with the session, travel with a pane when it is moved to another session,
  appear in the attach picker, and are listed by `muxr_panes_list` (except
  for private panes). Any MCP tool that takes `pane` now also accepts a name.
  An id always wins over a name that happens to look like one, and a name
  shared by two panes is refused. The bridge's refusal to let a claude read
  or type into its own pane also applies when that pane is referred to by
  name.
- `:sync` sends what you type to every pane in the window at once. It works
  in passthrough mode, and `C-a ]` pastes go to every pane too. Use it to run
  the same command on several hosts or checkouts. `:sync on` / `:sync off`
  set it explicitly, and a bare `:sync` toggles it. While it is on, the
  status bar shows a red `[SYNC]` and every unfocused pane gets a red border,
  so you cannot forget it is on. Borrowed panes are included, and your
  keystrokes reach their real shells. The drawer is left out in both
  directions: typing in the drawer stays in the drawer. Sync is deliberately
  not saved with the session.
- `z` (or `C-a z`, or `:zoom`) zooms the focused pane to full screen, and
  pressing it again restores the layout you were in. The status bar reads
  `layout:zoom:tall` while zoomed, so you can see what `z` will return to.
  Picking any layout explicitly forgets the zoom. A session saved while
  zoomed saves the layout underneath.
- The master area can be resized and can hold more than one pane, the way
  it can in xmonad. `<` / `>` shrink or grow the master's share of the
  screen in 5% steps, between 10% and 90%. `,` / `.` take a pane out of the
  master area or add one to it, so two panes can share the master column.
  Both keys work in normal mode and after `C-a`, and both apply to `tall`,
  `wide` and `centered`. `:ratio 60` and `:masters 2` set them directly. The
  current shape is flashed on every change and saved with the session.
- `:silence <secs>` alerts you when the focused pane stops printing. Once
  the pane has been quiet for that long, muxr flashes `pane #2 silent for
  30s`, rings the outer terminal's bell, and marks the pane `~` in its title
  and in `alerts:`. It fires once per quiet spell and re-arms on the next
  output. It takes `30`, `30s` or `2m`. `:silence off` disarms it, and a bare
  `:silence` reports the current setting. An armed pane shows
  `[silence 30s]` in its title, and the threshold is saved with the session.
- Panes that want your attention are marked. A pane that rings the bell or
  sends an OSC 9 / OSC 777 notification while you are looking elsewhere gets
  a `!` after its number in the title (`#2!`), and one that prints anything
  gets a `•` (`#3•`). The status bar collects them as `alerts:2!,3•`. Both
  clear the moment the pane is focused. The pane you are looking at is never
  marked, unless no client is attached, in which case nobody is looking at
  it either. Output within 1.5 s of a pane being resized or created is not
  counted: every layout change sends SIGWINCH to every shell, and each one
  answers by redrawing its prompt, which would otherwise light up every pane
  on screen.
- Scrollback can now drive the program instead of muxr's ring. A pane whose
  program has turned on mouse tracking (DECSET 1000/1002/1003 — `lazygit`,
  `k9s`, `htop`) gets `C-a [` routed to *it*: muxr synthesises
  wheel reports at the centre of the pane and writes them into the pty, so
  `j`/`k`, `C-d`/`C-u` and `C-f`/`C-b` scroll the program's own transcript
  from the keyboard, no mouse involved. SGR encoding when the program asked
  for 1006, legacy X10 otherwise. A full-screen program that wants no mouse
  falls back to arrow keys, which is what `less` and `vim` respond to — so
  `C-a [` no longer dead-ends with "no history while a full-screen app is
  running" on an alternate-screen pane. `Tab` switches between the app's
  scroll and muxr's ring at any time, and the mode chip reads `SCROLL:APP`
  while the app has it. `Terminal` tracks the mouse modes and carries them in
  `dump_ansi`, so a mirrored or moved pane knows its program speaks mouse.
  Visual selection is clamped to the visible screen while the app is being
  scrolled: a self-scrolling program repaints in place, so the ring's tail no
  longer continues into row 0 and a selection spanning that seam would splice
  two unrelated regions into the paste buffer.
- The MCP bridge now reaches *any* claude started inside muxr, not just the
  one in the Claude drawer. `MUXR_SESSION` and `MUXR_CONTROL_SOCKET` are
  injected into every PTY muxr spawns, so with the bridge registered once at
  user scope (`claude mcp add muxr muxr-mcp --scope user`) a claude launched
  from an ordinary pane is already wired to the session around it. Each
  pane's shell also carries `MUXR_PANE`, its own id: the bridge refuses
  `pane.read`, `pane.send_input`, `pane.run` and `pane.kill` against that
  pane, since driving your own pty feeds your output back to you — the pane
  equivalent of the drawer's `MUXR_DRAWER_SELF` guard. Panes that predate the
  upgrade need reopening to pick the vars up.
- The bridge follows its pane across a move. Those env vars are a snapshot of
  where the pane was when its shell started, and moving a pane to another
  session leaves them naming the old one — a running process's environment
  cannot be rewritten from outside. When the session the env names no longer
  lists `MUXR_PANE` among its own panes, the bridge asks the other control
  sockets in the same directory which of them owns it and connects there
  instead, re-checking on a ten-second TTL so a pane moved out from under a
  running claude is followed rather than left driving its old session. A
  mirrored pane carries `origin` and is never mistaken for the owner.
- Attach a pane from another muxr session: `A` (or `C-a A`, or `:attach`)
  opens a picker listing every pane the other live servers on this machine
  are willing to share, grouped by session. The chosen pane is *shared, not
  moved* — it keeps running where it is, both sessions show the same live
  shell, and either can type into it. The owner keeps the PTY and remains
  its only reader; what crosses the control socket is the raw byte stream
  and keystrokes, so colors, the alternate screen and full-screen TUIs all
  mirror faithfully. The PTY runs at the smallest viewport looking at it so
  it fits both layouts. If the owning session stops, the borrower drops the
  pane; if the borrower stops, only the mirror goes away and the pane
  carries on at home. Private panes are never offered, and borrowed panes
  are left out of `:save`. New control methods: `pane.mirror`,
  `pane.mirror_resize`, `pane.unmirror`, `pane.redraw`; `pane.send_input`
  and `pane.run` now also accept `base64: true` payloads.
- Move a pane between sessions for real, with `m` in the same picker. The
  master pty file descriptor crosses the socket via `SCM_RIGHTS`, so the
  same shell process keeps running — environment, background jobs, screen
  and full scrollback intact — and simply belongs to the receiving session
  afterwards, as an ordinary local pane. The handoff is two-phase: nothing
  is torn down until the receiver confirms it has a working pane, a failure
  anywhere leaves the pane where it was, and an abandoned move times out
  after ten seconds instead of pausing the pane forever. muxr refuses to
  move the last pane out of a session (it would shut that session down) or
  to move on a pane that is itself borrowed. Sessions mirroring a pane that
  moves away are told it is gone and detach. New control methods:
  `pane.move`, `pane.move_commit`, `pane.move_abort`.
- Kitty graphics protocol images are saved to `~/.muxr/images` and
  announced in the pane as a clickable `file://` path (OSC 8) instead of
  being drawn. muxr renders a cell grid and has nowhere to put pixels, so
  `[image 640×480 → ~/.muxr/images/…png]` is the honest rendering —
  Cmd-click opens it. Multi-chunk (`m=1`) transmissions are reassembled,
  `t=f`/`t=t` file transmissions are read from disk, and raw `f=24`/`f=32`
  pixel data is re-encoded into a PNG container so the saved file is
  actually openable. A capability query (`a=q`) is answered `OK` so inner
  programs pick the kitty path instead of falling back to sixel. The store
  keeps the 200 most recent images.
- A project page at https://roelbondoc.github.io/muxr/, served from `docs/`.
  Its layout playground runs a port of `LayoutManager` in the browser, so
  pressing muxr's own layout and `hjkl` keys tiles with the real algorithm.
  A **Screen** control switches the simulated terminal between 132×38 and
  220×54 so `auto` can be seen changing its mind.
- An `auto` layout (`F`, or `:layout auto`) that picks its geometry from the
  screen it is on: `spiral` once the content area is at least 180×30,
  `stack` below that. It is a resolver rather than a tenth geometry —
  `LayoutManager.resolve` maps it to a real layout and `compute` resolves
  before dispatching, so nothing downstream sees `:auto`. No new size
  plumbing: SIGWINCH already reaches the server as a `RESIZE` frame, so
  detaching onto a laptop or plugging in a monitor re-resolves on the next
  frame. The status bar names the verdict, e.g. `layout:auto:stack`.

- The alternate screen buffer (DECSET 47/1047/1049, and 1048 for its cursor
  slot). A full-screen program — a pager, an editor, `fzf` — now draws on a
  grid of its own, and the screen it covered is set aside untouched until it
  exits. Nothing drawn there reaches scrollback and the view offset is pinned
  to the live screen, so there is nothing to page into; scrollback declines to
  open on such a pane, and a pane that enters an alternate screen under a
  reader drops them out of the mode. `Terminal#dump_ansi` leads with a repaint
  of the covered screen, so a mirrored or moved pane carries both grids and
  quitting the pager on the far side uncovers the same shell it uncovers at
  home.
- `MUXR_SCROLLBACK` sets the scrollback depth at server start, clamped to a
  sane range.

### Changed
- `muxr-mcp` no longer exits when it can't find a muxr session. Registering
  it at user scope loads it into every claude on the machine, most of which
  are nowhere near a muxr, and exiting surfaced a failed MCP server in all of
  them. It now completes the handshake, advertises no tools when there is no
  session to talk to, and says so if called anyway. The socket is opened on
  first use rather than at startup and reopened if it drops, so a claude
  running in a pane survives a restart of the session around it.
- `auto` is the default layout for new windows (was `spiral`). Saved
  sessions are unaffected.
- Scrollback holds 50,000 rows per pane by default, up from 5,000. Rows are
  now stored packed — one string of characters plus run-length attributes,
  trimmed to their content and materialized into cells only when read — which
  cut a filled ring from ~330 MB of resident memory per pane to ~12 MB at
  20,000 rows and made the deeper default affordable. Search and the transfer
  serializer read the packed bytes directly, so `/` over a full 50,000-row
  ring completes in tens of milliseconds.

### Fixed
- The help overlay claimed `C-a t w g m` set layouts and `muxr --help`
  claimed `C-a k` closed a pane. Neither binding exists: layout keys are
  normal-mode only, and close is `C-a x`.
- `--list` and `:sessions` no longer report a phantom `<name>.ctrl`
  session. Both enumerated `~/.muxr/sockets/*.sock`, which also matches
  the sibling control socket `<name>.ctrl.sock`.
- A pane whose grid is larger than the box drawn for it is now clipped to
  the box instead of painting over its own border. Only reachable with a
  borrowed pane, whose geometry belongs to another session.
- Paging through a full-screen program no longer destroys scrollback. Without
  an alternate screen buffer, a pager drew straight onto the primary grid and
  every page-down pushed a screenful of its own frames into history, evicting
  real output at the ring's cap — twenty page-downs of `less` cost 232 rows —
  and quitting left the program's last frame on screen instead of uncovering
  the shell.
- APC (`ESC _ … ST`) and DCS/SOS/PM (`ESC P`/`ESC X`/`ESC ^`) string
  sequences are now consumed by the parser. Previously neither had a
  parser state: the introducer was swallowed and the entire body printed
  into the grid as text, so any program emitting kitty graphics or sixel
  sprayed kilobytes of base64 across the pane.

## [0.1.11] - 2026-06-11

### Added
- Wide (CJK/emoji) and combining character support in the emulator.
  `Terminal.char_width` classifies codepoints as 0/1/2 columns; a width-2
  glyph occupies a lead cell plus an empty continuation cell, and
  zero-width marks fold onto the preceding cell. Search highlights and
  synthetic URL hyperlinks stay aligned on rows containing wide or
  combining glyphs.
- `r` / `Ctrl-a r` refresh keybinding: a SIGWINCH winsize-wiggle nudges
  the focused program to repaint itself, and a forced full re-emit
  repaints the outer terminal — recovering from display drift whichever
  layer is at fault.
- Scrollback is now pane-bound: `Ctrl-a` works from inside scrollback
  and selection so pane-switch bindings work without leaving the mode,
  focus returning to a scrolled-back pane resumes where you were
  reading, yank returns to scrollback instead of snapping to the live
  bottom, and `i` drops into insert without losing your place.
- Opt-in `MUXR_TRACE_OUTPUT` tap: when the env var names a writable
  path, the server appends every byte it sends to the client, so a
  rendering bug can be reproduced from the byte stream alone.

### Fixed
- The diff renderer now forces an absolute cursor move after
  width-ambiguous glyphs (East Asian Ambiguous symbols, CJK, emoji)
  instead of trusting cursor contiguity, so a width disagreement with
  the outer terminal clips a single glyph rather than shifting the
  entire rest of the line — the "text doesn't line up until I resize"
  bug. Verified against pyte as a reference emulator.
- Bracketed-paste markers (`\e[200~`/`\e[201~`) are stripped before
  writing to panes whose program never enabled the mode, so pastes no
  longer show literal `^[[200~` text; programs that did enable it still
  receive the markers, and markers split across read boundaries are
  recombined.

### Changed
- `spiral` is the default layout for new windows (was `tall`). Saved
  sessions are unaffected.
- New panes and the drawer start in the session origin cwd — the
  directory `bin/muxr` was launched from — instead of the focused
  pane's live cwd. Explicit cwds (MCP `panes.create`, restored
  sessions) still win, and pane creation no longer pays the synchronous
  ~100–300ms `lsof` call on macOS.

## [0.1.10] - 2026-05-29

### Added
- Six new layouts join `tall`, `grid`, and `monocle`:
  - **`wide`** (`w`) — master on top, slaves split across the bottom.
  - **`columns`** (`|`) — equal-width, full-height vertical strips.
  - **`rows`** (`-`) — equal-height, full-width horizontal strips.
  - **`spiral`** (`f`) — Fibonacci spiral winding inward, each pane half
    the size of the last.
  - **`centered`** (`e`) — master in a centred column with slaves dealt
    to both sides.
  - **`stack`** (`S`) — accordion: the focused pane expands while the
    others collapse to title slivers.
  The `:layout` command resolves any unambiguous name prefix across all
  nine layouts; `C-a Tab` / `Tab` cycles through them in order. README
  screenshots cover every layout.

## [0.1.9] - 2026-05-29

### Added
- `:layout` accepts short-form prefixes — `:layout t` / `g` / `m` map to
  tall / grid / monocle via prefix matching. Full names still work; an
  ambiguous prefix flashes the candidate layouts.
- README screenshots are now generated by [VHS](https://github.com/charmbracelet/vhs)
  tapes under `docs/screenshots/tapes/`, regenerated with a single
  `regenerate.sh` run. New captures cover scrollback `/` search and
  movable-cursor visual selection.

### Documentation
- Documented that wrapped plain-text URLs are stamped with OSC 8
  hyperlink ids (the 0.1.8 feature) in the README architecture section.

## [0.1.8] - 2026-05-22

### Added
- Wrapped plain-text URLs are stamped with a shared OSC 8 hyperlink id
  after each `Terminal#feed`. The Terminal scans the live buffer plus
  the last scrollback row for `http`/`https`/`ftp` URLs and tags the
  covering cells with `id=muxr-url-<hash>` so Ghostty / iTerm2 / kitty /
  WezTerm merge the wrapped halves into a single clickable link.
  Program-emitted OSC 8 payloads continue to pass through unchanged.

### Changed
- Selection mode now anchors at the live cursor's visible position
  instead of `(0,0)`, so visual selection starts where the user's
  attention already is.

## [0.1.7] - 2026-05-20

### Added
- Scrollback search via `/` (forward) and `?` (backward). Enter commits
  the query, `n` / `N` cycle through matches with wrap. Smart-case
  matching scans both scrollback and the live buffer; the chosen match
  is centered in the viewport and every match is highlighted in yellow
  until the user exits scrollback.
- Arrow / page keys in scrollback. `↑`/`↓` scroll a line, `PgUp`/`PgDn`
  half-page, `Home`/`End` jump to top/bottom. `InputHandler#feed` now
  peeks for CSI escape sequences so a bare `Esc` still exits scrollback
  the way it always has.
- Shift-`H`/`J`/`K`/`L` swaps the focused pane with the spatial
  neighbor in that direction (linear next/prev fallback in monocle).
  Focus tracks the moved pane so you can keep dragging it; swapping
  into position 0 of tall/grid promotes it to master.

### Changed
- Pane close is now confirmed. The close binding moved from `K` to
  `x` (in both normal mode and the Ctrl-a prefix) so shift-`HJKL` is
  free for the new move action. Close routes through a `:confirm_close`
  state that flashes `close pane? (y/n)` — drawer hide stays
  prompt-free since it's reversible.

## [0.1.6] - 2026-05-15

### Added
- Vim-style `:normal` mode as the default startup state. Single keys
  (hjkl, c, K, t/g/m, s, etc.) act directly without the Ctrl-a prefix;
  `i` drops into the historical `:passthrough` mode and `Ctrl-a Esc`
  returns to normal.
- Spatial hjkl navigation via a new `LayoutManager.neighbor` that
  computes pane adjacency from layout rects, so focus moves the way the
  eye expects in tall and grid layouts (monocle falls back to linear).
- `[MODE]` chip rendered in the top-right corner of the focused
  container, plus a per-mode color palette on the focused pane border
  and status chip (cyan normal, green passthrough, orange scrollback,
  magenta selection, yellow command, red quit-confirm, blue help). The
  `:prefix` substate shares the passthrough green so the border doesn't
  flicker when Ctrl-a is pressed.
- Foreground-command annotation in pane titles. A 750ms background
  poller (`Application#start_foreground_poller`) walks each pane's
  foreground process group and stamps the name onto
  `pane.foreground_command`; titles now read `#1 abc123 · npm test`
  when the shell isn't itself in the foreground. Lookup goes through
  `/proc/<pid>/stat` on Linux and `ps` on macOS, off the event loop.
- OSC 8 hyperlink passthrough. The Terminal buffers OSC payloads,
  extracts OSC 8 link bodies (interned per terminal), and stamps the
  active link onto every cell. The Renderer carries hyperlink through
  its Cell struct and wraps each contiguous run with one open/close
  pair, so Ghostty et al. treat a wrapped URL as one clickable link.
- Space as a thumb-friendly alias for `v` in selection mode (toggle
  linear anchor).

### Changed
- Focused pane title now shows the mode label
  (`[NORMAL]`/`[PASS]`/etc.) instead of the redundant layout name —
  the status bar already shows the active layout.
- `[MODE]` chip moved out of the title and into the top-right corner
  of the focused container, freeing the left-side title for the
  foreground command.
- Dropped the old `space → page-down` mapping in scrollback so space
  is available for the new selection-mode alias.

### Fixed
- Exiting scrollback now restores the previous base mode (normal or
  passthrough) instead of always landing in normal. A
  passthrough → scrollback → exit round-trip now leaves you back in
  passthrough.

## [0.1.5] - 2026-05-13

### Added
- MCP (Model Context Protocol) integration so Claude Code can drive a
  muxr session as a tool. A second listener at
  `~/.muxr/sockets/<name>.ctrl.sock` accepts multiple concurrent NDJSON
  clients and exposes read-only and mutating methods over a small
  JSON-RPC surface (`session.get`, `panes.list`, `pane.read`,
  `pane.send_input`, `pane.run`, `pane.subscribe`, `layout.set`,
  `drawer.*`, etc.). The control socket does not interfere with TTY
  attach — programmatic clients never count as "attached", so a Claude
  session and a human can use the multiplexer concurrently.
- `pane.run` waits for the PTY to go idle before responding. Sends the
  input, polls for output, and returns once no bytes have arrived for
  `idle_ms` (default 500). Server-side idle detection avoids the
  send-then-poll race that plagues naive client-side automation.
- Stable per-pane ids: every pane carries a 6-hex `SecureRandom` id that
  survives splits, kills, promote_to_master, detach/reattach, and
  cold-restart from the session JSON. The status bar now reads
  `#1 a3f9b2` so users see both the slot (positional, what `Ctrl-a 1`
  targets) and the id (stable, what the MCP client should reference).
- `bin/muxr-mcp` — standalone MCP-over-stdio bridge that translates
  Claude Code tool calls into NDJSON requests on the control socket.
  Auto-detects the target session from `MUXR_CONTROL_SOCKET` or
  `MUXR_SESSION` env vars.
- `Ctrl-a C` (also `:claude`) opens a drawer whose shell is `claude`,
  with `MUXR_SESSION`, `MUXR_CONTROL_SOCKET`, `MUXR_FOCUSED_PANE`, and
  `MUXR_DRAWER_SELF=1` injected into its environment. The bridge picks
  those up automatically; the human gets a Quake-style Claude Code
  overlay that already knows what session it's in. The
  `MUXR_DRAWER_SELF` guard makes the bridge refuse `drawer.*` methods
  so a claude drawer can't recurse into its own PTY.
- Private panes (`Ctrl-a P` / `:private`) hide a pane from programmatic
  callers: `panes.list` strips cwd/rows/cols, and `pane.read`,
  `pane.send_input`, `pane.run`, `pane.subscribe`, and `pane.kill`
  refuse with an error message pointing the human at `Ctrl-a P` to
  expose it. The flag is persisted in session JSON, shown as `[P]` in
  the status bar, and intentionally one-way — there is no control
  method to flip it.
- Named keys on `pane.send_input`, `pane.run`, and `drawer.send_input`.
  A `keys` array accepts vim-style `<name>` tokens (`<esc>`, `<c-c>`,
  `<cr>`, arrows, etc.) interleaved with literal text, so MCP callers
  no longer have to remember that Escape is `"\e"` and Ctrl-C is
  `"\x03"`. Bracketed-paste wrapping still applies to literal segments
  only.
- Skill bundle at `skills/muxr-control/SKILL.md` teaching Claude how to
  drive muxr via the MCP. Installable via `muxr --install-skill`, which
  copies the skill into `~/.claude/skills/muxr-control` (survives
  `gem update`) and prints the `claude mcp add` registration line.

### Fixed
- Honor DSR cursor-position queries (`\e[5n`, `\e[6n`). The Terminal
  emulator now buffers a `\e[0n` OK reply or a `\e[<row>;<col>R` CPR
  reply into a pending-replies queue; the Pane drains it back through
  the PTY input side after each feed. AWS CLI and other programs that
  probe geometry this way no longer log "your terminal doesn't support
  cursor position requests (CPR)" and fall back to a degraded mode.
- Drawer height now has a floor of 16 rows. The old 35%-of-screen rule
  degraded badly on short terminals — a 24-row terminal gave only ~8
  rows of drawer, barely enough for one prompt and a few lines of
  output. The 35% growth still applies above the floor, so tall
  terminals are unaffected.

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

[Unreleased]: https://github.com/roelbondoc/muxr/compare/v0.1.11...HEAD
[0.1.11]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.11
[0.1.10]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.10
[0.1.9]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.9
[0.1.8]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.8
[0.1.7]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.7
[0.1.6]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.6
[0.1.5]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.5
[0.1.4]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.4
[0.1.3]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.3
[0.1.2]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.2
[0.1.1]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.1
[0.1.0]: https://github.com/roelbondoc/muxr/releases/tag/v0.1.0
