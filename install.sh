#!/bin/sh
# One-click installer for openwrt-mape-arm64.
#
# Run on your OpenWrt / QWrt router as root:
#
#   wget -O - https://github.com/kazehana99k/openwrt-mape-arm64.JP/releases/latest/download/install.sh | sh
#
# Or download and inspect first (recommended):
#
#   wget https://github.com/kazehana99k/openwrt-mape-arm64.JP/releases/latest/download/install.sh
#   less install.sh
#   sh install.sh

set -e

REPO_URL="https://github.com/kazehana99k/openwrt-mape-arm64.JP"
TARBALL_URL="$REPO_URL/releases/latest/download/openwrt-mape-arm64.tar.gz"
TMP_TARBALL="/tmp/openwrt-mape-arm64.tar.gz"

say() { printf '\033[1;36m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERR %s\033[0m\n' "$*" >&2; exit 1; }

cat <<'EOF'
====================================
openwrt-mape-arm64 — one-click install
====================================
EOF

# 1. Sanity: must be OpenWrt-like
[ -f /etc/openwrt_release ] || die "/etc/openwrt_release not found. This script targets OpenWrt / QWrt routers."
. /etc/openwrt_release
echo "Detected: $DISTRIB_DESCRIPTION ($DISTRIB_ARCH)"
echo ""

# 2. Prerequisites
say "Installing prerequisites via opkg..."
opkg update >/dev/null 2>&1 || warn "opkg update failed (continuing anyway)"
opkg install ip-full iptables iptables-mod-conntrack-extra \
             kmod-ip6-tunnel kmod-iptunnel6 jsonfilter \
    || warn "Some packages may already be installed; that's fine."

# 3. Download release tarball
say "Downloading $TARBALL_URL"
rm -f "$TMP_TARBALL"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$TMP_TARBALL" "$TARBALL_URL" || die "Download failed"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_TARBALL" "$TARBALL_URL" || die "Download failed"
else
    die "Neither curl nor wget found"
fi
[ -s "$TMP_TARBALL" ] || die "Downloaded tarball is empty"

# 4. Extract into /
say "Extracting package files to /..."
tar -C / -xzf "$TMP_TARBALL"
rm -f "$TMP_TARBALL"

# 5. Permissions
say "Setting executable bits..."
chmod +x /lib/netifd/proto/mape.sh \
         /usr/bin/mape-calc \
         /etc/init.d/mape-fw \
         /etc/hotplug.d/iface/40-mape
chmod +x \
         /usr/sbin/fleth \
         /usr/sbin/fleth-map-e.lua \
         /usr/sbin/mape-ppe \
         /usr/sbin/mape-ppe-status \
         /usr/sbin/mape-ppe-enable \
         /usr/sbin/mape-ppe-disable \
         /usr/libexec/fleth-fw4 \
         /usr/share/fleth/firewall.include \
         /usr/share/fleth/ipip6hp-hotplug.sh \
         /usr/share/fleth/map.sh \
         /lib/netifd/proto/ipip6h.sh \
         /lib/netifd/proto/ipip6hp.sh \
         /etc/hotplug.d/iface/38-mape-ppe \
         /etc/hotplug.d/iface/39-mape-wan6 \
         /etc/hotplug.d/net/10-mape-wan-ipv6

say "Initializing Flet'h LuCI helper defaults..."
for f in /etc/uci-defaults/luci-app-fleth-*; do
    [ -f "$f" ] || continue
    sh "$f" || true
done

# 6. Sysctl + LuCI ACL
say "Applying sysctl tuning..."
sysctl -p /etc/sysctl.d/99-mape.conf >/dev/null

say "Reloading rpcd (so LuCI can read /var/run/mape.*.json)..."
/etc/init.d/rpcd reload

cat <<'EOF'

====================================
 Installation complete.
====================================

NEXT STEPS:

  1. RESTART netifd so it picks up the new 'mape' protocol:
     /etc/init.d/network restart
     (this briefly drops all interfaces — your ssh on LAN is unaffected)

  2. Configure via LuCI:
     Network -> Interfaces -> Add new interface
       Name:     mape
       Protocol: MAP-E (custom)
       Fill IPv6 PD prefix, set WAN device (e.g. eth4), Save & Apply

     Or use the Flet'h helper:
       Network -> Flet'h Configuration
       Auto Configure tunnel Interface + PPE Acceleration

  3. Or via CLI:
     uci set network.mape=interface
     uci set network.mape.proto=mape
     uci set network.mape.pd_prefix='YOUR_PD_HERE/56'
     uci set network.mape.wan_dev='eth4'
     uci commit network && ifup mape

  4. Verify:
     cat /var/run/mape.mape.json     # parameter snapshot
     ping -c 3 -I mape 1.1.1.1       # connectivity check

  Full docs: https://github.com/kazehana99k/openwrt-mape-arm64.JP

EOF
