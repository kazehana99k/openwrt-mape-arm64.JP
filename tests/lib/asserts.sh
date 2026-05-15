#!/bin/sh
# Minimal assertion library for shell tests.
# Usage:
#   . tests/lib/asserts.sh
#   assert_eq "expected" "$actual" "what is being tested"
#   assert_file_eq tests/golden/x.json output.json
#   assert_exit_code 0 some_command

ASSERT_PASS=0
ASSERT_FAIL=0
ASSERT_NAMES_FAILED=""

assert_eq() {
    local expected="$1"
    local actual="$2"
    local name="$3"
    if [ "$expected" = "$actual" ]; then
        ASSERT_PASS=$((ASSERT_PASS + 1))
        printf "  PASS: %s\n" "$name"
    else
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        ASSERT_NAMES_FAILED="$ASSERT_NAMES_FAILED\n  - $name"
        printf "  FAIL: %s\n    expected: %s\n    actual:   %s\n" \
            "$name" "$expected" "$actual"
    fi
}

assert_file_eq() {
    local expected_file="$1"
    local actual_file="$2"
    local name="$3"
    if diff -u "$expected_file" "$actual_file" > /tmp/asserts.$$.diff 2>&1; then
        ASSERT_PASS=$((ASSERT_PASS + 1))
        printf "  PASS: %s\n" "$name"
    else
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        ASSERT_NAMES_FAILED="$ASSERT_NAMES_FAILED\n  - $name"
        printf "  FAIL: %s\n" "$name"
        cat /tmp/asserts.$$.diff
    fi
    rm -f /tmp/asserts.$$.diff
}

assert_exit_code() {
    local expected="$1"
    shift
    local name="last:$*"
    "$@" > /dev/null 2>&1
    local actual=$?
    if [ "$expected" = "$actual" ]; then
        ASSERT_PASS=$((ASSERT_PASS + 1))
        printf "  PASS: %s (exit=%d)\n" "$name" "$actual"
    else
        ASSERT_FAIL=$((ASSERT_FAIL + 1))
        printf "  FAIL: %s (expected exit=%d, got %d)\n" "$name" "$expected" "$actual"
    fi
}

assert_summary() {
    printf "\n=== %d passed, %d failed ===\n" "$ASSERT_PASS" "$ASSERT_FAIL"
    if [ "$ASSERT_FAIL" -gt 0 ]; then
        printf "Failed tests:%b\n" "$ASSERT_NAMES_FAILED"
        return 1
    fi
    return 0
}
