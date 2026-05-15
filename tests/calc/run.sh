#!/bin/sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/lib/asserts.sh"

CALC=$ROOT/package/mape/files/usr/bin/mape-calc
RULES=$ROOT/package/mape/files/usr/share/mape/rules.json
AWK=$ROOT/package/mape/files/usr/share/mape/calc.awk

export MAPE_RULES_JSON="$RULES"
export MAPE_CALC_AWK="$AWK"

# Golden-file regression: each fixture .pd → expected .json
for fixture in "$ROOT"/tests/calc/fixtures/*.pd; do
    [ -f "$fixture" ] || continue
    name=$(basename "$fixture" .pd)
    pd=$(cat "$fixture")
    golden="$ROOT/tests/calc/golden/$name.json"

    if [ ! -f "$golden" ]; then
        printf "  SKIP: %s (no golden file)\n" "$name"
        continue
    fi

    actual=$(mktemp)
    "$CALC" compute "$pd" > "$actual" 2>/dev/null
    assert_file_eq "$golden" "$actual" "calc compute: $name"
    rm -f "$actual"
done

# T: list-rules contains BIGLOBE A (requires jsonfilter; skip on hosts without it)
if command -v jsonfilter >/dev/null 2>&1; then
    out=$("$CALC" list-rules)
    echo "$out" | grep -q "biglobe-a-2404-7a80"
    assert_eq 0 $? "list-rules contains biglobe-a-2404-7a80"
else
    printf "  SKIP: list-rules contains biglobe-a-2404-7a80 (jsonfilter unavailable)\n"
fi

# T: check-port within range (needs jsonfilter)
if command -v jsonfilter >/dev/null 2>&1; then
    "$CALC" check-port 4096 "2404:7a80:0:0::/56" >/dev/null 2>&1
    assert_eq 0 $? "check-port 4096 (in first set 4096-4111) → exit 0"

    "$CALC" check-port 4099 "2404:7a80:0:0::/56" >/dev/null 2>&1
    assert_eq 0 $? "check-port 4099 (in first set) → exit 0"

    rc=0; "$CALC" check-port 1234 "2404:7a80:0:0::/56" >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "check-port 1234 (not in any PSID set) → exit 1"

    rc=0; "$CALC" check-port 80 "2404:7a80:0:0::/56" >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "check-port 80 → exit 1"

    n_lines=$("$CALC" port-sets "2404:7a80:0:0::/56" | wc -l | tr -d ' ')
    assert_eq 15 "$n_lines" "port-sets prints 15 lines for BIGLOBE PD"
else
    printf "  SKIP: check-port and port-sets tests (jsonfilter unavailable)\n"
fi

# T: error on no match (no jsonfilter needed — pure calc.awk exit code)
rc=0; "$CALC" compute "fd00::/56" >/dev/null 2>&1 || rc=$?
assert_eq 3 "$rc" "compute fd00::/56 → exit 3 (no rule)"

# T: error on bad PD (require_pd will fail if no colon)
rc=0; "$CALC" compute "garbage" >/dev/null 2>&1 || rc=$?
# Either exit 1 (require_pd usage) or exit 2 (calc.awk parse_pd) is acceptable
[ "$rc" = 1 ] || [ "$rc" = 2 ]
assert_eq 0 $? "compute 'garbage' → exit 1 or 2 (parse fail), got $rc"

assert_summary
