<sub>[English](README.en.md) · [简体中文](README.zh-CN.md) · **日本語**</sub>

# openwrt-mape-arm64

arm64 アーキテクチャの OpenWrt / QWrt ルーターで MAP-E（RFC 7597）を
動作させるためのパッケージ。shell + awk + iptables のみで実装し、
QSDK 由来のファームウェアで動作しない MAP-E を置き換える。

## 背景

日本国内の主要 ISP（BIGLOBE IPv6オプション、JPNE v6plus、OCN バーチャル
コネクト 等）は NTT FLET'S 光の IPv6 IPoE 上でサービスを提供しており、
IPv4 通信は MAP-E で IPv6 トンネル越しに行う。エンドユーザーの CE が
IPv6 prefix + 共有 IPv4 + PSID（ポート範囲）の組を受け取り、それに従って
SNAT してから ipip6 でカプセル化し、ISP の BR に送信する仕組み。

mainline OpenWrt や x86 ベースのソフトウェアルーターでは、`map` パッケージ
や nftables の flow offload パイプライン（nft_flow_offload）が整っており、
MAP-E は問題なく利用できる。NEC や I-O DATA 等の市販 HGW でも同様。

しかし aarch64 + QSDK ベースのファームウェア（Xiaomi BE7000、BE10000 等の
QWrt や原版 QSDK 12.5）では、以下の理由により MAP-E が事実上機能しない：

1. QSDK 12.5 系統に内蔵される MAP-E 実装（`proto='none' type='map-e'` で
   設定するもの）にバグがあり、トンネルが確立しないか、fw3 が
   インターフェースを認識しない
2. QSDK のカーネル（5.4 + QCA 独自パッチ）には mainline の nftables
   flow offload パイプラインが含まれず、対応する `map` パッケージも
   そのままでは組み込めない
3. ハードウェア加速側の MAP-E クライアントモジュール
   （qca-nss-ppe-tunipip6.ko）が、ほとんどのベンダー由来 QWrt ビルドでは
   コンパイル時に無効化されている

## このパッケージの役割

QSDK 内蔵の壊れた MAP-E を置き換え、netifd の正規プロトコルとして
ipip6 トンネル + SNAT + ポート転送を構築する。

- **ISP を自動判定** —— あなたの IPv6 PD から fc2 計算機の 690 個の
  ルール（BIGLOBE / JPNE v6plus / OCN をカバー）でマッチング。その他の
  ISP は手動モードで設定可能
- **netifd の正規プロトコルとして ipip6 トンネルを構築** ——
  `ifup mape` / `ifdown mape` で OpenWrt のネットワークスタックと完全に
  統合
- **条件付き確率による SNAT ルール** —— 割り当てられた PSID ポート範囲を
  100 % カバーします（ランダムな送信元ポートが BR で破棄されることが
  ありません）
- **UCI で設定するポートフォワード** —— src_port が PSID 範囲内かを
  自動検証
- **LuCI 統合** —— ネットワーク → インターフェース 一覧にプロトコル
  「MAP-E (custom)」として表示され、編集ページでは設定フォームと
  「自動検出されたパラメーター」プレビューパネルが利用可能
- **iptables のみ**で動作、nftables は不要、fw3 と互換

## スクリーンショット

LuCI ネットワーク → インターフェース —— `mape` がプロトコル
`MAP-E (custom)` の正規インターフェースとして表示されます：

![LuCI インターフェース一覧](docs/images/luci-interfaces.jpg)

編集画面に「自動検出されたパラメーター」プレビューパネル：

![LuCI 編集画面](docs/images/luci-edit.jpg)

## ワンクリックインストール（推奨）

ルーターに root で ssh して、次のコマンドを実行：

```sh
wget -O - https://github.com/kazehana99k/openwrt-mape-arm64.JP/releases/latest/download/install.sh | sh
```

このインストーラーは：

1. OpenWrt / QWrt 上で動作していることを確認
2. 前提パッケージ（ip-full、iptables、kmod-ip6-tunnel、jsonfilter 等）を `opkg install`
3. 最新リリースの tarball をダウンロードして `/` に展開
4. 実行権限を設定、sysctl チューニングを適用、rpcd を再読込
5. 次のステップを表示（netifd を再起動、インターフェースを設定）

インストール完了後、`/etc/init.d/network restart` で `mape` プロトコルを
netifd に登録してから、LuCI または CLI で設定してください（下記参照）。

> スクリプトを先に確認したい場合：
> `wget` でダウンロード → `less install.sh` で確認 → `sh install.sh`

## 手動インストール（ソースから）

### 前提パッケージ

```sh
opkg install ip-full iptables iptables-mod-conntrack-extra \
             kmod-ip6-tunnel kmod-iptunnel6 jsonfilter
```

### デプロイ

```sh
git clone https://github.com/kazehana99k/openwrt-mape-arm64.JP.git
cd openwrt-mape-arm64.JP

# tar パイプでパッケージファイルを / にプッシュ（パス構造を保持）
tar -C package/mape/files -cf - . | ssh root@<ルーターIP> "cd / && tar -xf -"

# 権限設定 + サービス再読込
ssh root@<ルーターIP> '
    chmod +x /lib/netifd/proto/mape.sh \
             /usr/bin/mape-calc \
             /etc/init.d/mape-fw \
             /etc/hotplug.d/iface/40-mape
    sysctl -p /etc/sysctl.d/99-mape.conf
    /etc/init.d/rpcd reload
    /etc/init.d/network restart   # netifd は新しい proto を登録するために再起動が必要
'
```

## 設定

### 方法 A —— LuCI（推奨）

1. **ネットワーク → インターフェース → 新しいインターフェースを追加**
2. 名前：`mape`、プロトコル：`MAP-E (custom)`
3. **IPv6 PD prefix** 欄に PD を入力（例：`2404:7a80:0:0::/56`）、
   **Physical WAN device** に IPv6 上流インターフェース(例：`eth4`)
   を入力
4. **保存して適用**
5. インターフェースを再度編集すると **自動検出されたパラメーター**
   パネルで ISP / CE IPv6 / IPv4 / BR / PSID が確認できます

ポートフォワード設定：`examples/mape.example` を `/etc/config/mape` に
コピーして編集してください（src_port は必ず PSID 割当範囲内の値に）。

### 方法 B —— CLI / UCI

```sh
# 1. QSDK MAP-E の残骸フィールドを削除（旧設定からの移行時）
for f in type peeraddr ipaddr ip4prefixlen ip6prefix ip6prefixlen \
         ealen psidlen offset tunlink; do
    uci delete network.wan.$f 2>/dev/null
done
uci commit network

# 2. mape インターフェースを定義
uci set network.mape=interface
uci set network.mape.proto=mape
uci set network.mape.pd_prefix='あなたの PD'
uci set network.mape.wan_dev='eth4'
uci set network.mape.mtu='1460'
uci set network.mape.legacy_mssfix='1'
uci commit network

# 別案：option tunlink 'wan6'  上流インターフェースから PD を自動取得

# 3. 起動
ifup mape
sleep 2
ip route show default                          # default dev mape
ip addr show mape | grep inet                  # MAP-E 割当の IPv4
cat /var/run/mape.mape.json                    # パラメータースナップショット
ping -c 3 -I mape 1.1.1.1                      # 接続性確認
```

## CLI クイックリファレンス

```sh
# 任意の PD に対して MAP-E パラメーターを計算
mape-calc compute 2404:7a80:0:0::/56

# ポート転送を追加する前に、ポートが PSID 範囲内かを検証
mape-calc check-port 4096 2404:7a80:0:0::/56

# 利用可能なすべてのポートセットをリスト
mape-calc port-sets 2404:7a80:0:0::/56

# サポートされている ISP ルールをリスト
mape-calc list-rules
```

## 手動モード（Asahi Net、transix、So-net 等）

ISP がルールデータベースに含まれていない場合は手動モードを使用してください
（RFC 7597 パラメーターを自分で指定）：

```sh
uci set network.mape.peeraddr='あなたの BR アドレス'  # ISP 文書から
uci set network.mape.ip6prefix='あなたの V6 prefix'   # 例：'2001:db8::'
uci set network.mape.ip6prefixlen='38'
uci set network.mape.ipaddr='1.2.3.0'
uci set network.mape.ip4prefixlen='22'
uci set network.mape.ealen='18'
uci set network.mape.psidlen='8'
uci set network.mape.offset='4'
uci commit network
```

## 動作確認

```sh
ip -6 tunnel show mape           # local/remote/dev を表示
ip addr show mape | grep inet    # mape に IPv4 がバインドされているか
ip route show default            # default dev mape
cat /var/run/mape.mape.json      # パラメータースナップショット
logread -e mape | tail -20       # 最近のログ
iptables -t nat -L POSTROUTING -n | grep -c "to:"   # 約 25 個の SNAT ルール
```

LAN クライアントから https://www.google.co.jp を開けば確認完了。

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `ifup mape` が黙って何も起こらない | netifd が新 proto を認識していない | `/etc/init.d/network restart` |
| LuCI に「サポートされていないプロトコルタイプ」と表示 | proto JS ファイルの欠落またはパス誤り | `/www/luci-static/resources/protocol/mape.js` の存在を確認；ブラウザで強制リロード |
| 「自動検出されたパラメーター：未検出」 | rpcd の ACL が読み込まれていない | `/etc/init.d/rpcd reload` の後、ブラウザでリロード |
| logread に `Cannot find device "mape"` が繰り返し出る | setup が静かに失敗している | `logread -e mape` で実際のエラー段階を確認 |
| インターネットは繋がるが TCP 接続が時々失敗 | SNAT ポートプール漏れ（旧バージョンのバグ） | v0.1.0+ にアップデート（条件付き確率で修正済み） |

## 制限事項

- ISP データベースは BIGLOBE（A & B）/ JPNE v6plus / OCN をカバー。
  Asahi Net、transix、So-net 等は手動モードが必要（または PR でルールを
  追加してください）
- IPK パッケージはまだ未提供 —— インストールは `cp` ベース
- ポートフォワード編集用の独立 GUI なし（LuCI ネットワーク → 「MAP-E」
  を使用、または `/etc/config/mape` を直接編集）

## ライセンス

MIT —— `LICENSE` を参照。
