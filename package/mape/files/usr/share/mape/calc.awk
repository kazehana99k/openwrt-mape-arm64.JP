#!/usr/bin/awk -f
#
# calc.awk — MAP-E parameter calculator core.
#
# Usage:  awk -f calc.awk -v pd=<prefix>/<len> -v rules=<rules.json>
#
# Translates fc2 calculator JavaScript (docs/reference-fc2-calc.html
# lines 705-841) to awk. Emits a JSON object on stdout describing the
# matched rule, computed CE IPv6, IPv4, PSID, and port sets.
#
# Exit codes:
#   0  success
#   2  PD prefix could not be parsed
#   3  no matching rule in rules.json
#
# Reads rules.json line-by-line; relies on the fixed shape produced by
# tools/extract-fc2-rules.awk.

BEGIN {
    if (pd == "") { print "calc.awk: -v pd=<prefix>/<len> required" > "/dev/stderr"; exit 2 }
    if (rules == "") { print "calc.awk: -v rules=<rules.json> required" > "/dev/stderr"; exit 2 }

    parse_pd(pd, hextet)
    prefix31 = hextet[0] * 65536 + and_u16(hextet[1], 0xfffe)
    prefix38 = hextet[0] * 16777216 + hextet[1] * 256 + rshift_u16(and_u16(hextet[2], 0xfc00), 8)

    if (DEBUG) {
        printf "DEBUG hextet: %x %x %x %x\n", hextet[0], hextet[1], hextet[2], hextet[3] > "/dev/stderr"
        printf "DEBUG prefix31=%x prefix38=%x\n", prefix31, prefix38 > "/dev/stderr"
    }

    matched_v6l = -1
    # Inject the rules file as input
    ARGV[ARGC] = rules
    ARGC++
}

# Parse "X:X:X:X:...:X/L" into hextet[0..3] (only first 4 are used as MAP-E
# input). The "::" shorthand is handled by replacing it with explicit zeros.
function parse_pd(s, h,    body, len, parts, n, i, expanded, n_existing, copy, n_zero, zero_str) {
    # Strip /len suffix if present
    if (match(s, /\/[0-9]+$/)) {
        body = substr(s, 1, RSTART - 1)
    } else {
        body = s
    }

    # Expand "::" shorthand
    if (index(body, "::")) {
        # Count existing hextets
        n_existing = 0
        copy = body
        gsub(/::/, ":", copy)
        n_existing = split(copy, parts, ":")
        # We need 8 hextets; insert (8 - n_existing) zeros where :: was
        n_zero = 8 - n_existing
        zero_str = ""
        for (i = 0; i < n_zero; i++) zero_str = zero_str ":0"
        zero_str = zero_str ":"
        gsub(/::/, zero_str, body)
        sub(/^:/, "", body)
        sub(/:$/, "", body)
    }

    n = split(body, parts, ":")
    for (i = 0; i < 4; i++) {
        if (i < n && parts[i+1] != "") {
            h[i] = strtonum_hex(parts[i+1])
        } else {
            h[i] = 0
        }
    }
}

# Parse hex string (no 0x prefix) to integer. Pure-awk implementation
# (gawk's strtonum() is not available on busybox awk).
function strtonum_hex(s,    i, c, v, r) {
    r = 0
    for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        if      (c >= "0" && c <= "9") v = _ord(c) - _ord("0")
        else if (c >= "a" && c <= "f") v = _ord(c) - _ord("a") + 10
        else return 0
        r = r * 16 + v
    }
    return r
}

# Character-to-ordinal helper (busybox awk lacks ord()).
function _ord(c,    i) {
    for (i = 0; i < 128; i++)
        if (sprintf("%c", i) == c) return i
    return -1
}

# 16-bit AND. AWK has and() in gawk but not in busybox. We provide a
# portable version using arithmetic.
function and_u16(a, b,    r, i, abit, bbit) {
    r = 0
    for (i = 0; i < 16; i++) {
        abit = int(a / (2^i)) % 2
        bbit = int(b / (2^i)) % 2
        if (abit && bbit) r = r + (2^i)
    }
    return r
}

# 16-bit right shift.
function rshift_u16(a, n) {
    return int(a / (2^n))
}

# 16-bit left shift.
function lshift_u16(a, n) {
    return int(a * (2^n))
}

# 16-bit OR.
function or_u16(a, b,    r, i, abit, bbit) {
    r = 0
    for (i = 0; i < 16; i++) {
        abit = int(a / (2^i)) % 2
        bbit = int(b / (2^i)) % 2
        if (abit || bbit) r = r + (2^i)
    }
    return r
}

# Read rules.json line by line. The format is fixed (produced by
# extract-fc2-rules.awk):
#     {
#       "id": "...",
#       "isp_name": "...",
#       "br": "...",
#       "v6_prefix": "...",
#       "v6_prefix_len": N,
#       "v4_prefix": "...",
#       "v4_prefix_len": N,
#       "ea_len": N,
#       "psid_offset": N,
#       "psid_len": N
#     }

FNR == 1 { rule_count = 0; in_rule = 0 }

FILENAME == rules && /^    \{/   { in_rule = 1; cur_id = ""; next }
FILENAME == rules && /^    \}/   {
    if (in_rule) {
        try_match(cur_id, cur_isp, cur_br, cur_v6p, cur_v6l + 0,
                  cur_v4p, cur_v4l + 0, cur_ealen + 0,
                  cur_offset + 0, cur_psidlen + 0)
        rule_count++
    }
    in_rule = 0
    next
}

FILENAME == rules && in_rule {
    if      ($0 ~ /"id":/)              cur_id      = json_str_value($0)
    else if ($0 ~ /"isp_name":/)        cur_isp     = json_str_value($0)
    else if ($0 ~ /"br":/)              cur_br      = json_str_value($0)
    else if ($0 ~ /"v6_prefix":/)       cur_v6p     = json_str_value($0)
    else if ($0 ~ /"v6_prefix_len":/)   cur_v6l     = json_num_value($0)
    else if ($0 ~ /"v4_prefix":/)       cur_v4p     = json_str_value($0)
    else if ($0 ~ /"v4_prefix_len":/)   cur_v4l     = json_num_value($0)
    else if ($0 ~ /"ea_len":/)          cur_ealen   = json_num_value($0)
    else if ($0 ~ /"psid_offset":/)     cur_offset  = json_num_value($0)
    else if ($0 ~ /"psid_len":/)        cur_psidlen = json_num_value($0)
}

function json_str_value(line,    v) {
    v = line
    sub(/^[^:]*:[[:space:]]*"/, "", v)
    sub(/",?[[:space:]]*$/, "", v)
    return v
}

function json_num_value(line,    v) {
    v = line
    sub(/^[^:]*:[[:space:]]*/, "", v)
    sub(/,?[[:space:]]*$/, "", v)
    return v + 0
}

# Try to match a rule against the current PD. Keep the most-specific match
# (longest v6_prefix_len) since BIGLOBE /38 entries overlap BIGLOBE /31.
function try_match(id, isp, br, v6p, v6l, v4p, v4l, ealen, offset, psidlen,
                   key, match_key, rule_h) {

    if (v6l == 31)      key = prefix31 / 2   # /31 → top 31 bits
    else if (v6l == 38) key = prefix38 / 4   # /38 → top 38 bits
    else                return                # unsupported prefix length

    # Compute the rule's key from its v6_prefix string
    parse_pd(v6p, rule_h)
    if (v6l == 31) {
        match_key = (rule_h[0] * 65536 + and_u16(rule_h[1], 0xfffe)) / 2
    } else {
        match_key = (rule_h[0] * 16777216 + rule_h[1] * 256 + rshift_u16(and_u16(rule_h[2], 0xfc00), 8)) / 4
    }

    if (key != match_key) return

    if (v6l > matched_v6l) {
        matched_v6l = v6l
        matched_id = id
        matched_isp = isp
        matched_br = br
        matched_v6p = v6p
        matched_v4p = v4p
        matched_v4l = v4l
        matched_ealen = ealen
        matched_offset = offset
        matched_psidlen = psidlen
    }
}

END {
    if (matched_id == "") {
        print "calc.awk: no rule matched PD " pd > "/dev/stderr"
        exit 3
    }
    if (DEBUG) {
        printf "DEBUG matched_rule: %s\n", matched_id > "/dev/stderr"
        printf "DEBUG ealen=%d offset=%d psidlen=%d v4p=%s/%d\n",
               matched_ealen, matched_offset, matched_psidlen,
               matched_v4p, matched_v4l > "/dev/stderr"
    }

    # IPv4 extraction (translates fc2 line 721-748)
    parse_pd(matched_v6p, rule_h)
    n_oct = split(matched_v4p, oct, ".")
    # oct[1..n_oct] currently has rule's v4 prefix octets

    if (matched_v6l == 31 && matched_psidlen == 8) {
        # Octet[1] |= hextet[1] & 0x0001
        oct[2] = or_u16(oct[2], and_u16(hextet[1], 0x0001))
        # Octet[2] = (hextet[2] & 0xff00) >> 8
        oct[3] = rshift_u16(and_u16(hextet[2], 0xff00), 8)
        # Octet[3] = hextet[2] & 0x00ff
        oct[4] = and_u16(hextet[2], 0x00ff)
        psid = rshift_u16(and_u16(hextet[3], 0xff00), 8)
    } else if (matched_v6l == 38 && matched_psidlen == 8) {
        # Octet[2] |= (hextet[2] & 0x0300) >> 8
        oct[3] = or_u16(oct[3], rshift_u16(and_u16(hextet[2], 0x0300), 8))
        # Octet[3] = hextet[2] & 0x00ff
        oct[4] = and_u16(hextet[2], 0x00ff)
        psid = rshift_u16(and_u16(hextet[3], 0xff00), 8)
    } else if (matched_v6l == 38 && matched_psidlen == 6) {
        # Octet[2] |= (hextet[2] & 0x03c0) >> 6
        oct[3] = or_u16(oct[3], rshift_u16(and_u16(hextet[2], 0x03c0), 6))
        # Octet[3] = ((hextet[2] & 0x003f) << 2) | ((hextet[3] & 0xc000) >> 14)
        oct[4] = or_u16(lshift_u16(and_u16(hextet[2], 0x003f), 2),
                        rshift_u16(and_u16(hextet[3], 0xc000), 14))
        psid = rshift_u16(and_u16(hextet[3], 0x3f00), 8)
    }
    ipv4 = oct[1] "." oct[2] "." oct[3] "." oct[4]

    if (DEBUG) {
        printf "DEBUG ipv4: %s\n", ipv4 > "/dev/stderr"
        printf "DEBUG psid: %d\n", psid > "/dev/stderr"
    }

    # Port set computation (fc2 line 757-766)
    n_sets = (2 ^ matched_offset) - 1
    set_size = 2 ^ (16 - matched_offset - matched_psidlen)
    total_ports = n_sets * set_size

    delete port_sets
    for (a = 1; a <= n_sets; a++) {
        port_start = lshift_u16(a, 16 - matched_offset) + lshift_u16(psid, 16 - matched_offset - matched_psidlen)
        port_end = port_start + set_size - 1
        port_sets[a, "start"] = port_start
        port_sets[a, "end"] = port_end
        # Probability of selecting this set when randomly distributing
        # outgoing connections among all available source ports.
        port_sets[a, "prob"] = sprintf("%.5f", set_size / total_ports)

        if (DEBUG) {
            printf "DEBUG port_set: %d-%d\n", port_start, port_end > "/dev/stderr"
        }
    }

    # CE IPv6 construction (fc2 line 769-788, draft mode)
    if (and_u16(hextet[3], 0xff) != 0) {
        printf "calc.awk: warning: PD lower bits non-zero, may be /60 or /48\n" > "/dev/stderr"
    }
    ce_h[0] = hextet[0]
    ce_h[1] = hextet[1]
    ce_h[2] = hextet[2]
    ce_h[3] = and_u16(hextet[3], 0xff00)
    ce_h[4] = oct[1]
    ce_h[5] = or_u16(lshift_u16(oct[2], 8), oct[3])
    ce_h[6] = lshift_u16(oct[4], 8)
    ce_h[7] = lshift_u16(psid, 8)

    ce = ""
    for (i = 0; i < 8; i++) {
        if (i > 0) ce = ce ":"
        ce = ce sprintf("%x", ce_h[i])
    }

    if (DEBUG) {
        printf "DEBUG ce: %s\n", ce > "/dev/stderr"
    }

    # Final JSON output
    print "{"
    printf "  \"rule_id\": \"%s\",\n", matched_id
    printf "  \"isp_name\": \"%s\",\n", matched_isp
    printf "  \"br_ipv6\": \"%s\",\n", matched_br
    printf "  \"ce_ipv6\": \"%s\",\n", ce
    printf "  \"ipv4\": \"%s\",\n", ipv4
    printf "  \"psid\": %d,\n", psid
    printf "  \"psid_offset\": %d,\n", matched_offset
    printf "  \"psid_len\": %d,\n", matched_psidlen
    printf "  \"ea_len\": %d,\n", matched_ealen
    printf "  \"v4_prefix_len\": %d,\n", matched_v4l
    printf "  \"port_sets\": [\n"
    for (a = 1; a <= n_sets; a++) {
        ps_start = port_sets[a, "start"]
        ps_end   = port_sets[a, "end"]
        ps_prob  = port_sets[a, "prob"]
        printf "    {\"start\": %d, \"end\": %d, \"probability\": \"%s\"}", ps_start, ps_end, ps_prob
        if (a < n_sets) print ","
        else print ""
    }
    print "  ]"
    print "}"
}
