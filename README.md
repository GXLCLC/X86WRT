# X86WRT —— ImmortalWrt X86_64 云编译

基于 GitHub Actions 的 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) **master 分支**（跟随最新内核版本）全自动云编译仓库，**仅编译 X86_64 架构固件**。

编译、扩容、发布全程自动化，无需任何交互式 SSH 登录操作：编译成功后自动创建 GitHub Releases 发布固件，Release 页面自动填充 LAN IP、后台登录账号密码、内核版本、固件版本与已安装插件清单。

## 固件特性

- **目标平台**：x86/64（BIOS + UEFI 双镜像）
- **镜像格式**：仅 squashfs combined IMG（不生成 VHDX / VMDK / QCOW2 / VDI 等其他格式）
- **分区扩容**：编译后由后置脚本将 `rootfs_data`（`/overlay`）可写空间精确扩容至 **2048 MiB**（首次启动自动格式化为 f2fs），可直接安装软件包、存放缓存与保存配置
- **默认主题**：Argon（首次启动自动设置为系统默认主题）
- **默认登录**：`http://192.168.1.1`，用户名 `root`，密码 `password`

## 集成插件

| 插件 | 说明 | 来源 |
| --- | --- | --- |
| OpenClash | 代理客户端（唯一的代理类插件） | 源码自带 |
| SmartDNS | DNS 分流解析 | 源码自带 |
| DDNSTO | 远程控制（前端 + 后端） | 第三方：linkease/nas-packages-luci + nas-packages |
| AdGuard Home | 去广告 DNS | 源码自带 |
| OAF 应用过滤 | 应用过滤 / 上网管控 | 源码自带 |
| TurboAcc | BBR 加速默认开启；软件流量分载默认关闭（与带宽监控互斥，见下方说明） | 第三方：kenzok8/small-package |
| Mwan3 | 多线多拨 / 负载均衡（默认禁用，需要时自行开启） | 源码自带 |
| 带宽监控 | nlbwmon | 源码自带 |
| UPnP | UPnP IGD / NAT-PMP 端口自动映射 | 源码自带 |
| 定时重启 | 按计划自动重启路由器 | 源码自带 |
| EasyTier | 内网穿透（核心 + Web 控制台默认启用，`http://192.168.1.1:11211`） | 第三方：EasyTier/luci-app-easytier |
| autocore | 状态页 CPU 频率 / 温度显示 | 源码自带 |
| Argon 主题 + argon-config | 主题与主题设置 | 源码自带 |

> 拉取规则：**优先使用 ImmortalWrt 源码自带软件包**；仅当源码中不存在时，才从第三方仓库浅克隆所需插件目录（不完整拉取整个仓库），由 [scripts/packages.sh](scripts/packages.sh) 自动完成。

**Turbo ACC 与带宽监控的取舍**：软件流量分载（Flow Offloading）开启后，转发流量走内核快速路径，绕过 conntrack 计数，nlbwmon 带宽监控将统计不到数据，**二者互斥**。因此固件默认开启 BBR 拥塞控制、关闭软件分载（保证带宽监控可用）；如需极限转发性能，可在 LuCI「网络 → Turbo ACC」自行开启"软件流量分载"，届时带宽监控将无法统计分载流量。

**驱动**：内置 USB2/USB3 主机控制器、OHCI/UHCI、USB 存储（含 UAS）、USB 网卡（CDC-ETHER/NCM 等），以及英特尔（e1000/e1000e/igb/igc/ixgbe/i40e 等）与瑞昱（r8169/8139 等）系列有线网卡驱动。

## 使用方法

1. **Fork 本仓库**到你的 GitHub 账号；
2. 进入你 Fork 仓库的 **Actions** 页面，选择 **ImmortalWrt X86_64 云编译** 工作流，点击 **Run workflow** 手动触发（推送修改 `.config` / `files` / `scripts` 后也会自动触发）；
3. 等待编译完成（约 2~3 小时），完成后进入 **Releases** 页面下载固件：
   - 新式主板 / 虚拟机：`*-squashfs-combined-efi.img.gz`
   - Legacy BIOS 引导的老主板：`*-squashfs-combined.img.gz`
4. `gunzip` 解压后使用 balenaEtcher / Rufus（DD 模式）或 `dd` 命令写入磁盘；
5. 启动后访问 `http://192.168.1.1` 登录后台（`root` / `password`）。

## 自行修改编译配置

仓库根目录的 [.config](.config) 为**增量式**配置文件（编译时由 `make defconfig` 自动补全），按需增减插件：

- **新增插件**：添加一行 `CONFIG_PACKAGE_<插件包名>=y`（插件需存在于 ImmortalWrt 源码或 [scripts/packages.sh](scripts/packages.sh) 的第三方来源表中）；
- **移除插件**：将该行改为 `# CONFIG_PACKAGE_<插件包名> is not set`；
- `kmod-*` 等依赖会自动解析，无需手动列出。

## 仓库结构

```text
.
├── .config                         # 编译配置（可自行修改）
├── files/
│   └── etc/uci-defaults/           # 首次启动脚本：设置 Argon 默认主题、默认密码
├── scripts/
│   ├── packages.sh                 # 第三方插件拉取（源码自带优先，缺失才浅克隆）
│   ├── post-build.sh               # 编译后置处理：扩容 rootfs_data(/overlay) 至 2G
│   └── release-info.sh             # 生成 Release 页面的固件信息
└── .github/workflows/build.yml     # GitHub Actions 工作流（每步骤含中文注释）
```

## 工作流说明

- **环境**：Ubuntu 22.04 LTS（GitHub 官方 Runner）
- **依赖处理**：进入源码目录执行标准命令 `./scripts/feeds update -a && ./scripts/feeds install -a`
- **错误终止**：所有 shell 步骤启用 `set -euo pipefail`，出错立即终止工作流；编译失败自动以单线程 + 完整日志重试一次，便于定位
- **权限**：工作流顶部配置 `permissions: contents: write`，规避 Release 发布 403 权限错误
- **磁盘扩容**：构建前清理 Runner 预装环境（Android SDK / .NET / Docker 镜像等），防止磁盘不足
- **编译缓存**：`actions/cache` 缓存 `dl`、`feeds`、`ccache` 三个目录（不缓存 `build_dir`），减少重复编译耗时
- **清理原则**：绝不执行 `make dirclean`（会删除 toolchain 导致全量重编），需要清理时仅执行 `make clean`
- **发布**：编译成功后自动创建 Release，附 IMG 镜像、`config.buildinfo`（编译配置）与 `sha256sums`（校验表）

## 许可

仅供学习交流使用。固件基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)（GPL-2.0）编译，请遵守上游开源协议。
