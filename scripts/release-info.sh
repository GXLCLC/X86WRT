#!/usr/bin/env bash
# ================================================================
# scripts/release-info.sh —— 生成 GitHub Release 页面的固件信息
#
# 功能：从编译产物目录（bin/targets/x86/64）提取固件信息，生成
#       Markdown 格式的 Release 正文输出到 stdout。内容包含：
#       固件版本、内核版本、LAN IP、后台登录账号密码、已安装插件
#       清单（每行一个插件，过滤 kmod/lib/i18n 等依赖信息）、
#       镜像文件列表与 SHA-256 校验值、刷机简要说明。
#
# 信息来源与优先级：
#   1. profiles.json   —— 固件版本 / 内核版本 / 源码提交（构建必生成）
#   2. *.manifest      —— 已安装软件包真实清单
#   3. config.buildinfo —— 兜底：.config 中启用的软件包
#
# 用法：release-info.sh [bin_dir]
#       bin_dir 默认为 bin/targets/x86/64
# ================================================================
set -euo pipefail

BIN_DIR="${1:-bin/targets/x86/64}"

if [ ! -d "$BIN_DIR" ]; then
  echo "错误: 编译产物目录不存在: $BIN_DIR" >&2
  exit 1
fi

# ---------- 从 profiles.json 提取版本信息（缺失时给空值，后续兜底） ----------
VERSION_NUMBER=""
VERSION_CODE=""
KERNEL_VERSION=""
SOURCE_DATE=""
if [ -f "$BIN_DIR/profiles.json" ] && command -v python3 >/dev/null 2>&1; then
  read -r VERSION_NUMBER VERSION_CODE KERNEL_VERSION SOURCE_DATE <<EOF
$(python3 - "$BIN_DIR/profiles.json" <<'PYEOF'
import json
import sys

try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("-", "-", "-", "-")
    raise SystemExit

vn = d.get("version_number") or "-"
vc = d.get("version_code") or "-"
kv = (d.get("linux_kernel") or {}).get("version") or "-"
sd = d.get("source_date_epoch") or "-"
print(vn, vc, kv, sd)
PYEOF
)
EOF
fi
[ -n "$VERSION_NUMBER" ] || VERSION_NUMBER="未知"
[ -n "$VERSION_CODE" ]   || VERSION_CODE="未知"
[ -n "$KERNEL_VERSION" ] || KERNEL_VERSION="未知"

# 编译时间（profiles.json 的 source_date_epoch, 展示为北京时间）
BUILD_DATE="未知"
if [ -n "$SOURCE_DATE" ] && [ "$SOURCE_DATE" != "-" ]; then
  BUILD_DATE=$(TZ=Asia/Shanghai date -d "@$SOURCE_DATE" "+%Y-%m-%d %H:%M" 2>/dev/null \
               || date -r "$SOURCE_DATE" "+%Y-%m-%d %H:%M" 2>/dev/null \
               || echo "未知")
fi

# ---------- 已安装软件包清单（manifest 优先, config.buildinfo 兜底） ----------
get_pkg_names() {
  local manifests
  manifests=$(ls "$BIN_DIR"/*.manifest 2>/dev/null || true)
  if [ -n "$manifests" ]; then
    # manifest 格式: "包名 - 版本", 取第一列
    # shellcheck disable=SC2086
    cat $manifests | awk 'NF {print $1}'
  elif [ -f "$BIN_DIR/config.buildinfo" ]; then
    grep -E '^CONFIG_PACKAGE_[a-zA-Z0-9._+-]+=y$' "$BIN_DIR/config.buildinfo" \
      | sed -e 's/^CONFIG_PACKAGE_//' -e 's/=y$//'
  elif [ -f "$BIN_DIR/profiles.json" ]; then
    python3 - "$BIN_DIR/profiles.json" <<'PYEOF'
import json
import sys

d = json.load(open(sys.argv[1], encoding="utf-8"))
pk = set(d.get("default_packages") or [])
for p in d.get("profiles", {}).values():
    pk.update(p.get("device_packages") or [])
for name in sorted(pk):
    print(name)
PYEOF
  fi
}

# 插件友好名称映射（未收录的插件显示原始包名）
friendly_name() {
  case "$1" in
    luci-app-openclash)    echo "OpenClash（代理客户端）" ;;
    luci-app-smartdns)     echo "SmartDNS（DNS 分流解析）" ;;
    luci-app-ddnsto)       echo "DDNSTO（远程控制）" ;;
    luci-app-adguardhome)  echo "AdGuard Home（去广告 DNS）" ;;
    luci-app-appfilter)    echo "OAF 应用过滤（应用过滤/上网管控）" ;;
    luci-app-turboacc)     echo "TurboAcc（流量分载加速 + BBR）" ;;
    luci-app-mwan3)        echo "Mwan3（多线多拨/负载均衡）" ;;
    luci-app-nlbwmon)      echo "带宽监控（nlbwmon）" ;;
    luci-app-easytier)     echo "EasyTier（内网穿透）" ;;
    luci-theme-argon)      echo "Argon 主题（系统默认主题）" ;;
    luci-app-argon-config) echo "Argon 主题设置（argon-config）" ;;
    luci-app-firewall)     echo "防火墙（firewall4）" ;;
    luci-app-opkg|luci-app-package-manager) echo "软件包管理器" ;;
    *) echo "$1" ;;
  esac
}

# ---------- 镜像文件描述 ----------
image_desc() {
  case "$1" in
    *squashfs-combined-efi*) echo "UEFI 引导（新式主板 / 虚拟机请选此文件）" ;;
    *squashfs-combined*)     echo "BIOS 引导（Legacy 引导的主板）" ;;
    *) echo "固件镜像" ;;
  esac
}

# ---------- 输出 Markdown ----------
cat <<EOF
# ImmortalWrt X86_64 固件

> 基于 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) master 分支全自动云编译，仅 X86_64 架构，squashfs combined 镜像。

## 固件信息

| 项目 | 内容 |
| --- | --- |
| 目标平台 | x86/64（仅 64 位） |
| 固件版本 | ImmortalWrt ${VERSION_NUMBER}（${VERSION_CODE}） |
| 内核版本 | ${KERNEL_VERSION} |
| 镜像格式 | squashfs combined（BIOS + UEFI 两个 IMG） |
| rootfs_data | 已扩容至 2048 MiB（首次启动自动格式化为 f2fs） |
| 编译时间 | ${BUILD_DATE} |

## 后台登录

| 项目 | 内容 |
| --- | --- |
| 管理地址 | http://192.168.1.1 |
| LAN IP | 192.168.1.1（固件默认，未改动） |
| 用户名 | root |
| 密码 | password |

## AdGuard Home 去广告

| 项目 | 内容 |
| --- | --- |
| 管理页面 | http://192.168.1.1:3000 |
| 用户名 / 密码 | admin / admin |
| 重定向模式 | dnsmasq 上游（LAN DNS :53 → AdGuardHome :5553 → 公网 DNS） |
| 过滤规则 | 内置 AdGuard DNS filter / EasyList / EasyList China / anti-AD 等中文优化规则，每 24 小时自动更新 |

> 广告过滤默认开箱即用；如需停止过滤，在「服务 → AdGuard Home → 基础设置」将重定向模式改为"不启用"即可。
> 注意：AdGuard Home 与 OpenClash 的 DNS 劫持不宜同时开启，以免互相干扰。

## 默认服务状态

- **Turbo ACC**：默认开启 BBR 拥塞控制与 FullCone NAT；软件/硬件流量分载默认关闭（分载走内核快速路径会绕过流量统计，与带宽监控互斥）。状态页按防火墙真实规则显示分载运行状态，可随时在「网络 → Turbo ACC」中开关；
- **带宽监控**：服务 → Bandwidth Monitor，开机自启，按主机/协议统计流量（首次需产生流量后才有数据）；
- **Mwan3 多线多拨**：默认未配置（无任何接口/策略/规则），需要多线负载时在「网络 → 多线多拨」中自行添加。

## 已安装插件

EOF

# 已安装插件清单：每行一个插件名称（仅展示 luci-app-* / luci-theme-*,
# 过滤 kmod 驱动、lib 依赖、i18n 翻译包等，方便快速查阅）
get_pkg_names | sort -u | while read -r pkg; do
  case "$pkg" in
    luci-app-*|luci-theme-*)
      echo "- $(friendly_name "$pkg")"
      ;;
  esac
done

echo ""
echo "## 镜像文件（含 SHA-256）"
echo ""
echo "| 文件 | 说明 | 大小 | SHA-256 |"
echo "| --- | --- | --- | --- |"

# 列出所有 combined IMG 镜像（.img.gz / .img）, 计算大小与校验值
for img in "$BIN_DIR"/*combined*.img.gz "$BIN_DIR"/*combined*.img; do
  [ -f "$img" ] || continue
  base=$(basename "$img")
  size=$(du -h "$img" | cut -f1)
  sha=$(sha256sum "$img" | cut -d' ' -f1)
  echo "| \`${base}\` | $(image_desc "$base") | ${size} | \`${sha:0:16}…\` |"
done

cat <<'EOF'

## 使用说明

1. 下载镜像文件（EFI 主板选 `combined-efi`，老主板选 `combined`）；
2. `gunzip` 解压得到 `.img` 文件；
3. 使用 balenaEtcher / Rufus（DD 模式）或 `dd` 命令写入磁盘：

```bash
gunzip immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz
sudo dd if=immortalwrt-x86-64-generic-squashfs-combined-efi.img of=/dev/sdX bs=4M conv=fsync status=progress
```

4. 启动后浏览器访问 http://192.168.1.1 进入管理后台（root / password）；
5. rootfs_data（/overlay）已预扩容 2G 可写空间，可直接安装软件包、存放缓存与配置。

> 完整的各文件 SHA-256 校验值见附件 `sha256sums`；本固件编译配置见附件 `config.buildinfo`。
EOF
