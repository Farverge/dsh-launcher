#!/bin/bash
# DSH Launcher 一键安装脚本
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/iiiiiei/dsh-launcher/main/install.sh | bash
#       三段式：① 环境预检 ② 下载安装 ③ 启动与状态回馈
#
# 行为：安装菜单栏应用 + 随包部署 dsh-mini-dialog 后端插件（迷你对话框的会话
# 创建/跳转能力）。插件重启 DSH 后端后生效——脚本结束时会给出明确提示。
#
# 卸载请使用同目录 uninstall.sh。
#
# 说明：curl 下载的文件不带隔离标记，Gatekeeper 不介入，无需任何签名证书。
set -euo pipefail

REPO="iiiiiei/dsh-launcher"
BASE_URL="https://github.com/${REPO}"
APP_NAME="DSH Launcher.app"
BUNDLE_ID="com.deepseek-ai.dsh-launcher"
ASSET="DSH.Launcher.zip"                       # 稳定资产名（GitHub 空格归一为点号），跨版本不变
PLUGIN_NAME="dsh-mini-dialog"
PROFILE_WEB="${HOME}/.dsh/profiles/web"
PLUGIN_DEST="${HOME}/.dsh/profiles/web/node_modules/${PLUGIN_NAME}"
INSTALL_DEST="${HOME}/Library/Application Support"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS="✓"; WARN="!"; FAIL="✗"
SUMMARY=()
note() { SUMMARY+=("$1"); }

# ---------------------------------------------------------------- 环境预检
preflight() {
  local rc=0
  echo "── ① 环境预检 ──────────────────────────────"

  local ver major
  ver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  major="${ver%%.*}"
  if [ "${major:-0}" -ge 13 ]; then
    echo " ${PASS} macOS ${ver}"
    note "OS_OK=1 OS_VERSION=${ver}"
  else
    echo " ${FAIL} macOS ${ver} 过旧，本应用需要 13+"; note "OS_OK=0"; rc=1
  fi

  local arch; arch="$(uname -m)"
  if [ "$arch" = "arm64" ]; then
    echo " ${PASS} 架构 ${arch}"
    note "ARCH=${arch}"
  else
    echo " ${FAIL} 架构 ${arch} —— 当前版本为 Apple Silicon 构建"; note "ARCH_OK=0"; rc=1
  fi

  for t in curl unzip ditto; do
    if command -v "$t" >/dev/null 2>&1; then
      echo " ${PASS} 工具 ${t}"
    else
      echo " ${FAIL} 缺少工具 ${t}"; note "TOOL_${t}_OK=0"; rc=1
    fi
  done

  # 主应用存在性（不阻断安装，但迷你框发送依赖主应用后端）
  local main_found=0
  for d in "/Applications/DSH Desktop.app" "${HOME}/Applications/DSH Desktop.app"; do
    [ -d "$d" ] && main_found=1 && break
  done
  if [ "$main_found" = "1" ]; then
    echo " ${PASS} 检测到主应用 DSH Desktop"
    note "MAIN_APP_OK=1"
  else
    echo " ${WARN} 未检测到 DSH Desktop —— 建议先安装主应用（https://github.com/Farverge/DSH-MacOS）"
    note "MAIN_APP_OK=0"
  fi

  # 既有安装
  if [ -d "${INSTALL_DEST}/${APP_NAME}" ]; then
    local old; old=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "${INSTALL_DEST}/${APP_NAME}/Contents/Info.plist" 2>/dev/null || echo '?')
    echo " ${PASS} 检测到既有安装 v${old}（将升级替换）"
    note "UPGRADE_FROM=${old}"
  fi

  return $rc
}

# ---------------------------------------------------------------- 插件装配
# mini-dialog 随 Launcher 分发（套件级组件）：装 Launcher 即部署，卸载即移除。
deploy_plugin() {
  if [ ! -d "$PROFILE_WEB" ]; then
    echo " ${WARN} 未发现 DSH 后端配置目录（~/.dsh/profiles/web）——插件暂缓部署"
    echo "     首次启动 DSH Desktop 后重新运行本命令即可补装"
    note "PLUGIN=deferred"
    return 0
  fi
  [ -d "${TMP}/${PLUGIN_NAME}" ] || {
    echo " ${FAIL} 资产包中缺少插件载荷"; note "PLUGIN=payload_missing"; return 0; }

  mkdir -p "${PLUGIN_DEST}"
  ditto "${TMP}/${PLUGIN_NAME}" "${PLUGIN_DEST}"
  echo " ${PASS} 插件已部署 → ${PLUGIN_DEST}"

  # patch 幂等写入：已有条目则跳过；无 patch 文件则创建最小结构
  local patch="${PROFILE_WEB}/cordis.patch.yml"
  if [ -f "$patch" ] && grep -q "${PLUGIN_NAME}" "$patch"; then
    echo " ${PASS} 装配条目已存在（幂等跳过）"
    note "PLUGIN_PATCH=already"
  elif [ -f "$patch" ]; then
    printf "    - id: mini-dialog\n      name: 'dsh-mini-dialog'\n" >> "$patch"
    echo " ${PASS} 装配条目已追加 → cordis.patch.yml"
    note "PLUGIN_PATCH=appended"
  else
    cat > "$patch" <<'YAML'
# DSH Launcher 附装插件（mini-dialog：迷你对话框会话创建/跳转）。随 Launcher 安装/卸载脚本维护。
- insert:
    - id: mini-dialog
      name: 'dsh-mini-dialog'
YAML
    echo " ${PASS} 已创建 ${patch}"
    note "PLUGIN_PATCH=created"
  fi
  note "PLUGIN=deployed"
}

# ---------------------------------------------------------------- 安装
do_install() {
  local pre_rc=0
  preflight || pre_rc=$?

  echo "── ② 下载与安装 ────────────────────────────"
  local url="${BASE_URL}/releases/latest/download/${ASSET}"
  echo " → ${url}"
  curl -fSL --progress-bar -o "${TMP}/${ASSET}" "$url"
  unzip -q -o "${TMP}/${ASSET}" -d "$TMP"
  [ -d "${TMP}/${APP_NAME}" ] || {
    echo " ${FAIL} 资产包结构不符合预期，请到 https://github.com/${REPO}/releases 手动下载"; exit 1; }

  # 运行中的旧实例先温和退出；3 秒不动则提示稍后自行重启生效
  if pgrep -x DSHLauncher >/dev/null 2>&1; then
    echo " → 检测到正在运行的 Launcher，尝试温和退出…"
    osascript -e 'quit app id "'"${BUNDLE_ID}"'"' >/dev/null 2>&1 || true
    sleep 3
    pgrep -x DSHLauncher >/dev/null 2>&1 \
      && echo " ! 实例仍在运行（可能被用户取消退出），本次替换将在其下次重启时生效"
  fi

  mkdir -p "$INSTALL_DEST"
  if [ -d "${INSTALL_DEST}/${APP_NAME}" ]; then
    local bak="${INSTALL_DEST}/${APP_NAME}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "${INSTALL_DEST}/${APP_NAME}" "$bak"
    echo " → 旧版已备份 → ${bak}"
    note "BACKUP=${bak}"
  fi
  ditto "${TMP}/${APP_NAME}" "${INSTALL_DEST}/${APP_NAME}"
  echo " ${PASS} 已安装到 ${INSTALL_DEST}/${APP_NAME}"

  deploy_plugin

  echo "── ③ 启动与状态回馈 ────────────────────────"
  open "${INSTALL_DEST}/${APP_NAME}"
  sleep 1
  if pgrep -x DSHLauncher >/dev/null 2>&1; then
    echo " ${PASS} Launcher 已启动（菜单栏鲸鱼图标就位）"
    note "LAUNCHER_STARTED=1"
  else
    echo " ${WARN} Launcher 未能确认启动，请手动打开 ${INSTALL_DEST}/${APP_NAME}"
    note "LAUNCHER_STARTED=0"
  fi

  echo "──────────────────────────────"
  echo "安装完成：${INSTALL_DEST}/${APP_NAME}"
  echo
  echo "── 摘要（供 agent 解析）──"
  local s; for s in "${SUMMARY[@]:-}"; do [ -n "$s" ] && echo "$s"; done
  echo "INSTALL_DEST=${INSTALL_DEST}/${APP_NAME}"
  [ "$pre_rc" -eq 0 ] || { echo "PREFLIGHT_WARN=1（存在告警项，见上文）"; }
  echo "PLUGIN_RESTART_HINT=重启 DSH 后端后 mini-dialog 插件生效（菜单栏 → 服务器 → 重启，或重启主应用）"
}

# ---------------------------------------------------------------- 入口
do_install
