#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IB_ARCHIVE="${1:?Usage: $0 <msm8916 ImageBuilder archive> [preset]}"
PRESET="${2:-UFI003}"
[[ "$PRESET" == UFI003 || "$PRESET" == UFI003+NOWING ]] || { echo "Unknown preset: $PRESET" >&2; exit 1; }
[ "$(uname -sm)" = 'Linux x86_64' ] || { echo 'ImageBuilder requires Linux x86_64' >&2; exit 1; }
[ -f "$IB_ARCHIVE" ] || { echo "ImageBuilder not found: $IB_ARCHIVE" >&2; exit 1; }

WORK="$(mktemp -d /tmp/oponwrt-msm8916.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/ib" "$WORK/files"
tar -xf "$IB_ARCHIVE" -C "$WORK/ib" --strip-components=1
IB="$WORK/ib"
[ -f "$IB/Makefile" ] && [ -f "$IB/.config" ] || { echo 'Unsupported ImageBuilder' >&2; exit 1; }
grep -q '^CONFIG_TARGET_msm89xx_msm8916=y$' "$IB/.config" || { echo 'ImageBuilder target is not msm89xx/msm8916' >&2; exit 1; }
grep -q '^CONFIG_USE_APK=y$' "$IB/.config" || { echo 'ImageBuilder must use APK packages' >&2; exit 1; }

# firmware.zip 需要交叉工具链编译 lk2nd/qhypstub，而 ImageBuilder 不带工具链；
# 本流程只交付 sysupgrade 镜像。
IMAGE_MAKEFILE="$IB/target/linux/msm89xx/image/msm8916.mk"
sed -i 's/ firmware\.zip$//' "$IMAGE_MAKEFILE"
grep -q '[[:space:]]ARTIFACTS.*firmware\.zip' "$IMAGE_MAKEFILE" && { echo 'Failed to drop firmware.zip artifact' >&2; exit 1; }
IB_VERSION=$(sed -n 's/^CONFIG_VERSION_NUMBER="\([0-9][0-9.]*\).*"$/\1/p' "$IB/.config")
OPENWRT_VER="${OPENWRT_VERSION:-$IB_VERSION}"
OPENWRT_VER="${OPENWRT_VER#v}"
[[ "$OPENWRT_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot determine OpenWrt release: $OPENWRT_VER" >&2; exit 1; }
OPENWRT_SERIES="${OPENWRT_VER%.*}"
touch "$IB/repositories"

# Keep the kernel packages from the matching standalone builder; ordinary
# userspace packages are provided by the corresponding OpenWrt release.
for feed in base luci packages routing telephony; do
	printf '%s\n' "https://downloads.openwrt.org/releases/$OPENWRT_VER/packages/aarch64_generic/$feed/packages.adb" >> "$IB/repositories"
done

source "$SCRIPT_DIR/packages.conf"
TARGET_BOARD=msm89xx TARGET_SUBTARGET=msm8916 TARGET_PROFILE=generic-ufi003-mb-v02
resolve_target_config "$PRESET"
cp -a "$SCRIPT_DIR/files/." "$WORK/files/"
awk '
	/^# 7\./ { skip_wan = 1 }
	/^# 8\./ { skip_wan = 0 }
	!skip_wan { print }
' "$SCRIPT_DIR/files/etc/uci-defaults/99-custom-init" > "$WORK/files/etc/uci-defaults/99-custom-init"
if [[ "$PRESET" != *+NOWING ]]; then
	cp -a "$SCRIPT_DIR/wing/." "$WORK/files/"
fi
cat > "$WORK/files/etc/uci-defaults/zz-msm8916-init" <<'EOF'
#!/bin/sh
uci set system.@system[0].hostname='OpenWrt'
uci commit system
EOF
chmod +x "$WORK/files/etc/uci-defaults/zz-msm8916-init"
find "$WORK/files" -name .DS_Store -delete

NOWING=""
[[ "$PRESET" == *+NOWING ]] && NOWING="--nowing"
python3 "$SCRIPT_DIR/prepare.py" "$IB" "$OPENWRT_SERIES" aarch64_generic $NOWING

# 目标默认包：chipidea 驱动已内建于内核，kmod-usb-chipidea 仅 ath79 提供；
# 默认 ip-tiny 与 Wing 所需 ip-full 互斥。
VALID_PKGS="-luci-app-firmware-upgrade -msm89xx-firmware-upgrade luci-i18n-filemanager-zh-cn luci-i18n-wol-zh-cn -luci-theme-feelgood -samba4-server -luci-app-samba4 -ksmbd-server -luci-app-ksmbd -dockerd -luci-app-dockerman -kmod-usb-chipidea -ip-tiny"
for pkg in $FINAL_PACKAGES; do
	case "$pkg" in
	chinadns-ng|ipt2socks|simple-obfs-client|shadowsocksr-libev-ssr-redir|trojan|tcping)
		if ! ls "$IB/packages/${pkg}"[-_]* >/dev/null 2>&1; then
			case "$pkg" in chinadns-ng|ipt2socks) echo "Missing $pkg" >&2; exit 1;; esac
			echo "[msm8916] Skip unavailable package: $pkg"
			continue
		fi ;;
	esac
	VALID_PKGS="$VALID_PKGS $pkg"
done
make -C "$IB" image FORCE=1 PROFILE="$TARGET_PROFILE" PACKAGES="$VALID_PKGS" FILES="$WORK/files"
mkdir -p "$SCRIPT_DIR/output"
OUTPUT_DIR="$(mktemp -d "$SCRIPT_DIR/output/OponWrt_msm8916_${PRESET}-XXXXXXXX")"
shopt -s nullglob
NAME="OponWrt_msm8916_${PRESET}"
images=("$IB"/bin/targets/msm89xx/msm8916/*ufi003*sysupgrade.bin)
[ "${#images[@]}" -eq 1 ] || { echo 'Expected one UFI003 sysupgrade image' >&2; exit 1; }
cp -av "${images[0]}" "$OUTPUT_DIR/${NAME}_squashfs-sysupgrade.bin"
manifests=("$IB"/bin/targets/msm89xx/msm8916/*ufi003*.manifest)
[ "${#manifests[@]}" -le 1 ] || { echo 'Expected at most one UFI003 manifest' >&2; exit 1; }
if [ "${#manifests[@]}" -eq 1 ]; then
	cp -av "${manifests[0]}" "$OUTPUT_DIR/${NAME}.manifest"
fi
(cd "$OUTPUT_DIR" && sha256sum *sysupgrade.bin > sha256sums)
