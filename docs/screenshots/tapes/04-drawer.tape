# Drawer overlay — Quake-style drop-down shell, opens from the bottom.
# Run from the repo root:  vhs docs/screenshots/tapes/04-drawer.tape

Output docs/screenshots/tapes/.04-drawer.gif

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
Type "ls -la lib/muxr/ | head -20"
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

Type "t"
Sleep 200ms
Type "1"
Sleep 200ms

# Open the drawer and run a quick command in it
Type "~"
Sleep 600ms
Type "i"
Sleep 150ms
Type "echo 'drawer: persistent overlay shell'; pwd"
Enter
Sleep 500ms
Ctrl+a
Escape
Sleep 200ms

Screenshot docs/screenshots/04-drawer.png
