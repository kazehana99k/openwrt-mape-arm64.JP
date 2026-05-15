#!/bin/sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/lib/asserts.sh"

INIT_SCRIPT="$ROOT/package/mape/files/etc/init.d/mape-fw"

# Source under test, with /etc/rc.common shebang neutralized
USE_PROCD_HARNESS=1
. "$ROOT/tests/fw/lib/uci-stub.sh"
# Define no-op procd helpers so init.d header doesn't error
procd_open_instance()  { :; }
procd_set_param()      { :; }
procd_close_instance() { :; }

# rc.common helpers we use
START=99; STOP=10; USE_PROCD=1
. "$INIT_SCRIPT"

type apply >/dev/null 2>&1
assert_eq 0 $? "apply function defined"
type clear_all >/dev/null 2>&1
assert_eq 0 $? "clear_all function defined"
type _fw_run >/dev/null 2>&1
assert_eq 0 $? "_fw_run function defined"

# Set up status file so port validation can find PSID range
mkdir -p /tmp/mape-state-fw
cat > /tmp/mape-state-fw/mape.mape.json <<'EOF'
{
  "iface":"mape","ce_ipv6":"2404:7a80:0:0:85:c800:0:0",
  "ipv4":"133.200.0.0","wan_dev":"eth4",
  "psid":0,"psid_offset":4,"psid_len":8
}
EOF
trap 'rm -rf /tmp/mape-state-fw' EXIT

export MAPE_STATE_DIR=/tmp/mape-state-fw
export MAPE_TEST_UCI_FILE="$ROOT/tests/fw/fixtures/sample-mape.uci"
export MAPE_CALC="$ROOT/package/mape/files/usr/bin/mape-calc"
export MAPE_RULES_JSON="$ROOT/package/mape/files/usr/share/mape/rules.json"
export MAPE_CALC_AWK="$ROOT/package/mape/files/usr/share/mape/calc.awk"
export MAPE_LAN_BRIDGE=br-lan

actual=$(MAPE_DRY_RUN=1 apply 2>&1 | grep -v '^LOG:')
echo "$actual" > /tmp/apply.out
assert_file_eq "$ROOT/tests/fw/golden/apply-sample.cmds" /tmp/apply.out \
    "apply emits expected DNAT+FORWARD for sample UCI"

export MAPE_TEST_UCI_FILE="$ROOT/tests/fw/fixtures/bad-port.uci"

actual=$(MAPE_DRY_RUN=1 apply 2>&1)

# Should NOT contain any RUN: iptables line
if echo "$actual" | grep -q '^RUN: iptables'; then
    rc=1
else
    rc=0
fi
assert_eq 0 $rc "bad-port fixture emits no iptables rules"

# Should contain the warning message
if echo "$actual" | grep -q "src_port 80 not in PSID-allocated range"; then
    rc=0
else
    rc=1
fi
assert_eq 0 $rc "bad port logged with rejection reason"

assert_summary
