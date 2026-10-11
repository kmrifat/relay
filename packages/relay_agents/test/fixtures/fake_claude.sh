#!/bin/sh
# Stands in for `claude -p --input-format stream-json --output-format stream-json`.
# Prints part 1, waits for Relay's control_response, prints part 2, then
# waits for stdin to close (Relay closes it after the final result).
D="$(dirname "$0")"
cat "$D/claude_part1.jsonl"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "${FAKE_LOG:-/dev/null}"
  case "$line" in *control_response*) break ;; esac
done
cat "$D/claude_part2.jsonl"
while IFS= read -r line; do printf '%s\n' "$line" >> "${FAKE_LOG:-/dev/null}"; done
exit 0
