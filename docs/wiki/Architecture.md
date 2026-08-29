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
│ CheckupWindow     体检窗（七项只读检测，逐行刷出）              │
└──────────────┬───────────────────────────────────────────────┘
               │ HTTP / WebSocket（仅本机回环 127.0.0.1:3080）
┌─ dsh-mini-dialog（plugin/，一包两脸的 Cordis 插件）───────────┐
│ 宿主脸 lib/index.js   POST session.new / session.send /        │
│                       focus；GET options / reasoning；         │
│                       ws 升级端点 + pendingFocus 冷启动回放    │
│ WebView 脸 lib/client.js  收 focus-session → ctx.sessions.open │
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
→ POST /api/mini/focus                {sessionId} → ws 广播 + pendingFocus 登记（TTL 120s）
→ 收起胶囊 → NSWorkspace 打开主应用
   主应用 WebView 就绪后客户端模块连 /api/mini/ws → 发 hello → 回放 focus-session
   → ctx.sessions.open(sessionId)（官方侧边栏点击同款调用：选中 + 展示全链路）
```

## 4. 关键设计决策

- **推送通道走自有 WebSocket**：官方宿主→浏览器的转发事件在白名单内不可扩展（`API_REMOTE_FORWARDED_EVENTS`），自定义事件无法直达客户端模块，故插件自持 `/api/mini/ws` 升级端点（零依赖手写帧编解码）。
- **展开迟滞（单锚定）**：展开与否只取决于「内容在单行宽度（412）下是否超过一行」，渲染宽度按状态切换（单行 412 / 通栏 600）。两个方向同锚定，结构上无抖动带。
- **失 key 即收**：面板 `didResignKey` 触发收起（点击外部 / 切应用的标准消散）；菜单跟踪与访达面板期间以计数器守卫抑制误收。
- **冷启动回放**：主应用冷启动时 WebView 晚于迷你框发送，focus 广播落在空连接表。插件缓存待投递（TTL 120 秒），客户端模块连上后发 `hello` 握手即回放，只投递给首个到达的 WebView。
- **思考强度覆盖**：官方 `AgentOptions` 无此字段，走 `agent/request` 瀑布改写 `LlmCallConfig.reasoningEffort`（仅对创建时显式选择的会话生效，其余原样放行）。
- **功耗红线**：轮询自适应且不缓存状态；图标角标仅在过渡态运行节拍器；菜单行 hover 用事件驱动，无常驻监视线程。

## 5. 目录结构

```
Sources/            Swift 源码（main + 七个组件文件）
Resources/          Info.plist、manifest.json、鲸鱼图标（SVG 矢量优先）
plugin/dsh-mini-dialog/   后端插件包（lib/index.js 宿主脸、lib/client.js WebView 脸、test/smoke.mjs）
docs/wiki/          本 wiki
build.sh            一键构建（DSH_LAUNCHER_NO_INSTALL=1 仅构建；安装前自动备份旧版）
release/            发版资产（gitignore：zip、sha256、发版说明）
```
