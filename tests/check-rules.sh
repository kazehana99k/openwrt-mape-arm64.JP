#!/bin/sh
# check-rules.sh — validate structural invariants of rules.json
set -e

RULES="${1:-package/mape/files/usr/share/mape/rules.json}"
[ -f "$RULES" ] || { echo "Not found: $RULES" >&2; exit 1; }

JF=$(command -v jsonfilter || command -v jq)
[ -n "$JF" ] || { echo "Need jsonfilter or jq" >&2; exit 1; }

fail=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  PASS: %s\n" "$desc"
    else
        printf "  FAIL: %s\n" "$desc"
        fail=$((fail + 1))
    fi
}

# Top-level fields
check "version is 1" sh -c \
    "[ \"\$(jsonfilter -i $RULES -e '@.version')\" = '1' ]"
check "rules is an array" sh -c \
    "jsonfilter -i $RULES -e '@.rules[0]' >/dev/null"

# Per-rule required fields (sample first, last, and a known one)
for idx in 0 -1; do
    for field in id isp_name br v6_prefix v6_prefix_len v4_prefix v4_prefix_len ea_len psid_offset psid_len; do
        check "rules[$idx].$field exists" sh -c \
            "jsonfilter -i $RULES -e \"@.rules[$idx].$field\" >/dev/null"
    done
done

# Algorithmic invariants
total=$(jsonfilter -i "$RULES" -e '@.rules[*].id' | wc -l | tr -d ' ')
check "rule count > 100 (sanity)" sh -c "[ $total -gt 100 ]"

# Check ealen + v4_prefix_len = 32 + psid_len for every rule (RFC 7597 invariant)
# (extract pairs; bash loop is fine since this is offline tooling)
i=0
while ealen=$(jsonfilter -i "$RULES" -e "@.rules[$i].ea_len" 2>/dev/null) \
   && v4l=$(jsonfilter -i "$RULES" -e "@.rules[$i].v4_prefix_len" 2>/dev/null) \
   && psl=$(jsonfilter -i "$RULES" -e "@.rules[$i].psid_len" 2>/dev/null) \
   && [ -n "$ealen" ] && [ -n "$v4l" ] && [ -n "$psl" ]; do
    expected=$((32 + psl - ealen))
    if [ "$v4l" != "$expected" ]; then
        echo "  FAIL: rules[$i] invariant: v4_prefix_len=$v4l expected $expected (32+$psl-$ealen)"
        fail=$((fail + 1))
        break
    fi
    i=$((i + 1))
    [ $i -ge $total ] && break
done
[ $fail -eq 0 ] && printf "  PASS: RFC 7597 invariant ealen=32+psid_len-v4_prefix_len holds for all %d rules\n" "$total"

if [ $fail -eq 0 ]; then
    printf "\nAll structural checks passed (%d rules).\n" "$total"
    exit 0
else
    printf "\n%d check(s) failed.\n" "$fail"
    exit 1
fi
