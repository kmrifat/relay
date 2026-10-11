#!/usr/bin/env bash
# Wraps Relay.app in the drag-to-Applications DMG (dmg_settings.py). Signing
# and notarizing happen in macos_sign_notarize.sh, which calls this.
#   macos_dmg.sh <Relay.app> <out.dmg>
set -euo pipefail
app="$1"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
# dmgbuild, pinned, in its own venv (no Finder scripting: works headless).
if [[ ! -x "$tmp/dmgvenv/bin/dmgbuild" ]]; then
  python3 -m venv "$tmp/dmgvenv"
  "$tmp/dmgvenv/bin/pip" install --quiet 'dmgbuild==1.6.7'
fi
rm -f "$out"
"$tmp/dmgvenv/bin/dmgbuild" -s "$here/dmg_settings.py" -D app="$app" -D background="$here/../../design/dmg/background.tiff" "Relay" "$out"
echo "Wrote $out"
