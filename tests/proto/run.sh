#!/bin/sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/lib/asserts.sh"

export MAPE_CALC="$ROOT/package/mape/files/usr/bin/mape-calc"
export MAPE_RULES_JSON="$ROOT/package/mape/files/usr/share/mape/rules.json"
export MAPE_CALC_AWK="$ROOT/package/mape/files/usr/share/mape/calc.awk"

PROTO="$ROOT/package/mape/files/lib/netifd/proto/mape.sh"

# Source proto handler in include-only mode with stubs.
INCLUDE_ONLY=1
. "$ROOT/tests/proto/lib/netifd-proto-stub.sh"
. "$PROTO"

# Confirm the helpers exist after sourcing.
type _mape_run >/dev/null 2>&1
assert_eq 0 $? "_mape_run defined after include-only source"

type proto_mape_init_config >/dev/null 2>&1
assert_eq 0 $? "proto_mape_init_config defined"

type _mape_setup >/dev/null 2>&1
assert_eq 0 $? "_mape_setup defined (stub for now)"

# Dry-run smoke
out=$(MAPE_DRY_RUN=1 _mape_run ip -6 tunnel add foo 2>&1)
echo "$out" | grep -q '^RUN: ip -6 tunnel add foo'
assert_eq 0 $? "_mape_run dry-run prints RUN: prefix"

# Test: PD-direct mode → calls mape-calc and exposes ce_ipv6, ipv4, etc.
TEST_PD_PREFIX="2404:7a80:0:0::/56"
TEST_WAN_DEV="eth4"
unset TEST_TUNLINK TEST_IP6PREFIX TEST_PEERADDR

if command -v jsonfilter >/dev/null 2>&1; then
    _mape_resolve_params 2>/dev/null
    assert_eq "2404:7a80:0:0:85:c800:0:0" "$P_CE_IPV6" "resolve: P_CE_IPV6 from PD"
    assert_eq "133.200.0.0" "$P_IPV4" "resolve: P_IPV4 from PD"
    assert_eq "2001:260:700:1::1:275" "$P_BR_IPV6" "resolve: P_BR_IPV6 from PD"
else
    printf "  SKIP: _mape_resolve_params (jsonfilter unavailable)\n"
fi

# Set P_* vars directly so we can exercise _mape_build_tunnel without
# depending on jsonfilter-driven _mape_resolve_params.
P_CE_IPV6="2404:7a80:0:0:85:c800:0:0"
P_IPV4="133.200.0.0"
P_BR_IPV6="2001:260:700:1::1:275"
wan_dev="eth4"
mtu="1460"
encaplimit="none"

actual=$(MAPE_DRY_RUN=1 _mape_build_tunnel mape 2>&1)
echo "$actual" > /tmp/build-tunnel.out
assert_file_eq "$ROOT/tests/proto/golden/build-tunnel.cmds" /tmp/build-tunnel.out \
    "build_tunnel emits expected command sequence"

actual=$(MAPE_DRY_RUN=1 _mape_setup_default_route_and_forward mape br-lan 2>&1)
echo "$actual" > /tmp/route.out
assert_file_eq "$ROOT/tests/proto/golden/route-and-forward.cmds" /tmp/route.out \
    "default route + FORWARD rules"

if command -v jsonfilter >/dev/null 2>&1; then
    P_PORT_SETS_JSON=$(cat "$ROOT/tests/calc/golden/biglobe-2404-7a80-0-0-56.json")
    actual=$(MAPE_DRY_RUN=1 _mape_setup_snat mape "$P_IPV4" "$P_PORT_SETS_JSON" statistic "" 2>&1)
    echo "$actual" > /tmp/snat.out
    assert_file_eq "$ROOT/tests/proto/golden/snat-statistic.cmds" /tmp/snat.out \
        "SNAT statistic mode generates 30 rules (15 sets × 2 protocols)"

    # Reserved port exclusion: with excluded_ports="4099", first set should be skipped
    actual2=$(MAPE_DRY_RUN=1 _mape_setup_snat mape "$P_IPV4" "$P_PORT_SETS_JSON" statistic "4099" 2>&1)
    if echo "$actual2" | grep -q "4096-4111"; then
        printf "  FAIL: first set should have been excluded (contains port 4099)\n"
    else
        printf "  PASS: first set excluded when contains reserved port 4099\n"
    fi
    echo "$actual2" | grep -q "8192-8207"
    assert_eq 0 $? "second set still emitted when first excluded"
else
    printf "  SKIP: SNAT statistic golden (jsonfilter unavailable)\n"
    printf "  SKIP: SNAT reserved-port exclusion (jsonfilter unavailable)\n"
fi

# ICMP SNAT (uses first port set as identifier range; needs jsonfilter)
if command -v jsonfilter >/dev/null 2>&1; then
    actual=$(MAPE_DRY_RUN=1 _mape_setup_icmp_snat mape "$P_IPV4" "$P_PORT_SETS_JSON" 1 2>&1)
    echo "$actual" | grep -q 'iptables -t nat -A POSTROUTING -o mape -p icmp -j SNAT --to-source 133.200.0.0:4096-4111'
    assert_eq 0 $? "ICMP SNAT uses first port set"
else
    printf "  SKIP: ICMP SNAT (jsonfilter unavailable)\n"
fi

# MSS clamp doesn't need jsonfilter
actual=$(MAPE_DRY_RUN=1 _mape_setup_mss_clamp mape 2>&1)
echo "$actual" | grep -q 'iptables -t mangle -A FORWARD -o mape -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
assert_eq 0 $? "TCPMSS clamp on FORWARD outbound"

TMP_STATE=$(mktemp -d)
trap 'rm -rf "$TMP_STATE"' EXIT

# Set P_* vars (test was already setting them; ensure full set is present)
P_CE_IPV6="2404:7a80:0:0:85:c800:0:0"
P_IPV4="133.200.0.0"
P_BR_IPV6="2001:260:700:1::1:275"
P_PSID=0
P_PSID_OFFSET=4
P_PSID_LEN=8
P_EA_LEN=25
P_V4_PREFIX_LEN=15
P_RULE_ID="biglobe-a-2404-7a80"
P_ISP_NAME="BIGLOBE IPv6オプション (A)"
wan_dev="eth4"

MAPE_STATE_DIR="$TMP_STATE" _mape_write_status mape

assert_eq 0 $? "_mape_write_status exit 0"
[ -f "$TMP_STATE/mape.mape.json" ]
assert_eq 0 $? "status file created"

if command -v jsonfilter >/dev/null 2>&1; then
    val=$(jsonfilter -i "$TMP_STATE/mape.mape.json" -e '@.ce_ipv6')
    assert_eq "2404:7a80:0:0:85:c800:0:0" "$val" "status file contains ce_ipv6"
    val=$(jsonfilter -i "$TMP_STATE/mape.mape.json" -e '@.iface')
    assert_eq "mape" "$val" "status file contains iface=mape"
else
    # Fallback: grep the file
    grep -q '"ce_ipv6": "2404:7a80:0:0:85:c800:0:0"' "$TMP_STATE/mape.mape.json"
    assert_eq 0 $? "status file contains ce_ipv6 (grep fallback)"
    grep -q '"iface": "mape"' "$TMP_STATE/mape.mape.json"
    assert_eq 0 $? "status file contains iface=mape (grep fallback)"
fi

# Set up state file to drive teardown
mkdir -p "$TMP_STATE"
cat > "$TMP_STATE/mape.mape.json" <<EOF
{"iface":"mape","ce_ipv6":"2404:7a80:0:0:85:c800:0:0","wan_dev":"eth4"}
EOF
actual=$(MAPE_DRY_RUN=1 MAPE_STATE_DIR="$TMP_STATE" _mape_teardown mape 2>&1 \
         | grep -v '^$')
echo "$actual" > /tmp/teardown.out
assert_file_eq "$ROOT/tests/proto/golden/teardown.cmds" /tmp/teardown.out \
    "teardown emits expected cleanup sequence"

# End-to-end orchestration: requires jsonfilter for _mape_resolve_params + SNAT.
if command -v jsonfilter >/dev/null 2>&1; then
    TEST_PD_PREFIX="2404:7a80:0:0::/56"
    TEST_WAN_DEV="eth4"
    TEST_MTU="1460"
    TEST_ENCAPLIMIT="none"
    TEST_LEGACY_MSSFIX="1"
    TEST_SNAT_MODE="statistic"
    TEST_ICMP_USE_FIRST_SET="1"

    mkdir -p /tmp/mape-state-test
    out=$(MAPE_DRY_RUN=1 \
          MAPE_STATE_DIR=/tmp/mape-state-test \
          MAPE_LAN_BRIDGE=br-lan \
          _mape_setup mape 2>&1)

    # Spot checks (we don't pin the EXACT line count since it depends on
    # whether config/mape exists, but key fragments must be there)
    echo "$out" | grep -q "ip -6 tunnel add mape mode ipip6"
    assert_eq 0 $? "e2e: tunnel add command present"
    echo "$out" | grep -q "ip route add default dev mape"
    assert_eq 0 $? "e2e: default route present"
    echo "$out" | grep -q "iptables -t nat -A POSTROUTING -o mape -p tcp -m statistic"
    assert_eq 0 $? "e2e: SNAT rules emitted"
    echo "$out" | grep -q "iptables -t nat -A POSTROUTING -o mape -p icmp"
    assert_eq 0 $? "e2e: ICMP SNAT emitted"
    echo "$out" | grep -q "iptables -t mangle -A FORWARD -o mape -p tcp"
    assert_eq 0 $? "e2e: MSS clamp emitted"
    echo "$out" | grep -q "NETIFD: send_update mape"
    assert_eq 0 $? "e2e: proto_send_update called"
    [ -f /tmp/mape-state-test/mape.mape.json ]
    assert_eq 0 $? "e2e: status file written"

    rm -rf /tmp/mape-state-test
else
    printf "  SKIP: end-to-end orchestration (jsonfilter unavailable)\n"
fi

assert_summary
