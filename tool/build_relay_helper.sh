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

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) exe=.exe; win=1 ;;
  *) exe=; win= ;;
esac

if [[ ! -f "$out/relay$exe" ]] || [[ -n "$(find "$root/packages" -name '*.dart' -newer "$out/relay$exe" -print -quit)" ]]; then
  (cd "$root" && "$dart" compile exe packages/relay_daemon/bin/relay.dart -o "$out/relay$exe")
fi
if [[ -n "$win" ]]; then
  # ConPTY (M10-02); mingw-w64's gcc, which GitHub's Windows images carry.
  src="$root/packages/relay_pty/native/relay_pty_win.c"
  if [[ ! -f "$out/relay-pty.exe" ]] || [[ "$src" -nt "$out/relay-pty.exe" ]]; then
    gcc -O2 -Wall -municode -static -o "$out/relay-pty.exe" "$src"
  fi
else
  src="$root/packages/relay_pty/native/relay_pty.c"
  if [[ ! -f "$out/relay-pty" ]] || [[ "$src" -nt "$out/relay-pty" ]]; then
    libs=()
    [[ "$(uname -s)" == "Linux" ]] && libs=(-lutil)
    cc -O2 -Wall -o "$out/relay-pty" "$src" "${libs[@]}"
  fi
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  for bin in relay relay-pty; do
    codesign --force --options runtime --timestamp=none \
      --entitlements "$root/apps/relay/macos/Runner/Helper.entitlements" \
      --identifier "com.binarycastle.relay.$bin" --sign "$identity" "$out/$bin"
  done
fi
