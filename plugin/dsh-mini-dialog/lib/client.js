/**
 * dsh-mini-dialog — WebView 客户端模块
 *
 * 职责：接收宿主经本插件 WebSocket 通道（/api/mini/ws）推送的 focus-session，
 * 并把对应会话选中为主应用当前会话。选中的唯一官方调用是
 * ctx.sessions.open(sessionId)（等价侧边栏点击路径，出处
 * ui-workspace/src/client/index.ts:77）。
 *
 * 【为什么必须是 __ModuleLoader__ 工厂形式——审查 P0-1】官方浏览器加载器
 * （packages/client/modules/src/client/system.ts 的 materialize）以 classic
 * script 同步执行 bundle 并调用 factory(require)，且要求模块在执行期通过
 * `window.__ModuleLoader__.load({ id, factory })` 自我注册。raw ESM 的
 * `export` 在 classic script 下直接 SyntaxError，模块永远激活不了。
 * 因此本文件是普通脚本 + IIFE，而不是 ESM。
 *
 * 【注入声明】inject = ['sessions']：Cordis fiber 注入保证 ctx.sessions
 * 在 apply 内必定可用（服务来自 @deepseek-ai/dsh-client-runtime 的
 * SessionRuntime）。package.json 的 dsh.client.inject 列 runtime 包，
 * 仅作为模块图元数据（预取/HMR diff），不决定激活顺序。
 *
 * 【类型引入说明】.js 无 type-only import（会被当语法错误），用等价 JSDoc：
 * @typedef {import('@deepseek-ai/dsh-client-runtime/client').ClientContext} ClientContext
 */
(function () {
  "use strict";

  var WS_URL = "ws://127.0.0.1:3080/api/mini/ws";
  var RECONNECT_BASE_MS = 5000;
  var RECONNECT_MAX_MS = 60000;

  /**
   * 选中会话。底层 SessionManager.select() 对未知会话直接 throw，因此先查
   * 列表快照，命中缺失时 refresh 后重查；最后仍包一层 try/catch 兜住
   * TOCTOU 窗口（审查 P2-5）。
   * @param {ClientContext} ctx
   * @param {string} sessionId
   */
  async function focusSession(ctx, sessionId) {
    let summary = ctx.sessions.list.getSnapshot().byId[sessionId];
    if (summary === undefined) {
      // 列表可能尚未拉全：刷新基线后再查。refresh 失败不阻断，按"不在列表"处理。
      try {
        await ctx.sessions.refresh();
      } catch { /* refresh 失败：静默，走下方兜底 */ }
      summary = ctx.sessions.list.getSnapshot().byId[sessionId];
    }
    if (summary === undefined) {
      console.warn("[dsh-mini-dialog] 会话不在列表", sessionId);
      return;
    }
    try {
      ctx.sessions.open(sessionId);
    } catch (error) {
      console.warn("[dsh-mini-dialog] 打开会话失败", sessionId, error);
    }
  }

  /**
   * Cordis 客户端 apply：建立 ws 连接并在卸载时清理。
   * @param {ClientContext} ctx
   * @returns {() => void} 卸载 disposer：停止重连并关闭连接。
   */
  function apply(ctx) {
    /** @type {WebSocket | null} */
    var socket = null;
    /** @type {ReturnType<typeof setTimeout> | null} */
    var reconnectTimer = null;
    var stopped = false;
    var reconnectDelay = RECONNECT_BASE_MS;

    var scheduleReconnect = function () {
      if (stopped) return;
      // 指数退避并封顶（审查 P2-4）：后端长时间缺席时把周期唤醒降到最低频
      reconnectTimer = setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
    };

    var connect = function () {
      if (stopped) return;
      // WebSocket 是浏览器全局；非浏览器环境（如 node 冒烟）防御性退出。
      if (typeof globalThis.WebSocket !== "function") {
        console.warn("[dsh-mini-dialog] 非浏览器环境，跳过 ws 连接");
        return;
      }
      var ws;
      try {
        ws = new WebSocket(WS_URL);
      } catch (error) {
        console.warn("[dsh-mini-dialog] ws 连接创建失败", error);
        scheduleReconnect();
        return;
      }
      socket = ws;
      ws.addEventListener("open", function () {
        reconnectDelay = RECONNECT_BASE_MS; // 成功即复位退避
        console.info("[dsh-mini-dialog] ws 已连接", WS_URL);
        // 握手信号：宿主若有未过期(120s)的待投递 focus，会立刻回放一条
        // focus-session——覆盖主应用冷启动晚于迷你框发送的时序。
        try {
          ws.send(JSON.stringify({ type: "hello" }));
        } catch { /* 连接刚建立即断的场景：交给 close→重连 */ }
      });
      ws.addEventListener("message", function (event) {
        var payload = null;
        try {
          payload = JSON.parse(String(event.data));
        } catch { return; }
        if (payload !== null && payload.type === "focus-session" && typeof payload.sessionId === "string") {
          void focusSession(ctx, payload.sessionId);
        }
      });
      ws.addEventListener("close", function () {
        if (socket === ws) socket = null;
        scheduleReconnect();
      });
      ws.addEventListener("error", function () {
        // error 之后必然跟 close，重连交给 close 处理，这里只留痕迹。
      });
    };

    // 页面加载后异步连（文档仍在加载则等 DOMContentLoaded）。
    if (typeof document !== "undefined" && document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", function () { connect(); }, { once: true });
    } else {
      connect();
    }

    return function () {
      stopped = true;
      if (reconnectTimer !== null) clearTimeout(reconnectTimer);
      if (socket !== null) {
        socket.close();
        socket = null;
      }
    };
  }

  // ---- 注册进官方模块加载器（classic script 协议，见头部说明）----
  if (typeof window !== "undefined" && window.__ModuleLoader__ && typeof window.__ModuleLoader__.load === "function") {
    window.__ModuleLoader__.load({
      id: "dsh-mini-dialog",
      factory: function () {
        return { name: "dsh-mini-dialog", inject: ["sessions"], apply: apply };
      },
    });
  } else if (typeof globalThis !== "undefined") {
    // 非浏览器/冒烟环境的测试钩子：让 node 侧能拿到工厂做行为验证。
    globalThis.__dshMiniDialogFactory = { name: "dsh-mini-dialog", inject: ["sessions"], apply: apply };
  }
})();
