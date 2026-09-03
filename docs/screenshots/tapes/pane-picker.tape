Output docs/screenshots/tapes/.pane-picker.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape
Source docs/screenshots/tapes/_others.tape

Type "bin/muxr shot"
Enter
Sleep 2000ms

Type "c"
Sleep 700ms
Type "w"
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

Type "A"
Sleep 1200ms
Type "j"
Sleep 600ms

Screenshot docs/screenshots/pane-picker.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
