#!/usr/bin/env bash
# Regenerate every README / project-page screenshot and video using VHS.
#
# Requires:  vhs and agg (brew install vhs agg)
# Run from anywhere — the script cd's to the repo root.

set -euo pipefail

cd "$(dirname "$0")/../../.."

cleanup() {
  pkill -f "muxr.*--server shot"  2>/dev/null || true
  pkill -f "muxr.*--server api"   2>/dev/null || true
  pkill -f "muxr.*--server notes" 2>/dev/null || true
  pkill -f "muxr.*--server .*screenshot-home" 2>/dev/null || true
  rm -f docs/screenshots/tapes/.*.gif
}
trap cleanup EXIT

THEME="1e1e2e,cdd6f4,45475a,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,bac2de,585b70,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,a6adc8"

if [ "$#" -gt 0 ]; then
  tapes=()
  for name in "$@"; do tapes+=("docs/screenshots/tapes/${name%.tape}.tape"); done
else
  # Tapes starting with "_" are shared fragments pulled in via `Source`.
  tapes=(docs/screenshots/tapes/[a-z]*.tape)
fi

mkdir -p docs/media
for tape in "${tapes[@]}"; do
  echo "==> $tape"
  vhs "$tape"
  name="$(basename "$tape" .tape)"
  if [[ "$name" == video-* ]]; then
    cast="docs/media/${name#video-}.cast"
    agg --theme "$THEME" --font-size 15 --idle-time-limit 1.5 --last-frame-duration 3 \
      "$cast" "docs/media/${name#video-}.gif"
  fi
done

echo
echo "Done. Updated:"
ls -1 docs/screenshots/*.png docs/media/*.gif docs/media/*.cast 2>/dev/null
