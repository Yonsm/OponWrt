# OponWrt

基于官方最新正式版 **OpenWrt ImageBuilder（镜像生成器）** 的轻量级固件定制与自动化打包仓库。

## 目录结构

- `files/`：直接合并注入固件根目录的覆盖文件与首次启动初始化脚本
  - `files/etc/uci-defaults/99-custom-init`：首次启动自动执行的 UCI 配置（默认密码、SSID `Router`、时区、NTP、HTTPS `:81`、WAN 防火墙放行规则、UPnP、Samba4/Ksmbd、腾讯软件源镜像、LuCI 快捷命令等）
  - `files/usr/bin/wing` & `files/etc/gfwlist.txt`：Wing 透明代理脚本及分流域名表
  - `files/etc/board.d/99-default_network`：多网口默认 WAN/LAN 分配规则
  - `files/sbin/backup` & `files/sbin/restore`：配置备份与恢复工具
- `patches/`：离线 UI 文案与模板定制规则
  - `patches/custom-ui.po`：抽取自原构建流的全部 LuCI 中文界面词条覆盖表
  - `patches/ui-replace.sh`：编译 `zzz-custom.zh-cn.lmo`（及修补各插件 `.zh-cn.lmo`）并静态替换菜单排序 JSON 与 Argon 主题页脚模板
- `packages.conf`：设备 Profile 矩阵与精简软件包配置清单（内置 `luci-theme-argon` v3.1.3+、`wing` 及 ImmortalWrt 源的 `chinadns-ng` 等依赖）
- `.github/workflows/build.yml`：GitHub Actions 极速云端打包流水线（自动解析 `downloads.openwrt.org` 最新正式 Release 版本，2 分钟内完成构建）
- `flash.sh`：局域网 SSH 一键刷机/升级脚本

## 参考上游

- [OpenWrt Official](https://github.com/openwrt/openwrt)
- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [LuCI Theme Argon](https://github.com/jerrykuku/luci-theme-argon)
