#!/usr/bin/env bash
# Ship Cua Bots (iPhone) to TestFlight for the internal group "Ossie".
#
# Runs on aojdevmac-m5 (Xcode, the Rust iOS targets, this checkout). From the
# MacBook:  ssh aojdevmac-m5-ts '~/code/cua-wt/ios/ossie/ship-testflight.sh'
#
#   ossie/ship-testflight.sh             upload the newest built ipa, or build one
#   ossie/ship-testflight.sh --rebuild   always archive a new build first
#   ossie/ship-testflight.sh --build-only  archive, export and validate, no upload
#
# Secrets come from BWS through hush: APPLE_API_PRIVATE_KEY, APPLE_API_KEY_ID,
# APPLE_API_ISSUER_ID, APPLE_TEAM_ID, and the signing identity it creates on
# first run (CUABOTS_DISTRIBUTION_KEY, CUABOTS_DISTRIBUTION_CERT_ID). The .p8
# and the signing keychain live in a mode-700 temp dir outside the repo and are
# removed on exit. Every step checks before it acts, so a rerun picks up where
# the last run stopped.
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$HOME/.bun/bin:$PATH"
export CMAKE_POLICY_VERSION_MINIMUM=3.5  # CMake 4 refuses audiopus_sys's bundled Opus

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo/examples/cua-bots-ios"
out="$app/build/testflight"
xcf="$repo/libs/cua/swift/build/CuaSDKFFI.xcframework"

rebuild=0
upload=1
for arg in "$@"; do
  case "$arg" in
    --rebuild) rebuild=1 ;;
    --build-only) rebuild=1; upload=0 ;;
    *) echo "unknown argument $arg" >&2; exit 2 ;;
  esac
done

[[ -z "${BWS_ACCESS_TOKEN:-}" && -f "$HOME/.env" ]] && { set -a; . "$HOME/.env"; set +a; }
for key in APPLE_API_PRIVATE_KEY APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_TEAM_ID; do
  [[ -n "${!key:-}" ]] || export "$key=$(hush get --key "$key")"
done

asc() { (cd "$repo" && bun ossie/asc.ts "$@"); }

# The app record is the one step only Ossie can do (the API refuses to create apps).
(( upload )) && asc check

keys="$(mktemp -d)"
chmod 700 "$keys"
keychains="$(security list-keychains -d user | xargs)"
cleanup() {
  # shellcheck disable=SC2086 # the saved list is space-separated paths
  [[ -f "$keys/signing.keychain-db" ]] && { security list-keychains -d user -s $keychains; security delete-keychain "$keys/signing.keychain-db"; }
  rm -rf "$keys"
}
trap cleanup EXIT
printf '%s\n' "${APPLE_API_PRIVATE_KEY//\\n/$'\n'}" > "$keys/AuthKey_$APPLE_API_KEY_ID.p8"
chmod 600 "$keys/AuthKey_$APPLE_API_KEY_ID.p8"
altool_auth=(--api-key "$APPLE_API_KEY_ID" --api-issuer "$APPLE_API_ISSUER_ID")
export API_PRIVATE_KEYS_DIR="$keys"

# Signing: the API key has no access to cloud-managed certificates, so this
# uses an Apple Distribution certificate made through the API. Its private key
# and id live in BWS. A throwaway keychain holds the identity for this run, so
# the login keychain (locked over ssh) is never needed.
signing() {
  local key cert_id kc="$keys/signing.keychain-db" pass
  key="$(hush get --key CUABOTS_DISTRIBUTION_KEY 2>/dev/null || true)"
  if [[ -z "$key" ]]; then
    openssl genrsa -traditional -out "$keys/dist.key" 2048 2>/dev/null
    # Base64 on stdin: bws reads a value that starts with "-----" as a flag,
    # and a --value would show in ps.
    base64 < "$keys/dist.key" | tr -d '\n' | hush add --key CUABOTS_DISTRIBUTION_KEY --project "API Keys" \
      --note "Base64 PEM private key of the Cua Bots Apple Distribution certificate (ossie/ship-testflight.sh)"
  else
    printf '%s' "$key" | base64 -d > "$keys/dist.key"
  fi
  chmod 600 "$keys/dist.key"
  cert_id="$(hush get --key CUABOTS_DISTRIBUTION_CERT_ID 2>/dev/null || true)"
  if [[ -z "$cert_id" ]]; then
    openssl req -new -key "$keys/dist.key" -subj "/CN=Cua Bots Distribution/C=US" -out "$keys/dist.csr"
    cert_id="$(asc create-cert "$keys/dist.csr")"
    printf '%s' "$cert_id" | hush add --key CUABOTS_DISTRIBUTION_CERT_ID --project "API Keys" \
      --note "App Store Connect id of the Cua Bots Apple Distribution certificate"
  fi
  asc cert "$cert_id" | base64 -d > "$keys/dist.cer"
  asc profile "$cert_id" | base64 -d > "$keys/dist.mobileprovision"
  curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$keys/wwdr.cer"

  pass="$(openssl rand -hex 16)"
  security create-keychain -p "$pass" "$kc"
  security set-keychain-settings "$kc"
  security unlock-keychain -p "$pass" "$kc"
  security import "$keys/dist.key" -k "$kc" -t priv -f openssl -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security import "$keys/dist.cer" -k "$kc" >/dev/null
  security import "$keys/wwdr.cer" -k "$kc" >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$kc" >/dev/null
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$kc" $keychains

  identity="$(openssl x509 -inform der -in "$keys/dist.cer" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
  profile_uuid="$(security cms -D -i "$keys/dist.mobileprovision" | plutil -extract UUID raw -)"
  for d in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    mkdir -p "$d" && cp "$keys/dist.mobileprovision" "$d/$profile_uuid.mobileprovision"
  done
  security find-identity -v -p codesigning "$kc" | grep -q "$identity" \
    || { echo "the signing keychain has no identity $identity" >&2; exit 1; }
  echo "signing: certificate $cert_id ($identity), profile $profile_uuid"
}

latest="$(ls -1 "$out" 2>/dev/null | sort -V | tail -1 || true)"
if (( rebuild )) || [[ -z "$latest" || ! -f "$out/$latest/CuaBots.ipa" ]]; then
  # UTC date.minute (20261023.520), so every archive gets a new, increasing
  # build number and each part stays a small integer.
  now="$(date -u +%Y%m%d%H%M)"
  build="${now:0:8}.$((10#${now:8}))"
  dir="$out/$build"
  mkdir -p "$dir"
  [[ -d "$xcf" ]] || (cd "$repo/libs/cua/swift" && scripts/build-xcframework.sh --ios --package cua-spaces-ffi)
  (cd "$app" && xcodegen generate --quiet)
  # Package.swift reads CUA_SWIFT_XCFRAMEWORK when xcodebuild resolves packages.
  export CUA_SWIFT_XCFRAMEWORK=build/CuaSDKFFI.xcframework
  # Archive unsigned; the export below signs the app for the App Store.
  xcodebuild -project "$app/CuaBots.xcodeproj" -scheme CuaBotsApp -configuration Release \
    -destination generic/platform=iOS -archivePath "$dir/CuaBots.xcarchive" \
    -derivedDataPath "$app/build/DerivedData" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$build" CODE_SIGNING_ALLOWED=NO \
    archive > "$dir/archive.log" 2>&1 \
    || { grep -E 'error:|\*\* ARCHIVE' "$dir/archive.log" | sort -u >&2; exit 1; }
  signing
  cat > "$dir/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$identity</string>
  <key>provisioningProfiles</key><dict><key>studio.aoj.cuabots</key><string>$profile_uuid</string></dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$dir/CuaBots.xcarchive" -exportPath "$dir" \
    -exportOptionsPlist "$dir/ExportOptions.plist" > "$dir/export.log" 2>&1 \
    || { grep -v '^\s*$' "$dir/export.log" | tail -20 >&2; exit 1; }
  latest="$build"
fi
ipa="$out/$latest/CuaBots.ipa"
echo "ipa: $ipa (build $latest)"

xcrun altool --validate-app "$ipa" -t ios "${altool_auth[@]}" 2>&1 | tee "$out/$latest/validate.log"
(( upload )) || exit 0

if asc uploaded "$latest"; then
  echo "build $latest: already uploaded"
else
  xcrun altool --upload-package "$ipa" -t ios "${altool_auth[@]}" 2>&1 | tee "$out/$latest/upload.log"
fi
asc distribute "$latest"
