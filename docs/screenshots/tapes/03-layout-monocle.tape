# Monocle layout — focused pane fullscreen.
# Run from the repo root:  vhs docs/screenshots/tapes/03-layout-monocle.tape

Output docs/screenshots/tapes/.03-layout-monocle.gif

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 700
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms

Hide
Type "rm -f ~/.muxr/sockets/shot.sock ~/.muxr/sessions/shot.json"
Enter
Type "pkill -f 'muxr.*--server shot' 2>/dev/null; true"
Enter
Type "clear"
Enter
Sleep 400ms
Show

Type "bin/muxr shot"
Enter
Sleep 1800ms

Type "i"
Sleep 150ms
Type "ls -la lib/muxr/"
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 150ms

Type "c"
Sleep 800ms
Type "i"
Sleep 150ms
Type "git log --oneline -15"
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 150ms

Type "c"
Sleep 800ms
Type "i"
Sleep 150ms
Type "wc -l lib/muxr/*.rb | sort -n | tail -10"
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 150ms

# Monocle layout, master focused — only #1 is visible
Type "m"
Sleep 200ms
Type "1"
Sleep 600ms

Screenshot docs/screenshots/03-layout-monocle.png
