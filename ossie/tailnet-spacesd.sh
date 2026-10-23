#!/bin/bash
# Makes each bot Space's spacesd reachable from the tailnet, and only there.
# Docker publishes spacesd (guest port 3211) on 127.0.0.1 with a random host
# port. This forwards the same port number on this Mac's Tailscale address to
# it with `tailscale serve --tcp`, and drops forwards whose Space is gone. It
# reconciles at start and on every container start or stop, so a recreated
# Space with a new port is picked up. Forwards it owns map P to 127.0.0.1:P.
set -uo pipefail
export PATH="$HOME/.orbstack/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

wanted() {
  for c in $(docker ps --format '{{.Names}}' | grep -E '(^|[-_])bot-'); do
    docker port "$c" 3211/tcp 2>/dev/null | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p'
  done | sort -u
}

owned() {
  tailscale serve status --json | /usr/bin/python3 -c '
import json, sys
tcp = (json.load(sys.stdin) or {}).get("TCP") or {}
for port, h in tcp.items():
    if h.get("TCPForward") == "127.0.0.1:" + port:
        print(port)' | sort -u
}

reconcile() {
  local want have
  want=$(wanted)
  have=$(owned)
  for p in $(comm -23 <(echo "$want") <(echo "$have")); do
    tailscale serve --bg --tcp "$p" "tcp://127.0.0.1:$p" >/dev/null && echo "tailnet-spacesd: forwarding :$p"
  done
  for p in $(comm -13 <(echo "$want") <(echo "$have")); do
    tailscale serve --tcp "$p" off >/dev/null && echo "tailnet-spacesd: dropped :$p"
  done
}

reconcile
docker events --filter type=container --filter event=start --filter event=die --format '{{.Actor.Attributes.name}}' |
  while read -r name; do
    [[ $name =~ (^|[-_])bot- ]] && reconcile
  done
