# openwrt-map-e

针对日本 ISP（BIGLOBE IPv6オプション、JPNE v6plus、OCN バーチャルコネクト 等）
的 OpenWrt / QWrt 路由器 MAP-E 客户端。

## 为什么有这个项目

QSDK / QWrt 自带的 MAP-E（`proto='none' type='map-e'`）有 bug，导致隧道无法建立
或 fw3 无法识别。本包提供一个能工作的替代实现：

- 根据你的 IPv6 PD 自动识别 ISP（BIGLOBE / JPNE / OCN，规则库内嵌；其他 ISP 走
  手动模式）
- 通过 netifd 建立 `ipip6` 隧道（一等公民接口，`ifup mape` / `ifdown mape`）
- 自动生成符合分配的 PSID 端口段的 SNAT 规则
- UCI 配置的端口转发，自动校验端口是否在 PSID 段内
- 纯 iptables（不依赖 nftables）；兼容 fw3

## 安装

本仓库是**后端**包。LuCI 集成是单独的包（见 Plan B）。目前先用 CLI/UCI 配置。

### 前置依赖

```
opkg install ip-full iptables iptables-mod-conntrack-extra \
             kmod-ip6-tunnel kmod-iptunnel6 jsonfilter
```

### 文件部署

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

（Plan C 会提供 IPK，到时候只需 `opkg install mape_*.ipk`。）

## 从手写 mape.sh 迁移

如果你目前用的是手写的 `mape.sh`：

### 1. 停止脚本

把对 `mape.sh` 的调用从 `/etc/rc.local` 或其他位置删掉。装新包后不要再跑 mape.sh。

### 2. 清理 QWrt 自带 MAP-E 的死字段

`/etc/config/network` 里大概率有 QSDK 残留（`type='map-e'`、`peeraddr`、`ipaddr`、
`ealen` 等挂在 `wan` 段下）。删掉它们：

```sh
for f in type peeraddr ipaddr ip4prefixlen ip6prefix ip6prefixlen \
         ealen psidlen offset tunlink; do
    uci delete network.wan.$f 2>/dev/null
done
uci commit network
```

### 3. 定义 mape 接口

```sh
uci set network.mape=interface
uci set network.mape.proto=mape
uci set network.mape.pd_prefix='2404:7a80:0:0::/56'    # ← 你的 PD
uci set network.mape.wan_dev='eth4'                           # ← 你的物理 WAN
uci set network.mape.mtu='1460'
uci set network.mape.legacy_mssfix='1'
uci commit network
```

（也可以用 `option tunlink 'wan6'` 替代 `pd_prefix`，从 IPv6 上联自动取 PD。）

### 4. 迁移端口转发

把 mape.sh 里每条 `iptables -t nat -A PREROUTING ... DNAT` 翻译成 UCI 段：

```sh
uci set mape.web=forward
uci set mape.web.iface='mape'
uci set mape.web.proto='tcp'
uci set mape.web.src_port='4096'
uci set mape.web.dest_ip='192.168.1.10'
uci set mape.web.dest_port='80'
# ... 每条转发重复 ...
uci commit mape
```

`examples/mape.example` 里有现成的模板：

```sh
cp examples/mape.example /etc/config/mape
```

### 5. 启动

```sh
ifup mape
sleep 2
ip route show default                            # 应该是: default dev mape
iptables -t nat -L POSTROUTING -n -v | head -5   # 应该有: 30 条 SNAT 规则
iptables -t nat -L PREROUTING -n -v | head      # 应该有: 你的 DNAT
ping -c 3 -I mape 1.1.1.1                       # 连通性检查
```

### 6. 开机自动启动

netifd 自动处理 —— 只要 `/etc/config/network` 里定义了，重启自动起 mape。

## CLI 速查

```sh
# 给定 PD 计算 MAP-E 参数
mape-calc compute 2404:7a80:0:0::/56

# 加端口转发前校验端口是否在 PSID 段内
mape-calc check-port 4096 2404:7a80:0:0::/56

# 列出所有可用端口段
mape-calc port-sets 2404:7a80:0:0::/56

# 列出已收录的 ISP 规则
mape-calc list-rules
```

## 验证是否工作

```sh
cat /var/run/mape.mape.json     # 参数快照
ip -s -6 tunnel show mape       # 隧道流量统计
logread -t 100 | grep mape      # 最近日志
```

## 手动模式（Asahi Net、transix、So-net 等）

如果你的 ISP 不在规则库里，用手动模式：

```sh
uci set network.mape=interface
uci set network.mape.proto=mape
uci set network.mape.pd_prefix='你的 PD'
uci set network.mape.peeraddr='你的 BR 地址'         # 看 ISP 文档
uci set network.mape.ip6prefix='你的 V6 前缀'        # 例如 '2001:db8::'
uci set network.mape.ip6prefixlen='38'
uci set network.mape.ipaddr='1.2.3.0'
uci set network.mape.ip4prefixlen='22'
uci set network.mape.ealen='18'
uci set network.mape.psidlen='8'
uci set network.mape.offset='4'
uci set network.mape.wan_dev='eth4'
uci commit network
```

## v0.1 限制

- ISP 数据库覆盖 BIGLOBE / JPNE v6plus / OCN，其他 ISP 需要手动模式
- 暂无 LuCI 网页 GUI（Plan B）
- 暂无 IPK 安装包（Plan C）

## 许可证

MIT — 见 `LICENSE`。
