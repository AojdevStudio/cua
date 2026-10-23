#!/bin/bash
# Builds the Mac app and copies what the bgjob com.obi.cua-bots runs to the
# internal disk (~/.local/share/cua-bots). The checkout is on the Lexar USB
# disk, and a launchd app reading it waits on a Removable Volumes prompt that
# nobody can click on a headless Mac. CuaBots finds libcua_sdk.dylib next to
# itself through its @loader_path rpath.
#   ossie/install-runtime.sh            build, copy, restart the job if loaded
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$here/.."
dest="$HOME/.local/share/cua-bots"
export PATH="$HOME/.orbstack/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

(cd "$repo/libs/cua" && cargo build --locked --release -p cua-spaces-ffi)
"$repo/libs/spaces-app-swift/scripts/stage-library.sh"
(cd "$repo/examples/cua-bots-macos" && swift build -c release --product CuaBots)

mkdir -p "$dest"
install -m 755 "$repo/examples/cua-bots-macos/.build/release/CuaBots" "$dest/CuaBots"
install -m 644 "$repo/libs/cua/swift/lib/libcua_sdk.dylib" "$dest/libcua_sdk.dylib"
install -m 755 "$here/run-cuabots.sh" "$here/tailnet-spacesd.sh" "$dest/"
echo "installed to $dest"

job="gui/$(id -u)/com.obi.cua-bots"
if launchctl print "$job" >/dev/null 2>&1; then
  launchctl kickstart -k "$job" && echo "restarted $job"
fi
