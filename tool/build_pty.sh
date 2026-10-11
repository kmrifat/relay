#!/bin/sh
# Builds the relay-pty helper into tool/out/ (macOS and Linux).
set -eu
cd "$(dirname "$0")/.."
mkdir -p tool/out
case "$(uname -s)" in
  Darwin) cc -O2 -Wall -Wextra -o tool/out/relay-pty packages/relay_pty/native/relay_pty.c ;;
  *) cc -O2 -Wall -Wextra -o tool/out/relay-pty packages/relay_pty/native/relay_pty.c -lutil ;;
esac
echo "built tool/out/relay-pty"
