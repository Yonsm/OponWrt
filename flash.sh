#!/bin/bash
# ==============================================================================
# OpenWrt 固件远程刷写与升级脚本 (flash.sh)
# 由原 9-flash 重构（已移除 N1 盒子定制，兼容 ImageBuilder 带版本号固件产物）
# ==============================================================================

if [ -z "$1" ] || [ "${1:0:1}" = "-" ]; then
	Router=Router
	ARGS="$1"
else
	Router="$1"
	ARGS="$2"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for DIR in "$SCRIPT_DIR/bin/targets" "$SCRIPT_DIR/output" "$SCRIPT_DIR/openwrt/bin/targets"; do
	if [ -d "$DIR" ]; then
		BIN_ROOT="$DIR"
		break
	fi
done
BIN_ROOT="${BIN_ROOT:-$SCRIPT_DIR/bin/targets}"

ARCH=$(ssh "$Router" "cat /etc/os-release | grep OPENWRT_BOARD | cut -d '\"' -f2")
[ -z "$ARCH" ] && echo "Could not get /etc/os-release on $Router" && exit 1

find_firmware() {
	local PATTERN="$1"
	ls "$BIN_ROOT/$ARCH"/$PATTERN "$BIN_ROOT"/$PATTERN 2>/dev/null | head -n 1
}

if [ "$ARCH" = "x86/64" ]; then
	# 1. EFI 500M VFAT /boot
	# 2. MSR 100M NONE
	# 3. WIN  80G NTFS /mnt/WIN
	# 4. DAT ...G NTFS /mnt/DAT
	# 5. OPT   8G EXT4 /opt
	# 6. WRT   2G EXT4 /mnt/WRT
	# 7. WRT2  2G EXT2 /mnt/WRT2
	DEFAULT=$(ssh "$Router" "grep default= /boot/grub/grub.cfg | cut -d '\"' -f2")
	[ -z "$DEFAULT" ] && echo "Could not read /boot/grub/grub.cfg" && exit 1
	[ "$DEFAULT" = "1" ] && VMLINUZ=vmlinuz || VMLINUZ=vmlinu2
	[ "$DEFAULT" = "1" ] && ROOTFS=/mnt/WRT || ROOTFS=/mnt/WRT2

	KERNEL_BIN=$(find_firmware "openwrt-*x86-64-generic-kernel.bin")
	ROOTFS_TAR=$(find_firmware "openwrt-*x86-64-generic-rootfs.tar.gz")
	if [ -z "$KERNEL_BIN" ] || [ -z "$ROOTFS_TAR" ]; then
		echo "Could not find x86/64 kernel.bin or rootfs.tar.gz in $BIN_ROOT"
		exit 1
	fi

	scp "$KERNEL_BIN" "$Router:/boot/$VMLINUZ" &&
	scp "$ROOTFS_TAR" "$Router:/tmp/rootfs.tar.gz" || exit 1

	echo "Preparing to write \"$ROOTFS\"..."
	read -p "Do you want to restore config? [Y/n]" ANSWER
	ssh "$Router" "rm -rf $ROOTFS/*; cd $ROOTFS && tar -xzf /tmp/rootfs.tar.gz; sync" || exit 1
	[ "$ANSWER" != "n" ] && echo "Restoring config from /etc to $ROOTFS/etc..." && (ssh "$Router" "for FILE in config dropbear samba ksmbd passwd shadow uhttpd.crt uhttpd.key rc.local; do [ -e /etc/\$FILE ] && cp -a /etc/\$FILE $ROOTFS/etc; done" || exit 1)
	read -p "Done. Press any key to reboot $ROOTFS"
	ssh "$Router" "cd /tmp && cp $ROOTFS/sbin/reboot2 /tmp && umount $ROOTFS && /tmp/reboot2"
else
	BOARD=$(ssh "$Router" "cat /etc/board.json | grep id | cut -d '\"' -f4")
	[ -z "$BOARD" ] && echo "Could not get /etc/board.json on $Router" && exit 1
	BIN=$(find_firmware "openwrt-*${ARCH/\//-}-${BOARD/,/_}-*-sysupgrade.bin")
	if [ -z "$BIN" ]; then
		echo "Could not find sysupgrade.bin for $ARCH ($BOARD) in $BIN_ROOT"
		exit 1
	fi
	scp -O "$BIN" "$Router:/tmp/sysupgrade.bin" &&
	ssh "$Router" "sysupgrade $ARGS /tmp/sysupgrade.bin"
fi
