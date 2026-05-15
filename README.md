# openwrt-map-e

A clean-room MAP-E client for OpenWrt / QWrt routers behind Japanese ISPs
(BIGLOBE IPv6オプション, JPNE v6plus, OCN バーチャルコネクト, etc.).

## Why this exists

QSDK / QWrt's built-in MAP-E (`proto='none' type='map-e'`) has bugs that
prevent the tunnel from establishing or fw3 from recognizing it. This
package replaces it with a working implementation that:

- Auto-detects the ISP from your IPv6 prefix delegation (BIGLOBE / JPNE / OCN
  via embedded fc2.com rule database; other ISPs via manual mode)
- Builds the `ipip6` tunnel as a proper netifd interface (`ifup mape`,
  `ifdown mape`)
- Generates SNAT rules covering the assigned PSID port range
- Exposes UCI-configured port forwarding with PSID-range validation
- Pure iptables (no nftables required); compatible with fw3

## Installation

This is the **backend** package. LuCI integration is a separate package
(see Plan B). For now, configure via CLI/UCI.

### Prerequisites

```
opkg install ip-full iptables iptables-mod-conntrack-extra \
             kmod-ip6-tunnel kmod-iptunnel6 jsonfilter
```

### Files to deploy

```
mkdir -p /usr/share/mape /usr/bin /lib/netifd/proto \
         /etc/init.d /etc/hotplug.d/iface /etc/config /etc/sysctl.d
cp package/mape/files/usr/bin/mape-calc                    /usr/bin/
cp package/mape/files/usr/share/mape/calc.awk              /usr/share/mape/
cp package/mape/files/usr/share/mape/rules.json            /usr/share/mape/
cp package/mape/files/lib/netifd/proto/mape.sh             /lib/netifd/proto/
cp package/mape/files/etc/init.d/mape-fw                   /etc/init.d/
cp package/mape/files/etc/hotplug.d/iface/40-mape          /etc/hotplug.d/iface/
cp package/mape/files/etc/sysctl.d/99-mape.conf            /etc/sysctl.d/
chmod +x /usr/bin/mape-calc /etc/init.d/mape-fw /etc/hotplug.d/iface/40-mape
sysctl -p /etc/sysctl.d/99-mape.conf
```

(Plan C will provide an IPK so all of this becomes `opkg install mape_*.ipk`.)

## Migrating from the standalone mape.sh

If you currently run a hand-written `mape.sh`:

### 1. Stop the script

Remove the call from `/etc/rc.local` or wherever you launch it. Don't run
`mape.sh` after the new package is in place.

### 2. Clean orphan UCI from QWrt's broken built-in MAP-E

Your `/etc/config/network` likely contains residue from the disabled
QSDK MAP-E (`type='map-e'`, `peeraddr`, `ipaddr`, `ealen`, etc. on the
`wan` section). Remove them:

```sh
for f in type peeraddr ipaddr ip4prefixlen ip6prefix ip6prefixlen \
         ealen psidlen offset tunlink; do
    uci delete network.wan.$f 2>/dev/null
done
uci commit network
```

### 3. Define the mape interface

```sh
uci set network.mape=interface
uci set network.mape.proto=mape
uci set network.mape.pd_prefix='2404:7a80:0:0::/56'    # ← your PD
uci set network.mape.wan_dev='eth4'                           # ← your physical WAN
uci set network.mape.mtu='1460'
uci set network.mape.legacy_mssfix='1'
uci commit network
```

(Alternative: `option tunlink 'wan6'` instead of `pd_prefix` to read PD
automatically from your IPv6 upstream.)

### 4. Migrate port forwarding

Translate each `iptables -t nat -A PREROUTING ... DNAT` from your
mape.sh into a UCI section:

```sh
uci set mape.web=forward
uci set mape.web.iface='mape'
uci set mape.web.proto='tcp'
uci set mape.web.src_port='4096'
uci set mape.web.dest_ip='192.168.1.10'
uci set mape.web.dest_port='80'
# ... repeat per rule ...
uci commit mape
```

A ready-made example is in `examples/mape.example` — copy it as a starting template:

```sh
cp examples/mape.example /etc/config/mape
```

### 5. Bring it up

```sh
ifup mape
sleep 2
ip route show default                            # should: default dev mape
iptables -t nat -L POSTROUTING -n -v | head -5   # should: 30 SNAT rules
iptables -t nat -L PREROUTING -n -v | head      # should: your DNATs
ping -c 3 -I mape 1.1.1.1                       # connectivity check
```

### 6. Persist on boot

netifd handles this automatically — `mape` will come up at boot if
defined in `/etc/config/network`.

## CLI quick reference

```sh
# Compute MAP-E parameters for any PD
mape-calc compute 2404:7a80:0:0::/56

# Verify a port is in your PSID range before adding a forward
mape-calc check-port 4096 2404:7a80:0:0::/56

# List all available port sets
mape-calc port-sets 2404:7a80:0:0::/56

# List supported ISP rules
mape-calc list-rules
```

## Verifying it's working

```sh
cat /var/run/mape.mape.json     # parameter snapshot
ip -s -6 tunnel show mape       # tunnel stats
logread -t 100 | grep mape      # recent log entries
```

## Manual mode (Asahi Net, transix, So-net, …)

If your ISP isn't in the rule database, use manual mode:

```sh
uci set network.mape=interface
uci set network.mape.proto=mape
uci set network.mape.pd_prefix='YOUR PD'
uci set network.mape.peeraddr='YOUR BR ADDRESS'      # from ISP docs
uci set network.mape.ip6prefix='YOUR V6 PREFIX'      # e.g. '2001:db8::'
uci set network.mape.ip6prefixlen='38'
uci set network.mape.ipaddr='1.2.3.0'
uci set network.mape.ip4prefixlen='22'
uci set network.mape.ealen='18'
uci set network.mape.psidlen='8'
uci set network.mape.offset='4'
uci set network.mape.wan_dev='eth4'
uci commit network
```

## Limitations (v0.1)

- ISP database covers BIGLOBE / JPNE v6plus / OCN. Others need manual mode.
- No LuCI GUI yet (Plan B).
- No IPK (Plan C).

## License

MIT — see `LICENSE`.
