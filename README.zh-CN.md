<sub>[English](README.en.md) · **简体中文** · [日本語](README.md)</sub>

# openwrt-mape-arm64

为 arm64 架构的 OpenWrt / QWrt 路由器提供 MAP-E（RFC 7597）客户端实现，
完全用 shell + awk + iptables 写成，替换 QSDK 系固件里跑不起来的
MAP-E 实现。

## 背景

日本主流 ISP（BIGLOBE IPv6オプション、JPNE v6plus、OCN バーチャル
コネクト 等）都基于 NTT FLET'S 光的 IPv6 IPoE 提供服务，IPv4 流量
通过 MAP-E 封装在 IPv6 隧道里走。用户 CE 拿到 IPv6 前缀 + 共享 IPv4
地址 + PSID（端口范围）的组合，出站 IPv4 包按 PSID 范围做 SNAT 后
用 ipip6 封装发给 ISP 的 BR。

在 mainline OpenWrt 和 x86 软路由上，这套机制是开箱即用的：上游
`map` 包加 nftables 的 flow offload 流水线（`nft_flow_offload`）配合
就能正常工作。日本市售的 NEC / I-O DATA 等 HGW 一体机也是同样原理。

但在 aarch64 + QSDK 系固件（小米 BE7000、BE10000、各种 QWrt、原版
QSDK 12.5 等）上，MAP-E 实际上是废的，原因有三：

1. QSDK 12.5 内置的 MAP-E 实现（`proto='none' type='map-e'` 配置方式）
   有 bug，ipip6 隧道经常建不起来，或者建起来了 fw3 也认不出接口。
2. QSDK 用的内核（5.4 + 一堆 QCA 私有 patch）里没有 mainline 的
   nftables flow offload 流水线，上游 `map` 包没法直接挪过来用。
3. 硬件加速侧的 MAP-E 客户端模块（`qca-nss-ppe-tunipip6.ko`）在几乎
   所有厂商的 QWrt build 里都被编译时关掉了。

## 这个包做什么

替换 QSDK 自带跑不起来的 MAP-E，作为 netifd 的标准 proto handler
重新搭建 ipip6 隧道 + SNAT + 端口转发的整套链路。

## 为什么有这个项目

QSDK / QWrt 自带的 MAP-E（在 wan 接口上配 `proto='none' type='map-e'`）
有 bug，要么隧道建不起来，要么 fw3 识别不到接口。本包提供一个能跑的
替代实现：

- **自动识别 ISP**（基于你的 IPv6 PD），内嵌 fc2 计算器的 690 条规则，
  覆盖 BIGLOBE / JPNE v6plus / OCN，其他 ISP 走手动模式
- **通过 netifd 建立 ipip6 隧道** —— `ifup mape` / `ifdown mape`，跟
  OpenWrt 网络栈完全集成
- **SNAT 用条件概率分布**，100 % 覆盖你被分配的 PSID 端口段（不会有
  漏掉的临时端口被 BR 丢包）
- **UCI 配置端口转发**，自动校验源端口是否在 PSID 段内
- **LuCI 集成** —— 协议出现在 网络 → 接口 列表里，编辑页含配置表单
  和 "自动检测到的参数" 预览面板
- **纯 iptables**，不依赖 nftables，兼容 fw3

## 截图

LuCI 网络 → 接口 —— `mape` 作为正经接口出现，协议显示 `MAP-E (custom)`：

![LuCI 接口列表](docs/images/luci-interfaces.jpg)

编辑页含 "自动检测到的参数" 预览面板：

![LuCI 编辑页](docs/images/luci-edit.jpg)

## 一键安装（推荐）

ssh 进路由器，root 用户跑：

```sh
wget -O - https://github.com/kazehana99k/openwrt-mape-arm64.JP/releases/latest/download/install.sh | sh
```

安装脚本做的事：

1. 验证你在 OpenWrt / QWrt 上
2. `opkg install` 前置依赖（ip-full、iptables、kmod-ip6-tunnel、jsonfilter 等）
3. 下载最新 release tarball 解压到 `/`
4. 设置可执行权限、应用 sysctl、reload rpcd
5. 打印下一步操作（重启 netifd、配置接口）

Qualcomm PPE 内核模块不包含在通用安装包中。Xiaomi BE10000、QWRT
25.12.2、IPQ95xx、Linux 5.4.213、R26.6.16 专用模块通过
[独立的 `qwrt-be10000-mape-ppe` 仓库](https://github.com/kazehana99k/qwrt-be10000-mape-ppe)
发布，避免误装到其他固件。

安装完成后跑 `/etc/init.d/network restart` 让 netifd 注册 `mape` 协议，
然后用 LuCI 或 CLI 配置（看下面）。

> 想先看一眼脚本内容？
> `wget` 下来 → `less install.sh` 检查 → `sh install.sh`

## 手动安装（从源码）

### 前置依赖

```sh
opkg install ip-full iptables iptables-mod-conntrack-extra \
             kmod-ip6-tunnel kmod-iptunnel6 jsonfilter
```

### 部署

```sh
git clone https://github.com/kazehana99k/openwrt-mape-arm64.JP.git
cd openwrt-mape-arm64.JP

# 把 package 文件 tar 管道推到路由器（保留路径结构）
tar -C package/mape/files -cf - . | ssh root@<路由器ip> "cd / && tar -xf -"
tar -C package/luci-app-fleth/root -cf - . | ssh root@<路由器ip> "cd / && tar -xf -"
tar -C package/luci-app-fleth/htdocs -cf - . | ssh root@<路由器ip> "cd /www && tar -xf -"

# 设置权限 + 加载服务
ssh root@<路由器ip> '
    chmod +x /lib/netifd/proto/mape.sh \
             /usr/bin/mape-calc \
             /etc/init.d/mape-fw \
             /etc/hotplug.d/iface/40-mape
    sysctl -p /etc/sysctl.d/99-mape.conf
    /etc/init.d/rpcd reload
    /etc/init.d/network restart   # netifd 必须重启才会注册新 proto
'
```

## 配置

### 方式 A —— LuCI 网页（推荐）

1. 打开 **网络 → Flet'h Configuration**
2. 点击 **Auto Configure tunnel Interface**
3. 确认系统从 `wan6` 自动获取 PD，并自动填入 ISP、CE IPv6、公网 IPv4、
   BR、PSID 和 WAN device
4. 在受支持的 QWRT 固件上打开 **PPE Acceleration**

端口转发：把 `examples/mape.example` 复制到 `/etc/config/mape` 后编辑
（src_port 必须在 PSID 段内）。

### 方式 B —— CLI / UCI

```sh
mape-ppe detect                              # 只读自动检测
mape-ppe autoconfigure                       # 自动配置 wan6、PD、WAN device 和 MAP-E
mape-ppe enable                              # 仅受支持固件启用 PPE
mape-ppe state
ip route show default                          # default dev mape
ip addr show mape | grep inet                  # 看到 MAP-E 分配的 IPv4
cat /var/run/mape.mape.json                    # 参数快照
ping -c 3 -I mape 1.1.1.1                      # 连通性检查
```

## CLI 速查

```sh
# 给定 PD 算 MAP-E 参数
mape-calc compute 2404:7a80:0:0::/56

# 加端口转发前校验端口是否在 PSID 段内
mape-calc check-port 4096 2404:7a80:0:0::/56

# 列出所有可用端口段
mape-calc port-sets 2404:7a80:0:0::/56

# 列出已收录的 ISP 规则
mape-calc list-rules
```

## 手动模式（Asahi Net、transix、So-net 等）

如果你的 ISP 不在规则库里，用手动模式（自己提供所有 RFC 7597 参数）：

```sh
uci set network.mape.peeraddr='你的 BR 地址'       # 看 ISP 文档
uci set network.mape.ip6prefix='你的 V6 前缀'      # 例如 '2001:db8::'
uci set network.mape.ip6prefixlen='38'
uci set network.mape.ipaddr='1.2.3.0'
uci set network.mape.ip4prefixlen='22'
uci set network.mape.ealen='18'
uci set network.mape.psidlen='8'
uci set network.mape.offset='4'
uci commit network
```

## 验证是否工作

```sh
ip -6 tunnel show mape           # 显示 local/remote/dev
ip addr show mape | grep inet    # IPv4 绑在 mape 上
ip route show default            # default dev mape
cat /var/run/mape.mape.json      # 参数快照
logread -e mape | tail -20       # 最近日志
iptables -t nat -L POSTROUTING -n | grep -c "to:"   # 约 25 条 SNAT 规则
```

LAN 设备打开 https://www.google.com 能正常访问 = 通了。

## 故障排查

| 现象 | 可能原因 | 解决 |
|---|---|---|
| `ifup mape` 静默失败 | netifd 没扫到新 proto | `/etc/init.d/network restart` |
| LuCI 显示 "不支持的协议类型" | proto JS 文件缺失或路径错 | 检查 `/www/luci-static/resources/protocol/mape.js` 存在；浏览器强制刷新 |
| "自动检测到的参数：尚未检测到" | rpcd ACL 没加载 | `/etc/init.d/rpcd reload`，然后浏览器刷新 |
| logread 反复出现 `Cannot find device "mape"` | setup 在静默失败 | `logread -e mape` 看实际报错 |
| 能上网但 TCP 经常连不上 | SNAT 端口池漏（老版本有这个 bug） | 升级到 v0.1.0+，已用条件概率修复 |

## 限制

- ISP 数据库覆盖 BIGLOBE（A & B）/ JPNE v6plus / OCN。Asahi Net、
  transix、So-net 等需要手动模式（或提交 PR 加规则）
- 暂无 IPK 安装包 —— 安装走 `cp`
- 端口转发暂无独立 GUI（用 LuCI 网络 → "MAP-E"，或手编 `/etc/config/mape`）

## 许可证

MIT —— 见 `LICENSE`。
