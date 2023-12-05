
include $(TOPDIR)/rules.mk

PKG_NAME:=wing
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/wing
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Wing to world with the least impact method
  URL:=https://github.com/Yonsm/OponWrt
  DEPENDS:=+iptables +ip-full +ipset +kmod-ipt-nat +kmod-nf-nathelper +@PACKAGE_dnsmasq_full_ipset +coreutils +coreutils-base64 +shadowsocks-libev-ss-redir +simple-obfs-client +shadowsocksr-libev-ssr-redir +trojan +ipt2socks +dns2tcp +tcping +resolveip
endef

# +kmod-crypto-arc4 +kmod-crypto-chacha20poly1305 kmod-nf-nathelper-extra kmod-ipt-raw kmod-tun +iptables-mod-tproxy iptables-mod-extra

define Package/wing/description
 Configuration file for wing
endef

Build/Compile:=

define Package/wing/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/wing $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_CONF) $(CURDIR)/gfwlist.txt $(1)/etc
endef

$(eval $(call BuildPackage,wing))
