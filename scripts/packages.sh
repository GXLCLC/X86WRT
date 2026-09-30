#!/usr/bin/env bash
# ================================================================
# scripts/packages.sh —— 第三方插件拉取脚本
#
# 拉取规则：
#   1. 优先使用 ImmortalWrt 源码自带软件包（feeds / package 目录）；
#   2. 仅当源码仓库中不存在对应软件包时，才从下表所列第三方仓库
#      浅克隆所需插件目录（git clone --depth 1 --filter=blob:none
#      --sparse，只检出插件目录本身，不完整拉取整个仓库）；
#   3. FORCE_SOURCES 强制覆盖表中的包例外：无论源码是否自带，
#      一律移除 feeds 软链接后使用第三方版本（如 luci-app-adguardhome）；
#   4. DDNSTO 同时拉取 luci 前端（nas-packages-luci, main 分支）
#      与后端程序包（nas-packages, master 分支），缺一不可；
#   5. 第三方包统一放置于 package/thirdparty/ 下参与编译。
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
  #   注意：分支名以各仓库实际默认分支为准（2026-09 核实）：
  #   kenzok8/small-package = main, EasyTier/luci-app-easytier = main,
  #   linkease/nas-packages = master, linkease/nas-packages-luci = main;
  #   若上游日后改动分支名, 脚本会自动回退到该仓库的默认分支
  "luci-app-turboacc|https://github.com/kenzok8/small-package|main|other/lean/luci-app-turboacc|"
  "easytier|https://github.com/EasyTier/luci-app-easytier|main|easytier|"
  "luci-app-easytier|https://github.com/EasyTier/luci-app-easytier|main|luci-app-easytier|"
  "ddnsto|https://github.com/linkease/nas-packages|master|network/services/ddnsto|"
  "luci-app-ddnsto|https://github.com/linkease/nas-packages-luci|main|luci/luci-app-ddnsto|"
  # --- 备用来源（当前 ImmortalWrt 源码已自带，正常情况下不会触发克隆） ---
  "smartdns|https://github.com/kenzok8/openwrt-packages|master|smartdns|"
  "luci-app-smartdns|https://github.com/kenzok8/openwrt-packages|master|luci-app-smartdns|"
  "adguardhome|https://github.com/kenzok8/openwrt-packages|master|adguardhome|"
  "luci-theme-argon|https://github.com/kenzok8/openwrt-packages|master|luci-theme-argon|"
  "luci-app-argon-config|https://github.com/kenzok8/openwrt-packages|master|luci-app-argon-config|"
  "luci-app-openclash|https://github.com/vernesong/OpenClash|master|.|"
)

# ---------------------------------------------------------------
# 强制覆盖表：格式与来源表相同。
# 表内包无论源码/feeds 中是否存在，一律以下方第三方仓库版本为准：
#   luci-app-adguardhome —— ImmortalWrt 自带版为精简 JS 版，缺少
#     “网页管理端口”“重定向模式”等配置界面，且服务默认停用、无
#     预置过滤规则，广告过滤无法开箱即用；kenzok8 增强版（Lua CBI）
#     提供完整中文配置界面 + 内置中文优化规则模板，故强制覆盖。
# ---------------------------------------------------------------
FORCE_SOURCES=(
  "luci-app-adguardhome|https://github.com/kenzok8/openwrt-packages|master|luci-app-adguardhome|"
)

# 判断包是否已存在于 ImmortalWrt 源码（package/ 或 feeds/ 目录）
pkg_exists() {
  local found
  found=$(find package feeds -maxdepth 4 -type d -name "$1" -print -quit 2>/dev/null || true)
  [ -n "$found" ]
}

# 移除 feeds 中同名包已安装到 package/feeds/ 的软链接（含 feeds 自动
# 生成的语言包 luci-i18n-<pkg>-*），避免与 package/thirdparty/ 内的
# 第三方版本产生同名包冲突。
# 注意：只删 package/feeds/ 下的软链接，不动 feeds/ 源仓库本身，
# 保证 feeds git 缓存的完整性不受影响。
remove_feed_links() {
  local pkg=$1 link
  find package/feeds -maxdepth 2 \( -name "$pkg" -o -name "luci-i18n-$pkg-*" \) \
    -print 2>/dev/null | while read -r link; do
      rm -rf "$link"
      echo "    已移除 feeds 软链接: $link"
    done
}

mkdir -p "$DEST_DIR"

# ---------------------------------------------------------------
# 第一步：筛选出源码中不存在的包，按“仓库+分支”分组，同一仓库只克隆一次
# ---------------------------------------------------------------
declare -A REPO_PKGS   # 键: repo|branch -> 值: “包名:子目录 空格分隔”

# 1a. 强制覆盖包：先移除 feeds 版软链接，再登记克隆（视同源码缺失）
for line in "${FORCE_SOURCES[@]}"; do
  IFS='|' read -r pkg repo branch subdir alt <<< "$line"
  name=${alt:-$pkg}
  echo "[覆盖] $pkg —— 强制使用第三方版本（源码自带版功能缺失）"
  remove_feed_links "$pkg"
  key="$repo|$branch"
  REPO_PKGS["$key"]+="$name:$subdir "
done

# 1b. 常规包：源码已存在则跳过，缺失才登记克隆
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
#   指定分支不存在时自动回退到仓库默认分支，避免上游改动分支名导致构建失败
# ---------------------------------------------------------------
clone_repo() {
  local repo=$1 branch=$2 dest=$3 def
  # 优先按来源表指定的分支克隆
  if git clone -q --depth 1 --filter=blob:none --sparse -b "$branch" "$repo" "$dest" 2>/dev/null; then
    return 0
  fi
  # 指定分支不存在 → 解析该仓库的默认分支（HEAD 符号引用）并回退重试
  def=$(git ls-remote --symref "$repo" HEAD 2>/dev/null \
        | awk '/^ref:/ { sub(".*refs/heads/", ""); print $1 }' | head -n 1)
  if [ -n "$def" ] && [ "$def" != "$branch" ]; then
    echo "    注意: 分支 $branch 不存在, 自动回退到默认分支 $def"
    git clone -q --depth 1 --filter=blob:none --sparse -b "$def" "$repo" "$dest"
  else
    echo "错误: 无法克隆仓库 $repo (尝试分支: $branch / $def)" >&2
    return 1
  fi
}

for key in "${!REPO_PKGS[@]}"; do
  IFS='|' read -r repo branch <<< "$key"
  tmp=$(mktemp -d)
  echo "==> 克隆仓库 $repo (分支 $branch, 仅稀疏检出插件目录)"
  clone_repo "$repo" "$branch" "$tmp/src"

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
