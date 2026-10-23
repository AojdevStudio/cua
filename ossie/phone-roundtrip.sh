#!/bin/bash
# Acts as the iPhone from another tailnet node (the MacBook): reads Obi's
# snapshot through spacesd with the pairing link, drops a message in the
# outbox exactly as RemoteClient.send does, and waits for Obi's reply in the
# snapshot the Mac publishes. Copy it next to a macOS `cua` binary (built in
# libs/cua/target/release) on any tailnet Mac and run it there.
set -euo pipefail
cd "$(dirname "$0")"
export HOME="$PWD/home" CUA_TELEMETRY=0
mkdir -p "$HOME" out
link=$(ssh aojdevmac-m5-ts 'sed -n "s/.*Obi: \`\(cuabots:[^\`]*\)\`.*/\1/p" ~/code/cua-wt/mac/ossie/PAIRING.local.md')
url=$(python3 -c 'import sys,urllib.parse as u; print(u.parse_qs(u.urlparse(sys.argv[1]).query)["url"][0])' "$link")
export CUA_ENV_TOKEN=$(python3 -c 'import sys,urllib.parse as u; print(u.parse_qs(u.urlparse(sys.argv[1]).query)["token"][0])' "$link")
echo "spacesd: $url"
home=$(./cua spacesd exec "$url" sh -c 'echo $HOME')
state="$home/bots/obi/.cua-bots/state.json"
./cua spacesd cp "$url" ":$state" out/state-before.json >/dev/null
echo "read $state over the tailnet: $(python3 -c 'import json; s=json.load(open("out/state-before.json")); print(s["bot"]["name"], "owner", s["bot"]["owner"], "harness", s["bot"]["harness"], len(s["messages"]), "messages")')"

text="Obi, this is a round-trip test from Ossie's MacBook over Tailscale. Reply in one sentence: who are you and who do you work for?"
id=$(uuidgen)
python3 - "$id" "$text" > out/command.json <<'EOF'
import json, sys, time
print(json.dumps({"id": sys.argv[1], "botID": "obi", "action": {"message": {"_0": sys.argv[2]}},
                  "sentAt": time.time() - 978307200, "from": "MacBook (tailnet proof)"}))
EOF
name="$(date +%s)000-$id.json"
./cua spacesd cp "$url" out/command.json ":$home/bots/obi/.cua-bots/outbox/$name" >/dev/null
echo "sent: $text"

for _ in $(seq 120); do
  sleep 3
  ./cua spacesd cp "$url" ":$state" out/state-after.json >/dev/null 2>&1 || continue
  reply=$(python3 - "$text" <<'EOF'
import json, sys
m = json.load(open("out/state-after.json"))["messages"]
i = next((k for k, x in enumerate(m) if x["role"] == "user" and x["text"] == sys.argv[1]), None)
after = [x["text"] for x in m[i + 1:] if x["role"] == "bot"] if i is not None else []
print(after[-1] if after else "")
EOF
)
  busy=$(python3 -c 'import json; print(json.load(open("out/state-after.json"))["busy"])')
  if [[ -n $reply && $busy == False ]]; then echo "reply: $reply"; exit 0; fi
done
echo "no reply within 6 minutes" >&2
exit 1
