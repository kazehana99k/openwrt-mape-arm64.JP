#!/bin/sh
# /lib/netifd/proto/mape.sh
#
# OpenWrt netifd protocol handler for MAP-E. See docs/superpowers/specs
# for full design rationale.
#
# Behavior is a one-to-one translation of the reference mape.sh
# (docs/reference-mape.sh), parameterized via UCI and managed by netifd.

[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . ../netifd-proto.sh
    init_proto "$@"
}

# Tool paths (overridable for testing).
MAPE_CALC="${MAPE_CALC:-/usr/bin/mape-calc}"

# Run a side-effecting command, or print it under dry-run.
_mape_run() {
    if [ "${MAPE_DRY_RUN:-0}" = 1 ]; then
        printf 'RUN:'
        for arg; do
            case "$arg" in
                *' '*|*\"*) printf ' %s' "\"$arg\"" ;;
                *)          printf ' %s' "$arg" ;;
            esac
        done
        printf '\n'
        return 0
    fi
    "$@"
}

# Like _mape_run but for shell redirections (echo > /proc/sys/...).
_mape_write() {
    local value="$1" path="$2"
    if [ "${MAPE_DRY_RUN:-0}" = 1 ]; then
        printf 'WRITE: %s -> %s\n' "$value" "$path"
        return 0
    fi
    echo "$value" > "$path"
}

proto_mape_init_config() {
    proto_config_add_string  pd_prefix
    proto_config_add_string  tunlink
    proto_config_add_string  ip6prefix
    proto_config_add_int     ip6prefixlen
    proto_config_add_string  ipaddr
    proto_config_add_int     ip4prefixlen
    proto_config_add_string  peeraddr
    proto_config_add_int     ealen
    proto_config_add_int     psidlen
    proto_config_add_int     offset
    proto_config_add_string  rule
    proto_config_add_string  wan_dev
    proto_config_add_int     mtu
    proto_config_add_string  encaplimit
    proto_config_add_boolean legacy_mssfix
    proto_config_add_string  snat_mode
    proto_config_add_boolean icmp_use_first_set
    no_device=1
    available=1
}

proto_mape_setup()    { _mape_setup    "$@"; }
proto_mape_teardown() { _mape_teardown "$@"; }

# Resolve canonical MAP-E parameters into P_* shell variables based on
# input mode:
#   ① pd_prefix set        → call mape-calc compute
#   ② tunlink set          → fetch PD via ubus, then mape-calc compute
#   ③ ip6prefix+ealen+...  → manual mode, skip mape-calc
#
# Outputs:
#   P_CE_IPV6, P_IPV4, P_BR_IPV6, P_PSID, P_PSID_OFFSET, P_PSID_LEN,
#   P_EA_LEN, P_V4_PREFIX_LEN, P_PORT_SETS_JSON, P_RULE_ID, P_ISP_NAME
_mape_resolve_params() {
    local pd json
    if [ -n "$ip6prefix" ] && [ -n "$peeraddr" ] && [ -n "$ealen" ]; then
        # Mode ③: fully manual — synthesize a calc-style JSON from UCI fields.
        # We still call mape-calc to compute CE/IPv4/port_sets from a
        # fake PD that uses the given ip6prefix as v6_prefix.
        # For v0.1 simplicity: require pd_prefix in addition to manual fields,
        # which lets the user override BR/v4_prefix without re-extracting.
        if [ -z "$pd_prefix" ]; then
            echo "_mape_resolve_params: manual mode requires pd_prefix" >&2
            return 1
        fi
        pd="$pd_prefix"
    elif [ -n "$tunlink" ]; then
        # Mode ②: read PD from upstream IPv6 interface.
        pd=$(ubus call "network.interface.$tunlink" status 2>/dev/null \
             | jsonfilter -e "@['ipv6-prefix'][0].address" \
             | head -1)
        local pdlen
        pdlen=$(ubus call "network.interface.$tunlink" status 2>/dev/null \
                | jsonfilter -e "@['ipv6-prefix'][0].mask")
        if [ -z "$pd" ] || [ -z "$pdlen" ]; then
            echo "_mape_resolve_params: cannot read PD from tunlink=$tunlink" >&2
            return 1
        fi
        pd="${pd}/${pdlen}"
    elif [ -n "$pd_prefix" ]; then
        # Mode ①: PD given directly.
        pd="$pd_prefix"
    else
        echo "_mape_resolve_params: must set one of pd_prefix, tunlink, or manual fields" >&2
        return 1
    fi

    json=$("$MAPE_CALC" compute "$pd" 2>/dev/null) || {
        echo "_mape_resolve_params: mape-calc failed for PD '$pd'" >&2
        return 1
    }

    P_CE_IPV6=$(echo "$json" | jsonfilter -e '@.ce_ipv6')
    P_IPV4=$(echo "$json" | jsonfilter -e '@.ipv4')
    P_BR_IPV6=$(echo "$json" | jsonfilter -e '@.br_ipv6')
    P_PSID=$(echo "$json" | jsonfilter -e '@.psid')
    P_PSID_OFFSET=$(echo "$json" | jsonfilter -e '@.psid_offset')
    P_PSID_LEN=$(echo "$json" | jsonfilter -e '@.psid_len')
    P_EA_LEN=$(echo "$json" | jsonfilter -e '@.ea_len')
    P_V4_PREFIX_LEN=$(echo "$json" | jsonfilter -e '@.v4_prefix_len')
    P_RULE_ID=$(echo "$json" | jsonfilter -e '@.rule_id')
    P_ISP_NAME=$(echo "$json" | jsonfilter -e '@.isp_name')
    P_PORT_SETS_JSON="$json"   # keep full JSON for SNAT loop

    # Honor manual override of peeraddr (user knows which BR even if rule
    # has no entry).
    if [ -n "$peeraddr" ]; then
        P_BR_IPV6="$peeraddr"
    fi
    return 0
}

# Build the ipip6 tunnel and assign IPv4. cfg = interface name (also tunnel
# device name). Reads P_* from earlier _mape_resolve_params.
_mape_build_tunnel() {
    local cfg="$1"
    local dev="${cfg}"

    # Kernel params (translated from mape.sh:36-39)
    _mape_write 1 /proc/sys/net/ipv4/ip_forward
    _mape_write 0 /proc/sys/net/ipv4/conf/all/rp_filter
    _mape_write 0 /proc/sys/net/ipv4/conf/default/rp_filter
    _mape_write 0 "/proc/sys/net/ipv4/conf/$wan_dev/rp_filter"

    # Bind CE address to WAN dev (mape.sh:59-60)
    _mape_run ip -6 addr del "$P_CE_IPV6/128" dev "$wan_dev" || true
    _mape_run ip -6 addr add "$P_CE_IPV6/128" dev "$wan_dev"

    # Build tunnel (mape.sh:62-66)
    _mape_run ip -6 tunnel add "$dev" mode ipip6 \
        remote "$P_BR_IPV6" \
        local "$P_CE_IPV6" \
        encaplimit "${encaplimit:-none}" \
        dev "$wan_dev"

    _mape_run ip link set "$dev" up
    [ -n "$mtu" ] && _mape_run ip link set "$dev" mtu "$mtu"
    # Address binding is handled by netifd via proto_add_ipv4_address in
    # _mape_setup. Don't ip-addr-add here — netifd would scrub it.
    return 0
}

# Delete any existing default route(s) so ours becomes the only one.
# (mape.sh:71-73 — destructive, only call inside _mape_setup proper.)
_mape_purge_default_route() {
    if [ "${MAPE_DRY_RUN:-0}" = 1 ]; then
        echo 'PURGE: default routes (skipped under dry-run; live: while ip route|grep default; do ip route del default; done)'
        return 0
    fi
    while ip route | grep -q '^default '; do
        ip route del default 2>/dev/null || break
    done
    ip route flush cache
}

# Add default route via tunnel + FORWARD ACCEPT rules. lan_bridge is the
# bridge name (br-lan). Both rules tagged for clean teardown.
_mape_setup_default_route_and_forward() {
    local cfg="$1" lan_bridge="$2"
    local dev="$cfg"

    _mape_run ip route add default dev "$dev"

    # Insert at position 1 to win over fw3's REJECT (mape.sh:78-79)
    _mape_run iptables -I FORWARD 1 \
        -i "$dev" -o "$lan_bridge" -j ACCEPT \
        -m comment --comment "mape:$cfg"
    _mape_run iptables -I FORWARD 1 \
        -i "$lan_bridge" -o "$dev" -j ACCEPT \
        -m comment --comment "mape:$cfg"
}

# Generate SNAT rules. mode = "statistic" (default) or "fullconenat"
# (requires kmod-ipt-fullconenat).
#
# NOTE: all 15 port sets receive the same probability value from calc.awk
# (0.06667 = 1/15).  This means later sets get less traffic than earlier ones.
# True uniform distribution would require conditional probabilities
# (1/15, 1/14, 1/13, … 1/1); that optimisation is deferred to v0.2.
#
# excluded_ports = space/newline-separated port numbers to skip from SNAT
# (used by mape-fw for port-forwarding DNAT conflict prevention).
_mape_setup_snat() {
    local cfg="$1"
    local ipv4="$2"
    local port_sets_json="$3"
    local mode="${4:-statistic}"
    local excluded_ports="$5"

    local dev="$cfg"
    local i=0 start end proto

    # First pass: collect non-excluded sets into a space-separated list
    # of "start:end" entries. We need to know how many sets remain
    # before emitting iptables rules so we can compute conditional
    # probabilities (1/N, 1/(N-1), ..., 1/1) — this is the same
    # technique mape.sh uses to guarantee every connection is SNAT'd
    # to a valid source port (uniform per-rule probability would leave
    # ~44% of connections leaking through with random ephemeral ports
    # that the BR drops).
    local sets="" n=0
    while start=$(echo "$port_sets_json" | jsonfilter -e "@.port_sets[$i].start" 2>/dev/null) \
       && [ -n "$start" ]; do
        end=$(echo "$port_sets_json" | jsonfilter -e "@.port_sets[$i].end")
        if ! _mape_set_overlaps_excluded "$start" "$end" "$excluded_ports"; then
            sets="$sets $start:$end"
            n=$((n + 1))
        fi
        i=$((i + 1))
    done

    # Second pass: emit rules with conditional probabilities. Each rule's
    # probability is 1/(remaining sets), so the LAST rule has prob=1.0
    # and catches anything not matched earlier.
    local idx=1 entry remaining prob
    for entry in $sets; do
        start="${entry%:*}"
        end="${entry#*:}"
        remaining=$((n - idx + 1))
        prob=$(awk "BEGIN { printf \"%.6f\", 1/$remaining }")

        case "$mode" in
            fullconenat)
                _mape_run iptables -t nat -A POSTROUTING -o "$dev" \
                    -j FULLCONENAT --to-source "$ipv4" \
                    --random-range "$start-$end" \
                    -m comment --comment "mape:$cfg"
                ;;
            statistic|*)
                for proto in tcp udp; do
                    _mape_run iptables -t nat -A POSTROUTING -o "$dev" \
                        -p "$proto" -m statistic --mode random \
                        --probability "$prob" \
                        -j SNAT --to-source "$ipv4:$start-$end" \
                        -m comment --comment "mape:$cfg"
                done
                ;;
        esac

        idx=$((idx + 1))
    done
}

# True if any port in [start..end] appears in the space/newline-separated
# excluded list.  Returns 1 (false) when excluded list is empty.
_mape_set_overlaps_excluded() {
    local start="$1" end="$2" excluded="$3" p
    [ -n "$excluded" ] || return 1
    for p in $excluded; do
        [ "$p" -ge "$start" ] && [ "$p" -le "$end" ] && return 0
    done
    return 1
}

_mape_setup_icmp_snat() {
    local cfg="$1" ipv4="$2" port_sets_json="$3" use_first="${4:-1}"
    local dev="$cfg" first_start first_end

    [ "$use_first" = 1 ] || return 0

    first_start=$(echo "$port_sets_json" | jsonfilter -e '@.port_sets[0].start')
    first_end=$(echo "$port_sets_json" | jsonfilter -e '@.port_sets[0].end')

    _mape_run iptables -t nat -A POSTROUTING -o "$dev" \
        -p icmp -j SNAT --to-source "$ipv4:$first_start-$first_end" \
        -m comment --comment "mape:$cfg"
}

_mape_setup_mss_clamp() {
    local cfg="$1"
    local dev="$cfg"

    _mape_run iptables -t mangle -A FORWARD -o "$dev" \
        -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu \
        -m comment --comment "mape:$cfg"
}

# Write resolved MAP-E parameters to a JSON status file so that mape-fw
# and LuCI can read them without re-running mape-calc.
# The file is: ${MAPE_STATE_DIR:-/var/run}/mape.<cfg>.json
_mape_write_status() {
    local cfg="$1"
    local out="${MAPE_STATE_DIR:-/var/run}/mape.$cfg.json"
    mkdir -p "$(dirname "$out")"

    # Wrap mape-calc output with iface name and timestamp.
    cat > "$out" <<EOF
{
  "iface": "$cfg",
  "rule_id": "$P_RULE_ID",
  "isp_name": "$P_ISP_NAME",
  "ce_ipv6": "$P_CE_IPV6",
  "ipv4": "$P_IPV4",
  "br_ipv6": "$P_BR_IPV6",
  "psid": $P_PSID,
  "psid_offset": $P_PSID_OFFSET,
  "psid_len": $P_PSID_LEN,
  "ea_len": $P_EA_LEN,
  "v4_prefix_len": $P_V4_PREFIX_LEN,
  "wan_dev": "$wan_dev",
  "tunnel_dev": "$cfg",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Remove all iptables rules tagged 'mape:<cfg>' from a given table.
# Live mode uses iptables-save | grep -v | iptables-restore for safety
# (precise per-rule deletion is fragile because you need the exact spec).
_mape_clean_table_by_comment() {
    local table="$1" tag="$2"
    if [ "${MAPE_DRY_RUN:-0}" = 1 ]; then
        echo "PURGE: iptables $table rules tagged '$tag' (skipped under dry-run; live: iterate iptables-save | grep -v $tag | iptables-restore)"
        return 0
    fi
    # iptables-save quotes comment values: --comment "mape:cfg".
    # Match the leading quote so we don't accidentally hit other tags
    # whose names contain ours as a substring.
    iptables-save -t "$table" 2>/dev/null \
        | grep -v -- "--comment \"$tag\"" \
        | iptables-restore -T "$table"
}

_mape_teardown() {
    local cfg="$1"
    local tag="mape:$cfg"

    # Try to read state file to recover P_CE_IPV6 / wan_dev for clean unbinding.
    local state="${MAPE_STATE_DIR:-/var/run}/mape.$cfg.json"
    if [ -f "$state" ]; then
        if command -v jsonfilter >/dev/null 2>&1; then
            P_CE_IPV6=$(jsonfilter -i "$state" -e '@.ce_ipv6' 2>/dev/null)
            wan_dev=$(jsonfilter -i "$state" -e '@.wan_dev' 2>/dev/null)
        else
            # grep-based fallback (works on dev box without jsonfilter)
            P_CE_IPV6=$(sed -n 's/.*"ce_ipv6": *"\([^"]*\)".*/\1/p' "$state" | head -1)
            wan_dev=$(sed -n 's/.*"wan_dev": *"\([^"]*\)".*/\1/p' "$state" | head -1)
        fi
    fi

    _mape_clean_table_by_comment nat    "$tag"
    _mape_clean_table_by_comment filter "$tag"
    _mape_clean_table_by_comment mangle "$tag"

    _mape_run ip route del default dev "$cfg" || true
    _mape_run ip link set "$cfg" down || true
    _mape_run ip -6 tunnel del "$cfg" || true

    if [ -n "$P_CE_IPV6" ] && [ -n "$wan_dev" ]; then
        _mape_run ip -6 addr del "$P_CE_IPV6/128" dev "$wan_dev" || true
    fi

    rm -f "$state"

    # Tell mape-fw to clean its DNAT rules too (safe even if not running).
    [ -x /etc/init.d/mape-fw ] && /etc/init.d/mape-fw stop 2>/dev/null || true
}

_mape_setup() {
    local cfg="$1"

    json_get_vars pd_prefix tunlink wan_dev mtu encaplimit \
                  legacy_mssfix snat_mode rule \
                  ip6prefix ip6prefixlen ipaddr ip4prefixlen \
                  peeraddr ealen psidlen offset icmp_use_first_set

    : "${wan_dev:=eth4}"
    : "${mtu:=1460}"
    : "${encaplimit:=none}"
    : "${legacy_mssfix:=1}"
    : "${snat_mode:=statistic}"
    : "${icmp_use_first_set:=1}"

    local lan_bridge="${MAPE_LAN_BRIDGE:-br-lan}"

    if ! _mape_resolve_params; then
        proto_setup_failed "$cfg"
        return 1
    fi

    # Read excluded_ports from /etc/config/mape (forward sections), if any.
    local excluded_ports=""
    if [ -f /etc/config/mape ]; then
        excluded_ports=$(uci -q show mape \
                         | sed -n "s/^mape\\.[^.]*\\.src_port='\\([0-9]*\\)'$/\\1/p")
    fi

    # Idempotent cleanup: remove any state from a prior (possibly incomplete)
    # setup before adding new rules. Without this, every ifup accumulates
    # iptables duplicates because netifd's teardown path may not have run.
    _mape_clean_table_by_comment nat    "mape:$cfg"
    _mape_clean_table_by_comment filter "mape:$cfg"
    _mape_clean_table_by_comment mangle "mape:$cfg"
    ip link set "$cfg" down 2>/dev/null
    ip -6 tunnel del "$cfg" 2>/dev/null
    ip -6 addr del "$P_CE_IPV6/128" dev "$wan_dev" 2>/dev/null

    _mape_build_tunnel "$cfg"
    _mape_purge_default_route
    _mape_setup_default_route_and_forward "$cfg" "$lan_bridge"
    _mape_setup_snat "$cfg" "$P_IPV4" "$P_PORT_SETS_JSON" "$snat_mode" "$excluded_ports"
    _mape_setup_icmp_snat "$cfg" "$P_IPV4" "$P_PORT_SETS_JSON" "$icmp_use_first_set"
    [ "$legacy_mssfix" = 1 ] && _mape_setup_mss_clamp "$cfg"
    _mape_write_status "$cfg"

    # Tell netifd we're up. proto_init_update sets the L3 device + link state;
    # proto_add_ipv4_address registers the IPv4 with netifd (which then binds
    # it and prevents it from being scrubbed); proto_add_ipv4_route adds the
    # default route through the tunnel.
    proto_init_update "$cfg" 1
    proto_add_ipv4_address "$P_IPV4" "32"
    proto_add_ipv4_route "0.0.0.0" "0"
    proto_set_keepalive "$cfg" 1
    proto_send_update "$cfg"

    # Trigger mape-fw to apply DNAT (safe to call even if no rules)
    [ -x /etc/init.d/mape-fw ] && /etc/init.d/mape-fw reload 2>/dev/null || true
}

[ -n "$INCLUDE_ONLY" ] || add_protocol mape
