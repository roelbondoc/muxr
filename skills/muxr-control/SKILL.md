---
name: muxr-control
description: |
  Use when driving a muxr terminal session — running commands across panes,
  watching long-running processes, capturing terminal output, setting up
  layouts, working with the muxr drawer, or driving a full-screen TUI app
  (vim, a notebook, lazygit) that is already running inside a pane.
  Triggers when MUXR_SESSION is set in the environment, or when the user
  asks to "run X in pane Y", "what does pane N show", "drive the editor in
  pane 1", "switch the muxr layout", etc.
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

- The session name, current layout, the full `available_layouts` list, and
  the session dimensions.
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

### Wait for something already running

```
muxr_pane_run({ "pane": "a3f9b2", "input": "", "append_enter": false,
                "idle_ms": 1000, "timeout_ms": 30000 })
```

Useful when the user has already typed a command and you want to capture
its output once it finishes — but **only if output is still coming.**

The idle timer is gated on having seen output at all: `pane.run` resolves
early only once the pane has emitted *something* and then gone quiet. On a
pane that stays silent for the whole wait, the only exit is the deadline,
so the call blocks for the full `timeout_ms` and returns
`timed_out: true` — which looks like a failure but just means "nothing
happened." A 30s timeout on an already-finished command costs you 30s.

So for a pane that may already be quiet, **poll with `muxr_pane_read`
instead** — it returns instantly, has no side effects, and re-reading a
few times is cheaper than one mis-sized wait. Reserve `pane.run` for input
you expect to produce output.

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

## Driving a full-screen TUI app

A pane may hold a full-screen application (vim, euporie, lazygit, htop, a
TUI notebook) rather than a shell prompt. Everything below is about those;
shells are more forgiving.

### One key per call. Never batch repeats.

Both `pane.send_input` and `pane.run` concatenate the entire `keys` array
into one payload and hand it to the PTY in a **single write**, with no
pacing between keys. A shell's line editor handles that fine. An app that
kicks off async work per keypress often does not: sending
`["<c-r>", "<c-r>", … ]` nine times to a TUI notebook produced **three**
actions, not nine — the rest were swallowed while the app was mid-render.
Sending the same key one call at a time worked every time.

Batching is safe for a *heterogeneous* scripted sequence where each key
does something different and cheap:

```
muxr_pane_send_input({ "pane": "a3f9b2",
                       "keys": ["G", "o", "hello world", "<esc>", ":w", "<enter>"] })
```

Batching is **not** safe for "do this N times." Loop the call instead, and
confirm the app actually advanced between iterations (see below).

### The status bar is ground truth, not the layout

Infer app state from whatever the app *prints* about itself — the status
line, a mode indicator, an execution counter — never from where borders or
highlights appear to be drawn. Box-drawing and reverse-video regions are
easy to misread, and the cell/buffer/pane you think is selected is
routinely not the one you think. If the app tells you `Cell 9`, believe
that over a box that looks like it surrounds cell 8.

This is also how you verify the previous point: read the indicator, send
one key, re-read, confirm it moved.

### Use the `cursor` field to find focus in a dialog

`pane.read` and `pane.run` both return `cursor: {row, col}`. In a modal
dialog from prompt_toolkit, ncurses, and friends, the cursor parks on the
**focused widget** — so it is the reliable way to tell which of
`[ Yes ] [ No ] [ Cancel ]` is armed, when the rendered text gives you
nothing to go on.

The safe gesture for any dialog you did not expect:

1. `pane_read` — note `cursor`.
2. Send one `<tab>` or `<right>`.
3. Re-read and confirm the cursor **moved**.
4. Only then press `<enter>`.

Use cursor **deltas**, never absolute column arithmetic. `text` is trimmed
of trailing whitespace per row, and double-width glyphs (box-drawing,
block elements, emoji — heavily used by TUI dialogs) desync any attempt to
map a `col` onto an index into the row string. Two adjacent buttons in one
real dialog reported cols 63 and 75.

### Scroll with the app's own keys, not muxr scrollback

`pane.read` is viewport-only, and a full-screen app *owns* its viewport: it
paints one screenful and keeps the rest in its own internal buffer. Content
below the fold is invisible to `pane.read` **and** absent from muxr's
scrollback, because it was never emitted as scrolled-off terminal output.
`Ctrl-a [` will not find it.

So to see the rest, drive the app's own scroll binding (euporie `]`/`}`,
vim `Ctrl-d`, less `space`) and re-read. Corollary: a command's output can
be sitting in the pane, already complete, and still absent from your last
read — check the app's own indicator before concluding a step didn't run.

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

If the pane holds a full-screen app, `Ctrl-a [` won't help either — see
"Scroll with the app's own keys" above.

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

### Borrowed panes belong to another session

A pane the user attached from another muxr session (`A` / `C-a A`) shows
up in `muxr_panes_list` with an `"origin"` of `"<session>:<pane id>"`,
and in the pane title as `@work:6021b5`. It behaves like any other pane
for reads and input — those reach the real shell, in the session that
owns it — with two differences worth knowing:

- `muxr_pane_kill` only detaches the mirror. The shell keeps running in
  its home session. If the user asks you to kill it, say that's what
  happened rather than reporting the process gone.
- It can vanish without dying: if the owning session goes away, or the
  pane is moved somewhere else, it disappears from `muxr_panes_list`.
  Re-read the list rather than assuming a stale id.
- Its size is negotiated with the owner, so `muxr_layout_set` may not
  give it the dimensions you'd expect from the layout alone.

Anything you type there is visible to whoever is looking at the owning
session, live. Treat it the way you'd treat a shared screen.

A pane the user *moved* here (rather than shared) has no `origin` — it is
an ordinary local pane, even though the shell inside it has been running
since before it arrived. Don't assume a pane's history started in this
session.

### You are running in one of these panes

`MUXR_PANE` in your environment is the id of the pane hosting you. The
bridge refuses `muxr_pane_read`, `muxr_pane_send_input`, `muxr_pane_run`
and `muxr_pane_kill` on that id — driving your own pty feeds your output
back to you, and reading it just returns your own UI. Check `MUXR_PANE`
before picking a target, and don't try to route around the refusal by
re-running the command in a pane you then read; ask the user to open
another pane if you need somewhere to work.

### The drawer might be Claude itself

If the bridge sees the env var `MUXR_DRAWER_SELF=1` it refuses
`muxr_drawer_*` methods — that means the bridge is running *inside* the
muxr drawer and the call would recurse into your own pty. If you get
that error, that's why: you can still drive the surrounding tiled panes
normally, you just can't toggle/read the drawer that's hosting you.

### No tools at all means no session

If `muxr_*` tools aren't listed, this claude isn't inside muxr (or its
server isn't running). The bridge advertises nothing rather than failing
to start. Nothing to fix — just don't claim you can drive panes.

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
- `muxr error -32602: layout: unknown layout` — the ten valid layouts are
  `tall`, `wide`, `columns`, `rows`, `grid`, `spiral`, `centered`, `stack`,
  `monocle`, `auto`. `muxr_session_get` returns the live list in
  `available_layouts`; trust that over any list written down here.

## Naming muxr in conversation

When responding to the user, call panes by **slot first, id second**:
"pane #2 (a3f9b2) is showing the test failures." That matches what's on
their status bar and makes the id available for follow-up references.
