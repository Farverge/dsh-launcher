# 更新

Launcher、主应用、DSH 后端三者的更新关系与准确流程。

> **定位声明**：社区项目，非 DeepSeek 官方出品。完整免责声明见仓库 [README](../../README.md#免责声明)。

---

## 1. 三层各自的更新源

| 层 | 版本源 | 更新方式 |
|---|---|---|
| DSH Launcher | `Farverge/DSH-Launcher` 的 Release tag | 主应用设置 → 菜单栏插件 → 检查 Launcher 更新（v1.0.3+ 确认后自动下载换壳，见第 2 节） |
| DSH Desktop 主应用 | `Farverge/DSH-MacOS` 的 Release tag | 主应用设置 → 检查应用更新 |
| dsh 后端 | npm `@deepseek-ai/dsh` | 主应用设置 → 检查 DSH 更新（先查后问，自动清缓存并重启后端） |
| mini-dialog 插件 | 随 Launcher Release 分发（安装脚本或主应用 v1.0.3+ 自动更新都会同步部署，卸载即移除） | 随 Launcher 更新同步 |

套件内三者版本节奏保持同步发布（同一发版窗口打各自 tag）。

## 2. 检查 Launcher 更新

主应用 `⌘,` → 菜单栏插件 → 「检查 Launcher 更新」（全自动安装需主应用 v1.0.3+）：

- 点击才联网（`api.github.com` 匿名接口），无常驻任务
- 语义化版本比较：`v1.0.10 > v1.0.9`、预发布（`-rc`/`-beta`）视为低于正式版
- 发现新版 → 确认窗（官方更新说明 + 备份策略）→ 确认后自动执行：
  1. 下载 `DSH.Launcher.zip` → 解包校验（.app 结构 / 可执行文件 / Info.plist 版本与 Release 一致）
  2. **先同步 mini-dialog 插件**到 `~/.dsh/profiles/node_modules/`（此步失败自动恢复原插件并整体中止，不连坐主程序）；幂等维护 `cordis.patch.yml` 装配条目
  3. 退出 Launcher → 分离脚本换壳（旧包备份至 `~/Library/Application Support/DSH Backups/`，保留最近 2 份）→ 自动启动新版
- 主应用低于 v1.0.3 时为旧行为：仅提示，到 [Releases](https://github.com/Farverge/DSH-Launcher/releases) 下载 zip 按 [Usage](Usage.md#1-安装) 手动覆盖安装

## 3. 更新时的兼容关系

- Launcher 向后兼容同代主应用；三态判定、窗口状态广播等跨应用信号以分布式通知为契约，双方独立升级不破坏
- mini-dialog 插件随 Launcher 分发：安装脚本与主应用 v1.0.3+ 的自动更新都会同步部署插件（自动更新时旧插件先备份、失败恢复原状）
- 插件上游 API 锁定 `@deepseek-ai/dsh@0.1.1-rc.2`；官方升级后按 [Architecture](Architecture.md) 核对所用接口再跟进
