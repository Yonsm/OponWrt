#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PO_FILE="${1:-$SCRIPT_DIR/custom-ui.po}"
FILES_DIR="${2:-$REPO_ROOT/files}"
IB_DIR="${3:-}"

mkdir -p "$FILES_DIR/usr/lib/lua/luci/i18n"
LMO_OUT="$FILES_DIR/usr/lib/lua/luci/i18n/zzz-custom.zh-cn.lmo"
command -v po2lmo >/dev/null 2>&1 && po2lmo "$PO_FILE" "$LMO_OUT"

python3 - "$PO_FILE" "$FILES_DIR" "$IB_DIR" <<'PYEOF'
import os, re, sys, glob, struct, shutil, tempfile, subprocess

po_file, files_dir = sys.argv[1], sys.argv[2]
ib_dir = sys.argv[3] if len(sys.argv) > 3 else ""

def sfh_hash(data: bytes) -> int:
    length = len(data)
    if length == 0:
        return 0
    h = length & 0xFFFFFFFF
    rem, loops, idx = length & 3, length >> 2, 0
    while loops > 0:
        lo = data[idx] | (data[idx + 1] << 8)
        hi = data[idx + 2] | (data[idx + 3] << 8)
        h = (h + lo) & 0xFFFFFFFF
        h = ((h << 16) ^ (((hi << 11) ^ h) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
        idx += 4
        loops -= 1
    if rem == 3:
        h = (h + (data[idx] | (data[idx + 1] << 8))) & 0xFFFFFFFF
        h = (h ^ ((h << 16) & 0xFFFFFFFF)) & 0xFFFFFFFF
        sb = data[idx + 2] if data[idx + 2] < 128 else data[idx + 2] - 256
        h = (h ^ ((sb << 18) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        h = (h + (data[idx] | (data[idx + 1] << 8))) & 0xFFFFFFFF
        h = (h ^ ((h << 11) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        sb = data[idx] if data[idx] < 128 else data[idx] - 256
        h = (h + sb) & 0xFFFFFFFF
        h = (h ^ ((h << 10) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF
    for shift_l, shift_r in ((3, 5), (4, 17), (25, 6)):
        h = (h ^ ((h << shift_l) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> shift_r)) & 0xFFFFFFFF
    return h & 0xFFFFFFFF

def parse_po(path: str) -> dict:
    entries = {}
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    unescape = lambda raw: "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', raw)).replace(r'\"', '"').replace(r'\n', '\n').replace(r'\t', '\t').replace(r'\\', '\\')
    for block in re.split(r"\n\s*\n", content):
        m_id = re.search(r'msgid\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        m_str = re.search(r'msgstr\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        if m_id and m_str:
            k, v = unescape(m_id.group(1)), unescape(m_str.group(1))
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
    for i in range(0, len(idx_data) - (len(idx_data) % 16), 16):
        key_id, _, offset, length = struct.unpack(">IIII", idx_data[i:i+16])
        entries[key_id] = buf[offset:offset+length].decode("utf-8", errors="replace")
    return entries

def write_lmo(path: str, entries_by_keyid: dict):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    body, index = bytearray(), []
    for key_id in sorted(entries_by_keyid.keys()):
        val_str = entries_by_keyid[key_id]
        if not val_str:
            continue
        val_bytes = val_str.encode("utf-8")
        val_id = sfh_hash(val_bytes)
        if key_id == val_id:
            continue
        offset, length = len(body), len(val_bytes)
        body.extend(val_bytes)
        body.extend(b"\x00" * ((4 - (length % 4)) % 4))
        index.append((key_id, val_id, offset, length))
    table_offset = len(body)
    for item in index:
        body.extend(struct.pack(">IIII", *item))
    body.extend(struct.pack(">I", table_offset))
    with open(path, "wb") as f:
        f.write(body)

po_hash_map = {sfh_hash(k.encode("utf-8")): v for k, v in parse_po(po_file).items()}
lmo_out = os.path.join(files_dir, "usr/lib/lua/luci/i18n/zzz-custom.zh-cn.lmo")
if not os.path.exists(lmo_out):
    write_lmo(lmo_out, po_hash_map)

EXACT = {
    "LED 配置": "灯光配置", "<abbr title=\"发光二极管\">LED</abbr> 配置": "灯光配置",
    "路由": "路由规则", "防火墙": "防火长城", "Aria2": "下载工具", "Docker": "容器",
    "frp 服务器": "公网穿透", "frp 客户端": "内网穿透", "UPnP IGD 和 PCP": "端口映射",
    "UPnP IGD 和 PCP/NAT-PMP": "端口映射", "uHTTPd": "网页服务", "Transmission": "比特传输",
    "WiFi 计划": "无线计划", "ShadowSocksR Plus+ 设置": "科学上网设置",
    "ShadowSocksR Plus+": "科学上网", "Refresh Token": "刷新令牌",
}
SUBSTR = [
    ("动态 DNS", "动态域名"), ("备份与升级", "备份升级"), ("DHCP/DNS", "主机域名"),
    ("自定义命令", "自定命令"), ("允许匿名用户", "访客"), ("允许旧协议与身份验证（不安全）。", "允许旧协议"),
    ("Apple Time-machine 共享", "时间机器"), ("可浏览", "浏览"), ("创建权限掩码", "创建掩码"),
    ("目录权限掩码", "目录掩码"), ("禁用 Netbios", "禁用 NetBIOS"), ("禁用 Winbind", "禁用 WinBind"),
    ("编辑用于生成 samba 配置的模板。", "编辑用来生成 Samba 配置的模板"),
    ("启用 macOS 兼容共享", "兼容 macOS 特性"), ("强制 Root", "强根"), ("仅来宾用户", "仅访客"),
    ("Time-machine 大小（GB）", "机器大小"), ("VFS 对象", "虚拟对象"),
    ("shadowsocks rust版本", "Shadowsocks"), ("阿里云盘 WebDAV", "阿里云盘"),
    ("(bytes)", "（字节）"), ("单位为", ""), ("云盘驱动类型", "云盘类型"), ("：resource, backup", "：资源盘、备份盘"),
]
KID_MOUNT, KID_REBOOT = sfh_hash(b"Mount Points"), sfh_hash(b"Reboot")

if ib_dir and os.path.isdir(ib_dir):
    pkgs = glob.glob(os.path.join(ib_dir, "**", "*.apk"), recursive=True) + glob.glob(os.path.join(ib_dir, "**", "*.ipk"), recursive=True)
    pats = ("luci-i18n-", "luci-base", "luci-lua-runtime", "luci-theme-argon", "luci-app-ddns", "luci-app-xfrpc", "luci-app-upnp", "luci-app-uhttpd", "luci-app-wifischedule")
    with tempfile.TemporaryDirectory() as tmpdir:
        for pkg in pkgs:
            bname = os.path.basename(pkg)
            if not any(bname.startswith(p) for p in pats):
                continue
            ext = os.path.join(tmpdir, bname)
            os.makedirs(ext, exist_ok=True)
            subprocess.run(["tar", "-xf", pkg, "-C", ext], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for dt in glob.glob(os.path.join(ext, "data.tar.*")):
                subprocess.run(["tar", "-xf", dt, "-C", ext], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for lmo_path in glob.glob(os.path.join(ext, "usr/lib/lua/luci/i18n/*.zh-cn.lmo")):
                entries = read_lmo(lmo_path)
                if not entries:
                    continue
                changed = os.path.basename(lmo_path) == "base.zh-cn.lmo"
                if changed:
                    entries.update(po_hash_map)
                for k_id, val in list(entries.items()):
                    orig = val
                    if k_id == KID_MOUNT and val == "挂载点": val = "挂载位置"
                    elif k_id == KID_REBOOT and val == "重启": val = "重新启动"
                    if val in EXACT: val = EXACT[val]
                    for o, n in SUBSTR:
                        if o in val: val = val.replace(o, n)
                    if k_id in po_hash_map: val = po_hash_map[k_id]
                    if val != orig:
                        entries[k_id] = val
                        changed = True
                if changed:
                    write_lmo(os.path.join(files_dir, "usr/lib/lua/luci/i18n", os.path.basename(lmo_path)), entries)
            for rel in (
                "www/index.html", "usr/share/ucode/luci/version.uc",
                "usr/share/luci/menu.d/luci-app-ddns.json", "usr/share/luci/menu.d/luci-app-xfrpc.json",
                "usr/share/luci/menu.d/luci-app-upnp.json", "usr/share/luci/menu.d/luci-app-uhttpd.json",
                "usr/share/luci/menu.d/luci-app-wifischedule.json",
                "usr/share/ucode/luci/template/themes/argon/footer.ut",
                "usr/share/ucode/luci/template/themes/argon/footer_login.ut",
            ):
                src_p = os.path.join(ext, rel)
                if os.path.isfile(src_p):
                    dst_p = os.path.join(files_dir, rel)
                    os.makedirs(os.path.dirname(dst_p), exist_ok=True)
                    shutil.copy2(src_p, dst_p)
PYEOF

apply_static() {
	local R="$1"
	[ -d "$R" ] || return 0
	[ -f "$R/www/index.html" ] && sed -i.bak 's/LuCI - Lua Configuration Interface/Loading.../g' "$R/www/index.html" && rm -f "$R/www/index.html.bak"
	[ -f "$R/usr/share/ucode/luci/version.uc" ] && sed -i.bak -e "s/luciname\s*=\s*\"[^\"]*\"/luciname = \"Yonsm\"/" -e "s/luciversion\s*=\s*\"[^\"]*\"/luciversion = \"$(date +%Y-%m-%d)\"/" "$R/usr/share/ucode/luci/version.uc" && rm -f "$R/usr/share/ucode/luci/version.uc.bak"
	local M="$R/usr/share/luci/menu.d"
	[ -f "$M/luci-app-ddns.json" ] && sed -i.bak 's/59/20/g' "$M/luci-app-ddns.json" && rm -f "$M/luci-app-ddns.json.bak"
	[ -f "$M/luci-app-xfrpc.json" ] && sed -i.bak -e '/"order"/d' -e 's/"title": "Reverse proxy",/"title": "Reverse proxy",\n\t\t"order": 21,/' "$M/luci-app-xfrpc.json" && rm -f "$M/luci-app-xfrpc.json.bak"
	[ -f "$M/luci-app-upnp.json" ] && sed -i.bak -e '/"order"/d' -e 's/PCP",/PCP",\n\t\t"order": 22,/' "$M/luci-app-upnp.json" && rm -f "$M/luci-app-upnp.json.bak"
	[ -f "$M/luci-app-uhttpd.json" ] && sed -i.bak -e '/"order"/d' -e 's/"title": "uHTTPd",/"title": "uHTTPd",\n\t\t"order": 25,/' "$M/luci-app-uhttpd.json" && rm -f "$M/luci-app-uhttpd.json.bak"
	[ -f "$M/luci-app-wifischedule.json" ] && sed -i.bak 's/services/network/g' "$M/luci-app-wifischedule.json" && rm -f "$M/luci-app-wifischedule.json.bak"
	for F in "$R/usr/share/ucode/luci/template/themes/argon/footer.ut" "$R/usr/share/ucode/luci/template/themes/argon/footer_login.ut"; do
		[ -f "$F" ] && sed -i.bak -e 's#openwrt/luci#Yonsm/OponWrt#g' -e 's/{{ version.luciname }} ({{ version.luciversion }})/Yonsm/g' -e 's/-{{ version.distrevision }}//g' "$F" && rm -f "$F.bak"
	done
}

apply_static "$FILES_DIR"
[ -n "$IB_DIR" ] && [ -d "$IB_DIR" ] && apply_static "$IB_DIR"
