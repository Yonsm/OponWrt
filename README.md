# OponWrt

基于官方最新正式版 **OpenWrt ImageBuilder** 的固件定制与自动化打包仓库。

* `files/`：所有固件通用的基础覆盖文件与首次启动 UCI 初始化（`etc/uci-defaults/99-custom-init`）
* `extras/`：按特性按需注入的覆盖文件（`wing`、`samba4`、`hass`）
* `patches/`：LuCI 中文词条（`custom-ui.po`）及菜单、模板静态替换脚本（`ui-replace.sh`）
* `packages.conf`：设备预设与软件包清单（含 `luci-theme-argon` v3.1.3+、`wing` 及 ImmortalWrt 源的 `chinadns-ng` 等）
* `build.sh` & `.github/workflows/build.yml`：自动追踪官方最新 Release 并构建固件
* `flash.sh`：局域网 SSH 刷机与升级脚本
* `wing.md`：[extras/wing.md](extras/wing.md)

参考：[OpenWrt](https://github.com/openwrt/openwrt) · [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) · [Argon](https://github.com/jerrykuku/luci-theme-argon)
