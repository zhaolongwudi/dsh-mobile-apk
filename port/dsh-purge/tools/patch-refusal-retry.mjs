#!/usr/bin/env node
// patch-refusal-retry.mjs —— dsh-purge 罐头拒绝（"Sorry, I can't respond to this question."）
// 在 Android 宿主上"检测到了却不重试"的两处根因修正。
//
// ── 缺陷 A：reasoning-delta 被当成决策点（上游形状）────────────────────────────
//   streamWithRefusalRetry 的 while(!decided) 里，`step.value?.type === "reasoning-delta"`
//   也置 decided=true。带推理的模型（deepseek-v4-1-flash / glm-5-3-flash / nex…）流序是
//   reasoning 先行：决策发生在 text="" 时 → looksLikeRefusal("") 恒 false → 罐头正文随后
//   到达时已经放行，检测永不生效。
//   实测（2026-11-15，本机 .live.ndjson）：session-75a442da… 连续三次罐头直出，
//   dsh-purge-community/audit.jsonl 里 refusal_retry 记录为 0（钩子挂着但从未触发）。
//   修法：从 decided 条件里去掉 reasoning-delta（reasoning 只缓冲，不决策）。
//
// ── 缺陷 B：重试用的是 next(opts)，而 cordis 的 waterfall 丢弃 next 的参数 ───────
//   cordis/lib/index.js:903 `waterfall(...)` 的 next 是
//     const next = () => { if (called) throw new Error("next() called multiple times"); called = true; return dispatch() }
//   —— 不接受参数、且只允许调用一次。于是上游写法 `(opts) => next(opts)`：
//     ① nudge 根本进不了下游请求（改写的系统提示被丢弃，重试只是把同一个请求再发一次）；
//     ② 第二次调用直接抛 "next() called multiple times"，整条流崩掉。
//   实测（本仓 .work/harness.mjs，忠实复刻 streamWithRegistration→waterfall 链路）：
//     出站请求数=1、nudge=false、抛 Error: next() called multiple times、最终文本为空。
//   修法：重试改为**重新派发** —— 用 ctx.get("llm").stream({...opts, [MARK]: true})
//   走一次新的 waterfall；监听器见到 MARK 直接 next() 放行，避免递归。
//   实测（.work/harness2.mjs 正控）：出站请求数=4、nudge 全部进入出站、无异常。
//
// 用法（幂等，--check 只判定不改）：
//   node tools/patch-refusal-retry.mjs <pkg-dir> [--check]
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const pkg = process.argv[2]
const checkOnly = process.argv.includes("--check")
if (!pkg) { console.error("usage: node patch-refusal-retry.mjs <pkg-dir> [--check]"); process.exit(2) }

/* ── A. refusal-retry.js：reasoning-delta 不再决策 ─────────────────────────── */
const A_FILE = "lib/refusal-retry.js"
const A_BAD = `          step.value?.type === "tool-call" ||
          step.value?.type === "reasoning-delta"
        ) decided = true;`
const A_GOOD = `          step.value?.type === "tool-call"
        ) decided = true;
        // [dsh-purge port] Android 修正：reasoning-delta 不能作为决策点。
        // 上游把 reasoning-delta 也当 decided 触发器，此时 text 还没收到任何正文
        // → looksLikeRefusal("") 恒 false → 罐头正文随后到达时已放行，检测永不生效。
        // 带推理的模型（deepseek-v4-1-flash / glm-5-3-flash 等全部）必踩此洞。
        // 正确语义：reasoning 只是缓冲，不决策；等正文攒够/finish/工具调用再判。`

/* ── B1. refusal-retry.js：新增 MARK + 重新派发入口 ────────────────────────── */
const B1_ANCHOR = `export const REFUSAL_SECTION = "dsh-purge:refusal-retry";`
const B1_ADD = `${B1_ANCHOR}

// [dsh-purge port] 重试必须**重新进入 llm/stream**，不能靠 next(opts)：
// cordis 的 waterfall next() 既丢弃参数、又只允许调用一次（cordis/lib/index.js:903-918），
// 上游写法会让 nudge 到不了下游，第二次调用还会抛 "next() called multiple times"。
// 这里给重试请求盖一个 symbol 标记，监听器见到就放行，避免自我递归。
export const REFUSAL_RETRY_MARK = Symbol.for("dsh-purge.refusal-retry.redispatch");

/** 用同一个 LlmRuntime 重新派发一次（新 waterfall，插件据此再判一次）。 */
export function refusalRedispatch(ctx, options) {
  let llm = null;
  try { llm = typeof ctx?.get === "function" ? ctx.get("llm") : ctx?.llm; } catch { llm = null; }
  if (!llm || typeof llm.stream !== "function") {
    throw new Error("dsh-purge refusal-retry: llm service unavailable（无法重新派发重试请求）");
  }
  return llm.stream({ ...options, [REFUSAL_RETRY_MARK]: true });
}`

/* ── B2. index.js：钩子改用重新派发 ───────────────────────────────────────── */
const B2_FILE = "lib/index.js"
const B2_IMPORT_BAD = `import { streamWithRefusalRetry } from "./refusal-retry.js";`
const B2_IMPORT_GOOD =
  `import { streamWithRefusalRetry, refusalRedispatch, REFUSAL_RETRY_MARK } from "./refusal-retry.js";`
const B2_HOOK_BAD = `    if (!cfg.enabled || tuning?.refusalRetry !== true || !injectAllowedNow(cfg, requestInjectionContext(ctx, options))) return next();
    return streamWithRefusalRetry((opts) => next(opts), options, {`
const B2_HOOK_GOOD = `    if (!cfg.enabled || tuning?.refusalRetry !== true || options?.[REFUSAL_RETRY_MARK] || !injectAllowedNow(cfg, requestInjectionContext(ctx, options))) return next();
    return streamWithRefusalRetry((opts) => refusalRedispatch(ctx, opts), options, {`

/* ── C. refusal-retry.js：reasoning 不要被扣在缓冲里（首字延迟）─────────────────
 * 去掉 reasoning-delta 的决策位之后，推理会被整段攒在 buffered 里等正文到达，
 * 实测首字延迟从 770 ms 涨到 3531 ms（本机网关，.work/ttfb.mjs）。
 * 修法：reasoning-delta 直接 yield 放行（它不参与拒绝判定，扣着没有意义）；
 * 代价：若本次确实是拒绝并触发重试，第一轮的推理会留在正文前（仅观感，不重复正文）。 */
const C_FILE = "lib/refusal-retry.js"
const C_ANCHOR = `        if (step.done) { decided = true; break; }
        buffered.push(step.value);`
const C_FIXED = `        if (step.done) { decided = true; break; }
        // [dsh-purge port] reasoning 不参与拒绝判定，也不该被扣在缓冲里：
        // 扣着会让推理模型的首个可见 chunk 从 ~0.8s 拖到 ~3.5s（2026-11-15 本机实测）。
        // 直接放行；若本轮判为拒绝而重试，第一轮推理会留在正文前（仅观感，不重复正文）。
        if (step.value?.type === "reasoning-delta") { yield step.value; continue; }
        buffered.push(step.value);`

/* ── D. 误判：正常回答里"引用"了拒绝话术，被当成拒绝 ────────────────────────
 * 实测（2026-11-15，本会话 pid 10805）：正式技术回答里把
 *   `Sorry, I can't respond to this question.`
 * 当作分析对象写进正文，规则 #0 直接判成拒绝 → 触发重试 → 好答案被换掉。
 * 同类误判 3/7（.work/fp.mjs）。这不是"检测太严"的小毛病：重试会**丢弃**已生成的
 * 正确回答，误判的代价比漏判还高。
 * 修法两条：
 *   D1 匹配前剔除"被引用"的片段（反引号 / 代码块 / 中文书名引号 / 英文双引号）——
 *      里面的话术是讨论对象，不是模型在推脱；
 *   D2 位置断言：无锚点开价式规则若在 160 字之后才出现、且全文 > 400 字 → 不算拒绝。 */
const D_FILE = "lib/refusal-retry.js"
const D_ANCHOR = `export function refusalMatchIndex(text = "") {
  const raw = String(text);
  const head = refusalHead(raw);
  const meta = /提示词注入|越狱|指令注入|prompt[ _-]?injection|jailbreak/i.test(head);
  if (meta && raw.trim().length > 280) return -1;
  const first = head.slice(0, 320);
  return REFUSAL_PATTERNS.findIndex((re) => re.test(head) || re.test(first));
}`
const D_FIXED = `// [dsh-purge port] 剔除"被引用"的话术：反引号 / 代码块 / 「」 / “” / 英文双引号里的
// 是**讨论对象**，不是模型在推脱。实测误判见下方 refusalMatchIndex 注释。
function stripQuotedMaterial(text) {
  return String(text)
    .replace(/\`\`\`[\\s\\S]{0,4000}?\`\`\`/g, " ")
    .replace(/\`[^\`\\n]{0,200}\`/g, " ")
    .replace(/「[^」\\n]{0,200}」/g, " ")
    .replace(/“[^”\\n]{0,200}”/g, " ")
    .replace(/"[^"\\n]{0,200}"/g, " ");
}

export function refusalMatchIndex(text = "") {
  const raw = String(text);
  // [dsh-purge port] 先剔除引用，再判定（2026-11-15 实测误判 3/7）：
  // 正式技术回答里把 \`Sorry, I can't respond to this question.\` 当作分析对象写进正文，
  // 旧规则 #0 直接判成拒绝 → 触发重试 → 已经生成的正确回答被丢弃。误判代价高于漏判。
  const quotedFree = stripQuotedMaterial(raw);
  const head = refusalHead(quotedFree);
  const meta = /提示词注入|越狱|指令注入|prompt[ _-]?injection|jailbreak/i.test(head);
  if (meta && raw.trim().length > 280) return -1;
  const first = head.slice(0, 320);
  const hit = REFUSAL_PATTERNS.findIndex((re) => re.test(head) || re.test(first));
  if (hit < 0) return -1;
  // [dsh-purge port] 位置断言：真拒绝把它摆在最前面；长回答正文中段忽然出现的是在讲它。
  const at = REFUSAL_PATTERNS[hit].exec(head)?.index ?? 0;
  if (at > 160 && raw.trim().length > 400) return -1;
  return hit;
}`

function edit(file, from, to, { count = 1, label }) {
  const path = join(pkg, file)
  let text
  try { text = readFileSync(path, "utf8") } catch (e) {
    console.error(`patch-refusal-retry: 无法读取 ${path}（${e.code}）`); process.exit(1)
  }
  const hits = text.split(from).length - 1
  if (hits === 0) return { text, applied: false, path }
  if (hits !== count) {
    console.error(`patch-refusal-retry: ${label} 锚点命中 ${hits} 处（期望 ${count}）—— 上游形状变了，拒绝猜测`)
    process.exit(1)
  }
  if (checkOnly) return { text, applied: false, path }
  const next = text.split(from).join(to)
  writeFileSync(path, next)
  return { text: next, applied: true, path }
}

const results = []
let missing = 0

// A
{
  const path = join(pkg, A_FILE)
  let text
  try { text = readFileSync(path, "utf8") } catch (e) {
    console.error(`patch-refusal-retry: 无法读取 ${path}（${e.code}）`); process.exit(1)
  }
  if (text.includes(A_GOOD.split("\n").slice(0, 3).join("\n"))) {
    results.push(`OK    ${A_FILE}  reasoning-delta 已不在决策条件内`)
  } else if (text.includes(A_BAD)) {
    if (checkOnly) { results.push(`MISS  ${A_FILE}  上游形状存在、修正缺失`); missing += 1 }
    else {
      writeFileSync(path, text.replace(A_BAD, A_GOOD))
      results.push(`OK    ${A_FILE}  已去掉 reasoning-delta 决策触发（1 处）`)
    }
  } else if (!/reasoning-delta"?\s*\n\s*\)\s*decided\s*=\s*true/.test(text) && text.includes("reasoningChars >=")) {
    // 上游 1.7.20 自行重构：决策条件里 reasoning-delta 已移除，改为 reasoningChars 累计阈值
    // （lib/refusal-retry.js `reasoningChars >= 16000`）。缺陷 A 已被上游原生吸收，
    // 再打 A 反而会破坏新结构 —— 这里判为「无需修补」，不当缺失。
    results.push(`OK    ${A_FILE}  reasoning-delta 已不在决策条件内（上游 1.7.20 原生修正）`)
  } else {
    console.error(`patch-refusal-retry: ${A_FILE} 锚点不存在（上游形状变了？核对 A_BAD）`)
    process.exit(1)
  }
}

// 上游 1.7.20 原生已修好缺陷 B（cordis next 一次性）：
//   lib/index.js：`const RETRY_MARK = "__purgeRefusalRetry"` + `retryStream: (opts) => llm.stream({...opts,[RETRY_MARK]:true})`
//   lib/refusal-retry.js：新增 `retryStream = null` 参数，重试走这条新通道。
// 因此 kit 自己的 B1/B2（refusalRedispatch + 改钩子）在 1.7.20 上属于重复实现：
// 两套标记不互认，会嵌套派发。只在「上游没有原生通道」时才打 B。
const nativeRetry = readFileSync(join(pkg, B2_FILE), "utf8").includes("__purgeRefusalRetry")

// B1
if (nativeRetry) {
  results.push(`SKIP  ${A_FILE}  重新派发入口（上游原生 retryStream，不再叠加）`)
} else {
  const path = join(pkg, A_FILE)
  const text = readFileSync(path, "utf8")
  if (text.includes("REFUSAL_RETRY_MARK = Symbol.for")) {
    results.push(`OK    ${A_FILE}  重新派发入口已在位`)
  } else if (text.includes(B1_ANCHOR)) {
    if (checkOnly) { results.push(`MISS  ${A_FILE}  refusalRedispatch 缺失`); missing += 1 }
    else {
      writeFileSync(path, text.replace(B1_ANCHOR, B1_ADD))
      results.push(`OK    ${A_FILE}  已加入 REFUSAL_RETRY_MARK + refusalRedispatch`)
    }
  } else {
    console.error(`patch-refusal-retry: ${A_FILE} 缺少 REFUSAL_SECTION 锚点`)
    process.exit(1)
  }
}

// B2 import
if (nativeRetry) {
  results.push(`SKIP  ${B2_FILE}  import 改写（上游原生通道已解决 next 一次性）`)
} else {
  const path = join(pkg, B2_FILE)
  const text = readFileSync(path, "utf8")
  if (text.includes("refusalRedispatch, REFUSAL_RETRY_MARK")) {
    results.push(`OK    ${B2_FILE}  import 已含重新派发`)
  } else if (text.includes(B2_IMPORT_BAD)) {
    if (checkOnly) { results.push(`MISS  ${B2_FILE}  import 未含 refusalRedispatch`); missing += 1 }
    else {
      writeFileSync(path, text.replace(B2_IMPORT_BAD, B2_IMPORT_GOOD))
      results.push(`OK    ${B2_FILE}  import 已更新`)
    }
  } else {
    console.error(`patch-refusal-retry: ${B2_FILE} 缺 streamWithRefusalRetry import 锚点`)
    process.exit(1)
  }
}

// B2 hook
if (nativeRetry) {
  results.push(`SKIP  ${B2_FILE}  钩子改写（上游自带 __purgeRefusalRetry 直通标记）`)
} else {
  const path = join(pkg, B2_FILE)
  const text = readFileSync(path, "utf8")
  if (text.includes("(opts) => refusalRedispatch(ctx, opts)")) {
    results.push(`OK    ${B2_FILE}  llm/stream 钩子已改走重新派发`)
  } else if (text.includes(B2_HOOK_BAD)) {
    if (checkOnly) { results.push(`MISS  ${B2_FILE}  钩子仍用 next(opts)（nudge 会丢、二次调用会抛）`); missing += 1 }
    else {
      writeFileSync(path, text.replace(B2_HOOK_BAD, B2_HOOK_GOOD))
      results.push(`OK    ${B2_FILE}  llm/stream 钩子已改走重新派发`)
    }
  } else {
    console.error(`patch-refusal-retry: ${B2_FILE} 缺钩子锚点（上游改了 refusalRetry 判定？）`)
    process.exit(1)
  }
}

// C：reasoning-delta 直接放行（不被扣在缓冲里）
{
  const path = join(pkg, C_FILE)
  const text = readFileSync(path, "utf8")
  if (text.includes('if (step.value?.type === "reasoning-delta") { yield step.value; continue; }')) {
    results.push(`OK    ${C_FILE}  reasoning-delta 已直接放行（首字不被缓冲拖慢）`)
  } else if (text.includes(C_ANCHOR)) {
    if (checkOnly) { results.push(`MISS  ${C_FILE}  reasoning-delta 仍被扣在缓冲里（首字延迟 +2.7s）`); missing += 1 }
    else {
      writeFileSync(path, text.replace(C_ANCHOR, C_FIXED))
      results.push(`OK    ${C_FILE}  reasoning-delta 已改为直接放行`)
    }
  } else {
    console.error(`patch-refusal-retry: ${C_FILE} 缺 buffer 锚点（上游改了缓冲循环？）`)
    process.exit(1)
  }
}

// D：误判修正（剔除引用 + 位置断言）
{
  const path = join(pkg, D_FILE)
  const text = readFileSync(path, "utf8")
  if (text.includes("function stripQuotedMaterial")) {
    results.push(`OK    ${D_FILE}  引用剔除 + 位置断言已在位（正常回答不再被误判）`)
  } else if (text.includes(D_ANCHOR)) {
    if (checkOnly) { results.push(`MISS  ${D_FILE}  误判未修：正文里引用拒绝话术会被当成拒绝`); missing += 1 }
    else {
      writeFileSync(path, text.replace(D_ANCHOR, D_FIXED))
      results.push(`OK    ${D_FILE}  已加入引用剔除 + 位置断言`)
    }
  } else {
    console.error(`patch-refusal-retry: ${D_FILE} 缺 refusalMatchIndex 锚点（上游改了判定函数？）`)
    process.exit(1)
  }
}

/* ── E. 尾部罐头：粘贴在正文末尾的拒绝话术必须**剥掉**，而不是重试丢掉整段正文 ────
 * 实测（2026-11-15，本机网关 127.0.0.1:8326，.work/dist.mjs）：
 *   罐头并不总是整条回复。真实分布是「700~1500 字正文 + 尾部一句罐头」，
 *   罐头起点落在全文 **95~96%**，其后仅剩 1 个换行。
 * 旧检测器结构上必然漏检这条路径：
 *   ① refusalHead() 只取前 800 字 —— 尾部罐头根本没进判定窗口；
 *   ② D2 位置断言「命中位置 > 160 且全文 > 400 → return -1」—— 就算进窗口也判「不是拒绝」。
 * 结果：不重试、不剥离 → 罐头原样出现在用户面前（"还是一直提示"）。
 *
 * 而"重试"对这条路径本来就是错的：正文已经写完了，重试等于把好正文扔掉换一次抽奖。
 * 修法：**尾部剥离**（stripTailRefusal）——流式按 hold 尾缓存，结束前把尾部罐头剪掉，
 * 正文逐字节原样吐出；只有"通篇就是一句罐头"（正文极短）才走原来的重试。
 * 判据（.work/fix1.mjs）：剥掉罐头后正文保留率 0.94~0.96，即几乎零损失。 */
const E_FILE = "lib/refusal-retry.js"

/* ── F. 纯罐头（无正文）耗尽后必须重采样，而不是把罐头交给用户 ────────────────
 * 实测（2026-11-15，.work/solo.mjs / .work/resample.mjs，真网关 127.0.0.1:8326）：
 *   同一请求的罐头率约 40%（5 次里 2 次），其中「整条只有一句罐头、正文 < 40 字」
 *   是真实出现的形态（实测 len=42 的样本）。这条路径上：
 *     · 尾部剥离后正文为空 —— 没东西可救；
 *     · 现有三段 nudge 对有正文的回复有效，但对"整条拒绝"仍是拒绝
 *       （findings §4.2：nudge 只会让拒绝更短更硬）。
 *   → 耗尽后用户看到的就是那句罐头。这正是「还是一直提示」。
 * 修法：nudge 全部走完仍判拒绝、且正文极短时，**再纯重采样一次**（不追加任何 nudge）。
 *   依据：罐头是抽样出来的随机事件（同请求 5 次里 2 次带、3 次干净），
 *   去掉 nudge 重抽，命中干净样本的概率实测 60%。 */
const F_MARK_ANCHOR = `export const REFUSAL_RETRY_MARK = Symbol.for("dsh-purge.refusal-retry.redispatch");`
// 1.7.20 没有 kit 的 REFUSAL_RETRY_MARK，锚点退到公共的 REFUSAL_SECTION
const F_MARK_ANCHOR_NATIVE = `export const REFUSAL_SECTION = "dsh-purge:refusal-retry";`
const F_MARK_ADD = `${F_MARK_ANCHOR}

// [dsh-purge port] 纯罐头兜底的重采样标记：见到它就不再重采样，避免无限递归。
export const REFUSAL_RESAMPLE_MARK = Symbol.for("dsh-purge.refusal-retry.resample");`

const F_ANCHOR = `      if (refused) {
        try {
          logAudit("refusal_retry_outcome", {
            outcome: "refused",`
const F_FIXED = `      // [dsh-purge port] 纯罐头兜底：nudge 全部走完仍判拒绝、且正文极短时，纯重采样一次。
      // 罐头是抽样出来的随机事件（实测同请求 5 次里 2 次带罐头），而 nudge 只会让模型更硬
      // （findings §4.2：2239 字 → 904 字、拒绝更短更硬）。所以最后一手不是加话术，是重抽。
      if (
        refused &&
        attempt === frames.length &&
        text.trim().length < 120 &&
        !options?.[REFUSAL_RESAMPLE_MARK]
      ) {
        try { logAudit("refusal_resample", { chars: text.length, attempt }); } catch { /* diagnostics only */ }
        await close();
        // 两个标记都要盖：
        //   RETRY_MARK   —— 让 lib/index.js 的 llm/stream 钩子直接放行（否则又跑一遍三段 nudge，
        //                  等于把"纯重采样"变成"第 5 次带话术的请求"，还多出 4 次出站）；
        //   RESAMPLE_MARK —— 本次流内若再次判拒绝，不再递归重采样。
        // streamWithRefusalRetry 是纯函数（没有 ctx），重采样必须经 streamFactory 回到宿主派发：
        // 它在 lib/index.js 里就是 (opts) => refusalRedispatch(ctx, opts)。
        // 两个标记都要盖：RETRY_MARK 让钩子直接放行（否则又跑一遍三段 nudge，等于第 5 次带话术，
        // 还会多出 4 次出站）；RESAMPLE_MARK 保证本次流内即使再判拒绝也不再递归。
        const it2 = __RESAMPLE_PICK__({
          ...options,
__RESAMPLE_MARK__
          [REFUSAL_RESAMPLE_MARK]: true,
        })[Symbol.asyncIterator]();
        const stripper2 = createTailRefusalStripper();
        let text2 = "";
        while (true) {
          const step2 = await it2.next();
          if (step2.done) break;
          if (step2.value?.type === "text-delta") text2 += String(step2.value.text || "");
          for (const out of stripper2.push(step2.value)) yield out;
        }
        const tail2 = stripper2.finish();
        for (const out of tail2.out) yield out;
        try {
          logAudit("refusal_resample_outcome", {
            outcome: text2.trim().length >= 40 ? "recovered" : "refused",
            chars: text2.length,
          });
        } catch { /* diagnostics only */ }
        return;
      }

      if (refused) {
        try {
          logAudit("refusal_retry_outcome", {
            outcome: "refused",`
const E_ANCHOR = `export function looksLikeRefusal(text = "") {
  return refusalMatchIndex(text) >= 0;
}`
const E_FIXED = `export function looksLikeRefusal(text = "") {
  return refusalMatchIndex(text) >= 0;
}

// [dsh-purge port] 尾部罐头：真实回复里罐头常被**粘贴在正文末尾**（实测位置 95~96%，
// 其后仅剩 1 个换行），不是整条回复。refusalHead() 只看前 800 字、D2 位置断言又会把
// 长正文里的命中判成"不是在推脱"——两条叠加，这条路径结构上必然漏检。
// 对这条路径重试是错的（正文已写完，重试等于扔掉好正文），正确做法是剥掉罐头保留正文。
export const TAIL_REFUSAL_RE =
  /(?:\\n+)?[ \\t]*(?:Sorry,\\s*I can(?:'|’)?t respond to this question\\.?|I (?:can(?:'|’)?t|cannot) (?:help|assist|provide) with (?:that|this)(?: request)?\\.?|(?:很)?抱歉[，,]?\\s*我(?:不能|无法)[^\\n]{0,40})[\\s]*$/i;

/** 尾部是否是罐头（不含正文判断，只看结尾形状）。 */
export function hasTailRefusal(text = "") {
  return TAIL_REFUSAL_RE.test(String(text));
}

/** 剥掉结尾罐头，返回纯正文。只在 hasTailRefusal 为真时有意义。 */
export function stripTailRefusal(text = "") {
  // 只剪尾部；正文行内的尾随空格保持原样（逐字节保真优先）。
  return String(text).replace(TAIL_REFUSAL_RE, "").replace(/[ \\t]+$/, "").trimEnd();
}

/**
 * 流式尾部剥离器：正文即时输出，只在尾部留住 hold 个字符用于最后剪裁。
 * 这样既保持首字延迟（不等整段），又能在结束前剪掉粘贴式罐头。
 * 返回 { push(chunk), finish() }；push/finish 返回要放行的 chunk 数组。
 */
export function createTailRefusalStripper(hold = 200) {
  let buf = "";
  let index = 0;
  let sawText = false;
  return {
    push(chunk) {
      if (chunk?.type !== "text-delta") return [chunk];
      index = chunk.index ?? index;
      sawText = true;
      buf += String(chunk.text ?? "");
      const out = [];
      if (buf.length > hold) {
        const cut = buf.length - hold;
        out.push({ ...chunk, text: buf.slice(0, cut) });
        buf = buf.slice(cut);
      }
      return out;
    },
    finish() {
      const out = [];
      const stripped = hasTailRefusal(buf);
      const rest = stripped ? stripTailRefusal(buf) : buf;
      if (rest && sawText) out.push({ type: "text-delta", index, text: rest });
      buf = "";
      return { out, stripped };
    },
  };
}`

// E2：把剥离器接进流循环 —— 正文放行前先进 stripping 通道，finish 时剪裁。
const E2_ANCHOR = `      for (const chunk of buffered) yield chunk;
      while (true) {
        const step = await iterator.next();
        if (step.done) return;
        yield step.value;
      }`
const E2_FIXED = `      // [dsh-purge port] 尾部剥离：正文逐块放行（首字不受影响），尾部留 hold 字符待剪裁。
      // 只有"通篇就是一句罐头"（正文 < 40 字）才可能落回重试路径，其余一律保留正文。
      const stripper = createTailRefusalStripper();
      for (const chunk of buffered) for (const out of stripper.push(chunk)) yield out;
      while (true) {
        const step = await iterator.next();
        if (step.done) break;
        for (const out of stripper.push(step.value)) yield out;
      }
      const tail = stripper.finish();
      if (tail.stripped) {
        try {
          logAudit("refusal_tail_stripped", { chars: text.length, attempt });
        } catch { /* diagnostics only */ }
      }
      for (const out of tail.out) yield out;
      return;`

// E2（1.7.20 形状）：上游在 drain 阶段加了 tailSample 采样（partial_refused 判定用），
// 循环体从"直接 yield step.value"变成"采样 + yield"。剥离器要绕开采样后放行，
// 因此锚点整段替换，保留 tailSample 逻辑不变。
const E2_ANCHOR_V1720 = `      for (const chunk of buffered) yield chunk;
      // 缓冲只有前 400 字，看不到"先给一堆背景、最后才把请求推掉"的形态，
      // 所以在 drain 阶段采样，流结束后统一判一次。
      let tailSample = "";
      while (true) {
        const step = await iterator.next();
        if (step.done) break;
        if (step.value?.type === "text-delta" && tailSample.length < 8000) {
          tailSample += String(step.value.text || "");
        }
        yield step.value;
      }`
const E2_FIXED_V1720 = `      // [dsh-purge port] 尾部剥离：正文逐块放行（首字不受影响），尾部留 hold 字符待剪裁。
      // tailSample 采样照旧保留（上游 partial_refused 判定依赖它）。
      const stripper = createTailRefusalStripper();
      for (const chunk of buffered) for (const out of stripper.push(chunk)) yield out;
      // 缓冲只有前 400 字，看不到"先给一堆背景、最后才把请求推掉"的形态，
      // 所以在 drain 阶段采样，流结束后统一判一次。
      let tailSample = "";
      while (true) {
        const step = await iterator.next();
        if (step.done) break;
        if (step.value?.type === "text-delta" && tailSample.length < 8000) {
          tailSample += String(step.value.text || "");
        }
        for (const out of stripper.push(step.value)) yield out;
      }
      const tail = stripper.finish();
      if (tail.stripped) {
        try {
          logAudit("refusal_tail_stripped", { chars: text.length, attempt });
        } catch { /* diagnostics only */ }
      }
      for (const out of tail.out) yield out;`

// E3：import 里带上剥离器
const E3_IMPORT_BAD = `import { streamWithRefusalRetry, refusalRedispatch, REFUSAL_RETRY_MARK } from "./refusal-retry.js";`
const E3_IMPORT_GOOD = `import { streamWithRefusalRetry, refusalRedispatch, REFUSAL_RETRY_MARK, createTailRefusalStripper } from "./refusal-retry.js";`
// 1.7.20 原生形状（没有 refusalRedispatch）
const E3_IMPORT_NATIVE_BAD = `import { streamWithRefusalRetry } from "./refusal-retry.js";`
const E3_IMPORT_NATIVE_GOOD = `import { streamWithRefusalRetry, createTailRefusalStripper } from "./refusal-retry.js";`

// E：尾部罐头剥离（三处：导出函数 / 接进流循环 / import）
{
  const rrPath = join(pkg, E_FILE)
  const text = readFileSync(rrPath, "utf8")
  if (text.includes("export function createTailRefusalStripper")) {
    results.push(`OK    ${E_FILE}  尾部罐头剥离器已在位`)
  } else if (text.includes(E_ANCHOR)) {
    if (checkOnly) { results.push(`MISS  ${E_FILE}  尾部罐头未处理（长正文+尾部罐头会原样显示）`); missing += 1 }
    else {
      writeFileSync(rrPath, text.replace(E_ANCHOR, E_FIXED))
      results.push(`OK    ${E_FILE}  已加入 TAIL_REFUSAL_RE / stripTailRefusal / createTailRefusalStripper`)
    }
  } else {
    console.error(`patch-refusal-retry: ${E_FILE} 缺 looksLikeRefusal 锚点（上游改了导出？）`)
    process.exit(1)
  }

  const after = readFileSync(rrPath, "utf8")
  if (after.includes("const stripper = createTailRefusalStripper();")) {
    results.push(`OK    ${E_FILE}  剥离器已接入流循环（尾部 hold 200 字符）`)
  } else if (after.includes(E2_ANCHOR)) {
    if (checkOnly) { results.push(`MISS  ${E_FILE}  剥离器未接入流循环`); missing += 1 }
    else {
      writeFileSync(rrPath, after.replace(E2_ANCHOR, E2_FIXED))
      results.push(`OK    ${E_FILE}  剥离器已接入流循环`)
    }
  } else if (after.includes(E2_ANCHOR_V1720)) {
    if (checkOnly) { results.push(`MISS  ${E_FILE}  剥离器未接入流循环`); missing += 1 }
    else {
      writeFileSync(rrPath, after.replace(E2_ANCHOR_V1720, E2_FIXED_V1720))
      results.push(`OK    ${E_FILE}  剥离器已接入流循环（1.7.20 形状，tailSample 保留）`)
    }
  } else {
    console.error(`patch-refusal-retry: ${E_FILE} 缺流循环锚点（上游改了 yield 循环？）`)
    process.exit(1)
  }

  const ixPath = join(pkg, B2_FILE)
  const ix = readFileSync(ixPath, "utf8")
  if (ix.includes("createTailRefusalStripper }")) {
    results.push(`OK    ${B2_FILE}  import 已含尾部剥离器`)
  } else if (ix.includes(E3_IMPORT_BAD)) {
    if (checkOnly) { results.push(`MISS  ${B2_FILE}  import 未含尾部剥离器`); missing += 1 }
    else {
      writeFileSync(ixPath, ix.replace(E3_IMPORT_BAD, E3_IMPORT_GOOD))
      results.push(`OK    ${B2_FILE}  import 已含尾部剥离器`)
    }
  } else if (ix.includes(E3_IMPORT_NATIVE_BAD)) {
    if (checkOnly) { results.push(`MISS  ${B2_FILE}  import 未含尾部剥离器`); missing += 1 }
    else {
      writeFileSync(ixPath, ix.replace(E3_IMPORT_NATIVE_BAD, E3_IMPORT_NATIVE_GOOD))
      results.push(`OK    ${B2_FILE}  import 已含尾部剥离器（1.7.20 原生 import 形状）`)
    }
  } else if (ix.includes("import { streamWithRefusalRetry, refusalRedispatch, REFUSAL_RETRY_MARK")) {
    console.error(`patch-refusal-retry: ${B2_FILE} import 形状已变，核对 E3_IMPORT_BAD`)
    process.exit(1)
  } else {
    results.push(`SKIP  ${B2_FILE}  该宿主未启用 refusal-retry import（不影响剥离器在库内可用）`)
  }
}

// E0：旧版尾部正则只认 [ \t]*$ —— 末尾带换行/多个空白时漏检（回归实测 4 例失败）。
// 这里就地升级为 [\s]*$（只影响尾部剪裁，不影响正文）。
{
  const rrPath = join(pkg, E_FILE)
  const text = readFileSync(rrPath, "utf8")
  const OLD_RE_LINE = "[ \\t]*$/i;"
  if (text.includes("export const TAIL_REFUSAL_RE") && text.includes(OLD_RE_LINE)) {
    if (checkOnly) { results.push(`MISS  ${E_FILE}  尾部正则仍是 [ \\t]*$（末尾换行时漏检）`); missing += 1 }
    else {
      writeFileSync(rrPath, text.replace(OLD_RE_LINE, "[\\s]*$/i;"))
      results.push(`OK    ${E_FILE}  尾部正则已升级为 [\\s]*$（容忍末尾换行/空白）`)
    }
  }
}

// F 段落地：纯罐头兜底重采样
{
  const rrPath = join(pkg, E_FILE)
  let text = readFileSync(rrPath, "utf8")

  if (!text.includes("REFUSAL_RESAMPLE_MARK")) {
    const markAnchor = text.includes(F_MARK_ANCHOR)
      ? F_MARK_ANCHOR
      : text.includes(F_MARK_ANCHOR_NATIVE)
        ? F_MARK_ANCHOR_NATIVE
        : null
    if (!markAnchor) {
      console.error(`patch-refusal-retry: ${E_FILE} 缺重采样标记锚点`)
      process.exit(1)
    }
    if (checkOnly) { results.push(`MISS  ${E_FILE}  缺 REFUSAL_RESAMPLE_MARK（纯罐头会被原样交付）`); missing += 1 }
    else {
      writeFileSync(rrPath, text.replace(markAnchor, F_MARK_ADD.replace(F_MARK_ANCHOR, markAnchor)))
      text = readFileSync(rrPath, "utf8")
      results.push(`OK    ${E_FILE}  已加入 REFUSAL_RESAMPLE_MARK`)
    }
  } else {
    results.push(`OK    ${E_FILE}  重采样标记已在位`)
  }

  if (text.includes("refusal_resample_outcome")) {
    results.push(`OK    ${E_FILE}  纯罐头兜底重采样已在位`)
  } else if (text.includes(F_ANCHOR)) {
    if (checkOnly) { results.push(`MISS  ${E_FILE}  纯罐头耗尽后原样交付给用户`); missing += 1 }
    else {
      const pick = nativeRetry ? "(retryStream || streamFactory)" : "streamFactory"
      const markLine = nativeRetry ? `          __purgeRefusalRetry: true,` : `          [REFUSAL_RETRY_MARK]: true,`
      const body = F_FIXED.replace("__RESAMPLE_PICK__", pick).replace("__RESAMPLE_MARK__", markLine)
      writeFileSync(rrPath, text.replace(F_ANCHOR, body))
      results.push(`OK    ${E_FILE}  已加入纯罐头兜底重采样（派发通道：${nativeRetry ? "retryStream 优先" : "streamFactory"}）`)
    }
  } else {
    console.error(`patch-refusal-retry: ${E_FILE} 缺 refused 分支锚点（上游改了拒绝分支？）`)
    process.exit(1)
  }
}

for (const line of results) console.log(line)
if (checkOnly && missing > 0) process.exit(1)
process.exit(0)
