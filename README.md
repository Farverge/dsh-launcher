# DSH Launcher

## 前言

DSH Launcher 是 [DSH Desktop](https://github.com/Farverge/DSH-MacOS) 的菜单栏伴侣应用（选装）。一枚常驻菜单栏的鲸鱼，把 DSH 变成随叫随到：状态一眼可读、`⌘⇧D` 随手提问、体检一键完成。

> **定位声明**：社区项目，非 DeepSeek 官方出品，与官方无隶属、合作或背书关系。完整免责声明见下方[免责声明](#免责声明)。

## 目录

- [它是什么](#它是什么)
- [获取安装](#获取安装)
- [它是如何工作的](#它是如何工作的)
- [注意事项](#注意事项)
- [免责声明](#免责声明)
- [查看更多](#查看更多)
- [友情链接](#友情链接)
- [许可证](#许可证)

## 它是什么

- **三态状态图标**：后端健康 / 过渡（？闪烁）/ 异常（！），自适应轮询，不缓存状态
- **迷你对话框**（`⌘⇧D`）：单行胶囊，选工作区、选模型、选思考强度，回车发送后自动拉起后端并直达主应用中的新会话
- **一键体检**：终端风只读体检窗，七项检测逐行刷出
- **轻量**：纯 Swift/AppKit 单进程，无 Electron、无守护进程、零系统权限

## 获取安装

一键命令（安装菜单栏应用，并随装部署 mini-dialog 后端插件）：

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-Launcher/main/install.sh | bash
```

一键卸载（对称移除应用与随装插件）：

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-Launcher/main/uninstall.sh | bash
```

手动方式：到 [Releases](https://github.com/Farverge/DSH-Launcher/releases) 下载 `DSH.Launcher.zip`，解压后把 `DSH Launcher.app` 拖入 `~/Library/Application Support/`。

> 建议与 [DSH Desktop](https://github.com/Farverge/DSH-MacOS) v1.0.0+ 搭配使用；迷你对话框的完整体验依赖主应用 v1.0.x 携带的 dsh-mini-dialog 插件。

## 它是如何工作的

Launcher 通过本机回环（`127.0.0.1:3080`）探测 DSH 后端健康并驱动会话；与主应用之间用系统分布式通知交换窗口状态。全部机制与设计决策见 [Wiki · 架构](docs/wiki/Architecture.md)。

## 注意事项

- 需要 macOS 13+、Apple Silicon
- Launcher 运行期间全局占用 `⌘⇧D`（Finder 的「前往桌面」快捷键会被拦截）
- 迷你对话框发送依赖后端可达；后端未运行时 Launcher 会按需代为拉起（需 Node.js，主应用安装器可自动补齐）

## 免责声明

> 本项目为社区作品，与 DeepSeek 官方无任何隶属、合作或背书关系。软件按「现状」提供，不附带任何明示或默示的担保。使用者需自行承担使用本项目所产生的一切风险与后果，包括但不限于数据丢失、服务中断或其他损害。将后端暴露到公网存在已知安全风险，请勿在不受信任的网络环境中使用。使用本项目即表示你已阅读并同意上述条款。

## 查看更多

完整文档在 [Wiki](docs/wiki/Home.md)：

| 页面 | 内容 |
|---|---|
| [使用](docs/wiki/Usage.md) | 安装、热键、迷你对话框、体检窗、设置联动 |
| [架构](docs/wiki/Architecture.md) | 分层设计、三态判定、发送链路、设计决策 |
| [构建](docs/wiki/Build.md) | 编译、部署、回滚、插件装配 |
| [更新](docs/wiki/Update.md) | 三层更新关系与流程 |
| [常见问题](docs/wiki/FAQ.md) | 现象与排查 |
| [版本历史](docs/wiki/Changelog.md) | v1.0.0 变更全记录 |

## 友情链接

- [DeepSeek Harness（dsh 官方仓库）](https://github.com/deepseek-ai/deepseek-harness)
- [DSH Desktop（主应用）](https://github.com/Farverge/DSH-MacOS)

## 许可证

[MIT](LICENSE)
