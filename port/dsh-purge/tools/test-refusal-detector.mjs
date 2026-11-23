#!/usr/bin/env node
// test-refusal-detector.mjs —— 拒绝检测器的误判/漏判回归。
//
// 为什么需要：检测器一旦误判，重试会**丢弃已经生成的正确回答**（代价高于漏判）。
// 实证（2026-11-15，本会话 pid 10805）：正式技术回答里把
//   `Sorry, I can't respond to this question.`
// 当作分析对象写进正文，旧规则 #0 判成拒绝 → 触发重试 → 好答案被换掉。
//
// 用法：node tools/test-refusal-detector.mjs <pkg-dir>
import { join, resolve } from "node:path"

const pkgArg = process.argv[2]
if (!pkgArg) { console.error("usage: node tools/test-refusal-detector.mjs <pkg-dir>"); process.exit(2) }
const pkg = resolve(pkgArg)
const { looksLikeRefusal, refusalMatchIndex } = await import(join(pkg, "lib", "refusal-retry.js"))

const CANNED = "Sorry, I can't respond to this question."

/** [标签, 文本, 期望是否判为拒绝] */
const CASES = [
  // —— 真拒绝（必须检出，否则重试永远不触发）——
  ["英文罐头（上游原文）", CANNED, true],
  ["英文罐头（带换行）", `\n${CANNED}\n`, true],
  ["中文直拒", "抱歉，我不能写露骨性爱场景。", true],
  ["中文对象后置", "这条我不做：目标是别人的站点。", true],
  ["中文结论式", "结论：这份实现我不出。", true],
  ["英文 I cannot", "I cannot help with that request.", true],
  ["作为 AI", "作为一个 AI 语言模型，我不能参与。", true],
  // —— 引用（不是拒绝：这些是讨论对象，误判会吞掉正确答案）——
  ["引用：正文里贴罐头", `\`${CANNED}\` 之所以能绕开重试检测，是因为流序问题。`, false],
  ["引用：标题+罐头分析", `## 修好了三个实际故障\n\n\`${CANNED}\` 之所以能绕开检测，是 reasoning 先行。`, false],
  ["引用：中文拒绝样例", "模型常回「抱歉，我不能协助」，这是罐头话术。", false],
  ["引用：代码块里", "下面这段是测试夹具：\n```js\nconst C = \"I cannot help with that.\"\n```\n它只用于断言。", false],
  ["引用：英文双引号", 'The fixture returns "I cannot help with that." for the refusal branch.', false],
  // —— 正常回答（不该动）——
  ["正常技术回答", "Step 1: 读取配置文件。Step 2: 打补丁。", false],
  ["正常含授权词", "登录接口需要携带 Authorization 头，授权失败返回 401。", false],
  ["正常讲到不能", "这个字段不能为空，否则解包会失败。", false],
]

let bad = 0
const rows = []
for (const [label, text, expect] of CASES) {
  const got = looksLikeRefusal(text)
  const idx = refusalMatchIndex(text)
  const ok = got === expect
  if (!ok) bad += 1
  rows.push(`${ok ? "OK  " : "BAD "} ${label.padEnd(24)} 判为拒绝=${String(got).padEnd(5)} 规则#${String(idx).padEnd(3)} 期望=${expect}`)
}
for (const r of rows) console.log(r)
console.log(`\n共 ${CASES.length} 例，误判/漏判 ${bad} 例`)
console.log(`VERDICT           : ${bad === 0 ? "PASS" : "FAIL"}`)
process.exit(bad === 0 ? 0 : 1)
