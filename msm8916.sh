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
find "$WORK/files" -name .DS_Store -delete

python3 - "$IB" "$PRESET" "$OPENWRT_SERIES" <<'PYEOF'
import json, os, re, sys, urllib.request
ib, preset, series = sys.argv[1:]
pkg_dir = os.path.join(ib, 'packages')
os.makedirs(pkg_dir, exist_ok=True)
def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'OponWrt'}), timeout=60).read()
release = json.loads(get('https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest'))
prefixes = ('luci-theme-argon-', 'luci-app-argon-config-', 'luci-i18n-argon-config-zh-cn-')
found = set()
for asset in release['assets']:
    name = asset['name']
    for prefix in prefixes:
        if name.startswith(prefix) and name.endswith('.apk'):
            with open(os.path.join(pkg_dir, name), 'wb') as f:
                f.write(get(asset['browser_download_url']))
            found.add(prefix)
if found != set(prefixes):
    raise SystemExit('Argon release does not contain all required APKs')
if '+NOWING' not in preset:
    base = f'https://downloads.immortalwrt.org/releases/packages-{series}/aarch64_generic/packages'
    html = get(base + '/').decode('utf-8', 'replace')
    for pkg in ('chinadns-ng', 'ipt2socks', 'simple-obfs-client', 'shadowsocksr-libev-ssr-redir', 'trojan', 'tcping'):
        match = re.search(r'href="(' + re.escape(pkg) + r'[_-][0-9][^"]*\.apk)"', html)
        if not match:
            if pkg in ('chinadns-ng', 'ipt2socks'):
                raise SystemExit('Required Wing package missing: ' + pkg)
            continue
        name = match.group(1)
        with open(os.path.join(pkg_dir, name), 'wb') as f:
            f.write(get(base + '/' + name))
PYEOF

# ImageBuilder includes third-party APKs downloaded above.
sed -i -e 's/apk add /apk add --allow-untrusted /g' -e 's/$(APK) add /$(APK) add --allow-untrusted /g' "$IB/Makefile"
python3 - "$IB/Makefile" "$SCRIPT_DIR/patches/ui-replace.sh" <<'PYEOF'
import re, sys
path, hook = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    text = f.read()
text, count = re.subn(r'(^build_image:[^\n]*\n)', lambda m: m.group(1) + '\t' + hook + ' $(TARGET_DIR)\n', text, count=1, flags=re.M)
if count != 1:
    raise SystemExit('ImageBuilder build_image target not found')
with open(path, 'w', encoding='utf-8') as f:
    f.write(text)
PYEOF

VALID_PKGS="-luci-theme-feelgood -samba4-server -luci-app-samba4 -ksmbd-server -luci-app-ksmbd -dockerd -luci-app-dockerman"
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
OUTPUT_DIR="$(mktemp -d "$SCRIPT_DIR/output/${PRESET}-msm8916-XXXXXXXX")"
shopt -s nullglob
images=("$IB"/bin/targets/msm89xx/msm8916/*ufi003*sysupgrade.bin)
[ "${#images[@]}" -eq 1 ] || { echo 'Expected one UFI003 sysupgrade image' >&2; exit 1; }
cp -av "${images[@]}" "$OUTPUT_DIR/"
manifests=("$IB"/bin/targets/msm89xx/msm8916/*ufi003*.manifest)
if [ "${#manifests[@]}" -gt 0 ]; then
	cp -av "${manifests[@]}" "$OUTPUT_DIR/"
fi
(cd "$OUTPUT_DIR" && sha256sum *sysupgrade.bin > sha256sums)
