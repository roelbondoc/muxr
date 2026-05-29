# Selection / copy-mode — movable-cursor visual selection (magenta border).
# Run from the repo root:  vhs docs/screenshots/tapes/06-selection.tape

Output docs/screenshots/tapes/.06-selection.gif

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

# Give the pane some content worth selecting.
Type "i"
Sleep 150ms
Type "git log --oneline -20"
Enter
Sleep 600ms
Ctrl+a
Escape
Sleep 150ms

# Monocle so the focused pane fills the screen.
Type "m"
Sleep 300ms

# Enter scrollback, then `v` to drop a movable cursor (magenta border).
# The cursor starts at the live cursor; walk it up and to the end of the
# line to sweep a multi-line character selection.
Type "s"
Sleep 400ms
Type "v"
Sleep 300ms
Type "kkkkkk"
Sleep 300ms
Type "$"
Sleep 700ms

Screenshot docs/screenshots/06-selection.png
