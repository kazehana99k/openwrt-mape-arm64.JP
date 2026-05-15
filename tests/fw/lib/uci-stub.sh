#!/bin/sh
# Stub UCI library for shell tests. Reads UCI-format file and provides
# config_load / config_foreach / config_get.

UCI_TEST_FILE=""

config_load() {
    UCI_TEST_FILE="${MAPE_TEST_UCI_FILE:-/dev/null}"
}

config_foreach() {
    local fn="$1" type="$2" cfg
    [ -f "$UCI_TEST_FILE" ] || return 0
    awk -v want="$type" '
        /^config / { in_section = 0; cur_type = $2; gsub(/'\''/, "", $3); cur_name = $3
                     if (cur_type == want) { in_section = 1; print cur_name } }
    ' "$UCI_TEST_FILE" | while read -r cfg; do
        "$fn" "$cfg"
    done
}

config_get() {
    local var="$1" cfg="$2" opt="$3" default="$4"
    local val
    val=$(awk -v cfg="$cfg" -v opt="$opt" '
        /^config / { gsub(/'\''/, "", $3); cur = $3 }
        cur == cfg && $1 == "option" && $2 == opt {
            sub(/^[[:space:]]*option[[:space:]]+[^[:space:]]+[[:space:]]+/, "")
            gsub(/^'\''|'\''$/, "")
            print
            exit
        }
    ' "$UCI_TEST_FILE")
    eval "$var=\"\${val:-\$default}\""
}
