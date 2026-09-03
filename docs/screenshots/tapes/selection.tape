Output docs/screenshots/tapes/.selection.gif
Set Width 1200
Set Height 760
Source docs/screenshots/tapes/_common.tape

Type "bin/muxr shot"
Enter
Sleep 2000ms

Type "i"
Sleep 150ms
Type "wc -l lib/muxr/*.rb | sort -rn"
Enter
Sleep 700ms
Ctrl+a
Escape
Sleep 200ms

Type "m"
Sleep 300ms

# s enters scrollback, the first v gives the movable cursor, the second v
# drops the anchor; everything swept after that highlights.
Type "s"
Sleep 400ms
Type "v"
Sleep 400ms
Type "g"
Sleep 200ms
Type "jjjj"
Sleep 200ms
Type "^"
Sleep 200ms
Type "v"
Sleep 400ms
Type "jjjjj"
Sleep 200ms
Type "$"
Sleep 700ms

Screenshot docs/screenshots/selection.png

# VHS flushes a Screenshot only once another command follows it.
Sleep 1s
