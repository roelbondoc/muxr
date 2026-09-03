Output docs/screenshots/tapes/.images.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape

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
Type "ruby docs/screenshots/tapes/kitty-image.rb"
Enter
Sleep 1500ms
Type "ruby docs/screenshots/tapes/kitty-image.rb"
Enter
Sleep 1500ms
Ctrl+a
Escape
Sleep 200ms

Type "2"
Sleep 200ms
Type "i"
Sleep 150ms
Type "ls -lh ~/.muxr/images | tail -6"
Enter
Sleep 700ms
Ctrl+a
Escape
Sleep 200ms

Type "1"
Sleep 500ms

Screenshot docs/screenshots/images.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
