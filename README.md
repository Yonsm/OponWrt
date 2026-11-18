# OponWrt

基于官方最新正式版 **OpenWrt ImageBuilder** 的固件定制与自动化打包仓库。

* `files/`：所有固件通用的基础覆盖文件与首次启动 UCI 初始化（`etc/uci-defaults/99-custom-init`）
* `extras/`：按特性按需注入的覆盖文件（`samba4`、`hass`、`x86`）
* `wing/`：Wing 脚本及规则；`miwifi/`：小米路由器 DIY（`root/` 覆盖、`setup.sh`），其中 `miwifi/wing/` 提供 Wing 预编译依赖
* `patches/`：LuCI 中文词条（`custom-ui.po`）及菜单、模板静态替换脚本（`ui-replace.sh`）
* `packages.conf`：设备预设与软件包清单（含 `luci-theme-argon` v3.1.3+、`wing` 及 ImmortalWrt 源的 `chinadns-ng` 等）
* `build.sh` & `.github/workflows/build.yml`：自动追踪官方最新 Release 并构建固件
* `flash.sh`：局域网 SSH 刷机与升级脚本
* `wing.md`：[wing.md](wing.md)

## 构建固件

在 Linux x86_64 上运行 `./build.sh 设备 [OpenWrt版本]`，或在 GitHub Actions 的 **Run workflow** 中输入设备。版本留空时使用最新正式版。脚本从 OpenWrt 官方索引匹配 profile，并自动获取目标平台和软件包架构；无需在代码中登记新设备。

```bash
./build.sh glinet_gl-mt6000
./build.sh 'mobipromo_cm520-79f-opboot+DOCKER' 25.12.6
./build.sh 'generic@x86.64+DOCKER+WIFI'
```

设备可填写完整 profile 或能唯一匹配的名称片段。匹配多个设备时，脚本列出候选项；同名 profile 可用 `@平台.子平台` 指定目标。CM520 的 `-opboot` 为专用镜像变体。

支持 `+USB`、`+SMB4`、`+NOWING`、`+DOCKER`、`+HASS` 和 `+WIFI` 后缀；`+WIFI` 目前仅针对 x86/64。未单独配置的设备使用官方默认包和项目基础包，特定设备的额外配置在 `packages.conf` 中维护。构建结果保存在 `output/` 下独立目录中。默认 `ALL` 的设备列表分别位于 `build.sh` 和工作流中。

## 随身 WiFi (MSM8916) 部署

OpenWrt 官方暂未收录高通 MSM8916 随身 WiFi。本项目用社区底包的独占 ImageBuilder 构建 **`UFI003`** 固件，并注入 `wing`、`dnsmasq-full`、Argon 主题与中文词条定制：

* **活跃推荐源**：[akbar-npj/msm8916-openwrt](https://github.com/akbar-npj/msm8916-openwrt)（基于 OpenWrt **25.12.6**，支持 AP+STA 中继/WISP 与热插拔换卡），已适配 **`UZ801`**、**`UF02`**、**`UFI003`**、**`UFI001B`**、**`HMUF02-V5`**、**`MF800B`**、**`JZ02`** 等板型。
* **归档备用源**：[hkfuertes/msm8916-openwrt](https://github.com/hkfuertes/msm8916-openwrt/releases)（`v1.0.14`，OpenWrt 25.12.5，已归档只读），适配 **`UZ801 v3`** 与 **`Generic UF02`**。
* **兼容性说明**：仅支持高通 **MSM8916（骁龙 410）** 方案，非高通芯片（如 ASR1803、展锐、中兴微等）不支持。

* **使用方式**：在 Linux x86_64 上取得独占 ImageBuilder 压缩包后执行（`UFI003+NOWING` 不含 Wing），产物写入 `output/`：

```bash
./msm8916.sh .cache/msm8916-imagebuilder.tar.zst UFI003
```

GitHub Actions 的 **构建固件：MSM8916** 会自动获取上游最新 Release 的 ImageBuilder 并构建。刷写前先按上游说明用 `edl` 备份原厂分区。

参考：[OpenWrt](https://github.com/openwrt/openwrt) · [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) · [Argon](https://github.com/jerrykuku/luci-theme-argon)
