#!/usr/bin/env bash
# ================================================================
# scripts/packages.sh —— 第三方插件拉取脚本
#
# 拉取规则：
#   1. 优先使用 ImmortalWrt 源码自带软件包（feeds / package 目录）；
#   2. 仅当源码仓库中不存在对应软件包时，才从下表所列第三方仓库
#      浅克隆所需插件目录（git clone --depth 1 --filter=blob:none
#      --sparse，只检出插件目录本身，不完整拉取整个仓库）；
#   3. DDNSTO 同时拉取 luci 前端（nas-packages-luci, main 分支）
#      与后端程序包（nas-packages, master 分支），缺一不可；
#   4. 第三方包统一放置于 package/thirdparty/ 下参与编译。
#
# 用法（工作流内自动执行，也可本地手动执行）：
#   cd <ImmortalWrt 源码目录>
#   ./scripts/feeds update -a && bash /path/to/scripts/packages.sh
# ================================================================
set -euo pipefail

DEST_DIR="package/thirdparty"

# ---------------------------------------------------------------
# 第三方来源表，每行格式：
#   包名|仓库地址|分支|仓库内插件目录|备用包名（可选，用于目录名与包名不一致时）
# 仅当该包在 ImmortalWrt 源码 feeds/package 中不存在时才会克隆。
# ---------------------------------------------------------------
SOURCES=(
  # --- 常驻第三方插件（ImmortalWrt 源码不含，需要拉取） ---
  "luci-app-turboacc|https://github.com/kenzok8/small-package|master|other/lean/luci-app-turboacc|"
  "easytier|https://github.com/EasyTier/luci-app-easytier|master|easytier|"
  "luci-app-easytier|https://github.com/EasyTier/luci-app-easytier|master|luci-app-easytier|"
  "ddnsto|https://github.com/linkease/nas-packages|master|network/services/ddnsto|"
  "luci-app-ddnsto|https://github.com/linkease/nas-packages-luci|main|luci/luci-app-ddnsto|"
  # --- 备用来源（当前 ImmortalWrt 源码已自带，正常情况下不会触发克隆） ---
  "smartdns|https://github.com/kenzok8/openwrt-packages|master|smartdns|"
  "luci-app-smartdns|https://github.com/kenzok8/openwrt-packages|master|luci-app-smartdns|"
  "adguardhome|https://github.com/kenzok8/openwrt-packages|master|adguardhome|"
  "luci-app-adguardhome|https://github.com/kenzok8/openwrt-packages|master|luci-app-adguardhome|"
  "luci-theme-argon|https://github.com/kenzok8/openwrt-packages|master|luci-theme-argon|"
  "luci-app-argon-config|https://github.com/kenzok8/openwrt-packages|master|luci-app-argon-config|"
  "luci-app-openclash|https://github.com/vernesong/OpenClash|master|.|"
)

# 判断包是否已存在于 ImmortalWrt 源码（package/ 或 feeds/ 目录）
pkg_exists() {
  local found
  found=$(find package feeds -maxdepth 4 -type d -name "$1" -print -quit 2>/dev/null || true)
  [ -n "$found" ]
}

mkdir -p "$DEST_DIR"

# ---------------------------------------------------------------
# 第一步：筛选出源码中不存在的包，按“仓库+分支”分组，同一仓库只克隆一次
# ---------------------------------------------------------------
declare -A REPO_PKGS   # 键: repo|branch -> 值: “包名:子目录 空格分隔”
for line in "${SOURCES[@]}"; do
  IFS='|' read -r pkg repo branch subdir alt <<< "$line"
  name=${alt:-$pkg}
  if pkg_exists "$pkg"; then
    echo "[跳过] $pkg —— ImmortalWrt 源码自带，使用 feeds 版本"
  else
    echo "[拉取] $pkg —— 源码缺失，从 $repo($branch) 克隆目录 $subdir"
    key="$repo|$branch"
    REPO_PKGS["$key"]+="$name:$subdir "
  fi
done

# ---------------------------------------------------------------
# 第二步：逐仓库浅克隆（稀疏检出所需目录），拷贝至 package/thirdparty/
# ---------------------------------------------------------------
for key in "${!REPO_PKGS[@]}"; do
  IFS='|' read -r repo branch <<< "$key"
  tmp=$(mktemp -d)
  echo "==> 克隆仓库 $repo (分支 $branch, 仅稀疏检出插件目录)"
  git clone -q --depth 1 --filter=blob:none --sparse -b "$branch" "$repo" "$tmp/src"

  read -r -a entries <<< "${REPO_PKGS[$key]}"
  # 收集该仓库需要检出的全部子目录
  dirs=()
  for e in "${entries[@]}"; do
    subdir=${e#*:}
    [ "$subdir" = "." ] || dirs+=("$subdir")
  done
  if [ ${#dirs[@]} -gt 0 ]; then
    git -C "$tmp/src" sparse-checkout set --no-cone "${dirs[@]}"
  fi

  # 逐个拷贝插件目录到 package/thirdparty/<包名>
  for e in "${entries[@]}"; do
    name=${e%%:*}
    subdir=${e#*:}
    if [ "$subdir" = "." ]; then
      # 仓库根目录即插件包（如 OpenClash）
      mkdir -p "$DEST_DIR/$name"
      (shopt -s dotglob; cp -a "$tmp/src/." "$DEST_DIR/$name/" 2>/dev/null || cp -a "$tmp/src/." "$DEST_DIR/$name/")
      rm -rf "$DEST_DIR/$name/.git"
    else
      cp -a "$tmp/src/$subdir" "$DEST_DIR/$name"
    fi
    [ -f "$DEST_DIR/$name/Makefile" ] || { echo "错误: $name 目录缺少 Makefile"; exit 1; }
    echo "    已就位: $DEST_DIR/$name"
  done
  rm -rf "$tmp"
done

echo "==> 第三方插件处理完成，位于 $DEST_DIR/："
ls -1 "$DEST_DIR" 2>/dev/null || echo "（无第三方插件，全部使用源码自带）"
