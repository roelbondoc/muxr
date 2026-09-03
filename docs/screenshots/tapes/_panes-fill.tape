Type "1"
Sleep 200ms
Type "i"
Sleep 150ms
Type "git log --oneline --decorate -12"
Enter
Sleep 500ms
Ctrl+a
Escape
Sleep 150ms

Type "2"
Sleep 200ms
Type "i"
Sleep 150ms
Type "wc -l lib/muxr/*.rb | sort -rn | head -12"
Enter
Sleep 500ms
Ctrl+a
Escape
Sleep 150ms

Type "3"
Sleep 200ms
Type "i"
Sleep 150ms
Type "ruby -Ilib -Itest test/test_layout_manager.rb"
Enter
Sleep 2500ms
Ctrl+a
Escape
Sleep 150ms

Type "4"
Sleep 200ms
Type "i"
Sleep 150ms
Type "ls lib/muxr"
Enter
Sleep 400ms
Ctrl+a
Escape
Sleep 150ms

Type "5"
Sleep 200ms
Type "i"
Sleep 150ms
Type "ruby -v && bin/muxr --version"
Enter
Sleep 900ms
Ctrl+a
Escape
Sleep 150ms

Type "1"
Sleep 700ms
