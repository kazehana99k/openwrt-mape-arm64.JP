#!/usr/bin/awk -f
#
# extract-fc2-rules.awk
#
# Reads UTF-8-converted fc2 calculator HTML on stdin, writes rules.json on
# stdout. The fc2 source has three rule tables; each entry produces one
# rule object.
#
# Algorithm parameters (per fc2 calc() line 705-841):
#   ruleprefix31      → ip6_len=31, psidlen=8, offset=4, ealen=25, v4_len=15
#   ruleprefix38      → ip6_len=38, psidlen=8, offset=4, ealen=18, v4_len=22
#   ruleprefix38_20   → ip6_len=38, psidlen=6, offset=6, ealen=18, v4_len=20
#
# BR mapping (per fc2 calc() line 812-822):
#   prefix31 in [0x24047a80, 0x24047a84) → 2001:260:700:1::1:275  (BIGLOBE A)
#   prefix31 in [0x24047a84, 0x24047a88) → 2001:260:700:1::1:276  (BIGLOBE B)
#   prefix31 in [0x240b0010, 0x240b0014) | [0x240b0250, 0x240b0254)
#                                        → 2404:9200:225:100::64  (JPNE v6plus)
#   ruleprefix38_20                       → 2001:380:a120::9       (OCN)
#   ruleprefix38 (regular)                → 2001:260:700:1::1:275  (inferred
#                                          BIGLOBE A — fc2 leaves this blank
#                                          but all entries fall in BIGLOBE
#                                          address space; same BR as /31 A)

BEGIN {
    table = ""
    rule_count = 0
    print "{"
    print "  \"version\": 1,"
    print "  \"source\": \"https://ipv4.web.fc2.com/map-e.html\","
    print "  \"rules\": ["
}

/var ruleprefix31 = \{/    { table = "31";    next }
/var ruleprefix38 = \{/    { table = "38";    next }
/var ruleprefix38_20 = \{/ { table = "38_20"; next }
/^[[:space:]]*\};?[[:space:]]*$/ { table = ""; next }

table != "" && /^[[:space:]]*0x[0-9a-fA-F]+:[[:space:]]*\[/ {
    line = $0
    sub(/^[[:space:]]*0x/, "", line)
    n = index(line, ":")
    keyhex = substr(line, 1, n - 1)
    rest = substr(line, n + 1)
    sub(/^[^\[]*\[/, "", rest)
    sub(/\].*/, "", rest)
    gsub(/[[:space:]]/, "", rest)
    n_oct = split(rest, oct, ",")
    emit_rule(table, keyhex, oct, n_oct)
}

END {
    print ""
    print "  ]"
    print "}"
    printf "Extracted %d rules\n", rule_count > "/dev/stderr"
}

function hex2int(s,    i, c, v, r) {
    r = 0
    for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        if      (c >= "0" && c <= "9") v = ord(c) - ord("0")
        else if (c >= "a" && c <= "f") v = ord(c) - ord("a") + 10
        else return -1
        r = r * 16 + v
    }
    return r
}

function ord(c,    i) {
    for (i = 0; i < 128; i++)
        if (sprintf("%c", i) == c) return i
    return -1
}

function emit_rule(t, keyhex, oct, n_oct,
                   v6h1, v6h2, v6h3, v6str, v4str,
                   v6len, v4len, ealen, psidlen, offset,
                   br, isp, idpfx, id, key_int, key_high, key_low) {

    if (t == "31") {
        v6len = 31; psidlen = 8; offset = 4; ealen = 25; v4len = 15
        key_int = hex2int(keyhex)
        v6h1 = sprintf("%x", int(key_int / 65536) % 65536)
        v6h2 = sprintf("%x", int(key_int) % 65536)
        v6str = v6h1 ":" v6h2 "::"
        v4str = oct[1] "." oct[2] ".0.0"
        if (key_int >= hex2int("24047a80") && key_int < hex2int("24047a84")) {
            br = "2001:260:700:1::1:275"; isp = "BIGLOBE IPv6オプション (A)"
            idpfx = "biglobe-a-"
        } else if (key_int >= hex2int("24047a84") && key_int < hex2int("24047a88")) {
            br = "2001:260:700:1::1:276"; isp = "BIGLOBE IPv6オプション (B)"
            idpfx = "biglobe-b-"
        } else if ((key_int >= hex2int("240b0010") && key_int < hex2int("240b0014")) ||
                   (key_int >= hex2int("240b0250") && key_int < hex2int("240b0254"))) {
            br = "2404:9200:225:100::64"; isp = "JPNE v6plus"
            idpfx = "jpne-"
        } else {
            br = "unknown"; isp = "unknown"
            idpfx = "unknown-"
        }
        id = idpfx v6h1 "-" v6h2
    } else if (t == "38") {
        v6len = 38; psidlen = 8; offset = 4; ealen = 18; v4len = 22
        key_high = hex2int(substr(keyhex, 1, 8))
        key_low  = hex2int(substr(keyhex, 9, 2))
        v6h1 = sprintf("%x", int(key_high / 65536) % 65536)
        v6h2 = sprintf("%x", int(key_high) % 65536)
        v6h3 = sprintf("%x", int(key_low * 256))
        v6str = v6h1 ":" v6h2 ":" v6h3 "::"
        v4str = oct[1] "." oct[2] "." oct[3] ".0"
        br = "2001:260:700:1::1:275"
        isp = "BIGLOBE IPv6オプション (A) /38 sub-pool"
        id = "biglobe-a-" v6h1 "-" v6h2 "-" v6h3
    } else if (t == "38_20") {
        v6len = 38; psidlen = 6; offset = 6; ealen = 18; v4len = 20
        key_high = hex2int(substr(keyhex, 1, 8))
        key_low  = hex2int(substr(keyhex, 9, 2))
        v6h1 = sprintf("%x", int(key_high / 65536) % 65536)
        v6h2 = sprintf("%x", int(key_high) % 65536)
        v6h3 = sprintf("%x", int(key_low * 256))
        v6str = v6h1 ":" v6h2 ":" v6h3 "::"
        v4str = oct[1] "." oct[2] "." oct[3] ".0"
        br = "2001:380:a120::9"
        isp = "OCN バーチャルコネクト"
        id = "ocn-" v6h1 "-" v6h2 "-" v6h3
    } else {
        return
    }

    if (rule_count > 0) print ","
    rule_count++

    printf "    {\n"
    printf "      \"id\": \"%s\",\n", id
    printf "      \"isp_name\": \"%s\",\n", isp
    printf "      \"br\": \"%s\",\n", br
    printf "      \"v6_prefix\": \"%s\",\n", v6str
    printf "      \"v6_prefix_len\": %d,\n", v6len
    printf "      \"v4_prefix\": \"%s\",\n", v4str
    printf "      \"v4_prefix_len\": %d,\n", v4len
    printf "      \"ea_len\": %d,\n", ealen
    printf "      \"psid_offset\": %d,\n", offset
    printf "      \"psid_len\": %d\n", psidlen
    printf "    }"
}
