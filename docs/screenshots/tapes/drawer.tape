Output docs/screenshots/tapes/.drawer.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape

Type "bin/muxr shot"
Enter
Sleep 2000ms

Source docs/screenshots/tapes/_panes-create.tape

Type "g"
Sleep 500ms

Source docs/screenshots/tapes/_panes-fill.tape

Type "~"
Sleep 1200ms
Type "i"
Sleep 300ms
Type "git diff --stat HEAD~5 | tail -8"
Enter
Sleep 900ms
Ctrl+a
Escape
Sleep 300ms

Screenshot docs/screenshots/drawer.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
