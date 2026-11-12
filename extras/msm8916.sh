#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-root@192.168.1.1}"
TMP_DIR="$(mktemp -d /tmp/msm8916.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/pkgs" "$TMP_DIR/overlay" "$TMP_DIR/rootfs"

source "$ROOT_DIR/packages.conf"

echo "[msm8916] Downloading Argon & Wing packages (aarch64_cortex-a53)..."
python3 - "$TMP_DIR/pkgs" "$WING_PACKAGES" <<'PYEOF'
import os, re, sys, json, urllib.request

pkg_dir, wing_pkgs = sys.argv[1], set(sys.argv[2].split())
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
for pkg in sorted(wing_pkgs):
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

echo "[msm8916] Patching UI & applying config from main repo..."
ssh "$TARGET" 'tar -C / -cf - usr/lib/lua/luci/i18n/*.zh-cn.lmo usr/share/luci/menu.d usr/share/ucode/luci/version.uc usr/share/ucode/luci/template/themes/argon/footer.ut usr/share/ucode/luci/template/themes/argon/footer_login.ut www/index.html 2>/dev/null || true' | tar -C "$TMP_DIR/rootfs" -xf -
"$ROOT_DIR/patches/ui-replace.sh" "$TMP_DIR/rootfs"
cp -a "$TMP_DIR/overlay/"* "$TMP_DIR/rootfs/"
tar -C "$TMP_DIR/rootfs" -cf - . | ssh "$TARGET" "tar -C / -xf -"

{
	awk '/^# (3|8|10)\./{p=1} /^# [0-9]+\./ && !/^# (3|8|10)\./{p=0} p' "$ROOT_DIR/files/etc/uci-defaults/99-custom-init"
	cat <<'EOF'
chmod +x /usr/bin/wing /sbin/backup /sbin/restore
rm -rf /tmp/luci-*
/etc/init.d/dnsmasq restart
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
EOF
} | ssh "$TARGET" 'sh -s'

echo "[msm8916] Done."
