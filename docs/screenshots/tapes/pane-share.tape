Output docs/screenshots/tapes/.pane-share.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape
Source docs/screenshots/tapes/_others.tape

Type "bin/muxr shot"
Enter
Sleep 2000ms

Type "i"
Sleep 150ms
Type "git log --oneline --decorate -12"
Enter
Sleep 600ms
Ctrl+a
Escape
Sleep 200ms

Type "A"
Sleep 1200ms
Enter
Sleep 1500ms

Type "t"
Sleep 400ms
Type "i"
Sleep 150ms
Type "wc -l *.rb | sort -rn | head -8"
Enter
Sleep 800ms
Ctrl+a
Escape
Sleep 400ms

Screenshot docs/screenshots/pane-share.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
