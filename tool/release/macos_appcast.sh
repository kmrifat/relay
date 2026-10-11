#!/usr/bin/env bash
# Writes appcast.xml for the notarized DMG (M9-03; from DevVault): one item
# with the version, the DMG's length and its EdDSA signature. Sparkle in
# the installed app reads it from
# $SPARKLE_FEED_URL (Configs/AppInfo.xcconfig)
# when the user presses Update…, checks the signature against
# SUPublicEDKey and only then installs.
#
#   macos_appcast.sh <dmg> <version> <build> [download-url]
#
# <version> and <build> are pubspec's `1.2.0+7`, split: Sparkle compares
# the build number (CFBundleVersion), so it must grow with every release.
# The download URL defaults to $RELEASE_BASE_URL/v<version>/Relay-macos.dmg.
#
# Needs SPARKLE_ED_PRIVATE_KEY: the private half of the update key,
# base64, as `generate_keys -x` exports it (docs/release.md). Sparkle's
# tools are pinned to the version in macos/Podfile and checked against
# the SHA-256 GitHub records; SPARKLE_BIN points at an unpacked copy
# instead.
set -euo pipefail

dmg="$1"
version="$2"
build="$3"
url="${4:-${RELEASE_BASE_URL:?Set RELEASE_BASE_URL (where releases are downloaded) or pass the URL}/v$version/Relay-macos.dmg}"

if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_ED_PRIVATE_KEY is not set." >&2
  exit 1
fi
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]]; then
  echo "Expected a version like 1.2.0 and a build number, got '$version' '$build'." >&2
  exit 1
fi

bin="${SPARKLE_BIN:-}"
if [[ -z "$bin" ]]; then
  sparkle_version=2.9.6
  sparkle_sha256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
  tmp="${RUNNER_TEMP:-$(mktemp -d)}/sparkle"
  mkdir -p "$tmp"
  curl -fsSL -o "$tmp/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
  echo "$sparkle_sha256  $tmp/sparkle.tar.xz" | shasum -a 256 -c -
  tar -xf "$tmp/sparkle.tar.xz" -C "$tmp"
  bin="$tmp/bin"
fi

# The key goes in on stdin, never on the command line or to disk.
signature="$(printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" \
  | "$bin/sign_update" -p --ed-key-file - "$dmg")"
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" \
  | "$bin/sign_update" --verify --ed-key-file - "$dmg" "$signature"
length="$(stat -f %z "$dmg" 2>/dev/null || stat -c %s "$dmg")"
published="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Relay</title>
    <item>
      <title>Relay $version</title>
      <pubDate>$published</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout appcast.xml
echo "Wrote appcast.xml for Relay $version ($build)"
