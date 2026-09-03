Output docs/screenshots/tapes/.scrollback-search.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape

Type "bin/muxr shot"
Enter
Sleep 2000ms

Type "i"
Sleep 150ms
Type "git log --oneline --decorate -60"
Enter
Sleep 900ms
Ctrl+a
Escape
Sleep 200ms

Type "m"
Sleep 300ms

Type "s"
Sleep 400ms
Type "g"
Sleep 300ms
Type "/Merge"
Sleep 300ms
Enter
Sleep 800ms

Screenshot docs/screenshots/scrollback-search.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
