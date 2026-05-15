#!/bin/sh
# extract-fc2-rules.sh — convert fc2 calculator HTML into rules.json
#
# Usage:
#   tools/extract-fc2-rules.sh <input.html> <output.json>
#   tools/extract-fc2-rules.sh --fetch    # download fresh from fc2
#
# Input is expected to be Shift_JIS-encoded HTML (the fc2 source). The
# script converts to UTF-8, then pipes the JS section to the awk parser.
#
# Idempotent: same input → same output (suitable for committing into git).

set -e
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
TOOLS=$(dirname "$SELF")
ROOT=$(dirname "$TOOLS")

usage() {
    cat <<EOF
Usage: $0 <input-shift-jis.html> <output.json>
       $0 --fetch    (downloads fresh source to .scratch/ then extracts)
EOF
    exit 1
}

case "$1" in
    --fetch)
        mkdir -p "$ROOT/.scratch"
        curl -sL --max-time 30 -A "Mozilla/5.0" \
            'https://ipv4.web.fc2.com/map-e.html' \
            -o "$ROOT/.scratch/mape-fc2.html"
        set -- "$ROOT/.scratch/mape-fc2.html" \
               "$ROOT/package/mape/files/usr/share/mape/rules.json"
        ;;
    -h|--help|"") usage ;;
esac

[ $# -eq 2 ] || usage
INPUT="$1"
OUTPUT="$2"

[ -f "$INPUT" ] || { echo "Input not found: $INPUT" >&2; exit 2; }

mkdir -p "$(dirname "$OUTPUT")"

iconv -f shift_jis -t utf-8 "$INPUT" \
    | awk -f "$TOOLS/extract-fc2-rules.awk" \
    > "$OUTPUT"

# Validate JSON
if command -v jsonfilter >/dev/null 2>&1; then
    jsonfilter -i "$OUTPUT" -e '@.version' >/dev/null \
        || { echo "Output is not valid JSON: $OUTPUT" >&2; exit 3; }
elif command -v jq >/dev/null 2>&1; then
    jq empty < "$OUTPUT" \
        || { echo "Output is not valid JSON: $OUTPUT" >&2; exit 3; }
fi

echo "Wrote: $OUTPUT"
