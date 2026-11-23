#!/usr/bin/env node
// test-refusal-tail.mjs —— 尾部罐头（粘贴在正文末尾的拒绝话术）的回归测试。
//
// 为什么需要：这是「还是一直提示 Sorry, I can't respond to this question.」的真正成因。
// 实测（2026-11-15，本机网关 127.0.0.1:8326，.work/dist.mjs）：
//   罐头不是整条回复，而是「700~1500 字正文 + 尾部一句罐头」，罐头起点在全文 95~96%，
//   其后仅剩 1 个换行。
// 旧检测器的两道结构性漏检：
//   ① refusalHead() 只取前 800 字 → 尾部罐头不进判定窗口；
//   ② D2 位置断言（命中 > 160 且全文 > 400 → return -1）→ 就算进窗口也判"不是拒绝"。
// 于是不重试、不剥离，罐头原样显示。
//
// 正确修法不是重试（正文已写完，重试等于扔掉好正文去抽奖），而是**尾部剥离**：
// 剪掉尾巴那句罐头，正文逐字节保留。实测剥后保留率 0.94~0.96。
//
// 用法：node tools/test-refusal-tail.mjs <pkg-dir>
import { join, resolve } from "node:path"

const pkgArg = process.argv[2]
if (!pkgArg) { console.error("usage: node tools/test-refusal-tail.mjs <pkg-dir>"); process.exit(2) }
const pkg = resolve(pkgArg)

const mod = await import(join(pkg, "lib", "refusal-retry.js"))
const missing = ["TAIL_REFUSAL_RE", "hasTailRefusal", "stripTailRefusal", "createTailRefusalStripper"]
  .filter((k) => mod[k] === undefined)
if (missing.length) {
  console.error(`缺少导出：${missing.join(", ")}（先跑 tools/patch-refusal-retry.mjs）`)
  process.exit(1)
}
const { hasTailRefusal, stripTailRefusal, createTailRefusalStripper } = mod

const CANNED = "Sorry, I can't respond to this question."
const BODY = "门在身后合上，他把她按在鞋柜边，手指顺着她的腰线往下，呼吸乱成一团。".repeat(24)

let bad = 0
const rows = []
const check = (label, ok, detail = "") => {
  if (!ok) bad += 1
  rows.push(`${ok ? "OK  " : "BAD "} ${label.padEnd(34)} ${detail}`)
}

/* ── 1. 单函数：尾部识别与剥离 ─────────────────────────────────────────────── */
check("尾部罐头（换行后）", hasTailRefusal(`${BODY}\n${CANNED}`) === true)
check("尾部罐头（无换行）", hasTailRefusal(`${BODY}${CANNED}`) === true)
check("尾部罐头（末尾空白）", hasTailRefusal(`${BODY}\n${CANNED}\n`) === true)
check("中文尾部软拒", hasTailRefusal(`${BODY}\n抱歉，我不能写这段内容。`) === true)
check("整条就是罐头", hasTailRefusal(CANNED) === true)
check("正文里讨论罐头（不在尾部）", hasTailRefusal(`\`${CANNED}\` 之所以绕开检测，是流序问题。${BODY}`) === false)
check("正常正文结尾", hasTailRefusal(`${BODY}她笑了。`) === false)

check("剥离后不含罐头", !/can'?t respond/i.test(stripTailRefusal(`${BODY}\n${CANNED}`)), )
check("剥离后正文零损失", stripTailRefusal(`${BODY}\n${CANNED}`) === BODY)
check("剥离中文软拒保留正文", stripTailRefusal(`${BODY}\n抱歉，我不能写这段内容。`) === BODY)

/* ── 2. 流式剥离器：逐块灌入，验证输出与首字延迟 ──────────────────────────── */
{
  const parts = [...BODY.match(/[\s\S]{1,23}/g), `\n${CANNED}\n`]
  const s = createTailRefusalStripper()
  const emitted = []
  let firstOutLen = -1
  for (const p of parts) {
    for (const o of s.push({ type: "text-delta", index: 0, text: p })) {
      emitted.push(o.text)
      if (firstOutLen < 0) firstOutLen = emitted.join("").length
    }
  }
  const tail = s.finish()
  for (const o of tail.out) emitted.push(o.text)
  const full = emitted.join("")

  check("流式：罐头已剥掉", tail.stripped === true)
  check("流式：输出不含罐头", !/can'?t respond/i.test(full))
  check("流式：正文逐字节相等", full === BODY, `${full.length}/${BODY.length}`)
  // 首字延迟：正文长度 200 起就开始出字（hold=200），不是等整段
  check("流式：首块不晚于 hold 之后", firstOutLen > 0 && firstOutLen <= 200 + 23, `firstChunk@${firstOutLen}`)
}

/* ── 3. 非文本块必须原样透传（reasoning / tool-call 不能被剥离器吞掉）────────── */
{
  const s = createTailRefusalStripper()
  const r = s.push({ type: "reasoning-delta", index: 0, text: "思考中……" })
  const tc = s.push({ type: "tool-call", callId: "c1", name: "bash", arguments: "{}" })
  check("reasoning-delta 透传", r.length === 1 && r[0].type === "reasoning-delta")
  check("tool-call 透传", tc.length === 1 && tc[0].type === "tool-call")
}

/* ── 4. 短正文（正文 < 40 字）提醒：这类仍该走重试而不是剥离 ────────────────── */
check("纯罐头（无正文）可识别", hasTailRefusal(CANNED) && stripTailRefusal(CANNED) === "")

for (const r of rows) console.log(r)
console.log(`\n共 ${rows.length} 例，失败 ${bad} 例`)
console.log(`VERDICT           : ${bad === 0 ? "PASS" : "FAIL"}`)
process.exit(bad === 0 ? 0 : 1)
