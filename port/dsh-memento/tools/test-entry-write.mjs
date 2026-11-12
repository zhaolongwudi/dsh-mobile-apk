// 面板条目写路由离线端到端自测：真 sqlite 存储 + 假 ctx/webServer/res。
//
// 覆盖（18 项）：
//   ① add 新增（workspace 层带键）：落盘、返回 entryId 与 usage、审计行 action=add
//   ② add 缺 workspaceKey（scope=workspace）→ 400 且零写入：绝不写进空键黑洞
//   ③ add 空文本 → 400
//   ④ add user-global：不需要 workspaceKey，全局可见
//   ⑤ replace：按旧全文定位改文本，返回 usage，审计行 action=replace
//   ⑥ replace 定位不存在 → 409 ENTRY_NOT_FOUND 且原文不变
//   ⑦ replace 多命中 → 409 AMBIGUOUS_MATCH
//   ⑧ remove：删掉目标，审计行 action=remove，用量回落
//   ⑨ 非 POST → 405；未知 op → 400
//   ⑩ 会话级 never → 403 且零写入
//   ⑪ GET /api/memento/entries 现在带 workspaces 与 writePolicy 两个事实字段
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const ROOT = process.env.MEMENTO_ROOT
  ?? '/data/data/com.dsharnessmobile.shell/files/home/.dsh/profiles/web/node_modules/dsh-memento'
const { openMemoryStore } = await import(pathToFileURL(path.join(ROOT, 'lib/store.mjs')).href)
const { MemoryService, registerWebRoutes } = await import(pathToFileURL(path.join(ROOT, 'index.mjs')).href)

const dbPath = path.join(os.tmpdir(), `memento-entry-write-${Date.now()}.db`)
const store = openMemoryStore(dbPath, { retentionDays: 30 })

const service = new MemoryService({
  store,
  budgets: { user: { userGlobal: 2000, workspace: 2000 }, agent: { userGlobal: 4000, workspace: 4000 } },
  writePolicy: 'auto',
  maxEntriesPerQuery: 20,
  commandListLimit: 50,
  commandAuditLimit: 20,
  language: 'zh',
  approval: { request: async () => 'allowed-once' },
  sourceLabel: 'dsh-memento',
})

function mount({ sessions, approval } = {}) {
  const routes = new Map()
  const ctx = {
    get(name) {
      if (name === 'connection') return { requestRejection: () => undefined }
      if (name === 'webServer') return { register: (route) => { routes.set(route.path, route); return () => routes.delete(route.path) } }
      if (name === 'sessions') return sessions
      return undefined
    },
    ...(approval === undefined ? {} : { approval }),
    effect(fn) { const d = fn(); return () => { if (typeof d === 'function') d() } },
    on() { return () => {} },
  }
  registerWebRoutes(ctx, service, { panelEntriesLimit: 200, panelAuditLimit: 20, panel: { enabled: true }, language: 'zh' })
  return async (route, method, body) => {
    const listeners = new Map()
    const req = { method, url: route, headers: {}, on(event, cb) { listeners.set(event, cb); return req } }
    setImmediate(() => {
      if (body !== undefined) listeners.get('data')?.(Buffer.from(JSON.stringify(body)))
      listeners.get('end')?.()
    })
    const res = { status: 0, headers: null, body: '', writeHead(s, h) { res.status = s; res.headers = h }, end(b) { res.body = b } }
    const handler = routes.get(route)?.handler
    if (handler === undefined) throw new Error(`route not registered: ${route}`)
    await handler(req, res)
    let json = null
    try { json = res.body ? JSON.parse(res.body) : null } catch { json = { raw: res.body } }
    return { status: res.status, json }
  }
}

const WRITE = '/api/memento/entry-write'
const ENTRIES = '/api/memento/entries'
const out = []
const call = mount({ sessions: { list: () => [{ id: 's1', header: { cwd: '/w/alpha' } }] } })
const entriesOf = (track, scope) => store.queryEntries({ track, scope, limit: 50 }).entries

// ── ① add（workspace 带键） ──
const a1 = await call(WRITE, 'POST', { op: 'add', track: 'agent', scope: 'workspace', workspaceKey: '/w/alpha', text: '用户偏好：中文回复。' })
out.push(['add ok', `${a1.status} ${JSON.stringify(a1.json.usage)}`])
out.push(['add landed', String(entriesOf('agent', 'workspace').length)])
out.push(['add audit', String(store.auditList(20).find((r) => r.action === 'add')?.outcome)])

// ── ② add 缺 workspaceKey → 400 且零写入 ──
const before2 = store.queryEntries({}).total
const a2 = await call(WRITE, 'POST', { op: 'add', track: 'agent', scope: 'workspace', text: '无键不该落盘。' })
out.push(['add no workspaceKey', `${a2.status} ${a2.json.code}`])
out.push(['add no key wrote nothing', String(store.queryEntries({}).total === before2)])

// ── ③ add 空文本 → 400 ──
const a3 = await call(WRITE, 'POST', { op: 'add', track: 'agent', scope: 'workspace', workspaceKey: '/w/alpha', text: '   ' })
out.push(['add empty text', `${a3.status} ${a3.json.code}`])

// ── ④ add user-global（不需要键） ──
const a4 = await call(WRITE, 'POST', { op: 'add', track: 'user', scope: 'user-global', text: '全局偏好：先给结论。' })
out.push(['add user-global', `${a4.status} ${JSON.stringify(a4.json.usage)}`])

// ── ⑤ replace ──
const a5 = await call(WRITE, 'POST', {
  op: 'replace', track: 'agent', scope: 'workspace', workspaceKey: '/w/alpha',
  match: '用户偏好：中文回复。', text: '用户偏好：中文回复，直接执行不啰嗦。',
})
const replaced = entriesOf('agent', 'workspace').find((e) => e.text.includes('不啰嗦'))
out.push(['replace ok', `${a5.status} ${replaced === undefined ? 'missing' : 'landed'}`])
out.push(['replace audit', String(store.auditList(20).find((r) => r.action === 'replace')?.outcome)])

// ── ⑥ replace 定位不存在 → 409 ──
const a6 = await call(WRITE, 'POST', { op: 'replace', track: 'agent', scope: 'workspace', workspaceKey: '/w/alpha', match: '这段文字不存在', text: 'x' })
out.push(['replace not found', `${a6.status} ${a6.json.code}`])

// ── ⑦ 多命中 → 409 AMBIGUOUS_MATCH ──
await call(WRITE, 'POST', { op: 'add', track: 'agent', scope: 'user-global', text: '重复片段 AAA' })
await call(WRITE, 'POST', { op: 'add', track: 'agent', scope: 'user-global', text: '重复片段 BBB' })
const a7 = await call(WRITE, 'POST', { op: 'replace', track: 'agent', scope: 'user-global', match: '重复片段', text: 'x' })
out.push(['replace ambiguous', `${a7.status} ${a7.json.code}`])

// ── ⑧ remove ──
const a8 = await call(WRITE, 'POST', { op: 'remove', track: 'user', scope: 'user-global', match: '全局偏好：先给结论。' })
out.push(['remove ok', `${a8.status} ${JSON.stringify(a8.json.usage)}`])
out.push(['remove audit', String(store.auditList(20).find((r) => r.action === 'remove')?.outcome)])
out.push(['remove gone', String(entriesOf('user', 'user-global').length === 0)])

// ── ⑨ 方法/入参门 ──
out.push(['GET rejected', String((await call(WRITE, 'GET', undefined)).status)])
out.push(['bad op', `${(await call(WRITE, 'POST', { op: 'nuke' })).status}`])

// ── ⑩ 会话级 never → 403 且零写入 ──
const neverCall = mount({ approval: { overrideOf: () => 'never', config: { policy: 'ask' } } })
const before10 = store.queryEntries({}).total
const a10 = await neverCall(WRITE, 'POST', { op: 'add', track: 'agent', scope: 'user-global', text: '这条不该写。' })
out.push(['never → 403', String(a10.status)])
out.push(['never wrote nothing', String(store.queryEntries({}).total === before10)])

// ── ⑪ entries 响应带 workspaces / writePolicy ──
const e11 = await call(ENTRIES, 'GET', undefined)
out.push(['entries workspaces', JSON.stringify(e11.json.workspaces)])
out.push(['entries writePolicy', String(e11.json.writePolicy)])

store.close()
fs.rmSync(dbPath, { force: true })
fs.rmSync(`${dbPath}-wal`, { force: true })
fs.rmSync(`${dbPath}-shm`, { force: true })
for (const [k, v] of out) console.log(k.padEnd(24), v)
