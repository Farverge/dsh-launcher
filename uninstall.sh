#!/bin/bash
# DSH Launcher 一键卸载脚本
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/iiiiiei/dsh-launcher/main/uninstall.sh | bash
#
# 行为：退出并移除菜单栏应用 + 移除随装的 dsh-mini-dialog 插件及其装配条目。
# 插件移除在 DSH 后端重启后生效——脚本结束时会给出明确提示。
# 不触碰主应用、后端进程与任何会话数据。
#
# 可选参数：
#   --keep-plugin   保留 mini-dialog 插件（仅移除 Launcher 应用本体）

set -euo pipefail

APP_NAME="DSH Launcher.app"
BUNDLE_ID="com.deepseek-ai.dsh-launcher"
PLUGIN_NAME="dsh-mini-dialog"
PROFILE_WEB="${HOME}/.dsh/profiles/web"
PLUGIN_DEST="${HOME}/.dsh/profiles/web/node_modules/${PLUGIN_NAME}"
INSTALL_DEST="${HOME}/Library/Application Support"

KEEP_PLUGIN=0
[ "${1:-}" = "--keep-plugin" ] && KEEP_PLUGIN=1

PASS="✓"; WARN="!"; FAIL="✗"

echo "── DSH Launcher 卸载 ────────────────────────"

# 1) 温和退出运行中的实例
if pgrep -x DSHLauncher >/dev/null 2>&1; then
  osascript -e 'quit app id "'"${BUNDLE_ID}"'"' >/dev/null 2>&1 || true
  sleep 2
  pgrep -x DSHLauncher >/dev/null 2>&1 && killall DSHLauncher 2>/dev/null || true
  sleep 1
  echo " ${PASS} 已退出 Launcher 进程"
else
  echo " ${PASS} Launcher 未在运行"
fi

# 2) 移除应用本体
if [ -d "${INSTALL_DEST}/${APP_NAME}" ]; then
  rm -rf "${INSTALL_DEST:?}/${APP_NAME}"
  echo " ${PASS} 已移除 ${INSTALL_DEST}/${APP_NAME}"
else
  echo " ${PASS} 未发现应用本体（可能已移除）"
fi

# 3) 移除随装插件（mini-dialog：随 Launcher 装，随 Launcher 卸）
if [ "$KEEP_PLUGIN" = "1" ]; then
  echo " ${WARN} 已按要求保留插件（--keep-plugin）"
elif [ -d "$PLUGIN_DEST" ]; then
  rm -rf "${PLUGIN_DEST:?}"
  echo " ${PASS} 已移除插件 ${PLUGIN_DEST}"
else
  echo " ${PASS} 未发现插件目录"
fi

# 4) 清理装配条目（幂等：仅删除 mini-dialog 两行，不动其他插件）
if [ -f "${PROFILE_WEB}/cordis.patch.yml" ] && grep -q "${PLUGIN_NAME}" "${PROFILE_WEB}/cordis.patch.yml"; then
  # 条目为两行结构：`    - id: mini-dialog` + 紧随的 `      name: 'dsh-mini-dialog'`
  sed -i '' "/^[[:space:]]*- id: mini-dialog$/,+1d" "${PROFILE_WEB}/cordis.patch.yml"
  echo " ${PASS} 已移除装配条目 → cordis.patch.yml"
else
  echo " ${PASS} 装配条目不存在（无需清理）"
fi

echo "──────────────────────────────"
echo "卸载完成。"
echo "提示：插件移除在 DSH 后端重启后生效（菜单栏 → 服务器 → 重启，或重启主应用）。"
echo "      主应用与本机会话数据不受影响。"
echo "UNINSTALLED=1"
[ "$KEEP_PLUGIN" = "1" ] && echo "PLUGIN_KEPT=1"
