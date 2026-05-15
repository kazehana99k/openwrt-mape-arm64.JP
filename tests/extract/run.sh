#!/bin/sh
# tests/extract/run.sh — verify extractor produces byte-identical output
# from cached fc2 source as what's committed.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/lib/asserts.sh"

FIXTURE="$ROOT/tests/extract/fixtures/mape-fc2.html"
COMMITTED="$ROOT/package/mape/files/usr/share/mape/rules.json"
TMP=$(mktemp)

trap "rm -f $TMP" EXIT

"$ROOT/tools/extract-fc2-rules.sh" "$FIXTURE" "$TMP" 2>/dev/null

assert_file_eq "$COMMITTED" "$TMP" "extractor output matches committed rules.json"

assert_summary
