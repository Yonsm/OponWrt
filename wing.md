# Wing

Wing 是单实例代理脚本：路由器按域名名单分流 IPv4 TCP；macOS 使用系统 PAC 或 SOCKS 代理；Linux 输出 SOCKS 环境变量。脚本使用设备上已有的客户端，不负责安装依赖、开机自启或进程守护。

## 支持与选择

| 协议 | 客户端及选择规则 | 建议 |
| --- | --- | --- |
| SS | 脚本先检查 Shadowsocks Rust 的 `sslocal`，否则使用 `ss-local` / `ss-redir`；本地模式缺少上述客户端时可回退 `ssr-client`，路由器缺少 SS 客户端时尝试 `ssr-redir` | 通用选择，建议使用 AEAD 加密 |
| SSR | 本地模式先检查 `ssr-client`，否则使用 `ssr-local`；路由器使用 `ssr-redir` | 兼容旧节点时使用 |
| Trojan | `trojan` | 已有 Trojan 节点时使用 |
| VMess、VLESS | sing-box 或 Xray；VLESS Reality 优先 Xray，其余优先 sing-box，配置检查失败会尝试另一个 | 新节点优先考虑 VLESS；VMess 用于兼容已有节点 |
| Hysteria 2、TUIC | sing-box | 网络允许 UDP 时可考虑；实际速度取决于设备和线路 |
| SOCKS5 | 直接使用上游；路由器还需 `ipt2socks` 转接 | 连接已有 SOCKS5 服务时使用 |

一般可安装 sing-box：一个客户端可覆盖多种协议；需要 VLESS Reality 时可同时安装 Xray。路由器 DNS 推荐 `chinadns-ng`：它能过滤名单域名的 AAAA 查询，减少通过 IPv6 绕过 IPv4 代理；不可用时可使用 `dns2tcp`。表中的检查顺序是脚本现有行为，不代表性能高低；性能需要在目标设备上测试。

VMess 支持 Base64 编码 JSON 格式，解析需要 `jsonfilter` 或 `jq`。VMess/VLESS 的 TCP、WebSocket、gRPC、HTTP Upgrade 和 TLS 参数支持以脚本实际映射为准；VLESS 还支持 Reality。Hysteria 2 支持 Salamander 混淆。不是所有分享链接参数、传输方式或客户端版本都受支持；`sslocal` 在路由器上必须编译包含 `redir` 功能。

上游 SOCKS5 仅支持无认证连接。节点服务器地址目前仅支持域名和 IPv4，不支持 IPv6 字面量。部分特殊字符、插件参数、SS/SSR 编码形式不保证兼容；使用传统 SS/SSR 命令行客户端时密码不要包含空格。Trojan 和 sing-box 的 TLS 配置关闭证书验证；Xray 使用默认验证。Reality 使用自己的公钥验证机制。

SS / SSR 分享数据若使用包含 `-` 或 `_` 的 URL-safe Base64，在部分系统上可能解码失败；VMess 会转换这两个字符。SS 用户信息采用明文格式时，空密码会被误判为 Base64 格式，无法正确解析。

## OpenWrt 编译依赖

软件包名称取决于固件、版本和 feeds；以下是 OpenWrt / ImmortalWrt 常见包名，不要求把所有可选内核都编进固件。

| 用途 | 软件包或要求 |
| --- | --- |
| VMess 分享链接解析 | `jsonfilter` 或 `jq` |
| DNS | 带 `ipset` 或 `nftset` 支持的 `dnsmasq-full`；转发程序按 `chinadns-ng`、`dns2tcp`、`dns-forwarder` 顺序选择其中一个 |
| nftables 路径 | `nftables`（或发行版对应的 `nftables-nojson` / `nftables-json`）及 `kmod-nft-core`、`kmod-nft-nat` 等匹配当前内核的模块 |
| iptables / ipset 路径 | `iptables` 或 `iptables-nft`、`ipset`、`kmod-ipt-ipset`，以及 `kmod-ipt-nat` 等支持 IPv4 `set`、`REDIRECT` 和 `REJECT` 的模块 |
| 客户端 | 按需选择 `sing-box`、`xray-core`、`shadowsocks-rust-sslocal`、提供 `ss-local` / `ss-redir` 的 Shadowsocks libev、提供 `ssr-local` / `ssr-redir` 的 SSR 客户端、`trojan` |
| SOCKS5 透明转接 | `ipt2socks`，仅路由器使用上游 SOCKS5 时需要 |

北大镜像按固件版本、目标平台和软件包架构提供目录，入口见文末。

依赖关系应由同一固件的构建系统解析。官方 OpenWrt 与 ImmortalWrt feeds 的包集合不同；例如北大镜像的 24.10.4 官方 OpenWrt 软件源中有 `sing-box`、`xray-core`，但没有 `chinadns-ng`、`dns2tcp`、`ipt2socks` 和 `shadowsocks-rust-sslocal`；对应 ImmortalWrt 软件源中有这些包。老固件或其他架构可能不同，缺少的客户端需要兼容该固件的 feed 或自行编译。**不要跨固件、版本或内核混装内核模块。**

## 已有 OpenWrt 安装

以下一段命令适用于已取得管理权限、使用 `opkg` 且现有官方 OpenWrt / ImmortalWrt 软件源与固件版本及架构匹配的设备。它临时将已有官方 feed 改用北京大学镜像，安装基础依赖和 sing-box，并在源中可用时安装一个 DNS 转发程序；不改写设备原有 feed 文件。设备须事先具有带 `ipset` 或 `nftset` 的 dnsmasq 和相应防火墙模块。

```sh
pku_dir=$(mktemp -d /tmp/wing-pku.XXXXXX) || exit 1
for f in /etc/opkg/*.conf; do
    [ -f "$f" ] || continue
    sed -e 's#https\?://downloads.openwrt.org/#https://mirrors.pku.edu.cn/openwrt/#g' \
        -e 's#https\?://downloads.immortalwrt.org/#https://mirrors.pku.edu.cn/immortalwrt/#g' "$f" |
        awk '$1 !~ /^src/ || $3 ~ /^https?:\/\/mirrors[.]pku[.]edu[.]cn\//' > "$pku_dir/${f##*/}"
done
OPKG_CONF_DIR=$pku_dir opkg update &&
OPKG_CONF_DIR=$pku_dir opkg install jsonfilter sing-box && {
    dns_pkg=$(OPKG_CONF_DIR=$pku_dir opkg list | awk '$1 == "chinadns-ng" || $1 == "dns2tcp" {print $1; exit}')
    if [ -n "$dns_pkg" ]; then OPKG_CONF_DIR=$pku_dir opkg install "$dns_pkg"
    else echo '软件源缺少 chinadns-ng 和 dns2tcp，请安装与固件兼容的 DNS 转发程序。' >&2; exit 1; fi
}
```

此命令不安装所有可选客户端或 `ipt2socks`，需要时按上表从**同一套匹配固件的源**安装。官方 OpenWrt 源可能缺少 DNS 转发程序，出现提示后必须自行提供兼容程序，不能认为安装已完成。已安装的 `dnsmasq` 与 `dnsmasq-full` 可能冲突，替换前须确认设备可恢复网络。

## 小米路由器

小米原厂固件可从文末的小米依赖仓库下载程序。以下命令将依赖放入 `/data/wing`，并从本项目的 `main` 分支下载 Wing；预编译依赖为 ARM64，使用前须确认固件兼容。

```sh
(
    mkdir -p /data/wing || exit 1
    for f in chinadns-ng dns-forwarder ipt2socks libsodium.so.23 libudns.so.0 ss-redir ssr-redir trojan; do
        curl -fL "https://yonsm.github.io/OponWrt/miwifi/$f" -o "/data/wing/$f" || exit 1
    done
    curl -fL https://yonsm.github.io/OponWrt/wing/usr/bin/wing -o /data/wing/wing || exit 1
    chmod +x /data/wing/wing /data/wing/chinadns-ng /data/wing/dns-forwarder /data/wing/ipt2socks /data/wing/ss-redir /data/wing/ssr-redir /data/wing/trojan
)
```

小米固件若支持将 `firewall` 的 include 路径作为整条命令执行，可沿用仓库的 UCI 配置方式；先设置 `WING_URL`，再执行：

```sh
uci set firewall.wing=include
uci set firewall.wing.type=script
uci set "firewall.wing.path=/data/wing/wing $WING_URL"
uci set firewall.wing.enabled=1
uci commit firewall
```

标准 OpenWrt `fw3` 的 include 路径要求是真实文件，不支持在路径中附加参数；上述 UCI 写法是否生效取决于小米固件的实现。

使用 APK 包管理器的固件不能直接套用上述 OpenWrt `opkg` 命令。

## macOS 和 Linux 依赖

Linux 需要 Bash。VMess 另需 `jq` 或 `jsonfilter`。按实际需要安装上述客户端，程序须在 `PATH` 中；路由器专用的 `ipt2socks`、dnsmasq 和防火墙模块不用于桌面模式。

- macOS 默认使用系统 PAC，需有 HTTP 服务将 `/Library/WebServer/Documents/gfwlist.pac` 提供为本机 `http://127.0.0.1/gfwlist.pac`。`WING_NETWORK` 可指定网络服务；`WING_PAC=0` 改为系统 SOCKS 代理。
- Linux 默认只输出 `ALL_PROXY` 设置，不能替父 shell 修改环境；`WING_PAC=1` 会在当前目录生成 PAC，需应用自行加载。

## 运行和分流规则

将 Wing 放入 `PATH` 并配置节点后，使用 `start`、`restart`、`pause`、`resume`、`stop` 管理；节点可通过 `WING_URL` 提供。切换节点使用 `restart`，重复 `start` 不会自动清理旧实例。`status` 跟随日志，并非健康检查；`status 2`、`status t`、`status s`、`status y` 分别查看转接日志、规则、地址集合和系统日志。`-v0/-v1` 前台运行，`-v2/-v3` 后台写日志，`-v4/-v5` 后台运行。

| 平台 | 默认名单 / 行为 |
| --- | --- |
| OpenWrt | `/etc/gfwlist.conf` 存在时优先使用，否则使用 `/etc/gfwlist.txt` |
| 小米原厂模式 | `/data/wing/gfwlist.conf` 存在时优先使用，否则使用 `/data/wing/gfwlist.txt` |
| macOS | `/Library/WebServer/Documents/gfwlist.pac` |
| Linux | 默认不生成名单；启用 PAC 时使用当前目录的 `gfwlist.pac` |

路由器可用 `WING_GFW_LIST` 指定名单。TXT 模式默认转换为同目录 CONF，由 dnsmasq 将名单查询转发到本机 5354，并把结果加入 ipset / nftset；CONF 也可直接提供。自定义 CONF 的完整路径必须包含 `gfwlist`，TXT 自动生成的 CONF 路径也一样，否则停止时无法清理 DNS 引用。`WING_CHINADNS=1` 改用 TXT 和 chinadns-ng 全量 DNS 分流，普通域名使用 `WING_DNS`，默认 `223.5.5.5`；该设置同时使脚本选择 iptables / ipset 路径。`WING_DNS` 不应指向路由器本机 DNS，以免循环。

脚本仅在系统有 `nft`、dnsmasq 声明 `nftset` 且声明 `no-ipset`、并且未设置 `WING_CHINADNS=1` 时使用原生 nftables；其他情况选择 `iptables-nft` 或 `iptables` 配合 ipset。现有 CONF 如果与选中的集合类型不一致，脚本会将 `ipset` / `nftset` 规则转换为当前后端。OpenWrt 会修改 `/etc/dnsmasq.conf`，小米原厂模式会写入 `/tmp/dnsmasq.d/wing.conf`，要求该目录已被 dnsmasq 加载。

透明代理只处理命中名单地址集合的 IPv4 TCP；命中集合的 UDP/443 被拒绝，以便支持回退的客户端改用 TCP。客户端需要使用路由器 DNS；DoH、缓存、IPv6、硬编码地址和共享 IP 都可能改变分流结果。脚本还预置少量固定 IPv4 地址。`pause` 只移除流量规则，不停止 DNS；`stop` 和 `restart` 会清理 nftables、iptables / ipset 规则及 Wing 的 DNS 配置，并重启 dnsmasq；重启 dnsmasq 失败时不会启动新客户端。客户端和 DNS 转发程序按进程名终止，可能影响其他同名服务。脚本不检查客户端是否成功启动；失败时可手动执行 `stop` 清理规则。

`update` 下载项目发布的名单，并按目标扩展名生成 TXT、dnsmasq CONF 或 PAC；更新非当前路径不会自动切换当前名单。下载失败会用两条兜底域名替换目标文件并提示重试。PAC 命中域名及其父域时使用 SOCKS5，代理不可用时允许直连；已有 PAC 不会自动随节点或 SOCKS 端口变化而更新。配置、日志和进程参数可能包含节点凭据。

## 相关链接

- 北大镜像：[OpenWrt](https://mirrors.pku.edu.cn/openwrt/releases/) · [ImmortalWrt](https://mirrors.pku.edu.cn/immortalwrt/releases/)
- 小米依赖：[miwifi](https://github.com/Yonsm/OponWrt/tree/main/miwifi)
- 客户端：[sing-box](https://github.com/SagerNet/sing-box/releases) · [Xray](https://github.com/XTLS/Xray-core/releases) · [Shadowsocks Rust](https://github.com/shadowsocks/shadowsocks-rust/releases) · [Trojan](https://github.com/trojan-gfw/trojan/releases) · [Shadowsocks libev](https://github.com/shadowsocks/shadowsocks-libev) · [ShadowsocksR libev](https://github.com/shadowsocksrr/shadowsocksr-libev)
