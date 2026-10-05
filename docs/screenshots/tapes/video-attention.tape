Output docs/screenshots/tapes/.video-attention.gif
Set Width 1200
Set Height 720
Source docs/screenshots/tapes/_common.tape
Source docs/screenshots/tapes/_video.tape
Type "bin/muxr --record docs/media/attention.cast shot"
Enter
Sleep 2000ms
Type "c"
Sleep 600ms
Type "c"
Sleep 600ms
Type "g"
Sleep 600ms
Type "2"
Sleep 400ms
Type "i"
Sleep 300ms
Type `sleep 3; printf '\a'; echo done`
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 500ms
Type "3"
Sleep 400ms
Type "i"
Sleep 300ms
Type "for i in 1 2 3; do sleep 1; echo tick $i; done"
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 500ms
Type "1"
Sleep 4500ms
Type "2"
Sleep 1500ms
Type "1"
Sleep 600ms
Type ":sync"
Sleep 400ms
Enter
Sleep 1500ms
Type "i"
Sleep 300ms
Type "echo same keys, pane $MUXR_PANE"
Enter
Sleep 1500ms
Ctrl+a
Escape
Sleep 500ms
Type ":sync"
Sleep 400ms
Enter
Sleep 1500ms
Sleep 1500ms
Type "d"
Sleep 1s
