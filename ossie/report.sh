#!/bin/bash
# Asks the running app for a report (SIGUSR1): a PNG of its window in
# ~/.local/share/cua-bots/snapshots and the iPhone pairing links in
# ~/.local/share/cua-bots/PAIRING.local.md, then copies the links next to this
# script (gitignored, they hold tokens) and prints the newest snapshot's path.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime="$HOME/.local/share/cua-bots"
before=$(date +%s)
pkill -USR1 -x CuaBots || { echo "report: CuaBots is not running" >&2; exit 1; }
for _ in $(seq 30); do
  [[ -f $runtime/PAIRING.local.md && $(stat -f %m "$runtime/PAIRING.local.md") -ge $before ]] && break
  sleep 1
done
[[ $(stat -f %m "$runtime/PAIRING.local.md" 2>/dev/null || echo 0) -ge $before ]] ||
  { echo "report: the app wrote no pairing file" >&2; exit 1; }
install -m 600 "$runtime/PAIRING.local.md" "$here/PAIRING.local.md"
echo "pairing: $here/PAIRING.local.md"
ls -t "$runtime"/snapshots/*.png 2>/dev/null | head -1 | sed 's/^/snapshot: /'
