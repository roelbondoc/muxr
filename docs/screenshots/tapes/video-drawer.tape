Output docs/screenshots/tapes/.video-drawer.gif
Set Width 1200
Set Height 720
Source docs/screenshots/tapes/_common.tape
Source docs/screenshots/tapes/_video.tape
Type "bin/muxr --record docs/media/drawer.cast shot"
Enter
Sleep 2000ms
Type "c"
Sleep 600ms
Type "c"
Sleep 600ms
Type "g"
Sleep 600ms
Type "1"
Sleep 400ms
Type "i"
Sleep 300ms
Type "git log --oneline -12"
Enter
Sleep 800ms
Ctrl+a
Escape
Sleep 500ms
Type "2"
Sleep 400ms
Type "i"
Sleep 300ms
Type "ls lib/muxr"
Enter
Sleep 800ms
Ctrl+a
Escape
Sleep 500ms
Type "~"
Sleep 1200ms
Type "i"
Sleep 300ms
Type "wc -l lib/muxr/*.rb | tail -1; git log -3 --format='%h %ar  %s'"
Enter
Sleep 1200ms
Ctrl+a
Escape
Sleep 500ms
Type "~"
Sleep 1500ms
Type "~"
Sleep 1800ms
Type "~"
Sleep 1500ms
Sleep 1500ms
Type "d"
Sleep 1s
