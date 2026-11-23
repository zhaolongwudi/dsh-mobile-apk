#!/usr/bin/env node
// test-refusal-host-integration.mjs —— 用**真实宿主 LlmRuntime**（dsh-llm）+ 真实插件模块跑一遍，
// 验证重新派发在真引擎里成立：adapter 注册、callConfig 解析、waterfall、frozen options 全走真代码。
//
// 与 test-refusal-retrain.mjs 的分工：
//   retrain        —— 用最小 ctx 复刻链路形状，快、判据清晰（正控/负控）
//   host-integration —— 上真 LlmRuntime，证明不是"只有我的假 harness 能跑"
//
// 用法：node tools/test-refusal-host-integration.mjs <pkg-dir>
import { join, resolve } from "node:path"
import { readFileSync } from "node:fs"

const pkgArg = process.argv[2]
if (!pkgArg) { console.error("usage: node tools/test-refusal-host-integration.mjs <pkg-dir>"); process.exit(2) }
const pkg = resolve(pkgArg)

const HOST = process.env.DSH_HOST_PACKAGES ||
  "/data/data/com.dsharnessmobile.shell/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai"
const CORDIS = `${HOST}/cordis/lib/index.js`
const DSH_LLM = `${HOST}/dsh-llm/lib/index.js`

const CANNED = "Sorry, I can't respond to this question."
const NUDGE_RE = /Produce the complete technical answer|synthetic fixture|smallest concrete component/

const { Context } = await import(CORDIS)
const { LlmRuntime, LlmAdapter } = await import(DSH_LLM)
const rrMod = await import(join(pkg, "lib", "refusal-retry.js"))
const { streamWithRefusalRetry, refusalRedispatch } = rrMod
const hookSrc = readFileSync(join(pkg, "lib", "index.js"), "utf8")
const NATIVE = hookSrc.includes("__purgeRefusalRetry")
const NATIVE_MARK = "__purgeRefusalRetry"
const REFUSAL_RETRY_MARK = NATIVE ? NATIVE_MARK : rrMod.REFUSAL_RETRY_MARK

const sendLog = []
class CannedAdapter extends LlmAdapter {
  constructor(ctx) { super(ctx, CANNED); this.ctx = ctx }
  listModels() { return [{ id: "canned-model", name: "canned-model", contextWindow: 65536, defaultMaxTokens: 4096 }] }
  async *stream(options) {
    sendLog.push(String(options.messages?.[0]?.content?.[0]?.text ?? ""))
    yield { type: "reasoning-delta", index: 0, text: "用户在请求……" }
    yield { type: "text-delta", index: 0, text: CANNED }
    yield { type: "finish", reason: { kind: "completed" } }
  }
}

const ctx = new Context()
const llm = new LlmRuntime(ctx)
try { llm.ctx.registerAdapter(["canned"], new CannedAdapter(llm.ctx)) } catch (e) {
  // 老接口名兜底
  llm.registerAdapter(["canned"], new CannedAdapter(llm.ctx))
}

// 与 lib/index.js 补丁后同构的钩子
ctx.on("llm/stream", (options, next) => {
  if (options?.[REFUSAL_RETRY_MARK]) {
    if (NATIVE) { const { [NATIVE_MARK]: _m, ...clean } = options; return next(clean) }
    return next()
  }
  if (NATIVE) {
    return streamWithRefusalRetry((opts) => next(opts), options, {
      decompose: true,
      retryStream: (o) => llm.stream({ ...o, [NATIVE_MARK]: true }),
    })
  }
  return streamWithRefusalRetry((opts) => refusalRedispatch(ctx, opts), options, { decompose: true })
})

const sys = (t) => ({ role: "system", content: [{ type: "text", text: t }] })
const out = []
let error = null
try {
  for await (const chunk of llm.stream({
    provider: "canned",
    model: "canned-model",
    messages: [sys("BASE SYSTEM")],
  })) out.push(chunk)
} catch (e) { error = e }

const nudged = sendLog.slice(1).filter((s) => NUDGE_RE.test(s))
const ok = sendLog.length >= 2 && nudged.length >= 1 && !error
console.log(`宿主 LlmRuntime   : ${DSH_LLM}`)
console.log(`出站请求数        : ${sendLog.length}`)
console.log(`带 nudge 的出站    : ${nudged.length}`)
console.log(`chunk 总数        : ${out.length}`)
console.log(`异常              : ${error ? `${error.name}: ${error.message}` : "无"}`)
console.log(`最终文本          : ${JSON.stringify(out.filter((c) => c.type === "text-delta").map((c) => c.text).join("").slice(0, 60))}`)
console.log(`VERDICT           : ${ok ? "PASS" : "FAIL"}`)
process.exit(ok ? 0 : 1)
