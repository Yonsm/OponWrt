#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-root@192.168.1.1}"
TMP_DIR="$(mktemp -d /tmp/msm8916.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/pkgs" "$TMP_DIR/overlay" "$TMP_DIR/rootfs"

echo "[msm8916] Downloading Argon & Wing packages (aarch64_cortex-a53)..."
python3 - "$TMP_DIR/pkgs" <<'PYEOF'
import os, re, sys, json, urllib.request

pkg_dir = sys.argv[1]
rel = json.loads(urllib.request.urlopen(urllib.request.Request(
    "https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest",
    headers={"User-Agent": "OpenWrt-Setup"},
)).read().decode("utf-8"))
for asset in rel.get("assets", []):
    url = asset.get("browser_download_url", "")
    name = os.path.basename(url)
    if url.endswith(".apk") and (name.startswith("luci-theme-argon") or name.startswith("luci-app-argon-config") or name.startswith("luci-i18n-argon-config-zh-cn")):
        urllib.request.urlretrieve(url, os.path.join(pkg_dir, name))

base = "https://downloads.immortalwrt.org/releases/packages-25.12/aarch64_cortex-a53/packages"
html = urllib.request.urlopen(f"{base}/").read().decode("utf-8", "ignore")
for pkg in ("chinadns-ng", "simple-obfs-client", "trojan", "ipt2socks", "tcping"):
    m = re.search(rf'href="({re.escape(pkg)}[_-][0-9][^"]*\.apk)"', html)
    if m:
        urllib.request.urlretrieve(f"{base}/{m.group(1)}", os.path.join(pkg_dir, m.group(1)))
PYEOF

cp -a "$ROOT_DIR/extras/wing/"* "$TMP_DIR/overlay/"
mkdir -p "$TMP_DIR/overlay/etc" "$TMP_DIR/overlay/sbin"
cp -a "$ROOT_DIR/files/etc/banner" "$ROOT_DIR/files/etc/uhttpd.crt" "$ROOT_DIR/files/etc/uhttpd.key" "$TMP_DIR/overlay/etc/"
cp -a "$ROOT_DIR/files/sbin/backup" "$ROOT_DIR/files/sbin/restore" "$TMP_DIR/overlay/sbin/"
find "$TMP_DIR/overlay" -name ".DS_Store" -delete

echo "[msm8916] Installing packages on $TARGET..."
ssh "$TARGET" "rm -rf /tmp/oponwrt-pkgs && mkdir -p /tmp/oponwrt-pkgs"
tar -C "$TMP_DIR/pkgs" -cf - . | ssh "$TARGET" "tar -C /tmp/oponwrt-pkgs -xf -"
ssh "$TARGET" 'sh -s' <<'REMOTE_INSTALL'
set -e
[ -f /etc/apk/repositories.d/distfeeds.list ] && sed -i 's#downloads.openwrt.org#mirrors.tencent.com/openwrt#g' /etc/apk/repositories.d/distfeeds.list
apk update
apk del dnsmasq 2>/dev/null || true
apk add dnsmasq-full curl ca-bundle htop openssh-sftp-server ip-full coreutils coreutils-base64 resolveip \
	luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn \
	luci-app-commands luci-i18n-commands-zh-cn luci-app-uhttpd luci-i18n-uhttpd-zh-cn
apk add --allow-untrusted /tmp/oponwrt-pkgs/*.apk
rm -rf /tmp/oponwrt-pkgs
REMOTE_INSTALL

echo "[msm8916] Patching UI & applying config..."
ssh "$TARGET" 'tar -C / -cf - usr/lib/lua/luci/i18n/*.zh-cn.lmo usr/share/ucode/luci/version.uc usr/share/ucode/luci/template/themes/argon/footer.ut usr/share/ucode/luci/template/themes/argon/footer_login.ut www/index.html 2>/dev/null || true' | tar -C "$TMP_DIR/rootfs" -xf -
"$ROOT_DIR/patches/ui-replace.sh" "$TMP_DIR/rootfs"
cp -a "$TMP_DIR/overlay/"* "$TMP_DIR/rootfs/"
tar -C "$TMP_DIR/rootfs" -cf - . | ssh "$TARGET" "tar -C / -xf -"

ssh "$TARGET" 'sh -s' <<'REMOTE_CFG'
set -e
M="/usr/share/luci/menu.d"
[ -f "$M/luci-mod-status.json" ] && sed -i -e 's/"title": "Routing"/"title": "路由规则"/g' -e 's/"title": "Firewall"/"title": "防火长城"/g' -e 's/"title": "Processes"/"title": "系统进程"/g' "$M/luci-mod-status.json"
[ -f "$M/luci-mod-system.json" ] && sed -i -e 's/"title": ".*LED.*Configuration"/"title": "灯光配置"/g' -e 's/"title": "Backup \/ Flash Firmware"/"title": "备份更新"/g' -e 's/"title": "Reboot"/"title": "重新启动"/g' "$M/luci-mod-system.json"
[ -f "$M/luci-app-commands.json" ] && sed -i 's/"title": "Custom Commands"/"title": "自定命令"/g' "$M/luci-app-commands.json"
for F in "$M"/luci-*argon*.json; do [ -f "$F" ] && sed -i 's/"title": "Argon Config"/"title": "主题设置"/g' "$F"; done
[ -f "$M/luci-app-firewall.json" ] && sed -i 's/"title": "Firewall"/"title": "防火长城"/g' "$M/luci-app-firewall.json"
[ -f "$M/luci-mod-network.json" ] && sed -i -e 's/"title": "Routes"/"title": "路由规则"/g' -e 's/"title": "Routing"/"title": "路由规则"/g' -e 's/"title": "DHCP"/"title": "网址分配"/g' -e 's/"title": "DNS"/"title": "网络域名"/g' "$M/luci-mod-network.json"
[ -f "$M/luci-app-uhttpd.json" ] && sed -i -e '/"order"/d' -e 's/"title": "uHTTPd",/"title": "网页服务",\n\t\t"order": 25,/' "$M/luci-app-uhttpd.json"

uci -q batch <<EOF
set system.@system[0].timezone='CST-8'
set system.@system[0].zonename='Asia/Shanghai'
delete system.ntp.server
add_list system.ntp.server='ntp.aliyun.com'
add_list system.ntp.server='cn.pool.ntp.org'
add_list system.ntp.server='time.ustc.edu.cn'
commit system
set dhcp.@dnsmasq[0].sequential_ip='1'
commit dhcp
set luci.main.lang='zh_cn'
set luci.main.mediaurlbase='/luci-static/argon'
commit luci
EOF

[ -f /etc/init.d/dnsmasq ] && ! grep -Fq "/etc/gfwlist.txt" /etc/init.d/dnsmasq && \
	sed -i 's#procd_add_jail_mount /etc/passwd#procd_add_jail_mount /etc/gfwlist.txt /etc/gfwlist.conf /etc/passwd#' /etc/init.d/dnsmasq

if [ -f /etc/config/luci ] && ! grep -q "poweroff" /etc/config/luci; then
	cat <<\EOF >> /etc/config/luci

config command
	option name '关闭系统'
	option command 'poweroff'

config command
	option name '网络接口'
	option command 'ifconfig'

config command
	option name '科学上网'
	option command 'wing'
	option param '1'
EOF
fi

chmod +x /usr/bin/wing /sbin/backup /sbin/restore
rm -rf /tmp/luci-*
/etc/init.d/dnsmasq restart
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
REMOTE_CFG

echo "[msm8916] Done."
