#!/bin/bash
# ==============================================================================
# OpenWrt ImageBuilder 极速自动化固件打包脚本 (build.sh)
# 用法: ./build.sh [PRESET] [OPENWRT_VERSION]
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRESET_ARG="${1:-X64+DOCKER+WIFI}"
OPENWRT_VER="${2:-$OPENWRT_VERSION}"

OPENWRT_DL_HOST="https://downloads.openwrt.org"
IMMORTAL_DL_HOST="https://downloads.immortalwrt.org"
ARGON_API_URL="https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest"

# 1. 自动解析最新正式版 OpenWrt Release 版本号（排除 SNAPSHOT 与 -rc 预览版）
if [ -z "$OPENWRT_VER" ]; then
	OPENWRT_VER=$(python3 -c '
import re, urllib.request
html = urllib.request.urlopen("https://downloads.openwrt.org/releases/").read().decode("utf-8", "ignore")
vers = re.findall(r"href=\"([0-9]+\.[0-9]+\.[0-9]+)/\"", html)
vers.sort(key=lambda s: [int(x) for x in s.split(".")])
print(vers[-1] if vers else "")
')
fi

if [ -z "$OPENWRT_VER" ]; then
	echo "[build] Error: Failed to resolve OpenWrt version!" >&2
	exit 1
fi

OPENWRT_SERIES="${OPENWRT_VER%.*}"
echo "[build] Target OpenWrt Release: $OPENWRT_VER (Series: $OPENWRT_SERIES)"

source "$SCRIPT_DIR/packages.conf"

build_single_preset() {
	local PRESET="$1"
	resolve_target_config "$PRESET"
	echo "[build] Preset: $PRESET -> $TARGET_BOARD/$TARGET_SUBTARGET ($TARGET_PROFILE, $PKG_ARCH)"

	local WORK_IB="/tmp/openwrt-ib-${TARGET_BOARD}-${TARGET_SUBTARGET}"
	python3 - "$OPENWRT_VER" "$OPENWRT_SERIES" "$TARGET_BOARD" "$TARGET_SUBTARGET" "$PKG_ARCH" "$WORK_IB" <<'PYEOF'
import os, re, sys, json, shutil, tarfile, subprocess, urllib.request

ver, series, board, subtarget, pkg_arch, work_ib = sys.argv[1:7]
base_url = f"https://downloads.openwrt.org/releases/{ver}/targets/{board}/{subtarget}"

if not os.path.isdir(work_ib):
    sums = urllib.request.urlopen(f"{base_url}/sha256sums").read().decode("utf-8", "ignore")
    m = re.search(rf"(openwrt-imagebuilder-{re.escape(ver)}-{re.escape(board)}-{re.escape(subtarget)}\.Linux-x86_64\.tar\.(?:zst|xz))", sums)
    if not m:
        raise SystemExit(f"ImageBuilder not found at {base_url}")
    ib_file = m.group(1)
    ib_path = f"/tmp/{ib_file}"
    print(f"[build] Downloading {base_url}/{ib_file} ...")
    urllib.request.urlretrieve(f"{base_url}/{ib_file}", ib_path)
    os.makedirs(work_ib, exist_ok=True)
    subprocess.run(["tar", "-xf", ib_path, "-C", work_ib, "--strip-components=1"], check=True)
    os.remove(ib_path)

pkg_ext = "apk" if os.path.exists(os.path.join(work_ib, "repositories")) else "ipk"
pkg_dir = os.path.join(work_ib, "packages")
os.makedirs(pkg_dir, exist_ok=True)

# 1. 下载最新 luci-theme-argon (v3.1.3+)
req = urllib.request.Request("https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest", headers={"User-Agent": "OpenWrt-ImageBuilder"})
rel = json.loads(urllib.request.urlopen(req).read().decode("utf-8"))
for asset in rel.get("assets", []):
    url = asset.get("browser_download_url", "")
    if url.endswith(f".{pkg_ext}"):
        dst = os.path.join(pkg_dir, os.path.basename(url))
        if not os.path.exists(dst):
            print(f"[build] Fetching Argon: {os.path.basename(url)}")
            urllib.request.urlretrieve(url, dst)

# 2. 从 ImmortalWrt 对应架构软件源获取 chinadns-ng 与 wing 依赖包
third_party = [
    "chinadns-ng",
    "shadowsocks-libev-ss-redir",
    "simple-obfs-client",
    "shadowsocksr-libev-ssr-redir",
    "trojan",
    "ipt2socks",
    "dns2tcp",
    "tcping",
]
for cand_series in (series, "24.10"):
    im_base = f"https://downloads.immortalwrt.org/releases/packages-{cand_series}/{pkg_arch}/packages"
    try:
        html = urllib.request.urlopen(f"{im_base}/").read().decode("utf-8", "ignore")
    except Exception:
        continue
    print(f"[build] Scanning ImmortalWrt feed: {im_base}/")
    for pkg in third_party:
        m = re.search(rf'href="({re.escape(pkg)}[_-][0-9][^"]*\.{pkg_ext})"', html)
        if m:
            fname = m.group(1)
            dst = os.path.join(pkg_dir, fname)
            if not os.path.exists(dst):
                print(f"  -> {fname}")
                urllib.request.urlretrieve(f"{im_base}/{fname}", dst)
    break
PYEOF

	# 关闭签名强校验以便安装 packages/ 目录下的第三方包
	[ -f "$WORK_IB/repositories.conf" ] && sed -i 's/^option check_signature/# option check_signature/' "$WORK_IB/repositories.conf"
	[ -f "$WORK_IB/Makefile" ] && sed -i 's/apk add /apk add --allow-untrusted /g' "$WORK_IB/Makefile" || true

	# 编译自定义 UI 翻译 (.lmo) 并执行静态模板/菜单替换
	export PATH="$WORK_IB/staging_dir/host/bin:$PATH"
	"$SCRIPT_DIR/patches/ui-replace.sh" "$SCRIPT_DIR/patches/custom-ui.po" "$SCRIPT_DIR/files" "$WORK_IB"

	if [ "$TARGET_BOARD" = "x86" ]; then
		sed -i 's/# CONFIG_TARGET_ROOTFS_TARGZ is not set/CONFIG_TARGET_ROOTFS_TARGZ=y/' "$WORK_IB/.config" || echo "CONFIG_TARGET_ROOTFS_TARGZ=y" >> "$WORK_IB/.config"
	fi
	if [ -n "$ROOTFS_PARTSIZE" ]; then
		sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_PARTSIZE}/" "$WORK_IB/.config"
	fi

	make -C "$WORK_IB" image \
		PROFILE="$TARGET_PROFILE" \
		PACKAGES="$FINAL_PACKAGES" \
		FILES="$SCRIPT_DIR/files"

	mkdir -p "$SCRIPT_DIR/output"
	cp -av "$WORK_IB/bin/targets/${TARGET_BOARD}/${TARGET_SUBTARGET}"/* "$SCRIPT_DIR/output/"
}

if [ "$PRESET_ARG" = "ALL" ]; then
	for p in X64+DOCKER+WIFI CM520 K2P C5 NEWIFI3 Y1 RMAX6000; do
		build_single_preset "$p"
	done
else
	build_single_preset "$PRESET_ARG"
fi
