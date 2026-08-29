/**
 * dsh-mini-dialog — DSH 迷你对话插件（宿主侧）
 *
 * 为桌面 Launcher 内嵌的 WebView 提供一组轻量会话 HTTP 路由：
 *   POST /api/mini/session.new    新建会话（可选 cwd / provider / model），并立即送入首条消息
 *   POST /api/mini/session.send   向既有会话追加一条用户消息
 *   POST /api/mini/focus          向所有已连 WebView 广播 focus-session（Launcher 打开主应用后调用）
 *   GET  /api/mini/options        尽力而为返回可选 provider / 默认模型
 *   GET  /api/mini/ws (upgrade)   宿主→WebView 的 WebSocket 推送通道（registerUpgrade）
 *
 * 一包两脸：宿主侧（本文件）挂 Cordis 服务；WebView 侧见 lib/client.js。
 *
 * 【部署方式】整个包拷入 ~/.dsh/profiles/node_modules/dsh-mini-dialog/，
 * 然后在 cordis.patch.yml 的 insert 列表补一行 `name: dsh-mini-dialog`，重启生效。
 * （与 dsh-desktop-bridge 同一套部署惯例。）
 *
 * 【三态行为职责边界】
 *   - i 场景（在光标处唤起输入窗）的窗口 spawn 由 DSH Launcher 负责：
 *     本插件不管进程、不管窗口、不管焦点，只接收 WebView 打来的 HTTP 请求。
 *   - 会话生命周期（create / followup / focus 广播 / options 查询）由本插件经
 *     Cordis 服务（ctx.agents / ctx.webServer）驱动，这是本插件的全部职权。
 *   - 进程退出即整体消亡：mini 会话不落盘、不跨重启，无需任何逐会话持久化。
 *
 * 【为什么推送通道不用 ctx.remote.$on】官方把宿主→浏览器的转发事件限制在一张
 * 白名单里（packages/api/remotes/src/remote-events.ts:17-29 的
 * API_REMOTE_FORWARDED_EVENTS），白名单不可扩展，focus-session 不在其中；
 * 因此宿主→模块推送改走本插件自有的 WebSocket 端点 /api/mini/ws（registerUpgrade）。
 */

import { createHash, randomUUID } from "node:crypto";
import { statSync } from "node:fs";
import { isAbsolute } from "node:path";
import { SessionId } from "@deepseek-ai/dsh-session";
import { createUserMessage } from "@deepseek-ai/dsh-llm";

export const name = "dsh-mini-dialog";
export const inject = ["webServer", "agents"];

// ---------------------------------------------------------------------------
// 极简 WebSocket 服务端（仅广播，零依赖）
// 为什么不用 ws 包：profile 的 node_modules 没有 ws，dsh-desktop-bridge 的惯例
// 是零依赖；握手只需 node:crypto 的 SHA-1，帧编解码几十行。
// 【语义陷阱备忘】registerUpgrade 的 handler 拿到的是裸 Duplex 流
// （req, socket, head），不是现成的 WebSocket 对象；101 响应必须直接写 socket，
// head 是随握手请求到达的首个分片（通常为空），必须喂进帧解析器。
// ---------------------------------------------------------------------------

/** RFC 6455 握手 GUID。 */
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** 已握手完成的连接表（模块级，跨 apply 生命周期存续；部署为重启生效，无 HMR 顾虑）。 */
const sockets = new Set();

// 【冷启动时序兜底】主应用冷启动时 WebView 尚未加载、ws 连接还没建立，
// 此时 focus 广播落在空连接表上，跳转指令就会丢失。这里把最近一次 focus
// 缓存为"待投递"：客户端模块连上后先发一条 {type:'hello'}，若存在未过期
// 的待投递会话则回放给它。TTL 过期即作废，避免陈旧跳转打扰。
let pendingFocus = null; // { sessionId: string, at: number }
const PENDING_FOCUS_TTL_MS = 120 * 1000;

/** 握手校验：Sec-WebSocket-Accept = base64(sha1(key + GUID))。 */
function wsAcceptKey(key) {
  return createHash("sha1").update(key + WS_GUID).digest("base64");
}

/** 编码一帧服务端帧（服务端→客户端不掩码；opcode 0x1=text，0x9=ping，0xa=pong）。 */
function wsFrame(opcode, payload = Buffer.alloc(0)) {
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x80 | opcode, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

/**
 * 增量解析一个客户端帧（客户端帧必须掩码）。数据不足返回 null；
 * RSV 位置位（未协商扩展）视为协议错误直接 throw，由调用方断连。
 */
function wsParseFrame(buffer) {
  if (buffer.length < 2) return null;
  const b0 = buffer[0];
  const b1 = buffer[1];
  if ((b0 & 0x70) !== 0) throw new Error("ws: RSV bits set");
  const opcode = b0 & 0x0f;
  const masked = (b1 & 0x80) !== 0;
  let len = b1 & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buffer.length < 4) return null;
    len = buffer.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    if (buffer.length < 10) return null;
    len = Number(buffer.readBigUInt64BE(2));
    offset = 10;
  }
  const maskLen = masked ? 4 : 0;
  if (buffer.length < offset + maskLen + len) return null;
  let payload = buffer.subarray(offset + maskLen, offset + maskLen + len);
  if (masked) {
    const mask = buffer.subarray(offset, offset + 4);
    const out = Buffer.alloc(len);
    for (let i = 0; i < len; i++) out[i] = payload[i] ^ mask[i & 3];
    payload = out;
  }
  return { opcode, payload, rest: buffer.subarray(offset + maskLen + len) };
}

/** registerUpgrade 的 handler：完成握手后加入 sockets，close 时移除。 */
function wsUpgradeHandler(req, socket, head) {
  const key = req.headers["sec-websocket-key"];
  const version = req.headers["sec-websocket-version"];
  if (typeof key !== "string" || version !== "13") {
    socket.destroy();
    return;
  }
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    `Sec-WebSocket-Accept: ${wsAcceptKey(key)}\r\n` +
    "\r\n"
  );
  sockets.add(socket);
  let buffer = head && head.length > 0 ? head : Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    // 防协议滥用：单连接缓存超 1MB 仍未构成完整帧，直接断连。
    if (buffer.length > 1024 * 1024) {
      socket.destroy();
      return;
    }
    for (;;) {
      let frame;
      try {
        frame = wsParseFrame(buffer);
      } catch {
        socket.destroy();
        return;
      }
      if (frame === null) break;
      buffer = frame.rest;
      if (frame.opcode === 0x8) { // close：按 RFC 6455 回显 close 帧后再断开（审查 P1-2）
        try { socket.write(wsFrame(0x8, frame.payload)); } catch {}
        socket.destroy();
        return;
      }
      if (frame.opcode === 0x9) { // ping → 回 pong，保活客户端心跳
        try { socket.write(wsFrame(0xa, frame.payload)); } catch {}
      }
      if (frame.opcode === 0x1) { // text 帧：客户端生命周期信号（目前仅 hello）
        let msg = null;
        try { msg = JSON.parse(frame.payload.toString("utf8")); } catch {}
        if (msg !== null && msg.type === "hello") {
          const fresh = pendingFocus !== null &&
            Date.now() - pendingFocus.at < PENDING_FOCUS_TTL_MS;
          if (fresh) {
            const sessionId = pendingFocus.sessionId;
            pendingFocus = null;   // 投递即清：只回放给首个到达的 WebView
            try {
              socket.write(wsFrame(0x1, Buffer.from(
                JSON.stringify({ type: "focus-session", sessionId }), "utf8")));
            } catch {}
          }
        }
        // 其余文本帧 v1 忽略；继续消化缓冲区里可能的后续帧（不可 return）
      }
    }
  });
  socket.on("close", () => {
    sockets.delete(socket);
  });
  socket.on("error", () => {
    socket.destroy();
  });
}

/** 向所有已连接 WebView 广播一个 JSON 对象（focus-session 推送）。 */
function broadcast(obj) {
  const text = JSON.stringify(obj);
  for (const socket of sockets) {
    try {
      socket.write(wsFrame(0x1, Buffer.from(text, "utf8")));
    } catch {
      // 写失败说明连接已死，交给 close 事件从集合移除
    }
  }
}

export function apply(ctx) {
  // 【会话泄漏防护 · v1 取舍】
  // ctx.agents.create() 返回的 AgentHandle 拥有 dispose 能力，且只对创建者可见。
  // 本插件把每个 handle 登记进 sessionHandles（只增不销）：
  //   - v1 接受"无显式回收"这一泄漏面：mini 会话的生命周期跟随宿主进程，
  //     进程退出即整体消亡；部署方式是"拷入 profiles 后重启生效"，
  //     本组成里没有插件热重载，因此没有触发逐会话 dispose 的时机。
  //   - 若把 handle 直接丢给 GC，会话照样留在 registry 直到进程退出，效果相同；
  //     登记表的价值在于让"谁持有句柄"可审计，并为后续版本铺路。
  //   - 后续版本：改为登记表统一管理，按会话空闲超时 / 客户端断开主动
  //     await handle.dispose()（dispose 会停驱动、退注册、删会话、解绑作用域）。
  const sessionHandles = new Map();

  // 【思考强度按会话覆盖 · R1-2g】迷你框可选思考强度；官方 AgentOptions 没有该
  // 字段（agent/src/index.ts:159-167 仅 provider/model/maxTokens），按会话覆盖
  // 的官方通道是 agent/request 瀑布（core.md:892：监听 next() 拿机器将用的
  // 配置，返回替换版即可，LlmCallConfig.reasoningEffort 字段名见
  // packages/llm/llm/src/call-config.ts:26）。仅在创建时用户显式选择了档位的
  // 会话进表；未选择走宿主/adapter 默认，不干预。
  const sessionReasoning = new Map();

  const sendJson = (res, status, payload) => {
    res.writeHead(status, {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    });
    res.end(JSON.stringify(payload));
  };

  // 请求体统一出口：整包读流后解析；非法 JSON 返回 undefined，由调用方按 400 处理。
  // 【审查 P1-1】1MB 上限防内存滥用；超限后继续丢弃剩余流（保证响应仍可正常写出）
  // 但不再累积。回环私有接口，413 与 400 的区分无实际价值，统一按 400 报错。
  const MAX_BODY_BYTES = 1024 * 1024;
  const parseBody = async (req) => {
    let body = "";
    let oversized = false;
    for await (const chunk of req) {
      if (!oversized) {
        body += chunk;
        if (Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES) {
          oversized = true;
          body = "";
        }
      }
    }
    if (oversized) return undefined;
    try {
      return JSON.parse(body || "{}");
    } catch {
      return undefined;
    }
  };

  // 异常出口：所有路由的 handler 都包 try/catch，未预料异常统一回 500。
  // 【语义陷阱备忘】绝不能把 `error.message` 以外的堆栈 / 服务内部状态
  // 泄到响应体里——WebView 侧只是 UI，不是诊断控制台。
  const reportError = (res, error) => {
    const message = error instanceof Error ? error.message : String(error);
    ctx.logger.error("dsh-mini-dialog: %s", message);
    sendJson(res, 500, { ok: false, error: message });
  };

  // ---- POST /api/mini/session.new ----
  // 注意：ctx.effect(callback) 会立即执行 callback 并把其返回值当作 disposer
  // 保存，因此必须把 register 调用包在箭头函数里返回（与 dsh-desktop-bridge 同款姿态）。
  ctx.effect(() => ctx.webServer.register({
    kind: "exact",
    path: "/api/mini/session.new",
    handler: async (req, res) => {
      try {
        const body = await parseBody(req);
        if (body === undefined) {
          return sendJson(res, 400, { ok: false, error: "请求体不是合法 JSON" });
        }
        const { text, cwd, provider, model, reasoning } = body;

        if (typeof text !== "string" || text.length === 0) {
          return sendJson(res, 400, { ok: false, error: "text 必须为非空字符串" });
        }

        // cwd：可选，但一旦提供必须是真实存在的绝对路径；本插件绝不代创建目录。
        if (cwd !== undefined) {
          if (typeof cwd !== "string" || !isAbsolute(cwd)) {
            return sendJson(res, 400, { ok: false, error: "cwd 必须为绝对路径" });
          }
          let stat;
          try {
            stat = statSync(cwd);
          } catch {
            return sendJson(res, 400, { ok: false, error: `cwd 不存在：${cwd}（本插件不代创建）` });
          }
          if (!stat.isDirectory()) {
            return sendJson(res, 400, { ok: false, error: `cwd 不是目录：${cwd}` });
          }
        }

        // 会话 id 由本插件铸新：brand 进 SessionId 再交给 registry。
        // 【语义陷阱备忘】create 需要调用方自供 sessionId（与 dsh-session 的
        // create() 不同，registry 不代铸）；ACP 桥同款写法是 SessionId(randomUUID())。
        const sessionId = SessionId(randomUUID());
        const meta = cwd === undefined ? undefined : { cwd };

        // agentOptions 只携带显式提供的字段：undefined 字段必须在 create 前剔除，
        // 否则会覆盖 provider adapter 的默认路由 / 默认模型。
        const agentOptions = {};
        if (provider !== undefined) agentOptions.provider = provider;
        if (model !== undefined) agentOptions.model = model;
        const handle = await ctx.agents.create({ sessionId, meta, agentOptions });
        sessionHandles.set(sessionId, handle);
        // 用户显式选择了思考强度才登记（字符串校验防误传对象/数字）
        if (typeof reasoning === "string" && reasoning.length > 0) {
          sessionReasoning.set(sessionId, reasoning);
        }

        // 【语义陷阱备忘】followup() 无返回值（MessageId 只标识入队，不代表
        // 后来的助手输出）；本插件 v1 不做"拿到某条回复"的承诺，UI 侧应订阅
        // session/event 流自行观察。
        // 【审查 P1-3】会话已建成而 followup 恰好抛错的半失败场景：
        // 此刻会话其实创建成功且已登记——若按异常回 500，客户端会以为"没建
        // 成"而重试，造成重复会话。因此 followup 异常降级为 200 + warning。
        let warning = null;
        try {
          handle.agent.followup(createUserMessage({
            content: [{ type: "text", text }],
            source: { kind: "user" },
          }));
        } catch (followupError) {
          warning = `会话已创建但首条消息入队失败：${followupError.message}`;
        }

        // 【语义陷阱备忘】Agent.id 与 Session.id 是同一品牌身份（SessionId），
        // 也就是 create 时我们铸的那个；把它回给客户端，session.send 再拿它
        // 原样进 ctx.agents.get()。不要误取 handle.agent.session（那是 Session
        // 对象）或 session.header 等其他途径。
        sendJson(res, 200, warning === null ? { ok: true, sessionId } : { ok: true, sessionId, warning });
      } catch (error) {
        reportError(res, error);
      }
    },
  }));

  // ---- POST /api/mini/session.send ----
  ctx.effect(() => ctx.webServer.register({
    kind: "exact",
    path: "/api/mini/session.send",
    handler: async (req, res) => {
      try {
        const body = await parseBody(req);
        if (body === undefined) {
          return sendJson(res, 400, { ok: false, error: "请求体不是合法 JSON" });
        }
        const { sessionId, text } = body;

        if (typeof sessionId !== "string" || sessionId.length === 0) {
          return sendJson(res, 400, { ok: false, error: "sessionId 必须为非空字符串" });
        }
        if (typeof text !== "string" || text.length === 0) {
          return sendJson(res, 400, { ok: false, error: "text 必须为非空字符串" });
        }

        // 【语义陷阱备忘】ctx.agents.get(id) 返回裸 Agent 而非 AgentHandle；
        // dispose 能力只属于创建者手里的 handle。因此这里只能 followup，
        // 不能 dispose——dispose 归属权 v1 下本来就在模块内登记的 handle 上。
        const agent = ctx.agents.get(SessionId(sessionId));
        if (agent === undefined) {
          return sendJson(res, 404, { ok: false, error: `会话不存在：${sessionId}` });
        }

        agent.followup(createUserMessage({
          content: [{ type: "text", text }],
          source: { kind: "user" },
        }));
        sendJson(res, 200, { ok: true });
      } catch (error) {
        reportError(res, error);
      }
    },
  }));

  // ---- WebSocket 推送通道（/api/mini/ws，HTTP Upgrade）----
  // 组合 effect：卸载时先释放 upgrade 路由，再断开所有连接。
  ctx.effect(() => {
    const disposeUpgrade = ctx.webServer.registerUpgrade({
      path: "/api/mini/ws",
      handler: wsUpgradeHandler,
    });
    return () => {
      disposeUpgrade();
      for (const socket of sockets) {
        try { socket.destroy(); } catch {}
      }
      sockets.clear();
    };
  });

  // ---- POST /api/mini/focus ----
  // Launcher 在主应用打开后调用：把选中会话广播给所有已连 WebView。
  ctx.effect(() => ctx.webServer.register({
    kind: "exact",
    path: "/api/mini/focus",
    handler: async (req, res) => {
      try {
        const body = await parseBody(req);
        if (body === undefined) {
          return sendJson(res, 400, { ok: false, error: "请求体不是合法 JSON" });
        }
        const { sessionId } = body;
        if (typeof sessionId !== "string" || sessionId.length === 0) {
          return sendJson(res, 400, { ok: false, error: "sessionId 必须为非空字符串" });
        }
        // 连接表为空也回 ok：主应用 WebView 未打开是正常态，
        // 客户端下次连上时由 Launcher 侧负责补发（或用户手动点开）。
        broadcast({ type: "focus-session", sessionId });
        // 同步登记为待投递：冷启动场景（连接表为空）时由 hello 握手回放
        pendingFocus = { sessionId, at: Date.now() };
        sendJson(res, 200, { ok: true, delivered: sockets.size });
      } catch (error) {
        reportError(res, error);
      }
    },
  }));

  // ---- GET /api/mini/options ----
  // 尽力而为：拿不到任何东西也回空清单，绝不 throw、绝不下线。
  ctx.effect(() => ctx.webServer.register({
    kind: "exact",
    path: "/api/mini/options",
    handler: async (_req, res) => {
      try {
        // 【语义陷阱备忘】本路由刻意不 inject llm / agentDefaultModel：
        // inject 会让插件在服务缺席时启动失败（fail-fast），而 options 只是
        // UI 的辅助数据，服务缺席时应优雅降级而不是拖垮整个插件。
        // 用 ctx.get(name)（未注入读取）恰好在缺席时返回 undefined。
        let providers = [];
        let defaultModel = null;
        try {
          const llm = ctx.get("llm");
          // v2（真机反馈 R1-2g）：带出每个 provider 的模型清单
          // （官方 LlmModelInfo：{provider,id,name,description?}，llm/src/types.ts:233）
          const rows = [];
          for (const { id, name } of llm?.listProviders?.() ?? []) {
            let models = [];
            try {
              models = ((await llm.listModels?.(id)) ?? []).map((m) => ({
                id: m.id,
                name: m.name ?? m.id,
                description: m.description ?? null,
              }));
            } catch {
              // 单个 provider 的模型清单失败不影响其余 provider
            }
            rows.push({ id, name, models });
          }
          providers = rows;
        } catch (error) {
          ctx.logger.warn("mini/options: llm 读取失败，providers 置空");
        }
        try {
          const selection = ctx.get("agentDefaultModel")?.currentSelection?.();
          if (selection !== undefined) {
            defaultModel = { provider: selection.provider, model: selection.model };
          }
        } catch (error) {
          ctx.logger.warn("mini/options: agentDefaultModel 读取失败，defaultModel 置空");
        }
        sendJson(res, 200, { ok: true, providers, defaultModel });
      } catch (error) {
        // 兜底同样回空清单——本路由刻意不用 500：options 拿不到时
        // 客户端应当继续走默认值，而不是把错误怼到用户脸上。
        ctx.logger.warn("mini/options: 兜底降级为空清单");
        sendJson(res, 200, { ok: true, providers: [], defaultModel: null });
      }
    },
  }));

  // ---- GET /api/mini/reasoning?provider=&model= ----
  // 返回某条 provider/model 路由的思考强度档位（LlmResolvedModelInfo.reasoning，
  // types.ts:274：{efforts:[{id,name,description}], defaultEffort}）。档位是
  // adapter 按路由私有的，没有全局枚举，因此单独开一个惰性查询端点，
  // 由客户端在选中模型后按需取。
  ctx.effect(() => ctx.webServer.register({
    kind: "exact",
    path: "/api/mini/reasoning",
    handler: async (req, res) => {
      try {
        const url = new URL(req.url ?? "/", "http://127.0.0.1");
        const provider = url.searchParams.get("provider") ?? "";
        const model = url.searchParams.get("model") ?? "";
        if (provider === "" || model === "") {
          return sendJson(res, 400, { ok: false, error: "provider 与 model 查询参数必填" });
        }
        const llm = ctx.get("llm");
        const info = await llm?.resolveModelInfo?.(provider, model, undefined);
        const reasoning = info?.reasoning ?? null;
        sendJson(res, 200, {
          ok: true,
          efforts: reasoning?.efforts ?? [],
          defaultEffort: reasoning?.defaultEffort ?? null,
        });
      } catch (error) {
        // 与 options 同姿态：档位查不到就给空，前端隐藏思考强度分区
        ctx.logger.warn("mini/reasoning: 降级为空档位");
        sendJson(res, 200, { ok: true, efforts: [], defaultEffort: null });
      }
    },
  }));

  // ---- agent/request 瀑布：把登记过思考强度的迷你会话配置替换掉 ----
  // 根级监听收到全部 agent 的请求；仅 sessionReasoning 表内会话被改写，
  // 其余一律原样放行（await next() 的返回即机器将用的配置）。
  // 卸载语义：ctx.on 返回退订器，包进 effect 随插件卸载自动解除。
  ctx.effect(() => ctx.on("agent/request", async (payload, next) => {
    const config = await next();
    const effort = sessionReasoning.get(String(payload.agent.id));
    if (effort === undefined) return config;
    return { ...config, reasoningEffort: effort };
  }));

  ctx.logger.info("dsh-mini-dialog: session.new + session.send + focus + options + reasoning + /api/mini/ws ready");
}
