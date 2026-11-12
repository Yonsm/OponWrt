# Wing

Wing 是单实例代理脚本，使用已有 SS、SSR、Trojan 内核或上游 SOCKS5，不安装服务管理器或 TUN。

| 平台 | 工作方式 | 默认名单 |
| --- | --- | --- |
| OpenWrt | DNS + ipset + IPv4 TCP 透明代理 | `/etc/gfwlist.conf`（存在时）或 `/etc/gfwlist.txt` |
| MIWIFI | 同上 | `/data/wing/gfwlist.conf`（存在时）或 `/data/wing/gfwlist.txt` |
| macOS | 系统 PAC 或 SOCKS 代理 | `/Library/WebServer/Documents/gfwlist.pac` |
| Linux | 输出 SOCKS 环境变量；可选生成 PAC | 当前目录的 `gfwlist.pac` |

## 使用

将可执行的 `wing` 放入 PATH，配置节点后启动：

```sh
export WING_URL='trojan://PASSWORD@SERVER:443'
wing start
wing restart                 # 切换节点或重新加载配置
wing pause                   # 暂停代理规则
wing resume
wing stop
```

也可以运行 `wing start 'ss://...'`，支持 `ss://`、`ssr://`、`trojan://`、`socks5://`。SS/SSR/Trojan 需要对应客户端内核；路由器转接 SOCKS5 还需要 `ipt2socks`，上游 SOCKS5 仅支持无认证连接。请用 `restart` 切换节点，重复 `start` 不会自动清理旧实例。

本地 SOCKS 端口为 `1080`，路由器透明代理端口为 `1088`；代理内核监听 `0.0.0.0`，需用防火墙限制访问。脚本不隔离进程，停止或重启会结束同名客户端及 DNS 转发程序。

## 路由器 DNS

OpenWrt / MIWIFI 需要 dnsmasq、ipset、支持 set/REDIRECT/REJECT 的 IPv4 iptables 兼容模块及代理内核。Wing 优先使用 `iptables-nft`，没有时使用 `iptables`；两者都仍需 ipset 及 set 匹配模块，不支持仅安装原生 nft 的环境。DNS 转发程序优先选择 `chinadns-ng`，否则使用 `dns2tcp`，最后使用 `dns-forwarder`。脚本不安装依赖。MIWIFI 还须确认 dnsmasq 加载 `/tmp/dnsmasq.d`，Wing 在其中写入单行 `wing.conf`；OpenWrt 则在 `/etc/dnsmasq.conf` 中写入单行配置（`conf-file=...` 或 `server=/#/127.0.0.1#5354`）。

默认优先使用已有的 `gfwlist.conf`（仅存在 `gfwlist.txt` 时自动在同目录生成 `gfwlist.conf` 并复用）；设置 `WING_CHINADNS=1` 或 `WING_GFW_LIST` 可切换策略或名单路径。设置在 `restart`、`update`、`stop` 时应保持一致：

```sh
export WING_GFW_LIST=/etc/gfwlist.txt   # MIWIFI 使用 /data/wing/gfwlist.txt
wing restart
```

| 名单与转发程序 | 处理方式 |
| --- | --- |
| 默认（自动生成/复用 CONF）+ chinadns-ng | dnsmasq 按 CONF 逐域转发并写入 ipset；普通域名沿用原 DNS，名单查询过滤 AAAA；新版额外过滤 HTTPS/SVCB |
| TXT + chinadns-ng + `WING_CHINADNS=1` | 普通外部查询也转到 5354，由 chinadns-ng 按名单分流、写入 ipset；仅过滤命中域名的 AAAA |
| 默认 / CONF + dns2tcp 或 dns-forwarder | dnsmasq 逐域转发并写入 ipset；不按名单过滤 IPv6 |

默认模式由 dnsmasq 按 `gfwlist.conf` 逐域转发，普通域名沿用原 DNS；若同目录仅有 `gfwlist.txt`（或 `.txt` 更新），首次启动会自动生成 `gfwlist.conf` 供后续复用。需要由 `chinadns-ng` 全量分流时，设置 `WING_CHINADNS=1` 并重启（普通域名使用 `WING_DNS`，默认 `223.5.5.5`，名单域名使用 `tcp://8.8.8.8`；勿将 `WING_DNS` 指向路由器本机 DNS，以免循环）。已有的 dnsmasq 本地记录及更具体的上游规则可能优先命中，脚本不会改动它们。

若使用 CONF，可通过 `wing update /etc/gfwlist.conf` 生成（MIWIFI 改为 `/data/wing/gfwlist.conf`）；它包含逐域的 `server` 和 `ipset` 规则。生成到**其他路径**不会切换当前模式，设置 `WING_GFW_LIST` 并 `restart` 后才会使用。

chinadns-ng 的程序版本要求（不是固件版本）：

| 用途 | 版本 | 行为 |
| --- | --- | --- |
| 推荐，全功能 | `2025.08.09` | 完整名单匹配及 HTTPS/SVCB 记录过滤 |
| `WING_CHINADNS=1` 模式最低 | `2024.03.07` | 使用旧式 `-N g`；五级及以上规则会截短，匹配范围可能扩大 |
| 默认 / CONF 模式最低 | `2024.03.07` | 支持 TCP 上游及 AAAA 过滤 |

Wing 先启动完整命令；参数错误退出时尝试旧版命令，正常停止不会触发回退。两次都失败也不会中断 Wing 启动，此时 5354 可能无人监听。`2024.04.13` 起支持 `--filter-qtype 64,65`，它过滤的是 DNS 的 SVCB/HTTPS 记录，**不是阻断 HTTPS 连接**；回退后仍过滤名单域名的 AAAA，但不能阻止 HTTPS/SVCB 记录携带 IPv6 地址提示。早于 `2024.03.07` 的版本不支持所需的 `tcp://` 上游写法。

[北大 ImmortalWrt 镜像](https://mirrors.pku.edu.cn/immortalwrt/releases/)的 `24.10.4` 软件源提供 `2025.08.09-r1`，常见架构示例：

| CPU / 平台 | 软件包架构 | 下载 |
| --- | --- | --- |
| ARM64 通用 | `aarch64_generic` | [推荐版](https://mirrors.pku.edu.cn/immortalwrt/releases/24.10.4/packages/aarch64_generic/packages/chinadns-ng_2025.08.09-r1_aarch64_generic.ipk) · [CONF 最低版](https://github.com/zfl9/chinadns-ng/releases/download/2024.03.07/chinadns-ng%40aarch64-linux-musl%40generic%2Bv8a%40fast%2Blto) |
| MT7620 / MT7621（K2P） | `mipsel_24kc` | [推荐版](https://mirrors.pku.edu.cn/immortalwrt/releases/24.10.4/packages/mipsel_24kc/packages/chinadns-ng_2025.08.09-r1_mipsel_24kc.ipk) · [CONF 最低版](https://github.com/zfl9/chinadns-ng/releases/download/2024.03.07/chinadns-ng%40mipsel-linux-musl%40mips32r2%2Bsoft_float%40fast%2Blto) |

`23.05.4` 软件源的 ARM64 包为 [2025.08.09-1](https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.4/packages/aarch64_generic/packages/chinadns-ng_2025.08.09-1_aarch64_generic.ipk)。推荐版是镜像软件包，CONF 最低版是官方独立程序，不能当作 IPK 安装；应核对固件和架构，旧源的 `2023.06.01` 不支持当前 TCP 上游参数。

Wing 不清理旧版留下的 dnsmasq 全局 `filter-AAAA`、`filter-rr` 和名单引用；若仍有 `filter-AAAA`，**普通域名的 IPv6 也会被过滤**，与是否设置 `WING_CHINADNS=1` 无关。透明代理只处理 IPv4 TCP，并拒绝命中 ipset 的 UDP/443 以促使支持回退的应用使用 TCP；客户端须使用路由器 DNS，DoH、缓存、IPv6 地址提示或硬编码地址仍可能绕过分流。`WING_CHINADNS=1` 模式只过滤名单域名的 AAAA；默认 / CONF 模式配合支持 `--filter-qtype` 的版本可同时过滤 HTTPS/SVCB 地址提示。按 IP 分流也可能影响共用该 IP 的其他域名。

`pause` 只撤销流量规则，DNS 继续运行；`restart` 重载 DNS；`stop` 移除 Wing DNS 配置并停止所选转发程序。此管理方式不适合与其他服务共用同名 DNS 进程。

## macOS 与 Linux

macOS 默认使用 PAC。需要已有 HTTP 服务将 `/Library/WebServer/Documents/gfwlist.pac` 提供为 `http://127.0.0.1/gfwlist.pac`；使用系统 Apache 时可运行 `sudo apachectl start`。脚本仅在首次生成 PAC 时尝试重启 Apache，已有文件不代表 HTTP 服务正在运行。可设置 `WING_NETWORK='Wi-Fi'` 指定网络服务，否则按默认路由选择；VPN 或网络切换时建议显式指定。设置 `WING_PAC=0 wing start` 则使用系统 SOCKS 代理，不按名单分流。

Linux 需要 Bash（脚本会从其他 `/bin/sh` 切换到 Bash）。默认不下载名单或设置系统代理；启动后在需要代理的终端执行脚本输出的命令，例如 `export ALL_PROXY=socks5h://127.0.0.1:1080`。脚本不能修改父终端，`pause` / `resume` 只输出提示。设置 `WING_PAC=1 wing start` 可在当前目录生成 PAC，供应用自行配置。

## 更新名单与 PAC

`wing update` 从项目发布地址下载名单，而非读取本地源码。路由器更新当前选定的名单会重新加载 DNS；导出到其他路径不会切换当前模式。下载失败时会用两条兜底域名**替换**原名单并提示重试，启动不会因此中断。更新需 `curl` 和可用的 CA 证书；`gfwlist.txt` 源文件应为每行一个小写域名后缀，不含空行、注释或通配符。

PAC 通过域名及其父域查表，命中时返回 `SOCKS5 地址:端口; DIRECT`，未命中则直连。默认地址为 `127.0.0.1:1080`；若本机 SOCKS5 服务监听 `127.0.0.1:1081`，可指定该地址和端口：

```sh
wing update /Library/WebServer/Documents/gfwlist.pac 127.0.0.1 1081
# Linux
wing update ./gfwlist.pac 127.0.0.1 1081
```

已有 PAC 不会因切换节点而自动更新，省略地址和端口重新生成时也不会保留旧值；必要时让应用刷新 PAC 缓存。PAC 不代理忽略系统代理设置的应用或 UDP 流量。

## 限制与日志

- `wing status` 持续跟随日志，不是健康检查；`wing status 2` 查看 ipt2socks 日志，`wing status t`、`wing status s`、`wing status y` 分别查看路由器 NAT、ipset、系统日志。
- `-v0/-v1` 在前台运行，`-v2/-v3` 使用 nohup 写日志，`-v4/-v5` 直接在后台运行；脚本不提供进程监督或开机自启。
- 节点地址仅支持普通域名或 IPv4；IPv6 字面量、部分编码密码及复杂插件参数不保证可用。SSR 空协议/混淆参数的命令行模式也可能启动失败，应检查客户端输出。
- Trojan 配置关闭服务端证书验证；临时配置、日志及命令行可能包含密码，不适合不可信的多用户环境。
