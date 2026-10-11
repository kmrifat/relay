#!/usr/bin/env bash
# Packages the Linux release bundle as an AppImage (M10-04; from DevVault).
# Run from apps/relay after `flutter build linux --release` with relayd in
# the bundle (tool/build_relay_helper.sh tool/out first). GTK 3 comes from
# the host.
#
# relayd outlives the window, but an AppImage's files exist only while its
# runtime runs. So relayd is started through the AppImage itself —
# `Relay.AppImage --relayd` — and keeps its own mount for as long as it
# runs (the app and the systemd unit both do this; see DaemonLauncher and
# DesktopLoginItem).
#
# appimagetool is pinned and checked against the SHA-256 GitHub records.
set -euo pipefail

name=relay-linux-x64.AppImage
update_info="gh-releases-zsync|kmrifat|relay|latest|$name.zsync"

version=1.9.1
sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
tool="$tmp/appimagetool-x86_64.AppImage"
curl -fsSL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/$version/appimagetool-x86_64.AppImage"
echo "$sha256  $tool" | sha256sum -c -
chmod +x "$tool"

bundle=build/linux/x64/release/bundle
[[ -x "$bundle/helpers/relay" ]] || { echo "No relayd in $bundle/helpers; run tool/build_relay_helper.sh tool/out before building." >&2; exit 1; }

appdir="$tmp/Relay.AppDir"
rm -rf "$appdir"
mkdir -p "$appdir/usr/lib/relay"
cp -r "$bundle/." "$appdir/usr/lib/relay/"

cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
if [ "$1" = "--relayd" ]; then
  shift
  exec "$HERE/usr/lib/relay/helpers/relay" daemon "$@"
fi
exec "$HERE/usr/lib/relay/relay" "$@"
RUN
chmod +x "$appdir/AppRun"

cat > "$appdir/com.binarycastle.relay.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Relay
Comment=Your coding agents and your team on one board
Exec=relay
Icon=com.binarycastle.relay
Categories=Development;ProjectManagement;
Terminal=false
DESKTOP
cp ../../design/icon/relay-ios-1024.png "$appdir/com.binarycastle.relay.png"

command -v zsyncmake >/dev/null || { echo "zsyncmake is missing: install the zsync package" >&2; exit 1; }
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --updateinformation "$update_info" "$appdir" "$name"
test -s "$name.zsync" || { echo "No $name.zsync was written" >&2; exit 1; }
echo "Wrote $name and $name.zsync"
