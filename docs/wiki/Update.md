# 更新

Launcher、主应用、DSH 后端三者的更新关系与准确流程。

> **定位声明**：社区项目，非 DeepSeek 官方出品。完整免责声明见仓库 [README](../../README.md#免责声明)。

---

## 1. 三层各自的更新源

| 层 | 版本源 | 更新方式 |
|---|---|---|
| DSH Launcher | `Farverge/DSH-Launcher` 的 Release tag | 主应用设置 → 菜单栏插件 → 检查 Launcher 更新（只提示，按 Usage 手动覆盖安装） |
| DSH Desktop 主应用 | `Farverge/DSH-MacOS` 的 Release tag | 主应用设置 → 检查应用更新 |
| dsh 后端 | npm `@deepseek-ai/dsh` | 主应用设置 → 检查 DSH 更新（先查后问，自动清缓存并重启后端） |
| mini-dialog 插件 | 随 Launcher 安装/卸载脚本分发（装 Launcher 即部署，卸载即移除） | 随 Launcher 更新窗口同步 |

套件内三者版本节奏保持同步发布（同一发版窗口打各自 tag）。

## 2. 检查 Launcher 更新

主应用 `⌘,` → 菜单栏插件 → 「检查 Launcher 更新」：

- 点击才联网（`api.github.com` 匿名接口），无常驻任务
- 语义化版本比较：`v1.0.10 > v1.0.9`、预发布（`-rc`/`-beta`）视为低于正式版
- 上游尚无 Release 时提示「尚未发布任何版本」，与网络故障分开提示
- 发现新版 → 前往 Releases 下载新 zip → 按 [Usage](Usage.md#1-安装) 覆盖 `~/Library/Application Support/DSH Launcher.app`

## 3. 更新时的兼容关系

- Launcher 向后兼容同代主应用；三态判定、窗口状态广播等跨应用信号以分布式通知为契约，双方独立升级不破坏
- mini-dialog 插件随主应用安装器分发，更新主应用即同步更新插件
- 插件上游 API 锁定 `@deepseek-ai/dsh@0.1.1-rc.2`；官方升级后按 [Architecture](Architecture.md) 核对所用接口再跟进
