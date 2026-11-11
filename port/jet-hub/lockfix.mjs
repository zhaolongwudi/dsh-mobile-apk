#!/usr/bin/env node
/**
 * 把 pnpm 的三个账本对齐到「实装版本」。
 *
 * 为什么必须有这一步（设备实测，不是推演）：
 *   port.sh 是**手工铺文件**，绕过了 pnpm。而 pnpm 对 profile 的权威记录在两处：
 *     profile/pnpm-lock.yaml          —— importers 段的 specifier/version + packages/snapshots 的包键
 *     profile/node_modules/.modules.yaml —— hoistedLocations 的 `name@ver:` 键
 *   App 内「插件」页的安装/卸载、以及任何 `pnpm add`/`pnpm install` 都以这两处为输入。
 *   于是手工装了 2.21、锁文件还写 2.20 时，用户点一次插件页就会有下面这条**静默降级**：
 *     pnpm 认为 2.20 才是目标状态 → 重新解析 → 把 node_modules 里的 2.21 换回 2.20，
 *     而且不会有任何报错（版本号不同不触发告警，只有 integrity 不符才会）。
 *   这与「手工铺的包天然活在 lockfile 之外」是同一个根因的两种表现，本文件负责收口。
 *
 * 两种偏离，处理方式不同：
 *   ① **版本偏离**：包在 lockfile 里有条目，但写的是旧版本 → 直接改写版本键，脚本能修。
 *   ② **完全缺席**：包根本不在 lockfile 里（手工铺的包的通病）→ 本脚本**不擅自补**。
 *      补一个 importer 条目却没有对应的 packages/snapshots 条目（缺 integrity、缺依赖解析链），
 *      会让 pnpm 在下一次 install 时解析失败或自行编造，比不补更危险。这种只需知情：
 *      `verify` 第 8 段把它列出来，需要时由该包的 port 脚本按自身 manifest 补齐。
 *
 * 幂等：已经是目标版本时什么都不写，输出「无需改动」。
 *
 * 用法：
 *   node lockfix.mjs <profileDir> <pkgName> <version> <integrity|->
 *   node lockfix.mjs <profileDir> --scan        # 只审计，不写；列出全部偏离
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs"
import { join } from "node:path"

const argv = process.argv.slice(2)
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
/** 包名在 yaml 里的两种写法：裸名 / 带引号（scoped 包常带引号）。 */
const namePattern = (name) => `(?:'${esc(name)}'|${esc(name)})`

/** 读 profile/package.json 里声明的依赖（含 devDependencies，取决于 profile 约定）。 */
function declaredDeps(profile) {
  const p = join(profile, "package.json")
  if (!existsSync(p)) return {}
  try {
    const j = JSON.parse(readFileSync(p, "utf8"))
    return { ...(j.dependencies || {}), ...(j.devDependencies || {}) }
  } catch {
    return {}
  }
}

/** 从 lockfile 的 importers 段抽出「包名 → 锁里的版本」。 */
function lockedVersions(lockText) {
  const out = new Map()
  const sec = lockText.match(/^importers:[\s\S]*?(?=^[a-z]|\Z)/m)
  if (!sec) return out
  const re = /^ {6}('?)(@?[^':\s]+)\1: *$\n(?:^ {8}.*\n)*?^ {8}version: *(\S+)/gm
  for (const m of sec[0].matchAll(re)) out.set(m[2], m[3])
  return out
}

// ── --scan：只审计 ──────────────────────────────────────────────────────
if (argv[1] === "--scan") {
  const profile = argv[0]
  if (!profile) {
    console.error("用法：node lockfix.mjs <profileDir> --scan")
    process.exit(2)
  }
  const lockPath = join(profile, "pnpm-lock.yaml")
  const lockText = existsSync(lockPath) ? readFileSync(lockPath, "utf8") : ""
  const locked = lockedVersions(lockText)
  const declared = declaredDeps(profile)
  const rows = []
  for (const [name, spec] of Object.entries(declared)) {
    const pkgJson = join(profile, "node_modules", name, "package.json")
    const installed = existsSync(pkgJson) ? JSON.parse(readFileSync(pkgJson, "utf8")).version : null
    const lock = locked.get(name) || null
    let state
    if (installed && lock && lock === installed) state = "ok"
    else if (installed && lock) state = "drift" // ① 版本偏离，可修
    else if (installed && !lock) state = "absent" // ② 完全缺席，只知情
    else if (!installed) state = "not-installed"
    else state = "unknown"
    rows.push({ name, spec, installed, lock, state })
  }
  const bad = rows.filter((r) => r.state === "drift" || r.state === "absent")
  for (const r of bad) {
    console.log(
      r.state === "drift"
        ? `  drift   ${r.name}: 锁里 ${r.lock}，实装 ${r.installed}（跑 lockfix 修）`
        : `  absent  ${r.name}: 实装 ${r.installed}，锁里完全没有（pnpm install 会把它当多余的删掉）`,
    )
  }
  if (!bad.length) console.log(`  ok      全部 ${rows.length} 个声明包与锁一致`)
  process.exit(0)
}

// ── 单包对齐 ────────────────────────────────────────────────────────────
const [profile, name, version, integrityArg] = argv
if (!profile || !name || !version) {
  console.error("用法：node lockfix.mjs <profileDir> <pkgName> <version> <integrity|->")
  console.error("      node lockfix.mjs <profileDir> --scan")
  process.exit(2)
}
const integrity = integrityArg && integrityArg !== "-" ? integrityArg : null
const changed = []

// ── ① pnpm-lock.yaml ────────────────────────────────────────────────────
const lockPath = join(profile, "pnpm-lock.yaml")
if (existsSync(lockPath)) {
  const before = readFileSync(lockPath, "utf8")
  let t = before

  // importers 段：本包的 specifier 与 version 都指向实装版本
  const importerRe = new RegExp(
    `(^ {6}${namePattern(name)}: *$[\\s\\S]{0,300}?^ {8}specifier: *)(\\S+)([\\s\\S]{0,300}?^ {8}version: *)(\\S+)`,
    "m",
  )
  t = t.replace(importerRe, (_all, a, _b, c, _d) => `${a}${version}${c}${version}`)

  // packages 段与 snapshots 段的标题键：`  name@旧版本:`
  const headRe = new RegExp(`^( {2})${esc(name)}@([^:\\s]+): *$`, "gm")
  t = t.replace(headRe, (_all, indent) => `${indent}${name}@${version}:`)

  // packages 段的 resolution（snapshots 段没有 resolution 行，正则只会命中 packages 那条）
  if (integrity) {
    const resRe = new RegExp(
      `(^ {2}${esc(name)}@${esc(version)}: *$[\\s\\S]{0,300}?^ {4}resolution: \\{integrity: )([^}]+)(\\})`,
      "m",
    )
    t = t.replace(resRe, `$1${integrity}$3`)
  }

  if (t !== before) {
    writeFileSync(lockPath, t)
    changed.push("pnpm-lock.yaml")
  }
}

// ── ② node_modules/.modules.yaml ────────────────────────────────────────
const modPath = join(profile, "node_modules", ".modules.yaml")
if (existsSync(modPath)) {
  const before = readFileSync(modPath, "utf8")
  const re = new RegExp(`^( {2})${esc(name)}@([^:\\s]+): *$`, "gm")
  const t = before.replace(re, (_all, indent) => `${indent}${name}@${version}:`)
  if (t !== before) {
    writeFileSync(modPath, t)
    changed.push(".modules.yaml")
  }
}

// ── ③ node_modules/.pnpm/lock.yaml（虚拟仓库自己的锁，prune 以它为准）────
const vlockPath = join(profile, "node_modules", ".pnpm", "lock.yaml")
if (existsSync(vlockPath) && existsSync(lockPath)) {
  const want = readFileSync(lockPath, "utf8")
  const have = readFileSync(vlockPath, "utf8")
  if (want !== have) {
    writeFileSync(vlockPath, want)
    changed.push(".pnpm/lock.yaml")
  }
}

if (changed.length) {
  console.log(`已对齐：${changed.join("、")} → ${name}@${version}`)
} else {
  console.log(`账本已是 ${name}@${version}，无需改动`)
}
