# Changelog

## v0.2.1

- Ship `/etc/config/fleth` and `/etc/config/mape_ppe` directly so the LuCI
  page cannot fail with `uci/get` ubus code 4 when `uci-defaults` has not run.

## v0.2.0

- Add Flet'h-based automatic WAN6/PD discovery and MAP-E configuration.
- Add Qualcomm PPE IPIP6 acceleration controls and status reporting.
- Integrate with the separate `qwrt-be10000-mape-ppe` repository for optional
  Xiaomi BE10000 firmware-specific PPE tunnel modules.
- Add strict compatibility and SHA-256 checks before installing PPE modules.
- Include `install.sh` and the versioned PPE module installer in releases.

## v0.1.0

- Initial software MAP-E implementation for OpenWrt/QWrt.
