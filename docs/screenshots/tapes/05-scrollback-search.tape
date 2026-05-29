# Scrollback search — vi-style copy-mode with `/` search highlighting.
# Run from the repo root:  vhs docs/screenshots/tapes/05-scrollback-search.tape

Output docs/screenshots/tapes/.05-scrollback-search.gif

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 700
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms

Hide
Type "rm -f ~/.muxr/sockets/shot.sock ~/.muxr/sessions/shot.json"
Enter
Type "pkill -f 'muxr.*--server shot' 2>/dev/null; true"
Enter
Type "clear"
Enter
Sleep 400ms
Show

Type "bin/muxr shot"
Enter
Sleep 1800ms

# Fill the pane with a long, searchable history.
Type "i"
Sleep 150ms
Type "git log --oneline -40"
Enter
Sleep 600ms
Ctrl+a
Escape
Sleep 150ms

# Monocle so the focused pane fills the screen.
Type "m"
Sleep 300ms

# Enter scrollback (orange border + key hint), jump to the top, then
# search forward for "Bump" — every match highlights in yellow and the
# chosen one is centered in the viewport.
Type "s"
Sleep 400ms
Type "g"
Sleep 300ms
Type "/Bump"
Sleep 300ms
Enter
Sleep 700ms

Screenshot docs/screenshots/05-scrollback-search.png
