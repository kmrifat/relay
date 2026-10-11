#!/usr/bin/env bash
# Signs Relay.app with a Developer ID, wraps it in a DMG, notarizes the DMG
# with Apple and staples the ticket (M9-03; adapted from DevVault's
# tool/release). Run from apps/relay after `flutter build macos --release`,
# on a Mac.
#
# Needs (docs/release.md):
#   MACOS_CERT_P12_BASE64   Developer ID Application certificate + key, .p12, base64
#   MACOS_CERT_PASSWORD     its password
#   APPLE_TEAM_ID           10-character Team ID
#   APPLE_ID                Apple ID used for notarization
#   APPLE_APP_PASSWORD      an app-specific password for that Apple ID
#
# Writes Relay-macos.dmg in the current directory.
set -euo pipefail

app="build/macos/Build/Products/Release/Relay.app"
dmg="Relay-macos.dmg"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
keychain="$tmp/relay-signing.keychain-db"
keychain_password="$(openssl rand -base64 24)"

cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -f "$tmp/relay-cert.p12"
}
trap cleanup EXIT

[[ -d "$app" ]] || { echo "No $app; run flutter build macos --release first." >&2; exit 1; }
for f in Contents/Helpers/relay Contents/Helpers/relay-pty Contents/Library/LaunchAgents/com.binarycastle.relay.daemon.plist; do
  [[ -e "$app/$f" ]] || { echo "Missing $f in the app." >&2; exit 1; }
done

# A throwaway keychain holding only the signing identity.
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$tmp/relay-cert.p12"
security import "$tmp/relay-cert.p12" -k "$keychain" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
existing=()
while IFS= read -r line; do
  line="${line//\"/}"
  existing+=("$(echo "$line" | xargs)")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" "${existing[@]}"

identity="$(security find-identity -v -p codesigning "$keychain" \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
[[ -n "$identity" ]] || { echo "No 'Developer ID Application' identity in the certificate." >&2; exit 1; }
echo "Signing as: $identity"

sign() {
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" "$@"
}

# Inside out, never --deep. Sparkle's helpers as its docs list them (the
# downloader keeps its entitlements), then every framework and dylib.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$sparkle" ]]; then
  sign "$sparkle/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
  sign "$sparkle/Autoupdate"
  sign "$sparkle/Updater.app"
fi
while IFS= read -r -d '' nested; do
  sign "$nested"
done < <(find "$app/Contents/Frameworks" \( -name '*.framework' -o -name '*.dylib' \) -print0)
# relayd and relay-pty (ADR-0001): Dart and C executables under the
# hardened runtime, with the code-signing exceptions a Dart AOT binary needs.
for bin in relay relay-pty; do
  sign --entitlements macos/Runner/Helper.entitlements --identifier "com.binarycastle.relay.$bin" "$app/Contents/Helpers/$bin"
done
# The app last; not sandboxed (Release.entitlements explains why).
sign --entitlements macos/Runner/Release.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

rm -f "$dmg"
hdiutil create -volname Relay -srcfolder "$app" -ov -format UDZO "$dmg"
sign "$dmg"
xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Wrote $dmg (signed, notarized, stapled)."
