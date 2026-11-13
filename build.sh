#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRESET_ARG="${1:-ALL}"
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
	[[ "$PRESET" =~ ^[a-zA-Z0-9_.@+-]+$ ]] || { echo "[build] Invalid preset: $PRESET" >&2; return 1; }
	local DEVICE="${PRESET%%+*}" TARGET_INFO
	DEVICE="${DEVICE%-opboot}"
	TARGET_INFO=$(python3 - "$OPENWRT_VER" "$DEVICE" <<'PYEOF'
import json, sys, urllib.request

version, device = sys.argv[1:]
query, _, target = device.partition('@')
if not query:
    raise SystemExit("[build] Device profile is empty")
target = target.replace('.', '/')
base = f"https://downloads.openwrt.org/releases/{version}"
with urllib.request.urlopen(f"{base}/.overview.json") as response:
    profiles = json.load(response)["profiles"]
matches = [p for p in profiles if query.lower() in p["id"].lower() and (not target or p["target"] == target)]
exact = [p for p in matches if p["id"].lower() == query.lower()]
matches = exact or matches
if len(matches) != 1:
    details = ", ".join(f'{p["id"]}@{p["target"].replace("/", ".")}' for p in matches)
    raise SystemExit(f"[build] Device '{device}' matched {len(matches)} profiles" + (f": {details}" if details else ""))
profile = matches[0]
board, subtarget = profile["target"].split("/")
with urllib.request.urlopen(f"{base}/targets/{board}/{subtarget}/profiles.json") as response:
    arch = json.load(response)["arch_packages"]
print(board, subtarget, profile["id"], arch)
PYEOF
	) || return 1
	read -r TARGET_BOARD TARGET_SUBTARGET TARGET_PROFILE PKG_ARCH <<< "$TARGET_INFO"
	local TARGET_PATCH="$SCRIPT_DIR/patches/$TARGET_PROFILE.sh"
	if [[ "${PRESET%%+*}" == *-opboot ]] && [ ! -f "$TARGET_PATCH" ]; then
		echo "[build] OpBoot is not supported for $TARGET_PROFILE" >&2
		return 1
	fi
	resolve_target_config "$PRESET"
	echo "[build] $PRESET -> $TARGET_BOARD/$TARGET_SUBTARGET ($TARGET_PROFILE, $PKG_ARCH)"

	local WORK_IB="/tmp/openwrt-ib-${OPENWRT_VER}-${TARGET_BOARD}-${TARGET_SUBTARGET}-${PRESET}"
	local WORK_FILES="/tmp/openwrt-files-${PRESET}"
	rm -rf "$WORK_FILES"
	cp -a "$SCRIPT_DIR/files" "$WORK_FILES"
	if [[ "$PRESET" != *"+NOWING"* ]]; then
		cp -a "$SCRIPT_DIR/wing/"* "$WORK_FILES/"
	fi
	if [ "$TARGET_BOARD/$TARGET_SUBTARGET" = x86/64 ]; then
		cp -a "$SCRIPT_DIR/extras/x86/"* "$WORK_FILES/"
	fi
	if [ "$TARGET_BOARD/$TARGET_SUBTARGET" = x86/64 ] || [[ "$PRESET" == *"+SMB4"* ]]; then
		cp -a "$SCRIPT_DIR/extras/samba4/"* "$WORK_FILES/"
	fi
	if [[ "$PRESET" == *"+HASS"* ]]; then
		cp -a "$SCRIPT_DIR/extras/hass/"* "$WORK_FILES/"
	fi
	find "$WORK_FILES" -name ".DS_Store" -delete

	python3 - "$OPENWRT_VER" "$TARGET_BOARD" "$TARGET_SUBTARGET" "$WORK_IB" <<'PYEOF'
import os, re, subprocess, sys, tempfile, urllib.request

ver, board, subtarget, work_ib = sys.argv[1:5]
base_url = f"https://downloads.openwrt.org/releases/{ver}/targets/{board}/{subtarget}"

if not os.path.isdir(work_ib):
    sums = urllib.request.urlopen(f"{base_url}/sha256sums").read().decode("utf-8", "ignore")
    m = re.search(rf"(openwrt-imagebuilder-{re.escape(ver)}-{re.escape(board)}-{re.escape(subtarget)}\.Linux-x86_64\.tar\.(?:zst|xz))", sums)
    if not m:
        raise SystemExit(f"ImageBuilder not found at {base_url}")
    with tempfile.TemporaryDirectory(prefix="openwrt-ib-", dir="/tmp") as tmp:
        ib_path = os.path.join(tmp, m.group(1))
        extracted = os.path.join(tmp, "imagebuilder")
        print(f"[build] Downloading {base_url}/{m.group(1)}")
        urllib.request.urlretrieve(f"{base_url}/{m.group(1)}", ib_path)
        os.mkdir(extracted)
        subprocess.run(["tar", "-xf", ib_path, "-C", extracted, "--strip-components=1"], check=True)
        os.rename(extracted, work_ib)
PYEOF

	mkdir -p "$WORK_IB/tmp"
	local NOWING=""
	[[ "$PRESET" == *"+NOWING"* ]] && NOWING="--nowing"
	python3 "$SCRIPT_DIR/prepare-imagebuilder.py" "$WORK_IB" "$OPENWRT_SERIES" "$PKG_ARCH" $NOWING

	if [ "$TARGET_BOARD" = "x86" ]; then
		sed -i 's/# CONFIG_TARGET_ROOTFS_TARGZ is not set/CONFIG_TARGET_ROOTFS_TARGZ=y/' "$WORK_IB/.config" || echo "CONFIG_TARGET_ROOTFS_TARGZ=y" >> "$WORK_IB/.config"
	fi
	if [ -n "$ROOTFS_PARTSIZE" ]; then
		sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_PARTSIZE}/" "$WORK_IB/.config"
	fi

	# Wing 核心依赖必须存在；旧协议客户端允许缺省
	local VALID_PKGS=""
	for pkg in $FINAL_PACKAGES; do
		case "$pkg" in
		simple-obfs-client|shadowsocksr-libev-ssr-redir|trojan|ipt2socks|tcping|chinadns-ng)
			if ls "$WORK_IB/packages/${pkg}"* >/dev/null 2>&1; then
				VALID_PKGS="$VALID_PKGS $pkg"
			else
				if [ "$pkg" = chinadns-ng ] || [ "$pkg" = ipt2socks ]; then
					echo "[build] Missing required Wing package: $pkg" >&2
					return 1
				fi
				echo "[build] Skip unavailable third-party package: $pkg"
			fi
			;;
		*)
			VALID_PKGS="$VALID_PKGS $pkg"
			;;
		esac
	done

	local ATTEMPT=1
	EXTRA_IMAGE_NAME=""
	if [ -f "$TARGET_PATCH" ]; then
		if [ "${OPBOOT:-0}" = "1" ] || [[ "${PRESET%%+*}" == *-opboot ]]; then
			"$TARGET_PATCH" "$WORK_IB" opboot
			EXTRA_IMAGE_NAME="opboot"
		else
			"$TARGET_PATCH" "$WORK_IB" restore
		fi
	fi
	until make -C "$WORK_IB" image FORCE=1 PROFILE="$TARGET_PROFILE" PACKAGES="$VALID_PKGS" FILES="$WORK_FILES" ${EXTRA_IMAGE_NAME:+EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME"}; do
		[ "$ATTEMPT" -ge 3 ] && return 1
		echo "[build] Image build failed (attempt $ATTEMPT/3), retrying in 10s..."
		ATTEMPT=$((ATTEMPT + 1))
		sleep 10
	done

	mkdir -p "$SCRIPT_DIR/output"
	local OUTPUT_DIR
	OUTPUT_DIR=$(mktemp -d "$SCRIPT_DIR/output/${PRESET}-${OPENWRT_VER}-XXXXXXXX")
	cp -av "$WORK_IB/bin/targets/${TARGET_BOARD}/${TARGET_SUBTARGET}"/* "$OUTPUT_DIR/"
	rm -rf "$WORK_FILES"
}

if [ "$PRESET_ARG" = "ALL" ]; then
	for p in generic@x86.64+DOCKER+WIFI mobipromo_cm520-79f-opboot phicomm_k2p xiaoyu_xy-c5 d-team_newifi-d2 lenovo_newifi-y1 xiaomi_redmi-router-ax6000-stock; do
		build_single_preset "$p"
	done
else
	build_single_preset "$PRESET_ARG"
fi
