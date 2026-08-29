# dsh-mini-dialog

DSH 迷你对话插件（一包两脸）。宿主侧（`lib/index.js`）为桌面 Launcher 内嵌的
WebView 提供一组轻量会话 HTTP 路由 + 一个 WebSocket 推送通道；WebView 侧
（`lib/client.js`）接收 focus-session 推送并选中会话。

> i 场景（光标处唤起输入窗）的窗口 spawn 由 DSH Launcher 负责，本插件不管进程、
> 不管窗口，只接收 WebView 打来的 HTTP 请求。会话生命周期（create / followup /
> focus / options）随宿主进程存活，进程退出即整体消亡，不落盘、不跨重启。

## 包结构

```
dsh-mini-dialog/
├── package.json        # type: module；exports "." / "./client"；dsh.client 声明（含 inject）
├── lib/
│   ├── index.js        # 宿主侧：路由 + 零依赖 WebSocket 广播服务端（本次主体）
│   └── client.js       # WebView 侧：focus-session 接收 + ctx.sessions.open 选中
└── test/
    └── smoke.mjs       # 冒烟：node --check + 桩环境真实 import（不碰真实后端）
```

## 路由

| 方法 | 路径 | 作用 |
|---|---|---|
| POST | `/api/mini/session.new` | 新建会话（可选 `cwd`/`provider`/`model`），立即送入首条消息，返回 `sessionId` |
| POST | `/api/mini/session.send` | 向既有会话追加一条用户消息 |
| POST | `/api/mini/focus` | 向所有已连 WebView 广播 focus-session（Launcher 打开主应用后调用） |
| GET  | `/api/mini/options` | 尽力而为返回可选 provider 与默认模型 |
| (WS) | `/api/mini/ws` | 宿主→WebView 推送通道（`registerUpgrade` 注册，广播 focus-session） |

统一错误形态：`4xx/5xx` 均回 JSON `{"ok":false,"error":"..."}`，不泄堆栈。

### curl 示例

```bash
# 新建会话（带工作目录 + 显式模型）
curl -s -X POST http://127.0.0.1:3080/api/mini/session.new \
  -H 'Content-Type: application/json' \
  -d '{"text":"帮我看看当前目录","cwd":"/Users/me/proj","model":"deepseek-chat"}'
# => {"ok":true,"sessionId":"<uuid>"}

# cwd 不存在的校验（不代创建）
curl -s -X POST http://127.0.0.1:3080/api/mini/session.new \
  -H 'Content-Type: application/json' \
  -d '{"text":"hi","cwd":"/no/such/dir"}'
# => 400 {"ok":false,"error":"cwd 不存在：/no/such/dir（本插件不代创建）"}

# 向既有会话追加消息
curl -s -X POST http://127.0.0.1:3080/api/mini/session.send \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"<uuid>","text":"继续"}'
# => {"ok":true}

# 广播 focus-session 给所有已连 WebView（连接表为空也回 ok，属正常态）
curl -s -X POST http://127.0.0.1:3080/api/mini/focus \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"<uuid>"}'
# => {"ok":true,"delivered":1}

# 查询可选 provider / 默认模型（拿不到时回空清单）
curl -s http://127.0.0.1:3080/api/mini/options
# => {"ok":true,"providers":[{"id":"...","name":"..."}],"defaultModel":{"provider":"...","model":"..."}}
```

## 装配（cordis.patch.yml）

把整个包拷入 `~/.dsh/profiles/node_modules/dsh-mini-dialog/`，然后在
`cordis.patch.yml` 的 insert 列表补一行，重启生效：

```yaml
- insert:
    - id: mini-dialog
      name: dsh-mini-dialog
```

## 推送通道设计

宿主→模块的 focus 推送**不用**官方 `ctx.remote.$on`：官方把宿主→浏览器的转发
事件锁死在一张白名单里（`packages/api/remotes/src/remote-events.ts:17-29` 的
`API_REMOTE_FORWARDED_EVENTS`），白名单不可扩展，`focus-session` 不在其中。
因此宿主侧用 `ctx.webServer.registerUpgrade` 注册自有端点 `/api/mini/ws`
（零依赖手写握手 + 帧编解码），WebView 侧连接
`ws://127.0.0.1:3080/api/mini/ws`，断线每 5s 重连；收到
`{"type":"focus-session","sessionId":...}` 即执行选中流程。

选中流程（`lib/client.js`）：先查 `ctx.sessions.list.getSnapshot().byId[sessionId]`，
缺失则 `await ctx.sessions.refresh()` 后重查，仍缺失静默返回并 `console.warn`；
命中则 `ctx.sessions.open(sessionId)` —— 官方
`ui-workspace/src/client/index.ts:77` 同款调用（等价侧边栏点击路径），
`SessionRuntime.open` = 选中 + 展示全链路。open 前必须预检，因为底层
`SessionManager.select()` 对未知会话直接 throw。

## 依赖的上游 API 清单

| API | 用途 | 文档出处 |
|---|---|---|
| `ctx.webServer.register(route)` | 注册命名路由（exact），返回 disposer | `docs/subsystems/web-server.md` |
| `ctx.webServer.registerUpgrade(route)` | 注册 `/api/mini/ws` HTTP Upgrade 路由 | `docs/subsystems/web-server.md` |
| `ctx.agents.create({sessionId, meta, agentOptions})` | 新建会话 + 代理，返回 `AgentHandle`（`sessionId` 必须自铸，见下） | `docs/subsystems/core.md`（`ctx.agents` / `CreateAgentOptions`） |
| `AgentHandle.agent.followup(message)` | 排队普通回合消息并唤醒驱动 | `docs/subsystems/core.md`（Agent） |
| `ctx.agents.get(id)` | 按 SessionId 查裸 Agent，缺席返回 `undefined` | `docs/subsystems/core.md`（`ctx.agents`） |
| `createUserMessage({content, source})` | 构造用户消息（来自 `@deepseek-ai/dsh-llm`） | `docs/cookbook/extension-cookbook.md`（UI plugin 示例） |
| `SessionId(string)` | 品牌化会话 id（来自 `@deepseek-ai/dsh-session`） | `docs/subsystems/core.md`（Branded IDs） |
| `ctx.get('llm').listProviders()` | 可选 provider 清单（`LlmProviderInfo[]`，尽力而为） | 官方 `packages/llm/llm/src/index.ts` |
| `ctx.get('agentDefaultModel').currentSelection()` | 当前默认模型（尽力而为） | `docs/subsystems/core.md`（`ctx.agentDefaultModel`） |
| `ctx.sessions.open / .list / .refresh` | WebView 侧选中会话（来自 `@deepseek-ai/dsh-client-runtime` 的 `SessionRuntime`） | 官方 `packages/client/ui-workspace/src/client/index.ts:77`、`packages/client/runtime/src/client/sessions/service.ts` |

要点备忘：

- `agents.create` 要求调用方自供 `sessionId`（registry 不代铸）；本插件用
  `SessionId(randomUUID())` 铸新，与 ACP 桥同款。
- `handle.agent.id` 与 session 共享同一身份，路由返回给客户端的 `sessionId` 就是它。
- `followup()` 无返回值，MessageId 不对外暴露；UI 侧应订阅 `session/event` 流观察回复。
- options 路由不 `inject` llm / agentDefaultModel，用 `ctx.get()` 弱引用读取，
  服务缺席时降级为空清单而非启动失败。
- 客户端 `inject = ['sessions']` 是 Cordis fiber 注入保证；package.json 的
  `dsh.client.inject: ["@deepseek-ai/dsh-client-runtime"]` 仅为信息性包名边
  （preflight/HMR 展示用），不参与激活顺序。

## TODO / 遗留

- **真机联调**（需宿主进程 + WebView 就位）：
  - 三个 HTTP 路由 + `/api/mini/focus` 广播 + `/api/mini/ws` 升级的端到端行为；
  - WebView 侧 `ctx.sessions.open` 全链路（选中 + 展示）在真实主应用中的表现；
  - `ctx.get('llm')` / `ctx.get('agentDefaultModel')` 在真实组成的服务名与返回
    形状核对；
  - `handle.dispose()` 语义（空闲回收）是否纳入 v2 登记表管理。
- **lib/client.js 类型引用**：`import type {} from '@deepseek-ai/dsh-client-runtime/client'`
  在 ESM `.js` 下会被 `node --check` 判为 SyntaxError，v1 用等价的 JSDoc typedef
  引用（`@typedef {import(...)}`）承担类型说明；若后续客户端面改 `.ts` 即可换回官方写法。

## 测试

```bash
node --check lib/index.js
node --check lib/client.js
npm test   # test/smoke.mjs：语法 + 桩环境真实 import（不启动后端，不碰 127.0.0.1:3080）
```
