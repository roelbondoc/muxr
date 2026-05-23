#!/usr/bin/env bash
# Regenerate all README screenshots using VHS.
#
# Requires:  vhs (brew install vhs)
# Run from anywhere — the script cd's to the repo root.

set -euo pipefail

cd "$(dirname "$0")/../../.."

for tape in docs/screenshots/tapes/[0-9]*.tape; do
  echo "==> $tape"
  vhs "$tape"
done

# Drop the .gif/intermediate files VHS leaves behind; we only keep the PNGs.
rm -f docs/screenshots/tapes/.*.gif

echo
echo "Done. Updated:"
ls -1 docs/screenshots/*.png
