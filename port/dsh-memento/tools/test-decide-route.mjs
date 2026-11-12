// 面板裁决路由离线端到端自测：真 sqlite 存储 + 假 ctx/webServer/res。
//
// 覆盖（12 项）：
//   ① 批准走 service.add() 协议通道：条目落盘、返回 usage、审计行 outcome 与命令/工具面同形
//   ② 预算门：超限 409 BUDGET_EXCEEDED，绝不截断
//   ③ 提案状态机：重复裁决 409 PROPOSAL_NOT_FOUND
//   ④ 方法/入参门：GET 405、缺参 400
//   ⑤ 驳回：只改状态 + 审计行 proposal-dismissed
//   ⑥ 会话级硬拒（policy never）：403 WRITE_DENIED，且什么都没写
//   ⑦ 活会话溯源：宿主 sessions 服务在场时审计行 sessionId 用活会话 id；
//      不在场时退化用提案记录的 sessionId（不丢溯源）
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

// 插件根：默认已安装的 profile 副本（peerDeps 由宿主 node_modules 解析），
// 可用 MEMENTO_ROOT 指向任意等价树（如 payload 旁边的 profile 副本）。
const ROOT = process.env.MEMENTO_ROOT
  ?? '/data/data/com.dsharnessmobile.shell/files/home/.dsh/profiles/web/node_modules/dsh-memento'
const { openMemoryStore } = await import(pathToFileURL(path.join(ROOT, 'lib/store.mjs')).href)
const { MemoryService, registerWebRoutes } = await import(pathToFileURL(path.join(ROOT, 'index.mjs')).href)

const dbPath = path.join(os.tmpdir(), `memento-test-${Date.now()}.db`)
const store = openMemoryStore(dbPath, { retentionDays: 30 })

// 服务：approval gate 直接放行（本测试只验面板路由，审批 seam 由路由自己的 gate 表达）。
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

/** 挂一份路由到指定的假 ctx 上，返回可调用的裁决入口。 */
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
    await routes.get(route).handler(req, res)
    return { status: res.status, json: res.body ? JSON.parse(res.body) : null }
  }
}

const DECIDE = '/api/memento/proposal-decide'
const out = []

/** 造一条提案（(session_id, kind) 幂等，所以每条用不同 sessionId）。 */
function propose(sessionId, text) {
  store.proposalUpsert({ kind: 'compaction-summary', track: 'agent', scope: 'workspace', text, source: 'compaction', sessionId, workspaceKey: '/w', agentKey: 'standard' })
  return store.proposalList('pending', 50).find((p) => p.sessionId === sessionId)
}

const call = mount()

// ── ①②③④⑤ 基础路径 ──
const okProposal = propose('s1', '用户偏好：中文回复，直接执行不啰嗦。')
const bigProposal = propose('s2', 'x'.repeat(5000))
const r1 = await call(DECIDE, 'POST', { id: okProposal.id, action: 'approve' })
out.push(['approve ok', JSON.stringify(r1)])
out.push(['entry written', String(store.queryEntries({}).total)])
out.push(['usage returned', JSON.stringify(r1.json.usage)])
const addRow = store.auditList(20).find((row) => row.action === 'add')
out.push(['audit outcome', String(addRow?.outcome)])
out.push(['audit sessionId', String(addRow?.sessionId)])
const r2 = await call(DECIDE, 'POST', { id: bigProposal.id, action: 'approve' })
out.push(['approve over-budget', JSON.stringify(r2)])
const r3 = await call(DECIDE, 'POST', { id: okProposal.id, action: 'dismiss' })
out.push(['dismiss already-decided', JSON.stringify(r3)])
const r4 = await call(DECIDE, 'GET', undefined)
out.push(['GET rejected', JSON.stringify(r4)])
const r5 = await call(DECIDE, 'POST', { id: bigProposal.id, action: 'dismiss' })
out.push(['dismiss ok', JSON.stringify(r5)])
const r6 = await call(DECIDE, 'POST', { action: 'approve' })
out.push(['missing id', JSON.stringify(r6)])

// ── ⑥ 会话级硬拒：policy never 不可绕过，且必须什么都没写 ──
const neverCall = mount({ approval: { overrideOf: () => 'never', config: { policy: 'ask' } } })
const neverProposal = propose('s-never', '这条不该被写进记忆。')
const entriesBefore = store.queryEntries({}).total
const r7 = await neverCall(DECIDE, 'POST', { id: neverProposal.id, action: 'approve' })
out.push(['never → 403', JSON.stringify(r7)])
out.push(['never wrote nothing', String(store.queryEntries({}).total === entriesBefore)])
out.push(['never still pending', String(store.proposalList('pending', 50).some((p) => p.id === neverProposal.id))])

// ── ⑦ 活会话在场：审计行 sessionId 必须取活会话 id（而不是提案记录里的 id） ──
const liveCall = mount({
  sessions: { get: (id) => (id === 's-live' ? { id: `${id}#live`, header: { cwd: '/w' }, append: () => 'appended' } : undefined) },
})
const liveProposal = propose('s-live', '活会话溯源检查。')
const r8 = await liveCall(DECIDE, 'POST', { id: liveProposal.id, action: 'approve' })
out.push(['live session ok', String(r8.status === 200)])
const liveRow = store.auditList(20).find((row) => row.action === 'add' && row.text === '活会话溯源检查。')
out.push(['live sessionId used', String(liveRow?.sessionId)])

out.push(['pending left', String(store.proposalList('pending', 50).length)])
out.push(['audit rows', store.auditList(40).map((r) => r.action).join(',')])

store.close()
fs.rmSync(dbPath, { force: true })
fs.rmSync(`${dbPath}-wal`, { force: true })
fs.rmSync(`${dbPath}-shm`, { force: true })
for (const [k, v] of out) console.log(k.padEnd(22), v)
