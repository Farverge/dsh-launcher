# DSH Launcher Wiki

欢迎来到 **DSH Launcher** 的文档。DSH Launcher 是 [DSH Desktop](https://github.com/Farverge/DSH-MacOS) 的菜单栏伴侣应用（选装）。

> **定位声明**：社区项目，**非 DeepSeek 官方出品**，与官方无隶属、合作或背书关系。Launcher 仅通过本机回环接口（`127.0.0.1:3080`）与 DSH 后端通信，不上传任何数据。完整免责声明见 [README](../../README.md#免责声明)。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/iiiiiei/dsh-launcher/main/install.sh | bash
```

一行完成：菜单栏应用安装 + mini-dialog 后端插件随装部署。卸载对称：

```bash
curl -fsSL https://raw.githubusercontent.com/iiiiiei/dsh-launcher/main/uninstall.sh | bash
```

## 它解决什么问题

| 场景 | 只有 DSH Desktop | 加装 DSH Launcher |
|---|---|---|
| 唤起应用 | 手动 Finder/Dock | 菜单栏鲸鱼一键；应用不可见时直接弹迷你对话框 |
| 快速提问 | 打开应用 → 新会话 → 选模型 → 输入 | `⌘⇧D` 胶囊输入 → 回车 → 自动直达新会话 |
| 后端状态 | 需打开应用查看 | 菜单栏图标三态常驻（正常 / 过渡 / 异常） |
| 环境体检 | 无 | 右键「一键体检」，终端风只读报告（十一项 + 条件动作按钮） |
| Launcher 自更新 | 无入口 | 主应用设置 → 菜单栏插件 → 检查 Launcher 更新 |

## 文档导航

| 页面 | 适合 | 内容 |
|---|---|---|
| [架构](Architecture.md) | 开发者 | 分层设计、三态判定、发送链路时序、插件家族（mini-dialog + norm） |
| [构建](Build.md) | 维护者 | 编译、部署、回滚、插件装配 |
| [使用](Usage.md) | 所有用户 | 安装、热键、迷你对话框、体检窗、设置联动 |
| [更新](Update.md) | 所有用户 | Launcher 与主应用、后端三者的更新关系 |
| [常见问题](FAQ.md) | 所有用户 | 现象与排查 |
| [版本历史](Changelog.md) | 所有人 | v1.0.0 变更全记录与后续日期注记 |

## 快速 FAQ

- **要装 Node.js？** Launcher 本身不需要；迷你对话框发送时会按需拉起后端（后端依赖 Node，主应用安装器可自动补齐）
- **常驻吗？** 是，菜单栏常驻；自适应轮询稳态 30 秒一次本机回环请求，功耗可忽略
- **要辅助功能权限吗？** 不需要。Launcher 全程零系统权限
- **卸载？** 退出应用后把 `~/Library/Application Support/DSH Launcher.app` 移入废纸篓即可，无任何残留
