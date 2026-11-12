#!/bin/bash
# ==============================================================================
# OpenWrt ImageBuilder UI 文案、菜单与模板静态替换脚本 (patches/ui-replace.sh)
# 功能：
#   1. 将 patches/custom-ui.po 编译为 files/usr/lib/lua/luci/i18n/zzz-custom.zh-cn.lmo
#      （优先调用 po2lmo，若宿主环境未安装则自动使用内置 SuperFastHash LMO 编译器）
#   2. 自动扫描 ImageBuilder 软件包 (.apk / .ipk) 或目标根目录中的现有 *.zh-cn.lmo、
#      menu.d/*.json、www/index.html、luci-theme-argon 模板及版本文件，
#      将修改后的静态文件输出至 files/ 覆盖目录，确保固件断网首次启动即 100% 生效。
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PO_FILE="${1:-$SCRIPT_DIR/custom-ui.po}"
FILES_DIR="${2:-$REPO_ROOT/files}"
IB_DIR="${3:-}"

mkdir -p "$FILES_DIR/usr/lib/lua/luci/i18n"

# ------------------------------------------------------------------------------
# 1. 编译 custom-ui.po -> zzz-custom.zh-cn.lmo 并修补 ImageBuilder 中的 .zh-cn.lmo
# ------------------------------------------------------------------------------
LMO_OUT="$FILES_DIR/usr/lib/lua/luci/i18n/zzz-custom.zh-cn.lmo"

if command -v po2lmo >/dev/null 2>&1; then
	echo "[ui-replace] Using system po2lmo to compile $PO_FILE -> $LMO_OUT"
	po2lmo "$PO_FILE" "$LMO_OUT"
fi

python3 - "$PO_FILE" "$FILES_DIR" "$IB_DIR" <<'PYEOF'
import os
import re
import sys
import glob
import struct
import shutil
import tarfile
import tempfile
import subprocess

po_file = sys.argv[1]
files_dir = sys.argv[2]
ib_dir = sys.argv[3] if len(sys.argv) > 3 else ""

def sfh_hash(data: bytes) -> int:
    """Paul Hsieh's SuperFastHash - exact match with LuCI po2lmo / lmo.c"""
    length = len(data)
    if length == 0:
        return 0
    h = length & 0xFFFFFFFF
    rem = length & 3
    loops = length >> 2
    idx = 0
    while loops > 0:
        lo = data[idx] | (data[idx + 1] << 8)
        hi = data[idx + 2] | (data[idx + 3] << 8)
        h = (h + lo) & 0xFFFFFFFF
        tmp = ((hi << 11) ^ h) & 0xFFFFFFFF
        h = ((h << 16) ^ tmp) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
        idx += 4
        loops -= 1
    if rem == 3:
        lo = data[idx] | (data[idx + 1] << 8)
        h = (h + lo) & 0xFFFFFFFF
        h = (h ^ ((h << 16) & 0xFFFFFFFF)) & 0xFFFFFFFF
        sb = data[idx + 2] if data[idx + 2] < 128 else data[idx + 2] - 256
        h = (h ^ ((sb << 18) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        lo = data[idx] | (data[idx + 1] << 8)
        h = (h + lo) & 0xFFFFFFFF
        h = (h ^ ((h << 11) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        sb = data[idx] if data[idx] < 128 else data[idx] - 256
        h = (h + sb) & 0xFFFFFFFF
        h = (h ^ ((h << 10) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF
    h = (h ^ ((h << 3) & 0xFFFFFFFF)) & 0xFFFFFFFF
    h = (h + (h >> 5)) & 0xFFFFFFFF
    h = (h ^ ((h << 4) & 0xFFFFFFFF)) & 0xFFFFFFFF
    h = (h + (h >> 17)) & 0xFFFFFFFF
    h = (h ^ ((h << 25) & 0xFFFFFFFF)) & 0xFFFFFFFF
    h = (h + (h >> 6)) & 0xFFFFFFFF
    return h & 0xFFFFFFFF

def parse_po(path: str) -> dict:
    entries = {}
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    blocks = re.split(r"\n\s*\n", content)
    for block in blocks:
        msgid_matches = re.findall(r'msgid\s+"((?:[^"\\]|\\.)*)"(?:\s*\n\s*"((?:[^"\\]|\\.)*)")*', block)
        if not msgid_matches:
            continue
        m_id = re.search(r'msgid\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        m_str = re.search(r'msgstr\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        if not m_id or not m_str:
            continue
        def unescape(raw):
            parts = re.findall(r'"((?:[^"\\]|\\.)*)"', raw)
            s = "".join(parts)
            return s.replace(r'\"', '"').replace(r'\n', '\n').replace(r'\t', '\t').replace(r'\\', '\\')
        k = unescape(m_id.group(1))
        v = unescape(m_str.group(1))
        if k and v:
            entries[k] = v
    return entries

def read_lmo(path: str) -> dict:
    with open(path, "rb") as f:
        buf = f.read()
    if len(buf) < 4:
        return {}
    (table_offset,) = struct.unpack(">I", buf[-4:])
    if table_offset >= len(buf) - 4:
        return {}
    idx_data = buf[table_offset:-4]
    entries = {}
    for i in range(0, len(idx_data), 16):
        if i + 16 > len(idx_data):
            break
        key_id, val_id, offset, length = struct.unpack(">IIII", idx_data[i:i+16])
        val_bytes = buf[offset:offset+length]
        try:
            entries[key_id] = val_bytes.decode("utf-8")
        except UnicodeDecodeError:
            entries[key_id] = val_bytes.decode("utf-8", errors="replace")
    return entries

def write_lmo(path: str, entries_by_keyid: dict):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    body = bytearray()
    index = []
    for key_id in sorted(entries_by_keyid.keys()):
        val_str = entries_by_keyid[key_id]
        if not val_str:
            continue
        val_bytes = val_str.encode("utf-8")
        val_id = sfh_hash(val_bytes)
        if key_id == val_id:
            continue
        offset = len(body)
        length = len(val_bytes)
        body.extend(val_bytes)
        pad = (4 - (length % 4)) % 4
        if pad:
            body.extend(b"\x00" * pad)
        index.append((key_id, val_id, offset, length))
    table_offset = len(body)
    for item in index:
        body.extend(struct.pack(">IIII", *item))
    body.extend(struct.pack(">I", table_offset))
    with open(path, "wb") as f:
        f.write(body)

po_entries = parse_po(po_file)
po_hash_map = {sfh_hash(k.encode("utf-8")): v for k, v in po_entries.items()}

lmo_out = os.path.join(files_dir, "usr/lib/lua/luci/i18n/zzz-custom.zh-cn.lmo")
if not os.path.exists(lmo_out):
    write_lmo(lmo_out, po_hash_map)
    print(f"[ui-replace] Compiled {len(po_hash_map)} entries into {lmo_out}")

# 原 4-fix 中针对各 PO 文件的精确与子串替换规则
EXACT_VALUE_MAP = {
    "LED 配置": "灯光配置",
    "<abbr title=\"发光二极管\">LED</abbr> 配置": "灯光配置",
    "路由": "路由规则",
    "防火墙": "防火长城",
    "Aria2": "下载工具",
    "Docker": "容器",
    "frp 服务器": "公网穿透",
    "frp 客户端": "内网穿透",
    "UPnP IGD 和 PCP": "端口映射",
    "UPnP IGD 和 PCP/NAT-PMP": "端口映射",
    "uHTTPd": "网页服务",
    "Transmission": "比特传输",
    "WiFi 计划": "无线计划",
    "ShadowSocksR Plus+ 设置": "科学上网设置",
    "ShadowSocksR Plus+": "科学上网",
    "Refresh Token": "刷新令牌",
}

SUBSTR_VALUE_MAP = [
    ("动态 DNS", "动态域名"),
    ("备份与升级", "备份升级"),
    ("DHCP/DNS", "主机域名"),
    ("自定义命令", "自定命令"),
    ("允许匿名用户", "访客"),
    ("允许旧协议与身份验证（不安全）。", "允许旧协议"),
    ("Apple Time-machine 共享", "时间机器"),
    ("可浏览", "浏览"),
    ("创建权限掩码", "创建掩码"),
    ("目录权限掩码", "目录掩码"),
    ("禁用 Netbios", "禁用 NetBIOS"),
    ("禁用 Winbind", "禁用 WinBind"),
    ("编辑用于生成 samba 配置的模板。", "编辑用来生成 Samba 配置的模板"),
    ("启用 macOS 兼容共享", "兼容 macOS 特性"),
    ("强制 Root", "强根"),
    ("仅来宾用户", "仅访客"),
    ("Time-machine 大小（GB）", "机器大小"),
    ("VFS 对象", "虚拟对象"),
    ("shadowsocks rust版本", "Shadowsocks"),
    ("阿里云盘 WebDAV", "阿里云盘"),
    ("(bytes)", "（字节）"),
    ("单位为", ""),
    ("云盘驱动类型", "云盘类型"),
    ("：resource, backup", "：资源盘、备份盘"),
]

KEYID_MOUNT_POINTS = sfh_hash(b"Mount Points")
KEYID_REBOOT = sfh_hash(b"Reboot")

def transform_lmo_entries(entries: dict) -> tuple[dict, bool]:
    changed = False
    new_entries = dict(entries)
    for k_id, val in list(new_entries.items()):
        orig = val
        if k_id == KEYID_MOUNT_POINTS and val == "挂载点":
            val = "挂载位置"
        elif k_id == KEYID_REBOOT and val == "重启":
            val = "重新启动"
        if val in EXACT_VALUE_MAP:
            val = EXACT_VALUE_MAP[val]
        for old_s, new_s in SUBSTR_VALUE_MAP:
            if old_s in val:
                val = val.replace(old_s, new_s)
        if k_id in po_hash_map and new_entries.get(k_id) != po_hash_map[k_id]:
            val = po_hash_map[k_id]
        if val != orig:
            new_entries[k_id] = val
            changed = True
    return new_entries, changed

# 若传入了 ImageBuilder 目录，自动从其中的软件包 (.apk / .ipk) 提取待定制的 LMO、JSON 与模板文件
if ib_dir and os.path.isdir(ib_dir):
    pkg_files = []
    for ext in ("*.apk", "*.ipk"):
        pkg_files.extend(glob.glob(os.path.join(ib_dir, "**", ext), recursive=True))
    target_Archive_patterns = (
        "luci-i18n-",
        "luci-base",
        "luci-lua-runtime",
        "luci-theme-argon",
        "luci-app-ddns",
        "luci-app-xfrpc",
        "luci-app-upnp",
        "luci-app-uhttpd",
        "luci-app-wifischedule",
    )
    with tempfile.TemporaryDirectory() as tmpdir:
        for pkg in pkg_files:
            bname = os.path.basename(pkg)
            if not any(bname.startswith(p) for p in target_Archive_patterns):
                continue
            extract_dir = os.path.join(tmpdir, bname)
            os.makedirs(extract_dir, exist_ok=True)
            try:
                if pkg.endswith(".ipk"):
                    subprocess.run(["tar", "-xzf", pkg, "-C", extract_dir], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    data_tar = glob.glob(os.path.join(extract_dir, "data.tar.*"))
                    if data_tar:
                        subprocess.run(["tar", "-xf", data_tar[0], "-C", extract_dir], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    subprocess.run(["tar", "-xf", pkg, "-C", extract_dir], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                continue

            # 1) 处理提取出的 .zh-cn.lmo
            for lmo_path in glob.glob(os.path.join(extract_dir, "usr/lib/lua/luci/i18n/*.zh-cn.lmo")):
                entries = read_lmo(lmo_path)
                if not entries:
                    continue
                if os.path.basename(lmo_path) == "base.zh-cn.lmo":
                    entries.update(po_hash_map)
                    changed = True
                new_entries, changed2 = transform_lmo_entries(entries)
                if changed or changed2 or os.path.basename(lmo_path) == "base.zh-cn.lmo":
                    dst_lmo = os.path.join(files_dir, "usr/lib/lua/luci/i18n", os.path.basename(lmo_path))
                    write_lmo(dst_lmo, new_entries)
                    print(f"[ui-replace] Patched LMO: {os.path.basename(lmo_path)}")

            # 2) 复制菜单 JSON、www/index.html、argon footer 模板、version.uc 到 files/ 以便后续 sed 修改
            rel_targets = [
                "www/index.html",
                "usr/share/ucode/luci/version.uc",
                "usr/share/luci/menu.d/luci-app-ddns.json",
                "usr/share/luci/menu.d/luci-app-xfrpc.json",
                "usr/share/luci/menu.d/luci-app-upnp.json",
                "usr/share/luci/menu.d/luci-app-uhttpd.json",
                "usr/share/luci/menu.d/luci-app-wifischedule.json",
                "usr/share/ucode/luci/template/themes/argon/footer.ut",
                "usr/share/ucode/luci/template/themes/argon/footer_login.ut",
            ]
            for rel in rel_targets:
                src_p = os.path.join(extract_dir, rel)
                if os.path.isfile(src_p):
                    dst_p = os.path.join(files_dir, rel)
                    os.makedirs(os.path.dirname(dst_p), exist_ok=True)
                    shutil.copy2(src_p, dst_p)
PYEOF

# ------------------------------------------------------------------------------
# 2. 对目标目录（files/ 或 rootfs）执行原 4-fix 中的菜单排序与静态模板替换
# ------------------------------------------------------------------------------
apply_static_replacements() {
	local ROOT="$1"
	[ -d "$ROOT" ] || return 0

	# LuCI 引导页标题: LuCI - Lua Configuration Interface -> Loading...
	if [ -f "$ROOT/www/index.html" ]; then
		sed -i.bak 's/LuCI - Lua Configuration Interface/Loading.../g' "$ROOT/www/index.html" && rm -f "$ROOT/www/index.html.bak"
	fi

	# LuCI 版本信息标识: Yonsm (<YYYY-MM-DD>)
	if [ -f "$ROOT/usr/share/ucode/luci/version.uc" ]; then
		sed -i.bak -e "s/luciname\s*=\s*\"[^\"]*\"/luciname = \"Yonsm\"/" \
			-e "s/luciversion\s*=\s*\"[^\"]*\"/luciversion = \"$(date +%Y-%m-%d)\"/" \
			"$ROOT/usr/share/ucode/luci/version.uc" && rm -f "$ROOT/usr/share/ucode/luci/version.uc.bak"
	fi

	# 左侧菜单顺序与分类调整 (menu.d/*.json)
	local MENU_DIR="$ROOT/usr/share/luci/menu.d"
	if [ -f "$MENU_DIR/luci-app-ddns.json" ]; then
		sed -i.bak 's/59/20/g' "$MENU_DIR/luci-app-ddns.json" && rm -f "$MENU_DIR/luci-app-ddns.json.bak"
	fi
	if [ -f "$MENU_DIR/luci-app-xfrpc.json" ]; then
		sed -i.bak -e '/"order"/d' -e 's/"title": "Reverse proxy",/"title": "Reverse proxy",\n\t\t"order": 21,/' "$MENU_DIR/luci-app-xfrpc.json" && rm -f "$MENU_DIR/luci-app-xfrpc.json.bak"
	fi
	if [ -f "$MENU_DIR/luci-app-upnp.json" ]; then
		sed -i.bak -e '/"order"/d' -e 's/PCP",/PCP",\n\t\t"order": 22,/' "$MENU_DIR/luci-app-upnp.json" && rm -f "$MENU_DIR/luci-app-upnp.json.bak"
	fi
	if [ -f "$MENU_DIR/luci-app-uhttpd.json" ]; then
		sed -i.bak -e '/"order"/d' -e 's/"title": "uHTTPd",/"title": "uHTTPd",\n\t\t"order": 25,/' "$MENU_DIR/luci-app-uhttpd.json" && rm -f "$MENU_DIR/luci-app-uhttpd.json.bak"
	fi
	if [ -f "$MENU_DIR/luci-app-wifischedule.json" ]; then
		sed -i.bak 's/services/network/g' "$MENU_DIR/luci-app-wifischedule.json" && rm -f "$MENU_DIR/luci-app-wifischedule.json.bak"
	fi

	# Argon 主题页脚版权与版本信息替换
	for FOOTER in \
		"$ROOT/usr/share/ucode/luci/template/themes/argon/footer.ut" \
		"$ROOT/usr/share/ucode/luci/template/themes/argon/footer_login.ut"; do
		if [ -f "$FOOTER" ]; then
			sed -i.bak \
				-e 's#openwrt/luci#Yonsm/OponWrt#g' \
				-e 's/{{ version.luciname }} ({{ version.luciversion }})/Yonsm/g' \
				-e 's/-{{ version.distrevision }}//g' \
				"$FOOTER" && rm -f "$FOOTER.bak"
		fi
	done
}

apply_static_replacements "$FILES_DIR"
[ -n "$IB_DIR" ] && [ -d "$IB_DIR" ] && apply_static_replacements "$IB_DIR"

echo "[ui-replace] UI translations and template replacements completed."
