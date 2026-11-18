#!/bin/sh
# 在 miwifi/ 目录执行：./setup.sh [HOST] [WING_URL|NO] [SMB_PASS]，输出需在路由器上执行的命令。

[ "$1" = "-h" ] && echo "Usage: $0 [HOST] [WING_URL|NO] [SMB_PASS]" && exit

[ -z "$1" ] && HOST=192.168.31.1 || HOST=$1

cd `dirname $0`

# 本机即路由器时不加 ssh/scp 前缀，改用 curl 下载
[ -f /etc/config/miwifi ] && LOCAL=1 || LOCAL=

if [ -z "$LOCAL" ]; then
	echo "# RedMi AX6000: https://www.right.com.cn/forum/thread-8253125-1-1.html"
	echo "# XiaoMi AX7000: https://www.gaicas.com/xiaomi-be7000.html"
	echo "# XiaoMi BE6500 Pro: https://www.gaicas.com/xiaomi-be6500-pro.html"
	echo
	[ -f ~/.ssh/authorized_keys ] && echo "scp -O ~/.ssh/authorized_keys root@$HOST:/data/root"
fi

# 仓库目录按原路径部署到 /data/<同路径>
ADD() {
	CMDS="$CMDS	mkdir -p /data/$1"
	for DIR in $(cd "$1" && find . -type d -not -name .DS_Store | sed 's#^\./##'); do
		[ "$DIR" = "." ] || CMDS="$CMDS	mkdir -p /data/$1/$DIR"
	done
	for FILE in $(cd "$1" && find . -type f -not -name .DS_Store | sed 's#^\./##'); do
		FILES="$FILES $1/$FILE"
	done
}
ADD root
ADD wing

# 文件推送后在设备上安装可选工具（feed 由 root/opkg.sh 配置）
POST="/data/root/opkg.sh"
POST="$POST	opkg update"
POST="$POST	opkg -d xpkg --force-depends install htop iperf3 jq screen socat sqlite3-cli"
POST="$POST	opkg -d xpkg --force-depends install frpc frps"
POST="$POST	opkg -d xpkg --force-depends install mosquitto-nossl && printf \"listener 1883\nallow_anonymous true\nallow_zero_length_clientid true\n\" > /data/other/xpkg/etc/mosquitto/mosquitto.conf"
POST="$POST	opkg -d xpkg --force-depends --nodeps install ddns-scripts_no-ip_com ddns-scripts_dnspod"
POST="$POST	opkg -d xpkg --force-depends --nodeps install openssh-sftp-server"
POST="$POST	rm -rf /data/other/xpkg/etc/config /data/other/xpkg/etc/ddns /data/other/xpkg/etc/init.d /data/other/xpkg/etc/screenrc /data/other/xpkg/etc/ssl /data/other/xpkg/etc/uci-defaults"
POST="$POST	rm -f /data/other/xpkg/usr/lib/libform*.so* /data/other/xpkg/usr/lib/libmenu*.so* /data/other/xpkg/usr/lib/libpanel*.so*"
POST="$POST	mkdir -p /data/other/libexec"
POST="$POST	ln -sf /data/other/xpkg/usr/libexec/sftp-server /data/other/libexec/sftp-server"
POST="$POST	/data/wing/wing update /data/wing/gfwlist.conf"

# ROOT + WING 开机执行
CMDS="$CMDS	uci set firewall.root=include"
CMDS="$CMDS	uci set firewall.root.type=script"
CMDS="$CMDS	uci set firewall.root.path=/data/root/root.sh $2 $3"
CMDS="$CMDS	uci set firewall.root.enabled=1"
CMDS="$CMDS	uci commit firewall"

# 首次无 SSH 密钥：生成 dropbear 授权
if [ -z "$LOCAL" ] && [ -f ~/.ssh/authorized_keys ]; then
	CMDS="$CMDS	ln -s /data/root/authorized_keys /etc/dropbear/"
fi

SHOW() {
	printf '%s' "$1" | tr '\t' '\n' | while IFS= read -r CMD; do
		[ -z "$CMD" ] && continue
		if [ -n "$LOCAL" ]; then
			printf '%s\n' "$CMD"
		else
			printf "ssh root@$HOST '%s'\n" "$CMD"
		fi
	done
}
SHOW "$CMDS"
for FILE in $FILES; do
	if [ -n "$LOCAL" ]; then
		echo "curl -fsL -o /data/$FILE https://yonsm.github.io/OponWrt/miwifi/$FILE"
	else
		echo  "scp -O $FILE root@$HOST:/data/$FILE"
	fi
done
SHOW "$POST"
