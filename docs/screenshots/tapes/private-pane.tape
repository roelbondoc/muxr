Output docs/screenshots/tapes/.private-pane.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape

Type "bin/muxr shot"
Enter
Sleep 2000ms

Type "c"
Sleep 700ms
Type "c"
Sleep 700ms
Type "g"
Sleep 400ms

Type "1"
Sleep 200ms
Type "i"
Sleep 150ms
Type "git log --oneline -8"
Enter
Sleep 600ms
Ctrl+a
Escape
Sleep 200ms

Type "2"
Sleep 200ms
Type "i"
Sleep 150ms
Type "ls -la ~ && cat ~/.bashrc"
Enter
Sleep 600ms
Ctrl+a
Escape
Sleep 200ms

Type "3"
Sleep 200ms
Type "i"
Sleep 150ms
Type "wc -l lib/muxr/*.rb | sort -rn | head -8"
Enter
Sleep 600ms
Ctrl+a
Escape
Sleep 200ms

Type "2"
Sleep 300ms
Type "P"
Sleep 900ms

Screenshot docs/screenshots/private-pane.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
