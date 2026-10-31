#!/bin/bash
# Makes each bot Space's spacesd reachable from the tailnet, and only there.
# Docker publishes spacesd (guest port 3211) on 127.0.0.1 with a host port it
# picks again at every container start. This gives each bot container a
# stable tailnet port (from 43211 up, kept in $ports), forwards it to the
# current loopback port with `tailscale serve --tcp`, and drops the forward
# when the container is deleted. It only touches forwards listed in $ports.
# It reconciles at start, on every container start or stop, and after 30 s with no event
# (a container can start before the event stream connects, as at boot, and
# Docker or Tailscale can be down), and reconnects when the event stream ends.
set -uo pipefail
export PATH="$HOME/.orbstack/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ports="${CUA_BOTS_PAIRING_PORTS:-$HOME/.local/share/cua-bots/tailnet-ports}"
touch "$ports"

is_bot() { [[ $1 =~ (^|[-_])bot- ]]; }

serve_tcp() {
  tailscale serve status --json | /usr/bin/python3 -c '
import json, sys
for port, h in ((json.load(sys.stdin) or {}).get("TCP") or {}).items():
    print(port, h.get("TCPForward", "-"))'
}

reconcile() {
  docker info >/dev/null 2>&1 || return 1
  local all running serving name port target loopback next failed=0
  all=$(docker ps -a --format '{{.Names}}')
  running=$(docker ps --format '{{.Names}}')
  serving=$(serve_tcp) || return 1

  while read -r name port; do
    [[ -n $name ]] || continue
    if ! grep -qx "$name" <<<"$all"; then
      tailscale serve --tcp "$port" off >/dev/null 2>&1
      sed -i '' "/^$name /d" "$ports"
      echo "tailnet-spacesd: $name is gone, dropped :$port"
    fi
  done < "$ports"

  for name in $running; do
    is_bot "$name" || continue
    loopback=$(docker port "$name" 3211/tcp 2>/dev/null | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p')
    [[ -n $loopback ]] || continue
    port=$(awk -v n="$name" '$1 == n { print $2 }' "$ports")
    if [[ -z $port ]]; then
      next=43211
      while awk '{ print $2 }' "$ports" | grep -qx "$next" || awk '{ print $1 }' <<<"$serving" | grep -qx "$next"; do
        next=$((next + 1))
      done
      port=$next
      echo "$name $port" >> "$ports"
    fi
    target=$(awk -v p="$port" '$1 == p { print $2 }' <<<"$serving")
    [[ $target == "127.0.0.1:$loopback" ]] && continue
    [[ -n $target ]] && tailscale serve --tcp "$port" off >/dev/null 2>&1
    if tailscale serve --bg --tcp "$port" "tcp://127.0.0.1:$loopback" >/dev/null; then
      echo "tailnet-spacesd: $name :$port -> 127.0.0.1:$loopback"
    else
      failed=1
    fi
  done
  return "$failed"
}

while :; do
  if ! reconcile; then sleep 30; continue; fi
  docker events --filter type=container --filter event=start --filter event=die --filter event=destroy \
    --format '{{.Actor.Attributes.name}}' 2>/dev/null | {
    while :; do
      # bash 3.2 returns 1 for both a timeout and the end of the stream; the
      # end comes at once, a timeout after 30 s.
      started=$SECONDS
      if read -r -t 30 name; then
        is_bot "$name" || continue
      elif (( SECONDS - started < 25 )); then
        break
      fi
      reconcile
    done
  }
  sleep 5
done
