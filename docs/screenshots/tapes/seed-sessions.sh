#!/usr/bin/env bash
# Bring up two extra headless muxr servers inside the scratch HOME, each with a
# couple of panes, so the pane picker has something real to list.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

start() {
  local name="$1" dir="$2"
  (cd "$dir" && ruby "$repo/bin/muxr" --server "$name" >/dev/null 2>&1 &)
  local sock="$HOME/.muxr/sockets/$name.ctrl.sock"
  for _ in $(seq 40); do [ -S "$sock" ] && break; sleep 0.1; done
  ruby "$repo/docs/screenshots/tapes/seed-panes.rb" "$sock" "$name"
}

cp "$repo"/lib/muxr/*.rb "$HOME/work/api/"

start api   "$HOME/work/api"
start notes "$HOME/notes"
