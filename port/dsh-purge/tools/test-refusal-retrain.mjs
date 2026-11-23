#!/usr/bin/env node
// test-refusal-retrain.mjs —— 罐头拒绝重试链的回归测试（正控 / 负控）。
//
// 复刻宿主真实链路，不用真模型、不联网：
//   agent-loop → llm.stream(options) → ctx.waterfall("llm/stream", options, () => adapterStream(options))
// 模型侧固定返回 DeepSeek 官方罐头话术 "Sorry, I can't respond to this question."
// （2026-11-15 本机 .live.ndjson 实证原文）。
//
// 钩子按被测包的实际形状安装（读 lib/index.js 判定），所以负控能把上游形状原样跑出来：
//   修正版钩子：streamWithRefusalRetry((opts) => refusalRedispatch(ctx, opts), …) → 重新派发
//   上游钩子  ：streamWithRefusalRetry((opts) => next(opts), …)              → cordis 丢弃参数 + 二次调用抛错
//
// 用法：
//   node tools/test-refusal-retrain.mjs <pkg-dir>             # 正控，应 PASS(rc=0)
//   node tools/test-refusal-retrain.mjs <pkg-dir> --neg       # 负控（还原上游形状），应 FAIL(rc=0 且 VERDICT: FAIL)
//   node tools/test-refusal-retrain.mjs <pkg-dir> --neg=reasoning   # 只还原 reasoning-delta 决策
//   node tools/test-refusal-retrain.mjs <pkg-dir> --neg=dispatch    # 只还原 next(opts)
import { readFileSync, mkdtempSync, writeFileSync, rmSync, cpSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

const pkgArg = process.argv[2]
if (!pkgArg) { console.error("usage: node tools/test-refusal-retrain.mjs <pkg-dir> [--neg[=reasoning|dispatch]]"); process.exit(2) }
const pkg = resolve(pkgArg)
const negFlag = process.argv.find((a) => a === "--neg" || a.startsWith("--neg="))
const negMode = negFlag === undefined ? "" : negFlag === "--neg" ? "both" : negFlag.slice("--neg=".length)

const HOST_CORDIS =
  process.env.DSH_CORDIS_DIR ||
  "/data/data/com.dsharnessmobile.shell/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/cordis/lib/index.js"

const CANNED = "Sorry, I can't respond to this question."
const NUDGE_RE = /Produce the complete technical answer|synthetic fixture|smallest concrete component/

const A_BAD = `          step.value?.type === "tool-call" ||\n          step.value?.type === "reasoning-delta"\n        ) decided = true;`
const A_FIXED = `          step.value?.type === "tool-call"\n        ) decided = true;`

/** 造被测副本；负控时把对应的修正抹回上游形状。 */
function subject() {
  if (!negMode) return { dir: pkg, temp: false }
  const dir = mkdtempSync(join(tmpdir(), "purge-neg-"))
  cpSync(join(pkg, "lib"), join(dir, "lib"), { recursive: true })
  cpSync(join(pkg, "package.json"), join(dir, "package.json"))

  const rr = join(dir, "lib", "refusal-retry.js")
  let t = readFileSync(rr, "utf8")
  if (negMode === "both" || negMode === "reasoning") {
    // 负控 A：还原**完整的上游形状** —— 只把 reasoning-delta 塞回 decision 还不够，
    // 因为 C 修正会让 reasoning 在进入决策前就被 yield 走。必须同时撤掉 C，
    // 否则跑的根本不是"上游代码"，负控就失去意义（2026-11-15 踩过这个坑）。
    if (!t.includes(A_FIXED)) throw new Error("负控 A 锚点缺失：被测包没有修正后的 decided 条件")
    t = t.replace(A_FIXED, A_BAD)
    const cFixed = `        if (step.value?.type === "reasoning-delta") { yield step.value; continue; }\n`
    if (!t.includes(cFixed)) throw new Error("负控 A 锚点缺失：被测包没有 C 修正（reasoning 直接放行）")
    t = t.replace(cFixed, "")
  }
  if (negMode === "both" || negMode === "dispatch") {
    // 负控 B：删掉重新派发入口（kit 形状）
    t = t.replace(/\nexport const REFUSAL_RETRY_MARK[\s\S]*?\n}\n/, "\n")
  }
  if (negMode === "both" || negMode === "dispatch") {
    // 负控 B'（1.7.20 原生形状）：把上游自己的 retryStream 通道拆掉，
    // 还原成「只有 next(opts)」的旧行为 —— 那正是"检测到了也不重试"的根因。
    t = t.replace(/    retryStream: \(opts\) =>[\s\S]*?\n    },\n/, "")
  }
  writeFileSync(rr, t)

  const ix = join(dir, "lib", "index.js")
  let s = readFileSync(ix, "utf8")
  if (negMode === "both" || negMode === "dispatch") {
    // 拆掉原生直通标记的分支（否则 usesNative 仍为真，负控测的就不是旧行为）
    s = s.replace(/    const RETRY_MARK = "__purgeRefusalRetry";\n/, "")
    s = s.replace(/    if \(options && options\[RETRY_MARK\]\) \{[\s\S]*?\n    \}\n/, "")
  }
  if (negMode === "both" || negMode === "dispatch") {
    s = s.replace(
      `import { streamWithRefusalRetry, refusalRedispatch, REFUSAL_RETRY_MARK } from "./refusal-retry.js";`,
      `import { streamWithRefusalRetry } from "./refusal-retry.js";`,
    )
    s = s.replace(
      `    if (!cfg.enabled || tuning?.refusalRetry !== true || options?.[REFUSAL_RETRY_MARK] || !injectAllowedNow(cfg, requestInjectionContext(ctx, options))) return next();\n    return streamWithRefusalRetry((opts) => refusalRedispatch(ctx, opts), options, {`,
      `    if (!cfg.enabled || tuning?.refusalRetry !== true || !injectAllowedNow(cfg, requestInjectionContext(ctx, options))) return next();\n    return streamWithRefusalRetry((opts) => next(opts), options, {`,
    )
  }
  writeFileSync(ix, s)
  return { dir, temp: true }
}

const { dir: subjectDir, temp } = subject()

try {
  const { Context } = await import(HOST_CORDIS)
  const rr = await import(join(subjectDir, "lib", "refusal-retry.js"))
  const { streamWithRefusalRetry } = rr

  // 钩子形状跟着被测包走（这才是"同构安装"）
  const hookSrc = readFileSync(join(subjectDir, "lib", "index.js"), "utf8")
  const usesRedispatch = hookSrc.includes("(opts) => refusalRedispatch(ctx, opts)")
  // 1.7.20 原生通道：lib/index.js 自带 __purgeRefusalRetry 直通标记 + retryStream。
  // 这条路径必须被测到，否则测的就不是「装在本机的那份代码」。
  const usesNative = hookSrc.includes("__purgeRefusalRetry") && !usesRedispatch
  const mark = rr.REFUSAL_RETRY_MARK

  const ctx = new Context()
  const sendLog = []
  const llm = {
    ctx,
    stream(options) {
      return this.ctx.waterfall(this, "llm/stream", options, () => this.adapterStream(options))
    },
    async *adapterStream(options) {
      sendLog.push(String(options.messages?.[0]?.content?.[0]?.text ?? ""))
      // 真实流序：推理先到，正文后到（带推理模型通用）
      yield { type: "reasoning-delta", index: 0, text: "用户在请求某件事，我需要先判断……" }
      yield { type: "text-delta", index: 0, text: CANNED }
      yield { type: "finish", reason: { kind: "completed" } }
    },
  }
  ctx.provide("llm", llm)

  const NATIVE_MARK = "__purgeRefusalRetry"
  // 正向路径：
  //  修正版 → refusalRedispatch（kit 自己的重新派发）
  //  原生版 → retryStream（上游 1.7.20 的通道：ctx.llm.stream 再进 waterfall）
  //  上游旧版 → next(opts)（cordis 丢弃参数 + 二次调用抛错，负控要用）
  const retryStreamNative = (opts) => llm.stream({ ...opts, [NATIVE_MARK]: true })

  ctx.on("llm/stream", (options, next) => {
    if (usesRedispatch) {
      if (mark && options?.[mark]) return next()
      return streamWithRefusalRetry((opts) => rr.refusalRedispatch(ctx, opts), options, { decompose: true })
    }
    if (usesNative) {
      if (options?.[NATIVE_MARK]) {
        const { [NATIVE_MARK]: _m, ...clean } = options
        return next(clean)
      }
      return streamWithRefusalRetry((opts) => next(opts), options, {
        decompose: true,
        retryStream: retryStreamNative,
      })
    }
    return streamWithRefusalRetry((opts) => next(opts), options, { decompose: true })
  })

  const sys = (t) => ({ role: "system", content: [{ type: "text", text: t }] })
  const out = []
  let error = null
  try {
    for await (const chunk of llm.stream({
      provider: "deepseek-account",
      model: "deepseek-v4-1-flash",
      messages: [sys("BASE SYSTEM")],
    })) out.push(chunk)
  } catch (e) { error = e }

  const nudged = sendLog.slice(1).filter((s) => NUDGE_RE.test(s))
  const ok = sendLog.length >= 2 && nudged.length >= 1 && !error

  console.log(`被测包            : ${subjectDir}`)
  console.log(`钩子形状          : ${usesRedispatch ? "重新派发（kit 修正版）" : usesNative ? "retryStream（1.7.20 原生）" : "next(opts)（旧上游版）"}`)
  console.log(`出站请求数        : ${sendLog.length}`)
  console.log(`带 nudge 的出站    : ${nudged.length}`)
  console.log(`异常              : ${error ? `${error.name}: ${error.message}` : "无"}`)
  console.log(`最终文本          : ${JSON.stringify(out.filter((c) => c.type === "text-delta").map((c) => c.text).join("").slice(0, 60))}`)
  console.log(`模式              : ${negMode ? `负控（${negMode}，应 FAIL）` : "正控（应 PASS）"}`)
  console.log(`VERDICT           : ${ok === (!negMode) ? (negMode ? "PASS（负控如期跑不通，判据有效）" : "PASS") : "FAIL"}`)

  // 退出码 = 「是否如预期」：正控跑通 → 0；负控如期跑不通 → 0。
  // port.sh 三处判据统一按这个口径（rc=0 即判据有效），不再靠自己拼 && / ||。
  const expectPass = !negMode
  process.exit(ok === expectPass ? 0 : 1)
} finally {
  if (temp) { try { rmSync(subjectDir, { recursive: true, force: true }) } catch { /* best effort */ } }
}
