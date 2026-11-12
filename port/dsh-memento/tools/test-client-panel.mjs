// 客户端面板离线冒烟：最小 DOM 桩 + 真 client.js，验证
//   ① 提案区渲染出「批准/驳回」按钮；② 点批准后发出正确的 POST；③ 失败时状态行显示原因。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const SELF = path.dirname(fileURLToPath(import.meta.url))
const CLIENT = process.env.MEMENTO_CLIENT ?? path.resolve(SELF, '../payload/node_modules/dsh-memento/client/client.js')

// ── 最小 DOM 桩 ────────────────────────────────────────────────────────────
class El {
  constructor(tag) {
    this.tagName = tag.toUpperCase()
    this.children = []
    this.parentNode = null
    this._id = ''
    this._html = ''
    this.style = {}
    this.dataset = {}
    this.disabled = false
    this.textContent = ''
    this.placeholder = ''
    this.events = new Map()
  }
  get id() { return this._id }
  set id(v) { this._id = v; if (v) doc.byId.set(v, this) }
  get innerHTML() { return this._html }
  set innerHTML(v) { this._html = v; doc.reparse(this, v) }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c }
  addEventListener(type, fn) {
    const list = this.events.get(type) ?? []
    list.push(fn); this.events.set(type, list)
  }
  removeEventListener() {}
  getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 40 } }
  closest(sel) { return doc.matchClosest(this, sel) }
  querySelector(sel) { return doc.querySelector(this, sel) }
  querySelectorAll(sel) { return doc.querySelectorAll(this, sel) }
  insertAdjacentHTML(_pos, html) { doc.reparse(this, html, true) }
  dispatch(type, event) { for (const fn of this.events.get(type) ?? []) fn(event) }
  get classList() { return { add() {}, remove() {}, toggle() {} } }
}

const doc = {
  byId: new Map(),
  head: null,
  body: null,
  createElement(tag) { return new El(tag) },
  getElementById(id) { return this.byId.get(id) ?? null },
  querySelector() { return null },
  // 只有面板用到的几种选择器：按 class 找按钮/状态行。
  querySelector(root, sel) { return this.querySelectorAll(root, sel)[0] ?? null },
  querySelectorAll(root, sel) {
    const out = []
    const want = sel.trim()
    const walk = (node) => {
      for (const child of node.children ?? []) {
        if (want.startsWith('.') && (child._class ?? '').split(/\s+/).includes(want.slice(1))) out.push(child)
        // 属性选择器（[data-status-for]）：面板状态行用它定位。
        const attr = /^\[data-([a-z-]+)\]$/.exec(want)
        if (attr !== null) {
          const key = attr[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase())
          if (Object.prototype.hasOwnProperty.call(child.dataset ?? {}, key)) out.push(child)
        }
        walk(child)
      }
    }
    walk(root)
    return out
  },
  matchClosest(node, sel) {
    const want = sel.trim()
    let cur = node
    while (cur !== null) {
      for (const token of want.split(/\s+/)) {
        const ok = token.startsWith('.')
          ? (cur._class ?? '').split(/\s+/).includes(token.slice(1))
          : cur.tagName === token.toUpperCase()
        if (ok && want.split(/\s+/).length === 1) return cur
      }
      if (want.includes(' ')) {
        // 复合选择器（.mem-proposal-actions button）：先找祖先再找后代标签
        const [anc, tag] = want.split(/\s+/)
        if (anc.startsWith('.') && (cur._class ?? '').split(/\s+/).includes(anc.slice(1))) {
          let n = node
          while (n !== null && n !== cur) n = n.parentNode
          if (n === cur) {
            let m = node
            while (m !== null && m !== cur) {
              if (m.tagName === tag.toUpperCase()) return m
              m = m.parentNode
            }
          }
        }
      }
      cur = cur.parentNode
    }
    return null
  },
  // 把 innerHTML 粗解析成节点树（只认 class / id / data-* / 标签）。
  reparse(root, html, append = false) {
    if (!append) root.children = []
    const stack = [{ node: root, classes: [] }]
    const tagRe = /<(\/?)([a-z]+)([^>]*)>/gi
    let m
    while ((m = tagRe.exec(html)) !== null) {
      const [, closing, tag, attrs] = m
      if (closing) { if (stack.length > 1) stack.pop(); continue }
      const el = new El(tag)
      const cls = /class="([^"]*)"/.exec(attrs)
      if (cls) el._class = cls[1]
      const idm = /id="([^"]*)"/.exec(attrs)
      if (idm) { el._id = idm[1]; this.byId.set(idm[1], el) }
      for (const dm of attrs.matchAll(/data-([a-z-]+)="([^"]*)"/g)) {
        const key = dm[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase())
        el.dataset[key] = dm[2]
      }
      // 内联文本（按钮文案）要保留：面板按钮靠它显示「批准/驳回」。
      const parent = stack[stack.length - 1].node
      const tail = html.slice(m.index + m[0].length, html.indexOf('<', m.index + m[0].length))
      if (tail.length > 0 && !tail.includes('=')) el.textContent = tail.trim()
      el.parentNode = parent
      parent.children.push(el)
      if (!/\/>$/.test(attrs) && !['input', 'br', 'img'].includes(tag.toLowerCase())) stack.push({ node: el, classes: [] })
    }
  },
}
doc.head = new El('head')
doc.body = new El('body')

// ── 宿主环境桩 ─────────────────────────────────────────────────────────────
const requests = []
let nextResponse = { ok: true, status: 200, body: { ok: true } }
const g = globalThis
g.document = doc
g.localStorage = { getItem: () => null, setItem() {}, removeItem() {} }
g.window = { innerWidth: 1024, innerHeight: 768, addEventListener() {}, __ModuleLoader__: null }
g.fetch = async (url, init) => {
  if (url.startsWith('/api/memento/proposal-decide')) {
    requests.push({ url, method: init?.method, body: JSON.parse(init?.body ?? '{}') })
    return { ok: nextResponse.ok, status: nextResponse.status, json: async () => nextResponse.body }
  }
  const table = {
    '/api/memento/entries?limit=1': { enabled: true, language: 'zh' },
    '/api/memento/entries?limit=200': { entries: [], total: 0, truncated: false, language: 'zh', panel: { enabled: true }, budgets: [
      { track: 'user', scope: 'user-global', used: 0, limit: 2000 },
      { track: 'user', scope: 'workspace', used: 0, limit: 2000 },
      { track: 'agent', scope: 'user-global', used: 0, limit: 4000 },
      { track: 'agent', scope: 'workspace', used: 0, limit: 4000 },
    ] },
    '/api/memento/audit?limit=20': { rows: [] },
    '/api/memento/proposals': { proposals: [{ id: 'p-1', track: 'agent', scope: 'workspace', text: '一条待审批提案', createdAt: 1 }] },
  }
  const key = Object.keys(table).find((k) => url.startsWith(k))
  return { ok: true, status: 200, json: async () => (key ? table[key] : {}) }
}
let factory = null
g.window.__ModuleLoader__ = { load: (def) => { factory = def.factory } }

// ── 跑真 client.js ────────────────────────────────────────────────────────
const src = fs.readFileSync(CLIENT, 'utf8')
new Function('window', 'document', 'localStorage', 'fetch', src)(g.window, doc, g.localStorage, g.fetch)
if (factory === null) throw new Error('client.js 没有注册 factory')

const plugin = factory((id) => {
  if (id === 'react') return { createElement: () => null }
  return {}
})
const out = []
out.push(['inject', JSON.stringify(plugin.inject ?? [])])

// 极简 ctx：slots 注册直接跑，apply 里 bootPanel 异步起面板。
let applied = false
const ctx = {
  get: () => undefined,
  on: () => () => {},
  effect: (fn) => { const d = fn?.(); return () => { if (typeof d === 'function') d() } },
  inject: () => {},
  logger: { info() {}, warn() {}, error() {} },
  slots: {
    register: (spec) => { out.push(['slots.register', spec?.name ?? '?']); return () => {} },
    registerFactory: () => () => {},
    inject: () => {},
    configure: () => {},
  },
  settings: { scope: null },
  configForms: undefined,
  locale: { bind: () => (k) => k },
}
plugin.apply(ctx)
applied = true
out.push(['apply', String(applied)])

await new Promise((r) => setTimeout(r, 60))

// 打开抽屉（触发 refresh 渲染提案区）
const openBtn = doc.getElementById('mem-open')
out.push(['fab', openBtn === null ? 'missing' : openBtn.textContent])
openBtn.dispatch('click', { preventDefault() {} })
await new Promise((r) => setTimeout(r, 80))

const slot = doc.getElementById('mem-proposal-slot')
const buttons = slot === null ? [] : doc.querySelectorAll(slot, '.mem-approve').concat(doc.querySelectorAll(slot, '.mem-dismiss'))
out.push(['proposal buttons', buttons.map((b) => `${b._class}=${b.textContent}`).join(' | ') || '(none)'])

// 点批准
const approve = slot === null ? null : doc.querySelector(slot, '.mem-approve')
if (approve !== null) {
  const body = doc.getElementById('mem-body')
  body.dispatch('click', { target: approve, preventDefault() {} })
  await new Promise((r) => setTimeout(r, 120))
}
out.push(['POST sent', JSON.stringify(requests[0] ?? null)])

// 失败路径：让服务端拒绝，点驳回，看状态行
nextResponse = { ok: false, status: 409, body: { ok: false, code: 'BUDGET_EXCEEDED', error: 'memory budget exceeded: agent/workspace at 4000/4000' } }
const slot2 = doc.getElementById('mem-proposal-slot')
const dismiss = slot2 === null ? null : doc.querySelector(slot2, '.mem-dismiss')
if (dismiss !== null) {
  doc.getElementById('mem-body').dispatch('click', { target: dismiss, preventDefault() {} })
  await new Promise((r) => setTimeout(r, 120))
}
const statusEl = doc.querySelector(doc.getElementById('mem-body'), '.mem-proposal-status')
out.push(['status line', statusEl === null ? '(none)' : statusEl.textContent])
out.push(['POST count', String(requests.length)])

for (const [k, v] of out) console.log(k.padEnd(18), v)
