#!/bin/bash
# 独立构建 DSH Launcher（macOS 菜单栏插件，LSUIElement 无 Dock 图标）
# 源码路径自适应：独立工程 Sources/main.swift 或 monorepo Sources/DSHLauncher/main.swift
# 产物：~/Library/Application Support/DSH Launcher.app，自带 manifest.json（主应用设置读取）
#
# 安装到私有目录而非 /Applications 的原因：
#   - Launchpad 只索引 /Applications(/Applications/Utilities)；挪到私有目录启动台不显示图标
#   - 主应用 MenuBarPluginManager 扫描同一私有目录，检测并控制该插件
#   - 代价：SMAppService 登录自启仅对 /Applications 有效，此处不依赖（由主应用设置开启）
set -euo pipefail
# 脚本位于工程根目录（独立工程）或 scripts/ 子目录（monorepo）；向上定位工程根
cd "$(dirname "$0")"
while [ ! -d Sources ] && [ "$(pwd)" != "/" ]; do cd ..; done
ROOT="$(pwd)"
APP_NAME="DSH Launcher"
mkdir -p "$HOME/Library/Application Support"
APP="$HOME/Library/Application Support/$APP_NAME.app"
BIN="$ROOT/.build/DSHLauncher"

# --- 定位源码（自适应）---
# v1 起源码多文件化（StatusProbe/StatusIcons/CheckupWindow…），整目录参与编译
if [ -d "$ROOT/Sources" ] && [ -f "$ROOT/Resources/Info.plist" ]; then
  SRC_DIR="$ROOT/Sources"
  PLIST="$ROOT/Resources/Info.plist"
  MANIFEST="$ROOT/Resources/manifest.json"
elif [ -d "$ROOT/Sources/DSHLauncher" ]; then
  SRC_DIR="$ROOT/Sources/DSHLauncher"
  PLIST="$ROOT/Resources/Info-Launcher.plist"
  MANIFEST="$ROOT/Resources/LauncherManifest.json"
else
  echo "找不到 Sources 目录"; exit 1
fi
SRC_FILES=()
while IFS= read -r f; do SRC_FILES+=("$f"); done < <(find "$SRC_DIR" -name '*.swift' | sort)
[ ${#SRC_FILES[@]} -gt 0 ] || { echo "Sources 下没有 .swift"; exit 1; }

# --- 工具链修复（与 build.sh 相同的 vfsoverlay）---
CLT_ROOT="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
FIX="$ROOT/.build/toolchain-fix"
mkdir -p "$FIX"; : > "$FIX/empty.modulemap"
cat > "$FIX/overlay.yaml" <<EOF
{"version":0,"case-sensitive":"true","roots":[{"type":"file","name":"$CLT_ROOT/usr/include/swift/module.modulemap","external-contents":"$FIX/empty.modulemap"}]}
EOF
export TMPDIR="$FIX/tmp" CLANG_MODULE_CACHE_PATH="$FIX/clang-modcache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

echo "==> [1/4] swiftc (release)"
rm -f "$BIN"
# DSH_LAUNCHER_NO_INSTALL=1 时只编译不部署（开发期默认用法；
# 运行中的 launcher 由编译产物路径隔离，绝无覆盖风险）
swiftc -O \
  -target arm64-apple-macosx13.0 \
  -vfsoverlay "$FIX/overlay.yaml" \
  "${SRC_FILES[@]}" \
  -o "$BIN"

if [ "${DSH_LAUNCHER_NO_INSTALL:-0}" = "1" ]; then
  echo "==> 仅构建完成（未安装）：$BIN"
  exit 0
fi

echo "==> [2/4] assemble bundle"
# 回滚保障：安装前快照当前运行副本，验收出问题整目录换回即可
if [ -d "$APP" ]; then
  BAK="$APP.bak-$(date +%Y%m%d-%H%M%S)"
  cp -R "$APP" "$BAK"
  echo "    已备份旧版 → $BAK"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DSHLauncher"
cp "$PLIST" "$APP/Contents/Info.plist"
# 菜单栏模板图标（SVG 矢量优先，PNG 后备；都不存在则 fallback 到 SF Symbol）
if [ -f "$ROOT/Resources/whale.svg" ]; then
  cp "$ROOT/Resources/whale.svg" "$APP/Contents/Resources/whale.svg"
fi
if [ -f "$ROOT/.build/whale-icon.png" ]; then
  cp "$ROOT/.build/whale-icon.png" "$APP/Contents/Resources/whale-icon.png"
elif [ -f "$ROOT/Resources/whale-icon.png" ]; then
  cp "$ROOT/Resources/whale-icon.png" "$APP/Contents/Resources/whale-icon.png"
fi
# 插件清单（主应用设置页读取）
cp "$MANIFEST" "$APP/Contents/Resources/manifest.json"

echo "==> [3/4] codesign (ad-hoc)"
codesign --force --deep -s - "$APP"

echo "==> [4/4] done"
echo "    $APP"
echo "    启动台不显示图标；在 DSH Desktop 设置页可直接控制。"