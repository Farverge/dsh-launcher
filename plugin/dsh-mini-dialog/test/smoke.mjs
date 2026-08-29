// dsh-mini-dialog 冒烟测试
//
// 约束：不启动任何 node 后端实例、不访问 127.0.0.1:3080。
//
// 策略说明：
//   Cordis 未运行时直接 import 模块本身不会触发 apply()（inject 解析发生在
//   服务挂载期），因此这里验证三件事：
//     1. 语法正确（node --check，覆盖 lib/index.js 与 lib/client.js）；
//     2. 宿主脸（index.js）在临时桩环境真实 import：@deepseek-ai/dsh-llm、
//       @deepseek-ai/dsh-session 用最小桩（只导出本插件确实用到的名字），
//       若导入名拼错这里就会 ERR_MODULE_NOT_FOUND / 无名导出而 FAIL；
//     3. 客户端脸（client.js）可直接 import 且导出面正确（inject=['sessions']、
//       apply 可调用并返回 disposer；apply 在无 WebSocket 全局的 Node 下自降级）。
//   桩名与官方源码核对过：createUserMessage 来自 packages/llm/llm/src/message.ts，
//   SessionId 来自 packages/core/session/src/types.ts。
//
// 输出：逐项 PASS/FAIL，任一 FAIL 则进程退出码非 0。

import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

const pass = (msg) => console.log(`PASS ${msg}`);
const fail = (msg) => {
  console.log(`FAIL ${msg}`);
  process.exitCode = 1;
};

// ---- 1. 语法检查 ----
for (const file of ["lib/index.js", "lib/client.js"]) {
  const target = join(root, file);
  const check = spawnSync(process.execPath, ["--check", target], { encoding: "utf8" });
  if (check.status === 0) pass(`node --check ${file}`);
  else {
    fail(`node --check ${file} 失败：${check.stderr}`);
    process.exit(1);
  }
}

// ---- 2. 宿主脸：桩环境真实 import ----
{
  const dir = mkdtempSync(join(tmpdir(), "dsh-mini-dialog-smoke-"));
  try {
    const nodeModules = join(dir, "node_modules");
    const stubs = [
      {
        specifier: "@deepseek-ai/dsh-llm",
        code: `export function createUserMessage(input) {
  return { ...input, role: "user", id: "msg-" + Math.random().toString(36).slice(2) };
}`,
      },
      {
        specifier: "@deepseek-ai/dsh-session",
        code: `export function SessionId(id) {
  return id;
}`,
      },
    ];
    for (const { specifier, code } of stubs) {
      const pkgDir = join(nodeModules, specifier);
      mkdirSync(pkgDir, { recursive: true });
      writeFileSync(join(pkgDir, "package.json"), JSON.stringify({
        name: specifier,
        type: "module",
        main: "index.js",
      }, null, 2));
      writeFileSync(join(pkgDir, "index.js"), code);
    }

    const copyTarget = join(dir, "index.mjs");
    copyFileSync(join(root, "lib/index.js"), copyTarget);

    const mod = await import(copyTarget);
    if (mod.name === "dsh-mini-dialog") pass("导出 name === 'dsh-mini-dialog'");
    else fail(`导出 name 异常：${String(mod.name)}`);
    if (Array.isArray(mod.inject) && mod.inject.includes("webServer") && mod.inject.includes("agents")) {
      pass(`导出 inject === ['webServer', 'agents']`);
    } else fail(`导出 inject 异常：${JSON.stringify(mod.inject)}`);
    if (typeof mod.apply === "function") pass("导出 apply 为函数（未触发——无 Cordis 运行时）");
    else fail("导出 apply 不是函数");

    const source = await (await import("node:fs/promises")).readFile(copyTarget, "utf8");
    for (const path of [
      "/api/mini/session.new",
      "/api/mini/session.send",
      "/api/mini/focus",
      "/api/mini/options",
      "/api/mini/ws",
    ]) {
      if (source.includes(path)) pass(`apply 注册了 ${path}`);
      else fail(`apply 缺少 ${path}`);
    }
    if (source.includes("registerUpgrade")) pass("使用了 ctx.webServer.registerUpgrade（ws 通道）");
    else fail("缺少 ctx.webServer.registerUpgrade");
    if (source.includes("ctx.remote.$on") || source.includes("API_REMOTE_FORWARDED_EVENTS")) {
      pass("头注说明了为何不用 ctx.remote.$on（白名单不可扩展）");
    } else fail("缺少 ctx.remote.$on 白名单说明");
    if (source.includes("@deepseek-ai/dsh-llm") && source.includes("@deepseek-ai/dsh-session")) {
      pass("静态 import 走官方包名（dsh-llm / dsh-session）");
    } else fail("静态 import 未走官方包名");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ---- 3. 客户端脸：脚本形态加载 + 工厂捕获校验 ----
// client.js 是 classic 脚本（__ModuleLoader__ 协议，审查 P0-1），无 ESM 导出。
// Node 下执行时走测试钩子：globalThis.__dshMiniDialogFactory 捕获工厂产物。
{
  delete globalThis.__dshMiniDialogFactory;
  await import(new URL("../lib/client.js", import.meta.url));
  const factory = globalThis.__dshMiniDialogFactory;
  if (factory && Array.isArray(factory.inject) && factory.inject.includes("sessions")) {
    pass("client 工厂 inject 包含 'sessions'");
  } else fail(`client 工厂 inject 异常：${JSON.stringify(factory?.inject)}`);
  if (factory && typeof factory.apply === "function") {
    // apply 在 Node（无 WebSocket 全局、无 document）下应自降级不抛错，
    // 并返回卸载 disposer（Cordis 插件卸载契约）。
    let disposer = null;
    try {
      disposer = factory.apply({});
    } catch (error) {
      fail(`client.apply 不应抛错：${error.message}`);
    }
    if (typeof disposer === "function") {
      pass("client.apply 返回 disposer 函数");
      disposer(); // 幂等：调用一遍确认不抛
      pass("client disposer 调用不抛错");
    } else {
      fail(`client.apply 应返回 disposer，实际为 ${typeof disposer}`);
    }
  } else {
    fail("client.apply 不是函数");
  }
  const source = await (await import("node:fs/promises")).readFile(join(root, "lib/client.js"), "utf8");
  if (source.includes("window.__ModuleLoader__.load")) pass("client 按官方 __ModuleLoader__.load 协议自我注册");
  else fail("client 缺少 __ModuleLoader__.load 注册");
  if (source.includes("ctx.sessions.open")) pass("client 使用了 ctx.sessions.open（选中会话）");
  else fail("client 缺少 ctx.sessions.open");
  if (source.includes("ctx.sessions.list.getSnapshot().byId")) pass("client 有 open 前 byId 预检");
  else fail("client 缺少 byId 预检");
  if (source.includes("ctx.sessions.refresh")) pass("client 有 refresh 重查");
  else fail("client 缺少 refresh 重查");
  if (source.includes("ws://127.0.0.1:3080/api/mini/ws")) pass("client 连接 /api/mini/ws");
  else fail("client 缺少 ws://127.0.0.1:3080/api/mini/ws");
  if (source.includes("RECONNECT_MAX_MS")) pass("client 断线指数退避重连");
  else fail("client 缺少退避重连逻辑");
}
