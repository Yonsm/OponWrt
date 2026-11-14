#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:?Usage: $0 <TARGET_DIR> [PO_FILE]}"
PO_FILE="${2:-$SCRIPT_DIR/custom-ui.po}"

[ -d "$TARGET_DIR" ] || { echo "TARGET_DIR not found: $TARGET_DIR" >&2; exit 1; }

# 1. 原地修补 TARGET_DIR 中已安装的官方 *.zh-cn.lmo 翻译包
python3 - "$PO_FILE" "$TARGET_DIR" <<'PYEOF'
import os, re, sys, glob, struct, json

po_file, target_dir = sys.argv[1], sys.argv[2]

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
EXACT = {
    "LED 配置": "灯光配置", "<abbr title=\"发光二极管\">LED</abbr> 配置": "灯光配置",
    "路由": "路由规则", "防火墙": "防火长城", "进程": "系统进程", "Aria2": "下载服务",
    "Docker": "容器", "frp 服务器": "公网穿透", "frp 客户端": "内网穿透",
    "UPnP IGD 和 PCP": "端口映射", "UPnP IGD 和 PCP/NAT-PMP": "端口映射",
    "uHTTPd": "网页服务", "Transmission": "比特传输", "WiFi 计划": "无线计划",
    "ShadowSocksR Plus+ 设置": "科学上网设置", "ShadowSocksR Plus+": "科学上网",
    "Argon 主题设置": "主题设置", "Refresh Token": "刷新令牌",
}
SUBSTR = [
    ("动态 DNS", "动态域名"), ("备份与升级", "备份更新"), ("备份与更新", "备份更新"),
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

for lmo_path in sorted(glob.glob(os.path.join(target_dir, "usr/lib/lua/luci/i18n/*.zh-cn.lmo"))):
    entries = read_lmo(lmo_path)
    if not entries:
        continue
    changed = False
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
        write_lmo(lmo_path, entries)
        print(f"[ui-replace] Patched LMO: {os.path.basename(lmo_path)}")

menu_dir = os.path.join(target_dir, "usr/share/luci/menu.d")
sms_menu = os.path.join(menu_dir, "luci-app-sms-manager.json")
if os.path.exists(sms_menu):
    with open(sms_menu, encoding="utf-8") as f:
        menu = json.load(f)
    menu.pop("admin/modem", None)
    menu = {key.replace("admin/modem/", "admin/network/"): node for key, node in menu.items()}
    sms = menu["admin/network/luci-app-sms-manager"]
    sms["order"] = 999
    sms["action"]["path"] = sms["action"]["path"].replace("admin/modem/", "admin/network/")
    with open(sms_menu, "w", encoding="utf-8") as f:
        json.dump(menu, f, ensure_ascii=False, indent="\t")
        f.write("\n")

menu_titles = {
    "WireGuard": "链路卫士", "Reboot to EDL": "重启救急", "File Manager": "文件管理",
    "SMS Manager": "短信管理", "CPU Performance": "核心性能", "USB Gadget": "外设模式",
    "Modem Watchdog": "基带监控", "Tailscale": "尾网互联", "Wake on LAN": "网络唤醒",
    "Station Mode": "站点模式", "Statation Mode": "站点模式",
    "Received Messages": "接收短信", "Send Messages": "发送短信", "USSD Codes": "USSD 指令",
    "AT Commands": "AT 指令", "Package update and support": "更新与支持",
    "Global Settings": "全局设置", "Interface Info": "接口信息", "Logs": "日志",
    "Overview": "概览", "Configuration": "配置", "Uplink": "上行网络",
}
for path in glob.glob(os.path.join(menu_dir, "*.json")):
    with open(path, encoding="utf-8") as f:
        menu = json.load(f)
    changed = False
    for node in menu.values():
        title = node.get("title")
        translation = menu_titles.get(title)
        if translation:
            node["title"] = translation
            changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(menu, f, ensure_ascii=False, indent="\t")
            f.write("\n")

gadget = os.path.join(target_dir, "usr/sbin/usb-gadget")
if os.path.exists(gadget):
    with open(gadget, encoding="utf-8") as f:
        text = f.read()
    cleanup = """    # Close the serial console before removing its USB function.
    for fd in /proc/[0-9]*/fd/0; do
        [ "$(readlink "$fd")" = /dev/ttyGS0 ] || continue
        local pid="${fd#/proc/}"
        kill "${pid%%/*}" 2>/dev/null || true
    done

"""
    if cleanup not in text:
        text = text.replace("    # Remove function directories\n", cleanup + "    # Remove function directories\n")
        with open(gadget, "w", encoding="utf-8") as f:
            f.write(text)

# UFI003 的无线灯为 blue:wlan，避免与基带监控共用 green:wan。
for name in ("usr/sbin/wifi-led-monitor", "etc/init.d/wifi-led-monitor"):
    path = os.path.join(target_dir, name)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if '/sys/class/leds/blue:wlan' in text:
            continue
        text = text.replace('LED="/sys/class/leds/green:wlan"\n',
                            'LED="/sys/class/leds/blue:wlan"\n'
                            '        [ -d "$LED" ] || LED="/sys/class/leds/green:wlan"\n')
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

edl = os.path.join(target_dir, "usr/lib/lua/luci/controller/reboot-modes.lua")
if os.path.exists(edl):
    with open(edl, encoding="utf-8") as f:
        text = f.read()
    with open(edl, "w", encoding="utf-8") as f:
        f.write(text.replace('"Reboot to EDL"', '"重启救急"'))
PYEOF

# 2. 原地修改 TARGET_DIR 中的菜单 JSON、引导页与主题页脚
M="$TARGET_DIR/usr/share/luci/menu.d"
if [ -f "$M/luci-mod-status.json" ]; then
	sed -i.bak \
		-e 's/"title": "Routing"/"title": "路由规则"/g' \
		-e 's/"title": "Firewall"/"title": "防火长城"/g' \
		-e 's/"title": "Processes"/"title": "系统进程"/g' "$M/luci-mod-status.json" && rm -f "$M/luci-mod-status.json.bak"
fi
if [ -f "$M/luci-mod-system.json" ]; then
	sed -i.bak \
		-e 's/"title": ".*LED.*Configuration"/"title": "灯光配置"/g' \
		-e 's/"title": "Backup \/ Flash Firmware"/"title": "备份更新"/g' \
		-e 's/"title": "Reboot"/"title": "重新启动"/g' "$M/luci-mod-system.json" && rm -f "$M/luci-mod-system.json.bak"
fi
if [ -f "$M/luci-app-commands.json" ]; then
	sed -i.bak 's/"title": "Custom Commands"/"title": "自定命令"/g' "$M/luci-app-commands.json" && rm -f "$M/luci-app-commands.json.bak"
fi
for F in "$M"/luci-*argon*.json; do
	if [ -f "$F" ]; then
		sed -i.bak 's/"title": "Argon Config"/"title": "主题设置"/g' "$F" && rm -f "$F.bak"
	fi
done
if [ -f "$M/luci-app-ddns.json" ]; then
	sed -i.bak -e 's/59/20/g' -e 's/"title": "Dynamic DNS"/"title": "动态域名"/g' "$M/luci-app-ddns.json" && rm -f "$M/luci-app-ddns.json.bak"
fi
if [ -f "$M/luci-app-upnp.json" ]; then
	sed -i.bak -e '/"order"/d' -e 's/PCP",/PCP",\
		"order": 22,/' -e 's/"title": "UPnP IGD[^"]*"/"title": "端口映射"/g' "$M/luci-app-upnp.json" && rm -f "$M/luci-app-upnp.json.bak"
fi
if [ -f "$M/luci-mod-network.json" ]; then
	sed -i.bak \
		-e 's/"title": "Routes"/"title": "路由规则"/g' \
		-e 's/"title": "Routing"/"title": "路由规则"/g' \
		-e 's/"title": "DHCP"/"title": "网址分配"/g' \
		-e 's/"title": "DNS"/"title": "网络域名"/g' "$M/luci-mod-network.json" && rm -f "$M/luci-mod-network.json.bak"
fi
[ -f "$M/luci-app-aria2.json" ] && sed -i.bak 's/"title": "Aria2"/"title": "下载服务"/g' "$M/luci-app-aria2.json" && rm -f "$M/luci-app-aria2.json.bak"
if [ -f "$M/luci-app-firewall.json" ]; then
	sed -i.bak 's/"title": "Firewall"/"title": "防火长城"/g' "$M/luci-app-firewall.json" && rm -f "$M/luci-app-firewall.json.bak"
fi
if [ -f "$M/luci-app-xfrpc.json" ]; then
	sed -i.bak -e '/"order"/d' -e 's/"title": "Reverse proxy",/"title": "Reverse proxy",\
		"order": 21,/' "$M/luci-app-xfrpc.json" && rm -f "$M/luci-app-xfrpc.json.bak"
fi
if [ -f "$M/luci-app-uhttpd.json" ]; then
	sed -i.bak -e '/"order"/d' -e 's/"title": "uHTTPd",/"title": "网页服务",\
		"order": 25,/' "$M/luci-app-uhttpd.json" && rm -f "$M/luci-app-uhttpd.json.bak"
fi
if [ -f "$M/luci-app-wifischedule.json" ]; then
	sed -i.bak 's/services/network/g' "$M/luci-app-wifischedule.json" && rm -f "$M/luci-app-wifischedule.json.bak"
fi

if [ -f "$TARGET_DIR/www/index.html" ]; then
	sed -i.bak 's/LuCI - Lua Configuration Interface/Loading.../g' "$TARGET_DIR/www/index.html" && rm -f "$TARGET_DIR/www/index.html.bak"
fi
for F in "$TARGET_DIR"/usr/share/ucode/luci/template/themes/*/footer*.ut; do
	if [ -f "$F" ]; then
		sed -i.bak -e 's#openwrt/luci#Yonsm/OponWrt#g' -e 's/{{ version.luciname }} ({{ version.luciversion }})/Yonsm/g' -e 's/-{{ version.distrevision }}//g' -e 's/ ({{ version.distrevision }})//g' -e "s/ + '-' + version.distrevision//g" \
			-e 's/{{ entityencode(version.luciname, true) }} ({{ entityencode(version.luciversion, true) }})/Yonsm/g' \
			-e 's/ ({{ entityencode(version.distrevision, true) }})//g' \
			-e "s/const luci_info = .*;/const luci_info = 'Powered by Yonsm';/" \
			-e "s/split(version.luciname, ' (')\[0\]/luci_info/" "$F" && rm -f "$F.bak"
	fi
done

rm -rf "$TARGET_DIR"/tmp/luci-indexcache* "$TARGET_DIR"/tmp/luci-modulecache* 2>/dev/null || true
exit 0
