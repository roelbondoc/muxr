---
name: muxr-control
description: |
  Use when driving a muxr terminal session — running commands across panes,
  watching long-running processes, capturing terminal output, setting up
  layouts, or working with the muxr drawer. Triggers when MUXR_SESSION is
  set in the environment, or when the user asks to "run X in pane Y",
  "what does pane N show", "switch the muxr layout", etc.
---

# muxr-control

You're driving a [muxr](https://github.com/roelbondoc/muxr) terminal
multiplexer session through its MCP bridge. muxr is a tiling terminal
multiplexer (think tmux + xmonad). Each pane is a real shell PTY; you can
read its current screen contents, send keystrokes, and wait for output to
settle — without taking control of the user's keyboard.

## First thing: ground yourself

Before doing anything else, call **`muxr_session_get`** and
**`muxr_panes_list`**. These are cheap, idempotent reads. They tell you:

- The session name, layout (tall / grid / monocle), and current dimensions.
- Each pane's stable id (6 hex chars, e.g. `a3f9b2`), its 1-based slot
  number as shown on screen (`#1`, `#2`, …), its cwd, and whether it's the
  focused or master pane.
- The `focused_pane` field in `session.get` tells you which pane the user
  was last looking at — if the user just said "run X" without naming a
  pane, that's the natural target.

## Pane identity: **always use the id, never the slot**

The status bar shows panes as `#1 a3f9b2`, `#2 c2e810`, etc. The number is
a *slot* — purely positional and tied to where the pane sits in the array.
The hex string is the *id* — generated once at pane creation and stable
forever.

Slots shift when panes are created, killed, or promoted to master. The id
never moves. **Every tool call that names a pane should pass the id.** If
the user says "the second pane", look it up in `muxr_panes_list` and pass
the id you find at slot 2 — don't pass `2` directly even though it works,
because by the time the call lands the slots may have changed.

## Recipes

### Run a command and get its output

```
muxr_pane_run({ "pane": "a3f9b2", "input": "ls -la" })
```

This sends `ls -la\r` to pane `a3f9b2`, waits for the PTY to go idle (no
output for 500ms by default), and returns the pane's full visible text
plus a `timed_out` flag.

**Always prefer `muxr_pane_run` over `muxr_pane_send_input` + a separate
`muxr_pane_read`.** The split version races — the read can fire before
the shell has redrawn the prompt, and you'll miss the output entirely.

### Tune `idle_ms` for the kind of command

- **Fast, simple commands** (`pwd`, `git status`): default 500ms is fine.
- **Bursty output** (test runners, builds): bump to `idle_ms: 800` or
  `1000`. Test runners often pause briefly between phases; a too-short
  idle window cuts off mid-run.
- **Interactive REPLs** that you want to type into without waiting for
  completion: use `muxr_pane_send_input` directly with `append_enter:
  false` — don't try to detect idleness on a REPL.
- **Long builds** (npm install, cargo build): bump `timeout_ms` to
  `120000` or higher. Default is 30s.

### Wait without sending anything

```
muxr_pane_run({ "pane": "a3f9b2", "input": "", "append_enter": false,
                "idle_ms": 1000, "timeout_ms": 30000 })
```

Useful when the user has already typed a command and you want to capture
its output once it finishes.

### Send multi-line input (paste mode)

```
muxr_pane_send_input({
  "pane": "a3f9b2",
  "data": "def hello\n  puts :world\nend\n",
  "bracketed": true
})
```

`bracketed: true` wraps the data in `\e[200~` / `\e[201~` so editors and
REPLs treat it as a single paste rather than N separate keystrokes (which
fires their auto-indent / autocomplete on every line).

### Look at the drawer without opening it

```
muxr_drawer_read({})
```

The drawer's shell process keeps running while hidden — its scrollback
survives. You can read it any time without disturbing the user's view.

### Set up a layout for a task

```
muxr_layout_set({ "layout": "tall" })
muxr_pane_new({})                              // create a second pane
muxr_pane_send_input({ "pane": "<new id>", "data": "npm run dev\n" })
```

Avoid doing this unsolicited — the human owns the layout. Only restructure
when the user explicitly asks ("set up a dev environment", "split this
into 3 panes").

## Gotchas

### Reading is cheap. Writing is destructive.

`muxr_pane_read`, `muxr_panes_list`, `muxr_drawer_read`, and
`muxr_session_get` have zero side effects — call them whenever you need
to ground yourself. **Mutating tools** (`muxr_pane_send_input`,
`muxr_pane_run`, `muxr_pane_kill`, `muxr_layout_set`, …) affect the
user's live session. Before calling any of them:

- Confirm the user named the specific pane you're about to act on (or
  agreed implicitly by saying "run X here").
- Double-check the id by reading `muxr_panes_list` if you haven't done so
  recently.
- **Never `muxr_pane_kill`** without the user explicitly saying "close
  pane X" — a pane often holds in-progress work that's not in any file.

### `pane.read` returns *visible* text only

The result is the pane's current 80×24-or-whatever grid, with trailing
whitespace trimmed per row. Lines that have scrolled into scrollback are
not in the response. If you need older output, ask the user to scroll
the pane up first (they have `Ctrl-a [` for scrollback mode), or watch
the pane via `muxr_pane_run` while the command is running.

### Private panes

The user can mark any pane *private* with `Ctrl-a P` (status bar shows
`[P]` after the pane id). Private panes appear in `muxr_panes_list` with
`"private": true` and *no* `cwd`/`rows`/`cols` — `muxr_pane_read`,
`muxr_pane_send_input`, `muxr_pane_run`, `muxr_pane_subscribe`, and
`muxr_pane_kill` all refuse with an error message that tells you the
human-side gesture to undo it.

When this happens: **do not retry**. Surface it to the user verbatim
("pane #2 a3f9b2 is private; press Ctrl-a P on it to expose it to me").
The privacy flag is intentionally one-way from MCP's perspective: there
is no `muxr_pane_unmark_private` tool.

`muxr_pane_focus` and `muxr_pane_promote` still work on private panes
(they're layout ops, not content ops) — useful if the user asks to
"bring my private pane to the front" without exposing it.

### The drawer might be Claude itself

If the bridge sees the env var `MUXR_DRAWER_SELF=1` it refuses
`muxr_drawer_*` methods — that means the bridge is running *inside* the
muxr drawer and the call would recurse into your own pty. If you get
that error, that's why: you can still drive the surrounding tiled panes
normally, you just can't toggle/read the drawer that's hosting you.

### Don't toggle the drawer just to peek

`muxr_drawer_read` works without showing the drawer. Toggling it to
look, then toggling back, is visible to the user as a flash of overlay
and is almost never what they wanted.

### Tool errors

If a tool call returns `isError: true`, the text usually starts with
`muxr error <code>: <message>`. Common ones:

- `muxr error -32602: pane: no pane with id "…"` — the pane has been
  killed, or you passed a stale id from before a kill/promote. Refetch
  `muxr_panes_list`.
- `muxr error -32602: layout: unknown layout` — valid layouts are
  `tall`, `grid`, `monocle`.

## Naming muxr in conversation

When responding to the user, call panes by **slot first, id second**:
"pane #2 (a3f9b2) is showing the test failures." That matches what's on
their status bar and makes the id available for follow-up references.
