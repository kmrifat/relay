#!/usr/bin/env bash
# The tag, the app (apps/relay/pubspec.yaml) and relayd (relayVersion) must
# agree, or the menu bar, Sparkle and `relay version` disagree about what
# is installed.  check_version.sh v0.2.0 → prints "0.2.0 7" (version, build)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tag="${1#v}"
pub="$(grep -E '^version:' "$root/apps/relay/pubspec.yaml" | awk '{print $2}')"
version="${pub%%+*}"
build="${pub#*+}"
daemon="$(grep -E "^const relayVersion = " "$root/packages/relay_daemon/lib/src/server.dart" | sed -E "s/.*'(.*)'.*/\1/")"
[[ "$version" == "$tag" ]] || { echo "Tag v$tag but pubspec says $version." >&2; exit 1; }
[[ "$daemon" == "$tag" ]] || { echo "Tag v$tag but relayVersion is $daemon." >&2; exit 1; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "pubspec needs a build number: version: $version+N" >&2; exit 1; }
echo "$version $build"
