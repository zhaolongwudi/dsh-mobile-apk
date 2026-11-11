#!/usr/bin/env node
/**
 * patch-android-exec.mjs —— 让插件「内部再执行 node」的路径在 Android 上不崩。
 *
 * 真因（本机实测，不是推演）
 * -------------------------
 * 本机 node 跑在 Termux 快照里，termux-exec 的 LD_PRELOAD 会把 exec 重路由到
 * linker，于是 **process.execPath 被报成 /apex/com.android.runtime/bin/linker64**：
 *     node -e 'console.log(process.execPath)'   ->  /apex/com.android.runtime/bin/linker64
 *     node -e 'require("node:child_process").execFileSync(process.execPath,["-e","1"])'
 *       ->  Command failed: /apex/…/linker64 -e 1
 *           error: expected absolute path: "-e"
 * 而真实解释器在 /data/data/com.dsharnessmobile.shell/files/usr/bin/node（实测可直接 spawn 成功）。
 * 所以插件里凡 `spawn(process.execPath, …)` / `execFile(process.execPath, …)` 都必崩。
 *
 * 上游不改（我们不动上游仓库，也不指望它适配 Android），帧内改不了调用点，
 * 就只能在**载荷落盘的瞬间**打一层可重入补丁：把这几处 `process.execPath` 换成一个
 * 解析式——先看环境变量 PURGE_NODE_EXEC，再用本机实测的绝对路径（安装时烧进去），
 * 该路径不存在时回落到 process.execPath（即恢复上游行为，不会比现在更坏）。
 *
 * 受影响的功能（不打这层补丁就是坏的）
 * -----------------------------------
 *   lib/web.js                 面板「重启引擎」的分离助手进程
 *   lib/rollback-transaction.js 维护回滚事务里的干净进程校验（回滚按钮）
 *   lib/redteam/ui.js          红队演练台的重启脚本
 *   bin/community.js           community.js 的 LEGACY 转发（port.sh 已绕开它）
 *
 * 锚点纪律
 * --------
 * 每个文件声明**期望出现次数**：数量不符 = 上游改了形状 → 明确失败退出 1，
 * 不猜、不半打、不静默跳过。上游版本一升，先看这里报哪一行，再决定新锚点。
 *
 * 有意不动的（写清理由，避免下次有人「顺手全改」）
 * ----------------------------------------------
 *   lib/desktop.js / lib/macos-asar-handoff.js / lib/surface.js / lib/instance.js
 *     —— 桌面 / Electron / macOS 路径，Web 宿主不入口
 *   lib/core.js:99,106 —— npm-cli 路径（path.dirname(process.execPath)/node_modules/npm/…）：
 *     在 Android 上本来就取不到，但那是**插件自升级**路径，本机更新走 port.sh sync
 *   lib/index.js:999-1007 —— 官方桌面升级标记，读 linker 路径无害
 *
 * 用法（幂等：已是目标状态则什么都不写）
 *   node tools/patch-android-exec.mjs <pkg-dir> [--node <绝对路径>] [--check]
 *   --check  只判定，不写盘；已打上 = rc 0，缺/漂移 = rc 1（guard.sh 与 verify 用它）
 */
import { readFileSync, writeFileSync, existsSync, copyFileSync, mkdtempSync, rmSync } from "node:fs"
import { join, basename } from "node:path"
import { execFileSync } from "node:child_process"
import { tmpdir } from "node:os"

const MARKER = "PURGE_NODE_EXEC"
const EXPR = (baked) =>
  `(process.env.${MARKER}||((process.getBuiltinModule&&process.getBuiltinModule("node:fs").existsSync(${JSON.stringify(baked)}))?${JSON.stringify(baked)}:process.execPath))`

/** 锚点表：相对包根的文件 → 期望的 process.execPath 出现次数（= 需要改写的调用点） */
const ANCHORS = {
  "lib/web.js": 3,
  "lib/rollback-transaction.js": 1,
  "lib/redteam/ui.js": 1,
  "bin/community.js": 1,
}

const argv = process.argv.slice(2)
const check = argv.includes("--check")
const ni = argv.indexOf("--node")
const pkgDir = argv.find((a, i) => !a.startsWith("--") && !(ni >= 0 && i === ni + 1))
const baked = (ni >= 0 ? argv[ni + 1] : "") || "/data/data/com.dsharnessmobile.shell/files/usr/bin/node"

const fail = (m) => {
  console.error(`patch-android-exec: ${m}`)
  process.exit(1)
}
if (!pkgDir) fail("用法：node tools/patch-android-exec.mjs <pkg-dir> [--node <绝对路径>] [--check]")
if (!existsSync(join(pkgDir, "package.json"))) fail(`不是插件包目录：${pkgDir}`)
if (!baked.startsWith("/")) fail(`--node 必须是绝对路径（实得 ${baked}）`)
if (!existsSync(baked)) console.error(`patch-android-exec: 警告：${baked} 当前不存在（补丁仍会打，运行时会回落到 process.execPath）`)

const rows = []
let bad = 0
for (const [rel, expect] of Object.entries(ANCHORS)) {
  const file = join(pkgDir, rel)
  if (!existsSync(file)) {
    rows.push({ rel, state: "缺文件", oc: "-", ok: false })
    bad++
    continue
  }
  const src = readFileSync(file, "utf8")
  const occurrences = (src.match(/process\.execPath/g) || []).length
  const marks = (src.match(new RegExp(MARKER, "g")) || []).length

  if (marks === expect && occurrences === expect) {
    rows.push({ rel, state: "已打上", oc: occurrences, ok: true })
    continue
  }
  if (occurrences !== expect) {
    rows.push({ rel, state: `锚点搬家（期望 ${expect} 处，实得 ${occurrences} 处）`, oc: occurrences, ok: false })
    bad++
    continue
  }
  // 形状对得上 → 打补丁（或只判定）
  const next = src.replace(/process\.execPath/g, EXPR(baked))
  if (check) {
    rows.push({ rel, state: "未打（--check 不写盘）", oc: occurrences, ok: false })
    bad++
    continue
  }
  // 语法自证：拷成 .mjs 走 node --check（纯解析，不执行）
  const tmp = mkdtempSync(join(tmpdir(), "purge-exec-"))
  try {
    const probe = join(tmp, basename(rel).replace(/\.js$/, "") + ".mjs")
    writeFileSync(probe, next)
    execFileSync(baked, ["--check", probe], { stdio: "pipe" })
  } catch (e) {
    rmSync(tmp, { recursive: true, force: true })
    rows.push({ rel, state: `改写后语法检查失败：${String(e.stderr || e.message).split("\n")[0]}`, oc: occurrences, ok: false })
    bad++
    continue
  }
  rmSync(tmp, { recursive: true, force: true })
  writeFileSync(file, next)
  rows.push({ rel, state: "已打上", oc: occurrences, ok: true })
}

const width = Math.max(...rows.map((r) => r.rel.length))
if (!check) {
  for (const r of rows) console.log(`  ${r.ok ? "OK  " : "FAIL"}  ${r.rel.padEnd(width)}  ${r.state}  (execPath×${r.oc})`)
  console.log(`  node=${baked}`)
  console.log(
    bad === 0
      ? "  Android 执行器补丁：全部在位（面板重启 / 回滚 / 演练台 / community.js 转发可用）"
      : `  Android 执行器补丁：${bad} 个文件未达目标状态`,
  )
}
process.exit(bad === 0 ? 0 : 1)
