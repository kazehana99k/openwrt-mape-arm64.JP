#!/bin/sh
# Run every tests/<group>/run.sh and aggregate results.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

FAIL=0
for d in tests/calc tests/proto tests/fw tests/extract; do
    [ -x "$d/run.sh" ] || continue
    printf "\n>>> %s\n" "$d"
    if ! "$d/run.sh"; then
        FAIL=$((FAIL + 1))
    fi
done

# Lint stage
printf "\n>>> lint\n"
fail_lint=0

if command -v shellcheck >/dev/null 2>&1; then
    if ! find package/ tools/ tests/ \
        \( -name '*.sh' -o -name mape-calc -o -name mape-fw \) \
        -print0 \
        | xargs -0 shellcheck -s sh -e SC2086,SC1090,SC1091; then
        fail_lint=1
    else
        printf "  PASS: shellcheck clean (SC2086,SC1090,SC1091 suppressed)\n"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

if command -v jq >/dev/null 2>&1; then
    json_fail=0
    for f in package/mape/files/usr/share/mape/rules.json tests/calc/golden/*.json; do
        if ! jq empty < "$f" >/dev/null 2>&1; then
            echo "  FAIL: invalid JSON: $f"
            json_fail=1
        fi
    done
    if [ "$json_fail" -eq 0 ]; then
        echo "  PASS: all JSON files valid"
    else
        fail_lint=1
    fi
else
    echo "  SKIP: jq not installed"
fi

[ $fail_lint -eq 0 ] || FAIL=$((FAIL + 1))

if [ "$FAIL" -gt 0 ]; then
    printf "\n%d test group(s) failed.\n" "$FAIL"
    exit 1
fi
printf "\nAll test groups passed.\n"
