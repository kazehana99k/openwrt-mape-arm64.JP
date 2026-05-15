<sub>**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)</sub>

# openwrt-mape-arm64

A working MAP-E client for arm64 OpenWrt / QWrt routers behind Japanese
ISPs (BIGLOBE IPv6オプション, JPNE v6plus, OCN バーチャルコネクト, etc.).
Replaces the broken built-in implementation in QSDK / QWrt.

> **Architecture**: developed and tested on aarch64 (IPQ95xx, QWrt 25.12),
> but the package is pure shell + awk + iptables and runs on any
> architecture supported by OpenWrt.

## Why this exists

QSDK / QWrt's built-in MAP-E (`proto='none' type='map-e'` on the wan
interface) has bugs that prevent the tunnel from establishing or fw3
from recognizing it. This package replaces it with a working
implementation that:

- **Auto-detects the ISP** from your IPv6 PD (690 rules from fc2
  calculator covering BIGLOBE / JPNE v6plus / OCN; other ISPs via
  manual mode)
- **Builds the ipip6 tunnel as a proper netifd interface** —
  `ifup mape` / `ifdown mape`, full integration with OpenWrt's
  network stack
- **Generates SNAT rules with conditional probabilities** covering
  100 % of the assigned PSID port range (no leaked ephemeral ports
  that the BR drops)
- **UCI-configured port forwarding** with PSID-range validation
- **LuCI integration** — protocol shows up in Network → Interfaces
  with a configuration form and an "Auto-detected parameters" preview
- **Pure iptables**, no nftables required; compatible with fw3

## Quick install (arm64 / generic)

### Prerequisites

```sh
opkg install ip-full iptables iptables-mod-conntrack-extra \
             kmod-ip6-tunnel kmod-iptunnel6 jsonfilter
```

### Deploy

```sh
git clone https://github.com/kazehana99k/openwrt-mape-arm64.JP.git
cd openwrt-mape-arm64.JP

# Push package files into / preserving paths
tar -C package/mape/files -cf - . | ssh root@<router-ip> "cd / && tar -xf -"

# Permissions + reload services
ssh root@<router-ip> '
    chmod +x /lib/netifd/proto/mape.sh \
             /usr/bin/mape-calc \
             /etc/init.d/mape-fw \
             /etc/hotplug.d/iface/40-mape
    sysctl -p /etc/sysctl.d/99-mape.conf
    /etc/init.d/rpcd reload
    /etc/init.d/network restart   # netifd needs restart to register the new proto
'
```

## Configuration

### Option A — LuCI (recommended)

1. Open **Network → Interfaces → Add new interface**
2. Name: `mape`, Protocol: `MAP-E (custom)`
3. Fill the **IPv6 PD prefix** field (e.g. `2404:7a80:0:0::/56`),
   set **Physical WAN device** to your IPv6 upstream interface
   (e.g. `eth4`)
4. **Save & Apply**
5. Re-edit the interface to see the **Auto-detected parameters**
   panel (ISP, CE IPv6, IPv4, BR, PSID)

For port forwarding: copy `examples/mape.example` to `/etc/config/mape`
and edit (must use `src_port` values inside the PSID-allocated range).

### Option B — CLI / UCI

```sh
# 1. Clean QSDK MAP-E orphan fields (if migrating)
for f in type peeraddr ipaddr ip4prefixlen ip6prefix ip6prefixlen \
         ealen psidlen offset tunlink; do
    uci delete network.wan.$f 2>/dev/null
done
uci commit network

# 2. Define mape interface
uci set network.mape=interface
uci set network.mape.proto=mape
uci set network.mape.pd_prefix='YOUR_PD_HERE'
uci set network.mape.wan_dev='eth4'
uci set network.mape.mtu='1460'
uci set network.mape.legacy_mssfix='1'
uci commit network

# Alternative: option tunlink 'wan6' to auto-fetch PD from upstream

# 3. Bring it up
ifup mape
sleep 2
ip route show default                          # default dev mape
ip addr show mape | grep inet                  # IPv4 from MAP-E
cat /var/run/mape.mape.json                    # parameter snapshot
ping -c 3 -I mape 1.1.1.1                      # connectivity check
```

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

## Manual mode (Asahi Net, transix, So-net, …)

If your ISP isn't in the rule database, use manual mode (provide all
RFC 7597 parameters yourself):

```sh
uci set network.mape.peeraddr='YOUR_BR_ADDRESS'    # from ISP docs
uci set network.mape.ip6prefix='YOUR_V6_PREFIX'    # e.g. '2001:db8::'
uci set network.mape.ip6prefixlen='38'
uci set network.mape.ipaddr='1.2.3.0'
uci set network.mape.ip4prefixlen='22'
uci set network.mape.ealen='18'
uci set network.mape.psidlen='8'
uci set network.mape.offset='4'
uci commit network
```

## Verifying it works

```sh
ip -6 tunnel show mape           # shows local/remote/dev
ip addr show mape | grep inet    # IPv4 bound to mape
ip route show default            # default dev mape
cat /var/run/mape.mape.json      # parameter snapshot
logread -e mape | tail -20       # recent log entries
iptables -t nat -L POSTROUTING -n | grep -c "to:"    # ~25 SNAT rules
```

From a LAN client: open https://www.google.com — should work.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ifup mape` silently does nothing | netifd hasn't picked up the new proto | `/etc/init.d/network restart` |
| `LuCI: unsupported protocol type` | proto JS file missing or in wrong dir | Verify `/www/luci-static/resources/protocol/mape.js` exists; force-refresh browser |
| `Auto-detected parameters: not detected` | rpcd ACL not loaded | `/etc/init.d/rpcd reload`, then refresh browser |
| `Cannot find device "mape"` repeating in logread | setup is failing silently | `logread -e mape` will show the actual stage that failed |
| Internet works but TCP connections fail randomly | SNAT port-pool miss (old version had this bug) | Update to v0.1.0+ which uses conditional probabilities |

## Limitations

- ISP database covers BIGLOBE (A & B) / JPNE v6plus / OCN. Asahi Net,
  transix, So-net, etc. need manual mode (or contribute a rule via PR)
- No IPK packaging yet — install is `cp` based
- No GUI for editing port forwards (use LuCI Network → "MAP-E" or
  edit `/etc/config/mape` by hand)

## License

MIT — see `LICENSE`.
