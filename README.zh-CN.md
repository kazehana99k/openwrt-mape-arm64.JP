<sub>[English](README.md) · **简体中文** · [日本語](README.ja.md)</sub>

# openwrt-mape-arm64

为 arm64 OpenWrt / QWrt 路由器提供能用的 MAP-E 客户端，目标日本 ISP
（BIGLOBE IPv6オプション、JPNE v6plus、OCN バーチャルコネクト 等）。
替代 QSDK / QWrt 自带的有 bug 的实现。

> **架构说明**：在 aarch64（IPQ95xx，QWrt 25.12）上开发和测试，但本包是
> 纯 shell + awk + iptables，理论上可以在 OpenWrt 支持的任何架构上跑。

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

1. 打开 **网络 → 接口 → 添加新接口**
2. 名称：`mape`，协议：`MAP-E (custom)`
3. 填 **IPv6 PD 前缀**（例如 `2404:7a80:0:0::/56`），**Physical WAN
   device** 填你的 IPv6 上联接口（例如 `eth4`）
4. **保存并应用**
5. 重新编辑接口可以看到 **自动检测到的参数** 面板（ISP / CE IPv6 /
   IPv4 / BR / PSID）

端口转发：把 `examples/mape.example` 复制到 `/etc/config/mape` 后编辑
（src_port 必须在 PSID 段内）。

### 方式 B —— CLI / UCI

```sh
# 1. 清掉 QSDK MAP-E 死字段（如果是从老配置迁移）
for f in type peeraddr ipaddr ip4prefixlen ip6prefix ip6prefixlen \
         ealen psidlen offset tunlink; do
    uci delete network.wan.$f 2>/dev/null
done
uci commit network

# 2. 定义 mape 接口
uci set network.mape=interface
uci set network.mape.proto=mape
uci set network.mape.pd_prefix='你的 PD'
uci set network.mape.wan_dev='eth4'
uci set network.mape.mtu='1460'
uci set network.mape.legacy_mssfix='1'
uci commit network

# 备选：option tunlink 'wan6'  从上联接口自动取 PD

# 3. 启动
ifup mape
sleep 2
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
