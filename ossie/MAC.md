# Cua Bots on aojdevmac-m5

The macOS sample runs in aojadmin's GUI session with one bot, Obi (Claude Code on
`claude-opus-5-5` through CLIProxyAPI on the mini). The iPhone reaches Obi's Space
over Tailscale only.

| What | Where |
|---|---|
| launchd job | `com.obi.cua-bots`, the signed app `~/Applications/Cua Bots.app`, from the bgjob manifest `agents-config/machines/aojdevmac-m5/launchd/jobs/com.obi.cua-bots.toml` |
| What it runs | `~/.local/share/cua-bots/run-cuabots.sh` (internal disk; the checkout is on the Lexar USB disk, which a launchd app can't read without a Removable Volumes click) |
| Log | `~/Library/Logs/com.obi.cua-bots.log` |
| App data | `~/Library/Application Support/Cua Bots/` |
| Pairing link | `ossie/PAIRING.local.md` (gitignored, holds the spacesd token) |
| Snapshots | `~/.local/share/cua-bots/snapshots/` |

## Commands (on aojdevmac-m5)

```sh
ossie/install-runtime.sh                                   # build, copy to ~/.local/share/cua-bots, restart
launchctl kickstart -k gui/$(id -u)/com.obi.cua-bots       # restart
launchctl bootout gui/$(id -u)/com.obi.cua-bots            # stop until next login
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.obi.cua-bots.plist   # start again
tail -f ~/Library/Logs/com.obi.cua-bots.log                # logs
ossie/report.sh                                            # window snapshot and fresh pairing link
```

## How the pieces fit

- `run-cuabots.sh` reads `CLIPROXYAPI_KEY_CUABOTS` from BWS, waits for OrbStack,
  and starts the app with `CUA_BOTS_SEED=Obi:claude-code`, so a fresh install
  creates Obi on This Mac.
- Docker publishes Obi's spacesd on `127.0.0.1` with a random port.
  `tailnet-spacesd.sh` forwards the same port on the Tailscale address with
  `tailscale serve --tcp`, on every container start or stop. The LAN never sees it.
- The app writes the pairing link with `CUA_BOTS_PAIRING_HOST`, the Tailscale name.
- `SIGUSR1` makes the app write a window snapshot (ScreenCaptureKit, current
  process only, so no Screen Recording grant) and the pairing links.
- `phone-roundtrip.sh` acts as the phone from another tailnet Mac: reads the
  snapshot, drops a message in the outbox, and prints Obi's reply.
