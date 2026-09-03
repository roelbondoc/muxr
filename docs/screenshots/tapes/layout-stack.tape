Output docs/screenshots/tapes/.layout-stack.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape

Type "bin/muxr shot"
Enter
Sleep 2000ms

Source docs/screenshots/tapes/_panes-create.tape

Type "S"
Sleep 500ms

Source docs/screenshots/tapes/_panes-fill.tape

Type "i"
Sleep 150ms
Type "git log --oneline --decorate -10"
Enter
Sleep 600ms
Ctrl+a
Escape
Sleep 500ms

Screenshot docs/screenshots/layout-stack.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
