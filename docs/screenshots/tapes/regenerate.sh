#!/usr/bin/env bash
# Regenerate every README / project-page screenshot using VHS.
#
# Requires:  vhs (brew install vhs)
# Run from anywhere — the script cd's to the repo root.

set -euo pipefail

cd "$(dirname "$0")/../../.."

cleanup() {
  pkill -f "muxr.*--server shot"  2>/dev/null || true
  pkill -f "muxr.*--server api"   2>/dev/null || true
  pkill -f "muxr.*--server notes" 2>/dev/null || true
  rm -f docs/screenshots/tapes/.*.gif
}
trap cleanup EXIT

# Tapes starting with "_" are shared fragments pulled in via `Source`.
for tape in docs/screenshots/tapes/[a-z]*.tape; do
  echo "==> $tape"
  vhs "$tape"
done

echo
echo "Done. Updated:"
ls -1 docs/screenshots/*.png
