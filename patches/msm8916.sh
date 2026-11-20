#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:?Usage: $0 <TARGET_DIR> [PO_FILE]}"
"$SCRIPT_DIR/ui-replace.sh" "$@"
# apk 打包的 modemmanager proto 丢了可执行位，netifd 因而报“不支持的协议类型”。
chmod +x "$TARGET_DIR/lib/netifd/proto/modemmanager.sh" 2>/dev/null || true
# 同一个可执行位问题还有第二处：modemmanager-proto-hotfix 在启动时用 cp -f 把
# /usr/share/msm89xx/modemmanager.sh.hotfix 覆盖到 /lib/netifd/proto/modemmanager.sh，
# 源文件是 644，覆盖后 proto 又变成不可执行。修源文件权限并在服务里 cp 后补 chmod。
MMSRC="$TARGET_DIR/usr/share/msm89xx/modemmanager.sh.hotfix"
[ -f "$MMSRC" ] && chmod +x "$MMSRC"
MMSVC="$TARGET_DIR/etc/init.d/modemmanager-proto-hotfix"
if [ -f "$MMSVC" ]; then
	sed -i 's|cp -f "$SRC" "$DST"|cp -f "$SRC" "$DST"; chmod +x "$DST"|' "$MMSVC"
fi

# 直接改上游默认值，不靠运行时 uci-defaults 叠加：
# LAN 192.168.8.1 -> 192.168.2.1、hostname -> Roamer、stawan -> wwan、AP SSID -> Roamer。
FB="$TARGET_DIR/etc/uci-defaults/99-msm89xx-firstboot"
if [ -f "$FB" ]; then
	sed -i -e 's/192\.168\.8\.1/192.168.2.1/g' \
	       -e 's/hostname="\$BOARD"/hostname="Roamer"/' "$FB"
fi
# 保留上游的 late-STA netifd 占位接口，统一命名为 wwan（auto=0，netifd 不会拉起；
# 上游注释把它当作 STA 的 network device，恢复它以免偏离上游设计）。
STA="$TARGET_DIR/etc/uci-defaults/95-wifi-sta-late"
[ -f "$STA" ] && sed -i 's/network\.stawan/network.wwan/g' "$STA"
WIFI="$TARGET_DIR/lib/wifi/mac80211.uc"
[ -f "$WIFI" ] && sed -i 's/"OpenWrt"/"Roamer"/' "$WIFI"
# WISP 上联 DNS 用上级路由器下发的地址，不用写死的 8.8.8.8。
UP="$TARGET_DIR/etc/config/uplink"
[ -f "$UP" ] && sed -i '/option sta_dns/d' "$UP"

python3 - "$TARGET_DIR" <<'PYEOF'
import glob, json, os, sys

target_dir = sys.argv[1]

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
    "Reboot to EDL": "重启救急",
    "SMS Manager": "短信管理", "CPU Performance": "核心性能", "USB Gadget": "外设模式",
    "Modem Watchdog": "基带监控",
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
