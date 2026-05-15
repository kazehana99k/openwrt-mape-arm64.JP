#!/bin/sh
# Minimal stub of /lib/netifd/netifd-proto.sh for unit testing.
# Provides no-op versions of the netifd protocol API.

init_proto()           { :; }
add_protocol()         { :; }
proto_init_update()    { echo "NETIFD: init_update $*"; }
proto_send_update()    { echo "NETIFD: send_update $*"; }
proto_set_keepalive()  { echo "NETIFD: keepalive $*"; }
proto_setup_failed()   { echo "NETIFD: setup_failed $*"; }
proto_config_add_string()  { :; }
proto_config_add_int()     { :; }
proto_config_add_boolean() { :; }

# Stub json_get_vars: read variable values from environment (set by tests).
json_get_vars() {
    # When tests run, they set TEST_PD_PREFIX, TEST_WAN_DEV, etc.
    # Re-export these as the variable names json_get_vars would set.
    for var; do
        upper=$(echo "TEST_$var" | tr '[:lower:]' '[:upper:]')
        eval "$var=\${$upper:-}"
    done
}
