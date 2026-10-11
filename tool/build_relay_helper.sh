#!/usr/bin/env bash
# Compiles the `relay` binary (packages/relay_daemon) and the `relay-pty`
# helper into <out dir>, and signs both for the hardened runtime (ADR-0001).
# The macOS build runs it to embed them at Relay.app/Contents/Helpers/.
# Skips compiling when the outputs are newer than their sources.
#
#   tool/build_relay_helper.sh <out dir> [signing identity, default "-"]
set -euo pipefail

out="$1"
identity="${2:--}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dart="${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/}dart"
mkdir -p "$out"

if [[ ! -f "$out/relay" ]] || [[ -n "$(find "$root/packages" -name '*.dart' -newer "$out/relay" -print -quit)" ]]; then
  (cd "$root" && "$dart" compile exe packages/relay_daemon/bin/relay.dart -o "$out/relay")
fi
if [[ ! -f "$out/relay-pty" ]] || [[ "$root/packages/relay_pty/native/relay_pty.c" -nt "$out/relay-pty" ]]; then
  cc -O2 -Wall -o "$out/relay-pty" "$root/packages/relay_pty/native/relay_pty.c"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  for bin in relay relay-pty; do
    codesign --force --options runtime --timestamp=none \
      --entitlements "$root/apps/relay/macos/Runner/Helper.entitlements" \
      --identifier "com.binarycastle.relay.$bin" --sign "$identity" "$out/$bin"
  done
fi
