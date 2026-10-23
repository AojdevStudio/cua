#!/bin/bash
# Starts Cua Bots on aojdevmac-m5 with Obi seeded. launchd runs this through
# the bgjob app com.obi.cua-bots, from ~/.local/share/cua-bots, where
# install-runtime.sh copies it. The model key is read from BWS here, at run
# time, and never written to disk.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$here/CuaBots"
export PATH="$HOME/.orbstack/bin:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

bws_token=$(sed -n 's/^\(export \)\{0,1\}BWS_ACCESS_TOKEN=//p' "$HOME/.env" | tr -d "\"'")
[[ -n $bws_token ]] || { echo "run-cuabots: no BWS_ACCESS_TOKEN in ~/.env" >&2; exit 1; }
key=$(BWS_ACCESS_TOKEN="$bws_token" hush get --key CLIPROXYAPI_KEY_CUABOTS)
[[ -n $key ]] || { echo "run-cuabots: CLIPROXYAPI_KEY_CUABOTS is empty" >&2; exit 1; }

# OrbStack starts at login too. Local Spaces need its Docker engine.
for _ in $(seq 90); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || { echo "run-cuabots: Docker (OrbStack) is not up" >&2; exit 1; }

export ANTHROPIC_API_KEY="$key"
export CUA_BOTS_MODEL_URL="https://ossies-mac-mini.tail3a79a5.ts.net:8317"
export CUA_BOTS_MODEL="claude-opus-5-5"
export CUA_BOTS_MODEL_KEY_VARS="ANTHROPIC_API_KEY"
export CUA_BOTS_OWNER="Ossie"
export CUA_TELEMETRY=0
export CUA_BOTS_DEVICE_NAME="aojdevmac-m5"
export CUA_BOTS_SEED="Obi:claude-code"
export CUA_BOTS_SHOW_COMPUTER=1
export CUA_BOTS_SNAPSHOT_DIR="$here/snapshots"
export CUA_BOTS_PAIRING_FILE="$here/PAIRING.local.md"
export CUA_BOTS_PAIRING_HOST="aojdevmac-m5.tail3a79a5.ts.net"

# The app and the tailnet forwarder live and die together, so launchd's
# KeepAlive restarts both when the app quits.
"$here/tailnet-spacesd.sh" &
forwarder=$!
"$app" &
app_pid=$!
stop_forwarder() { pkill -P "$forwarder" 2>/dev/null; kill "$forwarder" 2>/dev/null; }
trap 'kill "$app_pid" 2>/dev/null; stop_forwarder' TERM INT HUP
wait "$app_pid"
status=$?
stop_forwarder
exit "$status"
