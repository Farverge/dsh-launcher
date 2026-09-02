# dsh-mini-dialog

DSH 迷你对话插件（宿主单脸）。为桌面 Launcher 提供迷你框的会话 HTTP 路由：
创建会话、追加消息、会话跳转广播、模型/思考强度查询。

> i 场景（光标处唤起输入窗）的窗口 spawn 由 DSH Launcher 负责，本插件不管进程、
> 不管窗口，只接收 WebView 侧打来的 HTTP 请求。会话生命周期（create / followup /
> options）随宿主进程存活，进程退出即整体消亡，不落盘、不跨重启。

## v0.2.0 重大变更：client 脸退役

会话跳转的浏览器端执行（`ctx.sessions.open`）整体移交 **`dsh-plugins-norm`**
（家族漂移屏蔽层，唯一允许接触官方接口的插件）。本插件 v0.2.0 起：

- 移除 `lib/client.js`、`package.json` 的 `dsh.client` 声明、自有 WS 通道（`/api/mini/ws`）
- `POST /api/mini/focus` 改经 norm 稳定面广播（norm 缺席时返回 503 与部署指引）
- **部署前置：dsh-plugins-norm ≥ 1.0.1**，且装卸必须与 `cordis.patch.yml` 条目同步
  （patch 引用缺失包会拒启整个 profile）
- 回滚：恢复 v0.1.0（自带 client 脸）

## 包结构

```
dsh-mini-dialog/
├── package.json        # type: module；exports "." ；无 dsh.client 声明（纯宿主）
├── lib/
│   └── index.js        # 宿主侧：session.new / session.send / focus / options / reasoning 路由
└── test/
    └── smoke.mjs       # 冒烟 19 项：node --check + 桩环境真实 import + 路由/语义断言
```

## 路由

| 方法 | 路径 | 作用 |
|---|---|---|
| POST | `/api/mini/session.new` | 新建会话（可选 `cwd`/`provider`/`model`/`reasoning`），立即送入首条消息，返回 `sessionId` |
| POST | `/api/mini/session.send` | 向既有会话追加一条用户消息 |
| POST | `/api/mini/focus` | 会话跳转——经 `dsh-plugins-norm` 稳定面广播（Launcher 打开主应用后调用） |
| GET  | `/api/mini/options` | 尽力而为返回可选 provider（含各 provider 模型清单）与默认模型 |
| GET  | `/api/mini/reasoning?provider=&model=` | 返回某路由的思考强度档位（无则空清单） |

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

# 会话跳转（经 norm 广播；norm 未部署时 503 指引）
curl -s -X POST http://127.0.0.1:3080/api/mini/focus \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"<uuid>"}'
# => {"ok":true,"via":"norm","sent":1}

# 查询可选 provider / 默认模型（拿不到时回空清单）
curl -s http://127.0.0.1:3080/api/mini/options
# => {"ok":true,"providers":[{"id":"...","name":"...","models":[...]}],"defaultModel":{...}}
```

## 装配（cordis.patch.yml）

前置：`dsh-plugins-norm ≥ 1.0.1` 已部署（同套 node_modules/patch 机制）。
把整个包拷入 `~/.dsh/profiles/node_modules/dsh-mini-dialog/`，然后在
`cordis.patch.yml` 的 insert 列表补一行，重启生效：

```yaml
- insert:
    - id: mini-dialog
      name: dsh-mini-dialog
```

卸载：删除上表 patch 两行 + `rm -rf ~/.dsh/profiles/node_modules/dsh-mini-dialog`，重启即完全还原。

## 依赖的上游 API 清单

| API | 用途 | 文档出处 |
|---|---|---|
| `ctx.webServer.register(route)` | 注册命名路由（exact，优先于官方 `/api` 认证栅栏），返回 disposer | `docs/subsystems/web-server.md` |
| `ctx.agents.create({sessionId, meta, agentOptions})` | 新建会话 + 代理，返回 `AgentHandle`（`sessionId` 必须自铸） | `docs/subsystems/core.md`（`ctx.agents` / `CreateAgentOptions`） |
| `AgentHandle.agent.followup(message)` | 排队普通回合消息并唤醒驱动 | `docs/subsystems/core.md`（Agent） |
| `ctx.agents.get(id)` | 按 SessionId 查裸 Agent，缺席返回 `undefined` | `docs/subsystems/core.md`（`ctx.agents`） |
| `createUserMessage({content, source})` | 构造用户消息（来自 `@deepseek-ai/dsh-llm`） | `docs/cookbook/extension-cookbook.md`（UI plugin 示例） |
| `SessionId(string)` | 品牌化会话 id（来自 `@deepseek-ai/dsh-session`） | `docs/subsystems/core.md`（Branded IDs） |
| `ctx.get('llm').listProviders() / listModels()` | 可选 provider 与模型清单（尽力而为） | 官方 `packages/llm/llm/src/index.ts` |
| `ctx.get('agentDefaultModel').currentSelection()` | 当前默认模型（尽力而为） | `docs/subsystems/core.md`（`ctx.agentDefaultModel`） |
| `ctx.get('dshPluginsNorm').focus(sessionId)` | 会话跳转广播（v0.2.0 起；norm 缺席时本路由 503） | `dsh-plugins-norm` 仓库 README |

要点备忘：

- `agents.create` 要求调用方自供 `sessionId`（registry 不代铸）；本插件用
  `SessionId(randomUUID())` 铸新，与 ACP 桥同款。
- `handle.agent.id` 与 session 共享同一身份，路由返回给客户端的 `sessionId` 就是它。
- `followup()` 无返回值，MessageId 不对外暴露；UI 侧应订阅 `session/event` 流观察回复。
- options / reasoning 路由不 `inject` llm / agentDefaultModel，用 `ctx.get()` 弱引用读取，
  服务缺席时降级为空清单而非启动失败。
- 兼容性：0.1.2-alpha.3/4/5 沙箱+生产实测通过（见主仓 wiki Changelog）。

## 测试

```bash
node --check lib/index.js
npm test   # test/smoke.mjs：19 项（语法 + 桩环境真实 import + 路由清单与 focus-norm 语义断言）
```
