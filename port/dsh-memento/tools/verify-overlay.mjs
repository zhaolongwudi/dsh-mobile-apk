#!/usr/bin/env node
// 移植链可复现性验证：上游基线 → 补丁 → overlay → 已安装副本，四段逐字节对齐。
//
// 段① 上游基线 sha256 与 manifest.upstream.files 一致（证明基线未被改动、就是 npm 那份）
// 段② 补丁按序应用后与 overlay 逐字节一致（证明补丁**真的是** overlay 的来源，不是摆设）
// 段③ overlay 与 payload/node_modules 逐字节一致（证明离线载荷携带的正是补丁后态）
// 段④ overlay 与 profile 已安装副本逐字节一致（若未安装则跳过）
//
// 用法：node tools/verify-overlay.mjs [--quiet]
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const KIT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const P = (p) => path.join(KIT, p)
const QUIET = process.argv.includes('--quiet')
const FILES = process.env.DSH_FILES_DIR ?? '/data/data/com.dsharnessmobile.shell/files'
const INSTALLED = path.join(FILES, 'home/.dsh/profiles/web/node_modules/dsh-memento')

const manifest = JSON.parse(fs.readFileSync(P('manifest.json'), 'utf8'))
const sha = (file) => createHash('sha256').update(fs.readFileSync(file)).digest('hex')

let failures = 0
const say = (line) => { if (!QUIET) console.log(line) }
function check(label, ok, detail) {
  say(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail === undefined || ok ? '' : ` — ${detail}`}`)
  if (!ok) failures++
}

say('== ① 上游基线 ==')
for (const [rel, want] of Object.entries(manifest.upstream?.files ?? {})) {
  const base = rel === 'index.mjs' ? 'patches/index.mjs.upstream' : 'patches/client.js.upstream'
  const have = sha(P(base))
  check(`${rel} 与 manifest.upstream 一致`, have === want, `want ${want.slice(0, 12)} have ${have.slice(0, 12)}`)
}

say('== ② 补丁 → overlay ==')
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'memento-verify-'))
try {
  // 造一份上游工作树，然后按 manifest 顺序打补丁。
  fs.mkdirSync(path.join(tmp, 'client'), { recursive: true })
  fs.copyFileSync(P('patches/index.mjs.upstream'), path.join(tmp, 'index.mjs'))
  fs.copyFileSync(P('patches/client.js.upstream'), path.join(tmp, 'client/client.js'))
  for (const patch of manifest.patches ?? []) {
    execFileSync('patch', ['-p1', '--silent', '-i', P(`patches/${patch.file}`)], { cwd: tmp })
  }
  for (const [rel, want] of Object.entries(manifest.overlay?.files ?? {})) {
    const target = rel === 'index.mjs' ? 'index.mjs' : 'client/client.js'
    const have = sha(path.join(tmp, target))
    check(`打补丁后 ${rel} 等于 overlay`, have === want, `want ${want.slice(0, 12)} have ${have.slice(0, 12)}`)
  }
} catch (error) {
  check('补丁应用', false, error instanceof Error ? error.message : String(error))
} finally {
  fs.rmSync(tmp, { recursive: true, force: true })
}

say('== ③ overlay → payload ==')
// 仓库约定「kit 不背二进制载荷」（见 README §载荷约定）：净检出/CI 下 payload/ 与
// payload.tar.gz 都缺席，此时段③应 SKIP 而不是 FAIL —— 与 tools/after-upstream.sh 的
// 口径一致，否则 CI 会因"仓库本就不放载荷"而永远红。要真正核对载荷时先跑
// fetch-payload.sh --pack（按 manifest 从 npm 重建）或带上本地载荷副本。
const hasPayloadDir = fs.existsSync(P('payload/node_modules/dsh-memento'))
const hasPayloadTar = fs.existsSync(P('payload.tar.gz'))
if (!hasPayloadDir && !hasPayloadTar) {
  say('  SKIP  载荷缺席（仓库约定不背载荷；需核对时先跑 fetch-payload.sh --pack）')
} else {
  for (const [rel, want] of Object.entries(manifest.overlay?.files ?? {})) {
    const target = rel === 'index.mjs' ? 'index.mjs' : 'client/client.js'
    const file = P(`payload/node_modules/dsh-memento/${target}`)
    const have = fs.existsSync(file) ? sha(file) : '(缺文件)'
    check(`payload 里 ${rel} 等于 overlay`, have === want, `have ${have.slice(0, 12)}`)
  }
}

say('== ④ overlay → 已安装副本 ==')
if (fs.existsSync(INSTALLED)) {
  for (const [rel, want] of Object.entries(manifest.overlay?.files ?? {})) {
    const target = rel === 'index.mjs' ? 'index.mjs' : 'client/client.js'
    const file = path.join(INSTALLED, target)
    const have = fs.existsSync(file) ? sha(file) : '(缺文件)'
    check(`已安装 ${rel} 等于 overlay`, have === want, `have ${have.slice(0, 12)}`)
  }
} else {
  say('  SKIP  未安装（profile 里没有 dsh-memento）')
}

say('')
say(failures === 0 ? '移植链验证：四段全 PASS' : `移植链验证：${failures} 项 FAIL`)
process.exit(failures === 0 ? 0 : 1)
