#!/usr/bin/env bash
# Archives Relay for the App Store and uploads it to TestFlight (M9-04; from DevVault).
# Run from apps/relay after `flutter build ios --release --config-only`, on a Mac.
#
# Signing is automatic: Xcode fetches or creates the App Store provisioning
# profile through the App Store Connect API key, and signs with the Apple
# Distribution certificate imported here. `destination: upload` in the
# export options sends the build straight to App Store Connect, where it
# appears in TestFlight once processed.
#
# Needs (see docs/release.md):
#   APPLE_TEAM_ID                    10-character Team ID
#   IOS_DIST_CERT_P12_BASE64         Apple Distribution certificate + key, .p12, base64
#   IOS_DIST_CERT_PASSWORD           its password
#   APP_STORE_CONNECT_KEY_ID         API key ID (App Manager role or higher)
#   APP_STORE_CONNECT_ISSUER_ID      the key's issuer ID
#   APP_STORE_CONNECT_KEY_P8_BASE64  the AuthKey_<id>.p8 file, base64
set -euo pipefail

archive="build/ios/Relay.xcarchive"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
keychain="$tmp/relay-ios.keychain-db"
keychain_password="$(openssl rand -base64 24)"
api_key="$tmp/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
export_options="$tmp/ExportOptions.plist"

cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -f "$tmp/relay-ios.p12" "$api_key" "$export_options"
}
trap cleanup EXIT

# A throwaway keychain holding only the distribution identity.
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
printf '%s' "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$tmp/relay-ios.p12"
security import "$tmp/relay-ios.p12" -k "$keychain" \
  -P "$IOS_DIST_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "$keychain_password" "$keychain" >/dev/null
existing=()
while IFS= read -r line; do
  line="${line//\"/}"
  existing+=("$(echo "$line" | xargs)")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" "${existing[@]}"

printf '%s' "$APP_STORE_CONNECT_KEY_P8_BASE64" | base64 --decode > "$api_key"
auth=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$api_key"
  -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
)

xcodebuild archive \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  "${auth[@]}"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath build/ios/export \
  -exportOptionsPlist "$export_options" \
  "${auth[@]}"

echo "Uploaded to App Store Connect; it shows in TestFlight once processed."
