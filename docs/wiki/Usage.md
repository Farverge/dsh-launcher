# 使用

完整使用指南：安装、热键、迷你对话框、体检窗与设置联动。进阶问题见 [FAQ](FAQ.md)。

> **定位声明**：社区项目，非 DeepSeek 官方出品，与官方无隶属或背书关系。完整免责声明见仓库 [README](../../README.md#免责声明)。

---

## 1. 安装

一键命令（推荐）——自动下载安装菜单栏应用，并随装部署 mini-dialog 后端插件：

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-Launcher/main/install.sh | bash
```

手动方式：到 [Releases](https://github.com/Farverge/DSH-Launcher/releases) 下载 `DSH.Launcher.zip`，解压后把 `DSH Launcher.app` 拖入 `~/Library/Application Support/`；插件部署见 [Build](Build.md#4-插件装配dsh-mini-dialog)。

> **为什么不是 /Applications**：私有目录不在启动台扫描范围（启动台只索引 /Applications）， Launcher 因此只作为菜单栏常驻工具存在，不打扰启动台；主应用经同一目录发现并管理它。

安装脚本带三段式回馈（环境预检 / 下载安装 / 启动状态），结尾输出 KEY=VALUE 摘要行供 agent 解析。插件部署在 DSH 后端重启后生效，脚本结束时会明确提示。

前提：**macOS 13+**、Apple Silicon、已安装 [DSH Desktop](https://github.com/Farverge/DSH-MacOS)（建议 v1.0.0+，含 mini-dialog 插件时迷你框功能完整）。

## 2. 菜单栏图标（三态）

| 形态 | 含义 | 说明 |
|---|---|---|
| 鲸鱼原样 | 后端健康运行 | `127.0.0.1:3080` 返回桥接健康报文 |
| 鲸鱼 + 「？」角标闪烁 | 过渡/存疑 | 启动中、端口半开、或端口被其他服务占用 |
| 鲸鱼 + 「！」角标 | 异常 | 无进程监听后端端口 |

悬停图标可看文字详情（版本、运行时长）。探测为自适应节奏：稳态 30 秒一次，状态变化后 60 秒内加密到 5 秒，不缓存任何状态。

## 3. 点击行为

- **左键**：应用不可见（未启动 / 已最小化 / 已隐藏）→ 弹出迷你对话框；应用可见 → 启动 / 激活主应用
- **右键**：菜单（启动 DSH Desktop / 一键体检 / 退出 DSH Launcher）

## 4. 迷你对话框（`⌘⇧D`）

单行胶囊，唤起于屏幕底部居中：

- **+**：选择工作区（不使用项目 / 添加工作区——拉起访达选文件夹）
- **输入区**：占满一行的宽度；多行时胶囊向上生长（上限接近整屏，超出后内部滚动）；无修饰回车发送，`⇧回车` 换行
- **模型 chip**：列出全部提供方的模型（含描述）；DeepSeek 等暴露思考强度的路由会附「思考强度」分区（仅对本次新会话生效）
- **↑**：发送

发送链路：确保后端运行（不在则代为拉起）→ 创建会话（按所选工作区 / 模型 / 思考强度）→ 收起胶囊 → 自动打开主应用 → 新会话出现在列表顶部，配套的会话内跳转随之生效。

> **三态判定**：应用未启动或不可见时，`⌘⇧D` 与左键都会弹迷你框；主应用在前台可见时快捷键静默失效——永远只有一个输入面，不会双开。

## 5. 一键体检（终端风小窗）

右键菜单 → 一键体检。独立 460×320 起步的可拉伸小窗，逐行即时刷出七项只读检测：macOS 版本 / Node / 应用签名 / 端口身份 / 桥接接口 / npx 副本数 / 缓存体量，末尾汇总建议，支持复制纯文本报告。全程只读，不杀任何进程，可边体检边使用主应用。

## 6. 与主应用的设置联动

主应用 `⌘,` → 菜单栏插件区（该区域随 Launcher 安装与否自动显隐）：

- 启用 / 停用（菜单栏常驻开关）
- **检查 Launcher 更新**：以 `Farverge/DSH-Launcher` 的最新 Release 为版本源，点击才联网

## 7. 退出与卸载

一键卸载（退出应用 + 移除本体 + 随装移除 mini-dialog 插件及其装配条目）：

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-Launcher/main/uninstall.sh | bash
```

追加 `--keep-plugin`（`bash -s -- --keep-plugin`）可保留插件仅移除应用本体。插件移除在后端重启后生效；不触碰主应用与任何会话数据。

手动方式：退出后把 `~/Library/Application Support/DSH Launcher.app` 移入废纸篓。无 LaunchDaemons、无登录项、无其他系统残留。
