#!/usr/bin/env node
// ============================================================================
// api-push.mjs —— 用 GitHub Git Data API 把本地改动推到远端（本机 git push 不可靠的替代通道）
//
// 为什么需要它：本机直连 github.com 的 smart-http 常年不稳 —— 实测反复出现
//   fatal: unable to access ...: OpenSSL SSL_read: unexpected eof while reading
// 而 api.github.com 稳定（upstream-watch.mjs 的 publish 走同一通道，一直好用）。
// 所以本机侧「把结果写回仓库」的动作都不该依赖 git push。
//
// 取远端头指针也走 API（git ls-remote 同样会卡，且不受超时保护 —— 2026-11-13 实测踩到）。
// 推送用 base_tree 叠加，只带列出的路径，不 force、不动其它内容。
//
// 用法：
//   node port/tools/api-push.mjs                 # 推「工作树改动 + 已提交未推的改动」
//   node port/tools/api-push.mjs --dry           # 只列将推送的文件
//   node port/tools/api-push.mjs --path <p> ...  # 只推指定路径
//   node port/tools/api-push.mjs -m "提交说明"
//
// 退出码：0=成功或无变化／2=环境或 API 错误
// ============================================================================
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

const argv = process.argv.slice(2)
const has = (f) => argv.includes(f)
const opt = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d }

const REPO = opt('--repo', 'zhaolongwudi/dsh-mobile-apk')
const BRANCH = opt('--branch', 'main')
const DRY = has('--dry')
const MAX_BYTES = Number(opt('--max-bytes', String(1024 * 1024)))
const MSG = opt('-m', opt('--message', `port: 本地写回（${new Date().toISOString().slice(0, 16)}）`))

const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()

function token() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN
  const url = execFileSync('git', ['-C', ROOT, 'remote', 'get-url', 'origin'], { encoding: 'utf8' }).trim()
  const m = url.match(/^https?:\/\/[^/@]+:([^@]+)@/)
  return m ? m[1] : ''
}
const TK = token()
if (!TK) { console.error('✘ 无可用 GitHub 令牌'); process.exit(2) }

async function api(method, p, body) {
  const res = await fetch(`https://api.github.com${p}`, {
    method,
    headers: {
      Authorization: `Bearer ${TK}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60000),      // 没有超时的网络调用会把整条自动化挂死
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${p} → ${res.status} ${text.slice(0, 300)}`)
  return text ? JSON.parse(text) : {}
}

// ---- ① 远端头指针与树（API，带超时）----
const head = await api('GET', `/repos/${REPO}/git/ref/heads/${BRANCH}`)
const headSha = head.object.sha
const headCommit = await api('GET', `/repos/${REPO}/git/commits/${headSha}`)
const remoteTree = await api('GET', `/repos/${REPO}/git/trees/${headCommit.tree.sha}?recursive=1`)
const remote = new Map((remoteTree.tree || []).filter((t) => t.type === 'blob').map((t) => [t.path, t]))
console.log(`远端 ${BRANCH} = ${headSha.slice(0, 9)}（${remote.size} 个 blob）`)

// ---- ② 收集待推文件：工作树改动 + 已提交未推的改动 ----
const explicit = argv.reduce((acc, a, i) => (a === '--path' ? acc.concat(argv[i + 1]) : acc), [])
let files = []
if (explicit.length) {
  files = explicit.map((p) => path.relative(ROOT, path.resolve(ROOT, p)).replace(/\\/g, '/'))
} else {
  const st = execFileSync('git', ['-C', ROOT, 'status', '--porcelain'], { encoding: 'utf8' })
  for (const line of st.split('\n')) {
    if (!line.trim()) continue
    let p = line.slice(3).trim()
    if (p.includes(' -> ')) p = p.split(' -> ')[1]
    p = p.replace(/^"|"$/g, '')
    if (fs.existsSync(path.join(ROOT, p))) files.push(p)   // 删除不支持：避免误删远端文件
  }
  const unpushed = execFileSync('git', ['-C', ROOT, 'diff', '--name-only', `${headSha}..HEAD`], { encoding: 'utf8' })
  const extra = unpushed.split('\n').map((s) => s.trim()).filter(Boolean).filter((p) => fs.existsSync(path.join(ROOT, p)))
  if (extra.length) console.log(`  已提交未推的改动 ${extra.length} 个（按 ${headSha.slice(0, 9)}..HEAD 纳入）`)
  files = files.concat(extra)
}

const seen = new Set()
const picked = []
for (const rel of files) {
  if (seen.has(rel)) continue
  seen.add(rel)
  const abs = path.join(ROOT, rel)
  if (!fs.existsSync(abs) || !fs.statSync(abs).isFile()) continue
  const size = fs.statSync(abs).size
  if (size > MAX_BYTES) { console.log(`  跳过（>${(MAX_BYTES / 1048576).toFixed(1)}MB，疑似二进制载荷）：${rel} ${(size / 1048576).toFixed(1)}MB`); continue }
  picked.push({ rel, abs, buf: fs.readFileSync(abs) })
}

const gitBlobSha = (buf) => crypto.createHash('sha1').update(`blob ${buf.length}\0`).update(buf).digest('hex')
const changed = picked.filter((f) => {
  const r = remote.get(f.rel)
  if (r && r.sha === gitBlobSha(f.buf)) { console.log(`  远端内容已一致，跳过：${f.rel}`); return false }
  return true
})

if (!changed.length) { console.log('无待推送内容'); process.exit(0) }
console.log(`将推送 ${changed.length} 个文件：`)
for (const f of changed) console.log(`  ${f.rel} (${f.buf.length}B)`)
if (DRY) { console.log('（--dry：未写入远端）'); process.exit(0) }

// ---- ③ blob → tree(base_tree) → commit → 更新 ref ----
const entries = []
for (const f of changed) {
  const blob = await api('POST', `/repos/${REPO}/git/blobs`, { content: f.buf.toString('base64'), encoding: 'base64' })
  entries.push({ path: f.rel, mode: /\.sh$/.test(f.rel) ? '100755' : '100644', type: 'blob', sha: blob.sha })
  console.log(`  blob ${f.rel}`)
}
const tree = await api('POST', `/repos/${REPO}/git/trees`, { base_tree: headCommit.tree.sha, tree: entries })
const commit = await api('POST', `/repos/${REPO}/git/commits`, { message: MSG, tree: tree.sha, parents: [headSha] })
await api('PATCH', `/repos/${REPO}/git/refs/heads/${BRANCH}`, { sha: commit.sha })
console.log(`✔ 已推送：${headSha.slice(0, 9)} → ${commit.sha.slice(0, 9)}（${changed.length} 个文件）`)
console.log(`  https://github.com/${REPO}/commit/${commit.sha}`)
