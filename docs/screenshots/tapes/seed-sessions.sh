#!/usr/bin/env bash
# Bring up two extra headless muxr servers inside the scratch HOME, each with a
# couple of panes, so the pane picker has something real to list.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

start() {
  local name="$1" dir="$2" panes="$3"
  (cd "$dir" && ruby "$repo/bin/muxr" --server "$name" >/dev/null 2>&1 &)
  local sock="$HOME/.muxr/sockets/$name.ctrl.sock"
  for _ in $(seq 40); do [ -S "$sock" ] && break; sleep 0.1; done
  ruby -rsocket -e '
    sock, extra = ARGV[0], ARGV[1].to_i
    s = UNIXSocket.new(sock)
    extra.times { s.puts(%({"id":1,"method":"pane.new"})); s.gets }
    s.close
  ' "$sock" "$panes"
}

cp "$repo"/lib/muxr/*.rb "$HOME/work/api/"

start api   "$HOME/work/api" 2
start notes "$HOME/notes"    1
