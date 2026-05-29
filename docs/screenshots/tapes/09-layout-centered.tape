# Centered layout — master in a centred column, slaves dealt to both sides.
# Run from the repo root:  vhs docs/screenshots/tapes/09-layout-centered.tape

Output docs/screenshots/tapes/.09-layout-centered.gif

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

Type "c"
Sleep 800ms
Type "i"
Sleep 150ms
Type "cat lib/muxr/layout_manager.rb | head -40"
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 150ms

Type "c"
Sleep 800ms
Type "i"
Sleep 150ms
Type "ruby -v; echo muxr"
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 150ms

Type "e"
Sleep 200ms
Type "1"
Sleep 600ms

Screenshot docs/screenshots/09-layout-centered.png
