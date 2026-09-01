// dsh-mini-dialog 冒烟测试
//
// 约束：不启动任何 node 后端实例、不访问 127.0.0.1。
//
// 策略说明（v0.2.0：client 脸已退役，focus 通道由 dsh-plugins-norm 承载）：
//   1. 语法正确（node --check lib/index.js）；
//   2. 宿主脸（index.js）在临时桩环境真实 import：@deepseek-ai/dsh-llm、
//     @deepseek-ai/dsh-session 用最小桩（只导出本插件确实用到的名字），
//     若导入名拼错这里就会 ERR_MODULE_NOT_FOUND / 无名导出而 FAIL；
//   3. 路由清单与关键语义断言（focus 走 norm 稳定面、无自有 WS 残留）。
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
{
  const target = join(root, "lib/index.js");
  const check = spawnSync(process.execPath, ["--check", target], { encoding: "utf8" });
  if (check.status === 0) pass("node --check lib/index.js");
  else {
    fail(`node --check lib/index.js 失败：${check.stderr}`);
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
      "/api/mini/reasoning",
    ]) {
      if (source.includes(path)) pass(`apply 注册了 ${path}`);
      else fail(`apply 缺少 ${path}`);
    }
    if (source.includes('ctx.get("dshPluginsNorm")')) pass("focus 经 norm 稳定面（ctx.get 惰性解析）");
    else fail("focus 未走 norm 稳定面");
    if (source.includes("norm.focus(sessionId)")) pass("focus 调用 norm.focus（含审计）");
    else fail("focus 未调用 norm.focus");
    if (source.includes("503")) pass("norm 缺席时返回 503 指引（不 fail-fast）");
    else fail("缺少 norm 缺席的 503 降级");
    const codeOnly = source.split("\n").filter((line) => !line.trimStart().startsWith("*") && !line.trimStart().startsWith("//")).join("\n");
    if (!codeOnly.includes("/api/mini/ws") && !codeOnly.includes("registerUpgrade")) {
      pass("v0.2.0：自有 WS 通道已退役（代码无残留，注释除外）");
    } else fail("代码仍残留自有 WS 通道");
    if (!source.includes("ws://127.0.0.1:3080")) pass("无硬编码回环端口（旧债清除）");
    else fail("仍硬编码 127.0.0.1:3080");
    if (source.includes("@deepseek-ai/dsh-llm") && source.includes("@deepseek-ai/dsh-session")) {
      pass("静态 import 走官方包名（dsh-llm / dsh-session）");
    } else fail("静态 import 未走官方包名");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ---- 3. 退役面清点 ----
{
  const { existsSync } = await import("node:fs");
  if (!existsSync(join(root, "lib/client.js"))) pass("lib/client.js 已退役");
  else fail("lib/client.js 仍存在（应已退役）");
  const pkg = JSON.parse((await (await import("node:fs/promises")).readFile(join(root, "package.json"), "utf8")));
  if (pkg.version === "0.2.0") pass("package.json version = 0.2.0");
  else fail(`package.json version 异常：${pkg.version}`);
  if (!pkg.dsh) pass("package.json 无 dsh.client 声明（client 脸退役）");
  else fail("package.json 仍带 dsh.client 声明");
  if (pkg.exports && pkg.exports["."] && !pkg.exports["./client"]) pass("exports 仅保留宿主入口");
  else fail("exports 异常（应仅保留宿主入口）");
}
