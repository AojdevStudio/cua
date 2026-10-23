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
# Its own output dir: the default one may hold a plain cua-sdk build, which
# lacks the Spaces symbols this app links.
xcf_out="$repo/libs/cua/swift/build/spaces"

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
  [[ -n "${!key:-}" ]] || export "$key=$(hush get --key "$key" < /dev/null)"
done

asc() { (cd "$repo" && bun ossie/asc.ts "$@"); }

# The app record is the one step only Ossie can do (the API refuses to create apps).
(( upload )) && asc check

keys="$(mktemp -d)"
chmod 700 "$keys"
saved_keychains=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
  [[ -n "$line" ]] && saved_keychains+=("$line")
done < <(security list-keychains -d user)
cleanup() {
  if [[ -f "$keys/signing.keychain-db" ]]; then
    security list-keychains -d user -s "${saved_keychains[@]}" || echo "could not restore the keychain search list" >&2
    security delete-keychain "$keys/signing.keychain-db" || true
  fi
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
  local names certs cert_id="" kc="$keys/signing.keychain-db" pass pub id content
  # A failed lookup must stop the run, never read as "missing": that would
  # create another team certificate.
  names="$(hush list < /dev/null | cut -f2)"
  if ! grep -qx CUABOTS_DISTRIBUTION_KEY <<<"$names"; then
    openssl genrsa -traditional -out "$keys/dist.key" 2048 2>/dev/null
    # Base64 on stdin: bws reads a value that starts with "-----" as a flag,
    # and a --value would show in ps.
    base64 < "$keys/dist.key" | tr -d '\n' | hush add --key CUABOTS_DISTRIBUTION_KEY --project "API Keys" \
      --note "Base64 PEM private key of the Cua Bots Apple Distribution certificate (ossie/ship-testflight.sh)"
  else
    hush get --key CUABOTS_DISTRIBUTION_KEY < /dev/null | base64 -d > "$keys/dist.key"
  fi
  chmod 600 "$keys/dist.key"
  if grep -qx CUABOTS_DISTRIBUTION_CERT_ID <<<"$names"; then
    cert_id="$(hush get --key CUABOTS_DISTRIBUTION_CERT_ID < /dev/null)"
  else
    # A run that created the certificate but failed to store its id: find it
    # by its public key before making another.
    pub="$(openssl rsa -in "$keys/dist.key" -pubout -outform der 2>/dev/null | shasum -a 256)"
    certs="$(asc distribution-certs)"
    while read -r id content; do
      [[ "$(printf '%s' "$content" | base64 -d | openssl x509 -inform der -noout -pubkey \
        | openssl pkey -pubin -outform der | shasum -a 256)" == "$pub" ]] && cert_id="$id"
    done <<<"$certs"
  fi
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
  security list-keychains -d user -s "$kc" "${saved_keychains[@]}"

  identity="$(openssl x509 -inform der -in "$keys/dist.cer" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
  profile_uuid="$(security cms -D -i "$keys/dist.mobileprovision" | plutil -extract UUID raw -)"
  for d in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    mkdir -p "$d" && cp "$keys/dist.mobileprovision" "$d/$profile_uuid.mobileprovision"
  done
  security find-identity -v -p codesigning "$kc" | grep -q "$identity" \
    || { echo "the signing keychain has no identity $identity" >&2; exit 1; }
  echo "signing: certificate $cert_id ($identity), profile $profile_uuid"
}

# The newest exported ipa, by file time (the build number is in its dir name).
latest_ipa="$(ls -t "$out"/*/CuaBots.ipa 2>/dev/null | head -1 || true)"
latest="$( [[ -n "$latest_ipa" ]] && basename "$(dirname "$latest_ipa")" || true)"
if (( rebuild )) || [[ -z "$latest" ]]; then
  # UTC date.hhmmss (20261023.52233), so every archive gets a new, increasing
  # build number and each part stays a small integer.
  now="$(date -u +%Y%m%d%H%M%S)"
  build="${now:0:8}.$((10#${now:8}))"
  dir="$out/$build"
  mkdir -p "$out"
  mkdir "$dir" || { echo "$dir already exists, rerun in a second" >&2; exit 1; }
  [[ -d "$xcf_out/CuaSDKFFI.xcframework" ]] \
    || (cd "$repo/libs/cua/swift" && scripts/build-xcframework.sh --ios --package cua-spaces-ffi --out "$xcf_out")
  (cd "$app" && xcodegen generate --quiet)
  # Package.swift reads CUA_SWIFT_XCFRAMEWORK when xcodebuild resolves packages.
  export CUA_SWIFT_XCFRAMEWORK=build/spaces/CuaSDKFFI.xcframework
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
