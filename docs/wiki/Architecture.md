# 架构

面向开发者的分层设计与关键机制。配套页面：[构建](Build.md)、[使用](Usage.md)。

> **定位声明**：社区项目，非 DeepSeek 官方出品。本文描述的宿主接口以 `@deepseek-ai/dsh@0.1.1-rc.2` 为基准。

---

## 1. 系统分层

```
┌─ DSH Launcher（本仓库，Swift/AppKit，LSUIElement）────────────┐
│ StatusIcons    三态图标合成（模板单色 + ？/！角标，全胶囊圆角） │
│ StatusProbe    自适应健康轮询（稳态30s/突变5s/菜单展开强刷）    │
│ HotKeyCenter   ⌘⇧D 全局热键（Carbon RegisterEventHotKey）      │
│ VisibilityMonitor 主应用窗口可见性（分布式通知，内存布尔位）    │
│ MiniDialogPolicy  三态判定（i 弹出 / ii 失效 / iii 最小化弹出）│
│ MiniDialogPanel   胶囊面板（单行⇄展开迟滞、控件沉底、失key即收）│
│ BackendSpawner    按需拉起后端（npx 缓存定位 + 健康等待）       │
│ CheckupWindow     体检窗（十一项只读检测，逐行刷出）            │
└──────────────┬───────────────────────────────────────────────┘
               │ HTTP（仅本机回环 127.0.0.1:3080）
┌─ dsh-mini-dialog v0.2.0（plugin/，宿主单脸的 Cordis 插件）────┐
│ lib/index.js   POST session.new / session.send / focus；       │
│                GET options / reasoning；                       │
│                focus 惰性转发 dsh-plugin-norm（缺席回 503）   │
│                （client 脸、/api/mini/ws 与 9 包 inject 已移除）│
├─ dsh-plugin-norm ≥1.0.1（家族漂移屏蔽层，独立仓库）──────────┤
│ 稳定面  GET /api/dsh-plugin-norm/caps（部署体检锚点）         │
│         POST /api/dsh-plugin-norm/focus（跳转广播+审计）      │
│         /api/dsh-plugin-norm/ws 被动事件通道                  │
│ client 侧 window.__dshPluginNorm 微内核（on/caps/focusSession，│
│         会话跳转三级降级链 → ctx.sessions.open）               │
└──────────────┬───────────────────────────────────────────────┘
               │ Cordis 服务（agents / webServer / llm / agentDefaultModel）
┌─ @deepseek-ai/dsh 后端（官方，node）──────────────────────────┐
└──────────────────────────────────────────────────────────────┘
```

## 2. 三态判定矩阵

| 主应用进程 | 后端 3080 | 可见性信号 | `⌘⇧D` / 左键 |
|---|---|---|---|
| 不在跑 | 任意 | — | 弹迷你框 |
| 在跑 | down（且非可见） | 任意 | 弹迷你框（可见时保守失效） |
| 在跑 | 任意 | 收到广播 visible=false | 弹迷你框 |
| 在跑 | 任意 | 可见 / 信号未知 | 激活主应用 |

可见性来源：主应用壳在最小化 / 恢复 / 获焦 / `Cmd+H` 隐藏时经 `NSDistributedNotificationCenter` 广播 `com.deepseek-ai.dsh-desktop.windowState`。事件驱动零轮询，Launcher 端只留一个内存布尔位。

## 3. 发送链路时序

```
输入 ⏎
→ BackendSpawner.ensureRunning()      探测既有实例；不可用则 spawn node 并轮询健康 ≤10s
→ POST /api/mini/session.new          {text, cwd?, provider?, model?, reasoning?}
   插件内：agents.create(meta.cwd, agentOptions) → sessionHandles 登记
          reasoning 非空则 sessionReasoning 登记 → agent/request 瀑布按会话覆盖
          followup(首条消息) → 200 {sessionId}
→ POST /api/mini/focus                {sessionId} → 惰性解析 norm 服务 → norm.focus()
   norm 稳定面广播（含 lastFocusResult 审计）+ norm 侧 pendingFocus 登记（TTL 120s）
   norm 缺席 → 503 {部署指引}（会话已建成，仅自动跳转降级，不拖垮发送主链）
→ 收起胶囊 → NSWorkspace 打开主应用
   主应用 WebView 就绪后 window.__dshPluginNorm 接收跳转广播
   → 会话跳转三级降级链 → ctx.sessions.open(sessionId)（官方侧边栏点击同款调用：选中 + 展示全链路）
```

## 4. 关键设计决策

- **会话跳转执行移交 dsh-plugin-norm（mini-dialog 0.2.0 起）**：官方 client 侧接口只允许一个插件触碰——家族漂移屏蔽层 norm（仓库 [iiiiiei/dsh-plugin-norm](https://github.com/iiiiiei/dsh-plugin-norm)，包名/服务名/路由前缀为 `dsh-plugin-norm`）持有浏览器端执行面：`window.__dshPluginNorm` 微内核（on / caps / focusSession，会话跳转三级降级链）。mini-dialog 因此退役 client 脸（含 9 包 inject 声明）与自有 `/api/mini/ws` 通道，`/api/mini/focus` 改经 norm 稳定面广播（`POST /api/dsh-plugin-norm/focus`，含 lastFocusResult 审计）；norm 缺席时惰性解析落空、回 503 部署指引，不把插件拖进 fail-fast。norm 另提供 `GET /api/dsh-plugin-norm/caps`（宿主形状探测 + 客户端上报合并 + 降级清单，免认证）兼作部署体检锚点与 `/api/dsh-plugin-norm/ws` 被动事件通道；全程零轮询零缓存。
- **展开迟滞（单锚定）**：展开与否只取决于「内容在单行宽度（412）下是否超过一行」，渲染宽度按状态切换（单行 412 / 通栏 600）。两个方向同锚定，结构上无抖动带。
- **失 key 即收**：面板 `didResignKey` 触发收起（点击外部 / 切应用的标准消散）；菜单跟踪与访达面板期间以计数器守卫抑制误收。
- **冷启动回放**：主应用冷启动时 WebView 晚于迷你框发送，focus 广播落在无人接收的窗口期。norm 侧缓存待投递（TTL 120 秒），客户端就绪后回放，只投递给首个到达的会话。
- **迷你框深浅色（v2 根治）**：不跟随 `NSApp.effectiveAppearance`——accessory（菜单栏）应用后台时该值会过期（真机实测：系统已切浅色、它仍是 dark，窗口跟随它就永远深色）。改为从系统偏好直读 `AppleInterfaceStyle` 把窗口显式钉到系统真实外观；换肤经 `AppleInterfaceThemeChangedNotification` 分布式通知事件驱动重读，零轮询。
- **思考强度覆盖**：官方 `AgentOptions` 无此字段，走 `agent/request` 瀑布改写 `LlmCallConfig.reasoningEffort`（仅对创建时显式选择的会话生效，其余原样放行）。
- **功耗红线**：轮询自适应且不缓存状态；图标角标仅在过渡态运行节拍器；菜单行 hover 用事件驱动，无常驻监视线程。
- **认证演进备注（2026-08-29）**：当前锁定的 `dsh@0.1.1-rc.2` 无内置认证（README 安全警示基于此）；上游 0.1.2-alpha.1 起提供 launch token + 签名 Cookie 浏览器认证链（实测该版本仅有 GitHub tag、未上 npm，npm latest 仍为 0.1.1-rc.2）。升级锁定版本时，`/api/mini/*` 需一并纳入同一信任栅栏（Cookie 校验或经栅栏内注册）；浏览器端执行面已移交 norm——其 caps 路由设计为免认证（体检锚点需可匿名探测）、ws 为被动事件通道，届时需一并核对 norm 稳定面的暴露面。

## 5. 套件级嵌套部署（mini-dialog 的归属与生命周期）

mini-dialog 是**套件级组件**：它的宿主服务跑在 DSH 后端（v0.2.0 起宿主单脸，浏览器端执行面在 dsh-plugin-norm 的 client 微内核里），但它的唯一调用方是 Launcher 的迷你框。归属与分发据此设计：

- **归属**：源码在本仓库 `plugin/dsh-mini-dialog/`，随 **Launcher** 分发（用户"随着 Launcher 下载、随着卸载移除"）
- **安装**：Release 资产 `DSH.Launcher.zip` 内含应用本体 + 插件载荷，[install.sh](../../install.sh) 一次完成应用安装 + 插件拷入 profiles + cordis.patch.yml 幂等写入
- **卸载**：[uninstall.sh](../../uninstall.sh) 对称移除应用本体、插件目录与装配条目（`--keep-plugin` 可保留）
- **前置依赖（v0.2.0 起）**：会话跳转通道前置 **dsh-plugin-norm ≥ 1.0.1**（独立仓库，见第 4 节，不随 Launcher Release 分发）；装卸必须与 cordis.patch.yml 条目同步——patch 引用了 node_modules 里缺失的包时，整个 profile 会拒绝启动
- **生效时机**：插件文件的部署/移除在 **DSH 后端重启后**生效（脚本会明确提示）；主应用设置里的启用/停用开关只控制 Launcher **进程**启停——关闭后插件仍在后端空转（回环路由无调用方，无害），不做硬联动是为了避免为空转状态重启后端、打断会话

## 6. 目录结构

```
Sources/            Swift 源码（main + 六个组件文件）
Resources/          Info.plist、manifest.json、鲸鱼图标（SVG 矢量优先）
plugin/dsh-mini-dialog/   后端插件包 v0.2.0（lib/index.js 宿主单脸，client 脸已退役；test/smoke.mjs）
install.sh          一键安装（应用 + 插件随装部署，三段式回馈）
uninstall.sh        一键卸载（对称移除，--keep-plugin 可保留插件）
docs/wiki/          本 wiki
build.sh            一键构建（DSH_LAUNCHER_NO_INSTALL=1 仅构建；安装前自动备份旧版）
release/            发版资产（gitignore：DSH.Launcher.zip 稳定名、sha256、发版说明）
```
