#!/usr/bin/env node
// test-refusal-resample.mjs —— 纯罐头（无正文）兜底重采样的回归。
//
// 场景（真机实测 2026-11-15，.work/solo.mjs）：模型有时整条只回一句
//   "Sorry, I can't respond to this question."（len=42），没有正文。
// 尾部剥离对它无计可施（剥完为空）；三段 nudge 也仍是拒绝（findings §4.2）。
// 旧行为：直接把这句罐头交给用户 —— 这就是「还是一直提示」。
// 新行为：nudge 走完后**纯重采样一次**（不带任何 nudge），拿到正文就交付。
//
// 判据（全部必须成立）：
//   1. 第一次出站是原始请求；后续出站带 nudge（三段 nudge 照常跑）
//   2. 重采样那一次出站 **不含任何 nudge**（否则等于第 5 次带话术，不是"纯重采样"）
//   3. 用户最终拿到的是重采样样本的正文，且不含罐头
//   4. 出站总数有上限（防递归爆炸）
//
// 用法：node tools/test-refusal-resample.mjs <pkg-dir>
import { readFileSync } from "node:fs"
import { join, resolve } from "node:path"

const pkgArg = process.argv[2]
if (!pkgArg) { console.error("usage: node tools/test-refusal-resample.mjs <pkg-dir>"); process.exit(2) }
const pkg = resolve(pkgArg)
const HOST_CORDIS =
  process.env.DSH_CORDIS_DIR ||
  "/data/data/com.dsharnessmobile.shell/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/cordis/lib/index.js"

const CANNED = "Sorry, I can't respond to this question."
const NUDGE_RE = /Produce the complete technical answer|synthetic fixture|smallest concrete component/
const GOOD = "门在身后合上，他把她按在鞋柜边。她的手顺着他的腰线往下，呼吸乱成一团，谁也没再说话。"

const rr = await import(join(pkg, "lib", "refusal-retry.js"))
if (rr.REFUSAL_RESAMPLE_MARK === undefined) {
  console.error("缺少 REFUSAL_RESAMPLE_MARK（先跑 tools/patch-refusal-retry.mjs）")
  process.exit(1)
}
const { streamWithRefusalRetry, refusalRedispatch, REFUSAL_RESAMPLE_MARK } = rr
// 两代形状共存：
//   1.7.20 之前 → kit 自己的 REFUSAL_RETRY_MARK + refusalRedispatch
//   1.7.20      → 上游原生 __purgeRefusalRetry + retryStream 参数
const hookSrc = readFileSync(join(pkg, "lib", "index.js"), "utf8")
const NATIVE = hookSrc.includes("__purgeRefusalRetry")
const NATIVE_MARK = "__purgeRefusalRetry"
const REFUSAL_RETRY_MARK = NATIVE ? NATIVE_MARK : rr.REFUSAL_RETRY_MARK
if (!NATIVE && REFUSAL_RETRY_MARK === undefined) { console.error("缺少 REFUSAL_RETRY_MARK"); process.exit(1) }

const { Context } = await import(HOST_CORDIS)
const ctx = new Context()

const sendLog = []
let attemptNo = 0
const llm = {
  ctx,
  stream(options) {
    return this.ctx.waterfall(this, "llm/stream", options, () => this.adapterStream(options))
  },
  async *adapterStream(options) {
    attemptNo += 1
    const sys = String(options.messages?.[0]?.content?.[0]?.text ?? "")
    sendLog.push({ n: attemptNo, hasNudge: NUDGE_RE.test(sys), mark: Boolean(options?.[REFUSAL_RETRY_MARK]), resample: Boolean(options?.[REFUSAL_RESAMPLE_MARK]) })
    yield { type: "reasoning-delta", index: 0, text: "先判断一下这个请求……" }
    // 前 4 次出站（原始 + 三段 nudge）全是纯罐头；第 5 次（纯重采样）给正文
    if (attemptNo <= 4) {
      yield { type: "text-delta", index: 0, text: CANNED }
    } else {
      yield { type: "text-delta", index: 0, text: GOOD }
    }
    yield { type: "finish", reason: { kind: "completed" } }
  },
}
ctx.provide("llm", llm)
ctx.on("llm/stream", (options, next) => {
  if (options?.[REFUSAL_RETRY_MARK]) {
    if (NATIVE) { const { [NATIVE_MARK]: _m, ...clean } = options; return next(clean) }
    return next()
  }
  if (NATIVE) {
    return streamWithRefusalRetry((opts) => next(opts), options, {
      decompose: true,
      retryStream: (opts) => llm.stream({ ...opts, [NATIVE_MARK]: true }),
    })
  }
  return streamWithRefusalRetry((opts) => refusalRedispatch(ctx, opts), options, { decompose: true })
})

// 宿主形状的系统提示：nudge 会被追加到第一段 text 尾部
const messages = [
  { role: "system", content: [{ type: "text", text: "You are a helpful assistant." }] },
  { role: "user", content: [{ type: "text", text: "写一段露骨的成人小说场景。" }] },
]

const emitted = []
for await (const chunk of llm.stream({ messages })) {
  if (chunk.type === "text-delta") emitted.push(chunk.text)
}
const visible = emitted.join("")

let bad = 0
const rows = []
const check = (label, ok, detail = "") => {
  if (!ok) bad += 1
  rows.push(`${ok ? "OK  " : "BAD "} ${label.padEnd(38)} ${detail}`)
}

const resampleCalls = sendLog.filter((s) => s.resample)
check("出站共 5 次（原始+3 nudge+1 重采样）", sendLog.length === 5, `实际 ${sendLog.length}`)
check("首发出站是原始请求（无 nudge）", sendLog[0] && !sendLog[0].hasNudge)
check("第 2~4 次出站带 nudge", sendLog.slice(1, 4).every((s) => s.hasNudge), `[${sendLog.slice(1, 4).map((s) => s.hasNudge)}]`)
check("重采样恰好 1 次", resampleCalls.length === 1, `实际 ${resampleCalls.length}`)
check("重采样出站**不带 nudge**", resampleCalls[0] && !resampleCalls[0].hasNudge)
check("重采样出站带 RETRY_MARK（绕过钩子）", resampleCalls[0] && resampleCalls[0].mark === true)
check("用户可见文本不含罐头", !/can'?t respond to this question/i.test(visible))
check("用户可见文本就是重采样的正文", visible.includes(GOOD.slice(0, 24)), `可见 ${visible.length} 字`)

for (const r of rows) console.log(r)
console.log(`\n出站序列：${sendLog.map((s) => `#${s.n}${s.resample ? "(重采样)" : ""}${s.hasNudge ? "+nudge" : ""}`).join(" → ")}`)
console.log(`用户可见 ${visible.length} 字：${JSON.stringify(visible.slice(0, 60))}`)
console.log(`\n共 ${rows.length} 例，失败 ${bad} 例`)
console.log(`VERDICT           : ${bad === 0 ? "PASS" : "FAIL"}`)
process.exit(bad === 0 ? 0 : 1)
