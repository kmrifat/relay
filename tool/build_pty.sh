#!/bin/sh
# Builds the relay-pty helper into tool/out/: forkpty on macOS and Linux,
# ConPTY on Windows (Git Bash with mingw-w64 gcc).
set -eu
cd "$(dirname "$0")/.."
mkdir -p tool/out
case "$(uname -s)" in
  Darwin) cc -O2 -Wall -Wextra -o tool/out/relay-pty packages/relay_pty/native/relay_pty.c ;;
  MINGW*|MSYS*|CYGWIN*) gcc -O2 -Wall -municode -static -o tool/out/relay-pty.exe packages/relay_pty/native/relay_pty_win.c ;;
  *) cc -O2 -Wall -Wextra -o tool/out/relay-pty packages/relay_pty/native/relay_pty.c -lutil ;;
esac
echo "built tool/out/relay-pty"
