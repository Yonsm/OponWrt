#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRESET_ARG="${1:-X64+DOCKER+WIFI}"
OPENWRT_VER="${2:-$OPENWRT_VERSION}"

if [ -z "$OPENWRT_VER" ]; then
	OPENWRT_VER=$(python3 -c '
import re, urllib.request
html = urllib.request.urlopen("https://downloads.openwrt.org/releases/").read().decode("utf-8", "ignore")
vers = sorted(re.findall(r"href=\"([0-9]+\.[0-9]+\.[0-9]+)/\"", html), key=lambda s: [int(x) for x in s.split(".")])
print(vers[-1] if vers else "")
')
fi
[ -z "$OPENWRT_VER" ] && echo "Failed to resolve OpenWrt version" >&2 && exit 1

OPENWRT_SERIES="${OPENWRT_VER%.*}"
echo "[build] OpenWrt $OPENWRT_VER ($OPENWRT_SERIES)"
source "$SCRIPT_DIR/packages.conf"

build_single_preset() {
	local PRESET="$1"
	resolve_target_config "$PRESET"
	echo "[build] $PRESET -> $TARGET_BOARD/$TARGET_SUBTARGET ($TARGET_PROFILE, $PKG_ARCH)"

	local WORK_IB="/tmp/openwrt-ib-${TARGET_BOARD}-${TARGET_SUBTARGET}"
	local WORK_FILES="/tmp/openwrt-files-${PRESET}"
	rm -rf "$WORK_FILES"
	cp -a "$SCRIPT_DIR/files" "$WORK_FILES"
	if [[ "$PRESET" != *"+NOWING"* ]]; then
		cp -a "$SCRIPT_DIR/extras/wing/"* "$WORK_FILES/"
	fi
	if [[ "$PRESET" == X64* ]]; then
		cp -a "$SCRIPT_DIR/extras/x86/"* "$WORK_FILES/"
	fi
	if [[ "$PRESET" == X64* ]] || [[ "$PRESET" == *"+SMB4"* ]]; then
		cp -a "$SCRIPT_DIR/extras/samba4/"* "$WORK_FILES/"
	fi
	if [[ "$PRESET" == *"+HASS"* ]]; then
		cp -a "$SCRIPT_DIR/extras/hass/"* "$WORK_FILES/"
	fi
	find "$WORK_FILES" -name ".DS_Store" -delete

	python3 - "$OPENWRT_VER" "$OPENWRT_SERIES" "$TARGET_BOARD" "$TARGET_SUBTARGET" "$PKG_ARCH" "$WORK_IB" <<'PYEOF'
import os, re, sys, json, subprocess, urllib.request

ver, series, board, subtarget, pkg_arch, work_ib = sys.argv[1:7]
base_url = f"https://downloads.openwrt.org/releases/{ver}/targets/{board}/{subtarget}"

if not os.path.isdir(work_ib):
    sums = urllib.request.urlopen(f"{base_url}/sha256sums").read().decode("utf-8", "ignore")
    m = re.search(rf"(openwrt-imagebuilder-{re.escape(ver)}-{re.escape(board)}-{re.escape(subtarget)}\.Linux-x86_64\.tar\.(?:zst|xz))", sums)
    if not m:
        raise SystemExit(f"ImageBuilder not found at {base_url}")
    ib_path = f"/tmp/{m.group(1)}"
    print(f"[build] Downloading {base_url}/{m.group(1)}")
    urllib.request.urlretrieve(f"{base_url}/{m.group(1)}", ib_path)
    os.makedirs(work_ib, exist_ok=True)
    subprocess.run(["tar", "-xf", ib_path, "-C", work_ib, "--strip-components=1"], check=True)
    os.remove(ib_path)

pkg_ext = "apk" if os.path.exists(os.path.join(work_ib, "repositories")) else "ipk"
pkg_dir = os.path.join(work_ib, "packages")
os.makedirs(pkg_dir, exist_ok=True)

req = urllib.request.Request("https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest", headers={"User-Agent": "OpenWrt-ImageBuilder"})
rel = json.loads(urllib.request.urlopen(req).read().decode("utf-8"))
for asset in rel.get("assets", []):
    url = asset.get("browser_download_url", "")
    name = os.path.basename(url)
    if url.endswith(f".{pkg_ext}") and (name.startswith("luci-theme-argon") or name.startswith("luci-app-argon-config") or name.startswith("luci-i18n-argon-config-zh-cn")):
        dst = os.path.join(pkg_dir, name)
        if not os.path.exists(dst):
            print(f"[build] Argon: {name}")
            urllib.request.urlretrieve(url, dst)

third_party = [
    "chinadns-ng", "shadowsocks-libev-ss-redir", "simple-obfs-client",
    "shadowsocksr-libev-ssr-redir", "trojan", "ipt2socks", "tcping",
]
for cand_series in (series, "24.10"):
    im_base = f"https://downloads.immortalwrt.org/releases/packages-{cand_series}/{pkg_arch}/packages"
    try:
        html = urllib.request.urlopen(f"{im_base}/").read().decode("utf-8", "ignore")
    except Exception:
        continue
    print(f"[build] ImmortalWrt: {im_base}/")
    for pkg in third_party:
        m = re.search(rf'href="({re.escape(pkg)}[_-][0-9][^"]*\.{pkg_ext})"', html)
        if m:
            dst = os.path.join(pkg_dir, m.group(1))
            if not os.path.exists(dst):
                print(f"  -> {m.group(1)}")
                urllib.request.urlretrieve(f"{im_base}/{m.group(1)}", dst)
    break
PYEOF

	mkdir -p "$WORK_IB/tmp"

	# 跳过第三方本地包的签名强校验（同时适配 opkg 与 25.12 apk）
	if [ -f "$WORK_IB/repositories.conf" ]; then
		sed -i 's/^option check_signature/# option check_signature/' "$WORK_IB/repositories.conf"
	fi
	if [ -f "$WORK_IB/Makefile" ]; then
		sed -i -e 's/apk add /apk add --allow-untrusted /g' -e 's/$(APK) add /$(APK) add --allow-untrusted /g' "$WORK_IB/Makefile"
	fi

	PATH="$WORK_IB/staging_dir/host/bin:$PATH" "$SCRIPT_DIR/patches/ui-replace.sh" "$SCRIPT_DIR/patches/custom-ui.po" "$WORK_FILES" "$WORK_IB"

	if [ "$TARGET_BOARD" = "x86" ]; then
		sed -i 's/# CONFIG_TARGET_ROOTFS_TARGZ is not set/CONFIG_TARGET_ROOTFS_TARGZ=y/' "$WORK_IB/.config" || echo "CONFIG_TARGET_ROOTFS_TARGZ=y" >> "$WORK_IB/.config"
	fi
	if [ -n "$ROOTFS_PARTSIZE" ]; then
		sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_PARTSIZE}/" "$WORK_IB/.config"
	fi

	# 过滤掉源里确实没有的第三方旧包（如 25.12 移除的 shadowsocksr-libev-ssr-redir），避免中断构建
	local VALID_PKGS=""
	for pkg in $FINAL_PACKAGES; do
		case "$pkg" in
		shadowsocks-libev-ss-redir|simple-obfs-client|shadowsocksr-libev-ssr-redir|trojan|ipt2socks|tcping|chinadns-ng)
			if ls "$WORK_IB/packages/${pkg}"* >/dev/null 2>&1; then
				VALID_PKGS="$VALID_PKGS $pkg"
			else
				echo "[build] Skip unavailable third-party package: $pkg"
			fi
			;;
		*)
			VALID_PKGS="$VALID_PKGS $pkg"
			;;
		esac
	done

	make -C "$WORK_IB" image FORCE=1 PROFILE="$TARGET_PROFILE" PACKAGES="$VALID_PKGS" FILES="$WORK_FILES"

	mkdir -p "$SCRIPT_DIR/output"
	cp -av "$WORK_IB/bin/targets/${TARGET_BOARD}/${TARGET_SUBTARGET}"/* "$SCRIPT_DIR/output/"
	rm -rf "$WORK_FILES"
}

if [ "$PRESET_ARG" = "ALL" ]; then
	for p in X64+DOCKER+WIFI CM520 K2P C5 NEWIFI3 Y1 RMAX6000; do
		build_single_preset "$p"
	done
else
	build_single_preset "$PRESET_ARG"
fi
