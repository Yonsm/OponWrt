# OponWrt

基于官方最新正式版 **OpenWrt ImageBuilder** 的固件定制与自动化打包仓库。

* `files/`：所有固件通用的基础覆盖文件与首次启动 UCI 初始化（`etc/uci-defaults/99-custom-init`）
* `extras/`：按特性按需注入的覆盖文件（`wing`、`samba4`、`hass`）
* `patches/`：LuCI 中文词条（`custom-ui.po`）及菜单、模板静态替换脚本（`ui-replace.sh`）
* `packages.conf`：设备预设与软件包清单（含 `luci-theme-argon` v3.1.3+、`wing` 及 ImmortalWrt 源的 `chinadns-ng` 等）
* `build.sh` & `.github/workflows/build.yml`：自动追踪官方最新 Release 并构建固件
* `flash.sh`：局域网 SSH 刷机与升级脚本
* `wing.md`：[extras/wing.md](extras/wing.md)

## 新增路由器配置

1. **查询机型参数**：在 [OpenWrt 官方软件源](https://downloads.openwrt.org/releases/) 对应版本的 `targets/<board>/<subtarget>/profiles.json` 中查出：
   * `TARGET_BOARD` / `TARGET_SUBTARGET`：目标平台路径（如 `mediatek` / `filogic`）
   * `TARGET_PROFILE`：`profiles` 下的设备 ID（如 `glinet_gl-mt6000`）
   * `PKG_ARCH`：文件顶部的 `arch_packages`（如 `aarch64_cortex-a53`，用于匹配 ImmortalWrt 软件源）
2. **添加预设分支**：在 `packages.conf` 的 `resolve_target_config()` 中新增 `case` 分支（无 USB 接口可加 `USB=0`，有专属驱动可通过 `EXTRA_PKGS` 附加）：

```bash
	MT6000*)
		TARGET_BOARD="mediatek"; TARGET_SUBTARGET="filogic"
		TARGET_PROFILE="glinet_gl-mt6000"; PKG_ARCH="aarch64_cortex-a53"
		;;
```

3. **构建与刷机**：在 GitHub Actions 的 **Run workflow** 中直接输入新预设名（支持叠加 `+SMB4`、`+NOWING`、`+DOCKER` 等特性后缀）即可打包；如需纳入 `ALL` 批量构建，将其加入 `build.sh` 末尾的循环列表即可。`flash.sh` 会自动读取设备信息匹配固件，无需额外修改。

## 随身 WiFi (MSM8916) 部署

OpenWrt 官方暂未收录高通 MSM8916 随身 WiFi，可先刷入以下社区底包之一，再通过 [`extras/msm8916.sh`](extras/msm8916.sh) 一键注入 `wing`、`dnsmasq-full`、Argon 主题与中文词条定制：

* **活跃推荐源**：[akbar-npj/msm8916-openwrt](https://github.com/akbar-npj/msm8916-openwrt)（基于 OpenWrt **25.12.6**，支持 AP+STA 中继/WISP 与热插拔换卡），已适配 **`UZ801`**、**`UF02`**、**`UFI003`**、**`UFI001B`**、**`HMUF02-V5`**、**`MF800B`**、**`JZ02`** 等板型。
* **归档备用源**：[hkfuertes/msm8916-openwrt](https://github.com/hkfuertes/msm8916-openwrt/releases)（`v1.0.14`，OpenWrt 25.12.5，已归档只读），适配 **`UZ801 v3`** 与 **`Generic UF02`**。
* **兼容性说明**：仅支持高通 **MSM8916（骁龙 410）** 方案，非高通芯片（如 ASR1803、展锐、中兴微等）不支持。

* **使用方式**：先用 `edl` 备份原厂分区并刷入社区底包，连网后在本地执行：

```bash
./extras/msm8916.sh root@192.168.1.1
```

参考：[OpenWrt](https://github.com/openwrt/openwrt) · [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) · [Argon](https://github.com/jerrykuku/luci-theme-argon)
