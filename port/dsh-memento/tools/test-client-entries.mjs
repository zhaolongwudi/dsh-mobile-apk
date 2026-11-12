// 面板条目控制面离线冒烟：最小 DOM 桩 + 真 client.js，验证
//   ① 每条记忆渲染出「编辑 / 删除」按钮
//   ② 点删除 → 确认后发出 {op:'remove', track, scope, match:全文, workspaceKey}
//   ③ 点编辑 → 就地 textarea；改文本后点保存 → {op:'replace', match:旧全文, text:新文本}
//   ④ 「新增」表单 → {op:'add', track, scope, text, workspaceKey}
//   ⑤ workspace 层缺工作区候选时：新增被本地拦下（不发请求），状态行给出原因
// 与 test-client-panel.mjs 同一套 DOM 桩思路，只是把响应换成「有条目」的世界。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const SELF = path.dirname(fileURLToPath(import.meta.url))
const CLIENT = process.env.MEMENTO_CLIENT ?? path.resolve(SELF, '../payload/node_modules/dsh-memento/client/client.js')

class El {
  constructor(tag) {
    this.tagName = tag.toUpperCase()
    this.children = []
    this.parentNode = null
    this._id = ''
    this._html = ''
    this._class = ''
    this.style = {}
    this.dataset = {}
    this.disabled = false
    this.textContent = ''
    this.placeholder = ''
    this.value = ''
    this.events = new Map()
  }
  get id() { return this._id }
  set id(v) { this._id = v; if (v) doc.byId.set(v, this) }
  get innerHTML() { return this._html }
  set innerHTML(v) { this._html = v; doc.reparse(this, v) }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c }
  addEventListener(type, fn) { const list = this.events.get(type) ?? []; list.push(fn); this.events.set(type, list) }
  removeEventListener() {}
  getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 40 } }
  focus() {}
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
  querySelector(root, sel) { return this.querySelectorAll(root, sel)[0] ?? null },
  querySelectorAll(root, sel) {
    const out = []
    const want = String(sel ?? '').trim()
    const walk = (node) => {
      for (const child of node.children ?? []) {
        if (want.startsWith('.') && (child._class ?? '').split(/\s+/).includes(want.slice(1))) out.push(child)
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
    const want = String(sel ?? '').trim()
    let cur = node
    while (cur !== null) {
      if (want.includes(' ')) {
        const [anc, tag] = want.split(/\s+/)
        if (anc.startsWith('.') && (cur._class ?? '').split(/\s+/).includes(anc.slice(1))) {
          let m = node
          while (m !== null && m !== cur) {
            if (m.tagName === tag.toUpperCase()) return m
            m = m.parentNode
          }
        }
      } else if (want.startsWith('.')) {
        if ((cur._class ?? '').split(/\s+/).includes(want.slice(1))) return cur
      } else if (want.startsWith('[')) {
        const attr = /^\[data-([a-z-]+)\]$/.exec(want)
        if (attr !== null) {
          const key = attr[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase())
          if (Object.prototype.hasOwnProperty.call(cur.dataset ?? {}, key)) return cur
        }
      } else if (cur.tagName === want.toUpperCase()) {
        return cur
      }
      cur = cur.parentNode
    }
    return null
  },
  reparse(root, html, append = false) {
    if (!append) root.children = []
    const stack = [{ node: root }]
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
      const parent = stack[stack.length - 1].node
      const nextLt = html.indexOf('<', m.index + m[0].length)
      const tail = html.slice(m.index + m[0].length, nextLt < 0 ? html.length : nextLt)
      if (tail.trim().length > 0 && !tail.includes('=')) el.textContent = tail.trim()
      // textarea 的内容是它的 value（编辑器回填、读取都走这里）。
      if (tag.toLowerCase() === 'textarea') el.value = tail
      el.parentNode = parent
      parent.children.push(el)
      const selfClosing = /\/>$/.test(attrs) || ['input', 'br', 'img'].includes(tag.toLowerCase())
      if (!selfClosing) stack.push({ node: el })
    }
  },
}
doc.head = new El('head')
doc.body = new El('body')

// ── 宿主桩：有一个工作区、两条记忆 ──
const ENTRIES = [
  { id: 'e1', track: 'agent', scope: 'workspace', workspaceKey: '/w/alpha', agentKey: 'standard', text: '用户偏好：中文回复。', source: 'dsh-memento', createdAt: 1 },
  { id: 'e2', track: 'user', scope: 'user-global', workspaceKey: '', agentKey: '', text: '全局偏好：先给结论。', source: 'dsh-memento', createdAt: 2 },
]
const writes = []
let nextWrite = { ok: true, status: 200, body: { ok: true } }
const g = globalThis
g.document = doc
g.localStorage = { getItem: () => null, setItem() {}, removeItem() {} }

g.window = { innerWidth: 1024, innerHeight: 768, addEventListener() {}, setTimeout: (fn, ms) => setTimeout(fn, ms), __ModuleLoader__: null }
g.fetch = async (url, init) => {
  if (url.startsWith('/api/memento/entry-write')) {
    writes.push(JSON.parse(init?.body ?? '{}'))
    return { ok: nextWrite.ok, status: nextWrite.status, json: async () => nextWrite.body }
  }
  if (url.startsWith('/api/memento/entries?limit=200')) {
    return { ok: true, status: 200, json: async () => ({ entries: ENTRIES, total: ENTRIES.length, truncated: false, language: 'zh', panel: { enabled: true }, workspaces: ['/w/alpha'], writePolicy: 'auto', budgets: [{ track: 'agent', scope: 'workspace', used: 20, limit: 4000 }] }) }
  }
  if (url.startsWith('/api/memento/entries?limit=1')) return { ok: true, status: 200, json: async () => ({ panel: { enabled: true }, language: 'zh' }) }
  if (url.startsWith('/api/memento/audit')) return { ok: true, status: 200, json: async () => ({ rows: [] }) }
  if (url.startsWith('/api/memento/proposals')) return { ok: true, status: 200, json: async () => ({ proposals: [] }) }
  return { ok: true, status: 200, json: async () => ({}) }
}
let factory = null
g.window.__ModuleLoader__ = { load: (def) => { factory = def.factory } }

const src = fs.readFileSync(CLIENT, 'utf8')
new Function('window', 'document', 'localStorage', 'fetch', src)(g.window, doc, g.localStorage, g.fetch)
if (factory === null) throw new Error('client.js 没有注册 factory')
const plugin = factory(() => ({}))
const ctx = {
  get: () => undefined,
  on: () => () => {},
  effect: (fn) => { const d = fn?.(); return () => { if (typeof d === 'function') d() } },
  inject: () => {},
  logger: { info() {}, warn() {}, error() {} },
  slots: { register: () => () => {}, registerFactory: () => () => {}, inject: () => {}, configure: () => {} },
  settings: { scope: null },
  locale: { bind: () => (k) => k },
}
plugin.apply(ctx)

const tick = () => new Promise((r) => setTimeout(r, 25))
await tick()
await tick()

/** 打开面板（等同点 FAB），触发 refresh。 */
const openFab = doc.getElementById('mem-open')
openFab.dispatch('click', {})
await tick()
await tick()

const body = doc.getElementById('mem-body')

/** 模拟浏览器冒泡：面板的监听挂在 body 上（事件委托），所以点按钮要在 body 上派发。 */
const clickOn = (el) => { body.dispatch('click', { target: el, preventDefault() {} }) }

const out = []

/** 按文案找按钮（桩里按钮文本在 textContent）。 */
const buttonsIn = (root) => {
  const acc = []
  const walk = (n) => { for (const c of n.children ?? []) { if (c.tagName === 'BUTTON') acc.push(c); walk(c) } }
  walk(root)
  return acc
}
const cardOf = (id) => body.querySelectorAll(body, '[data-entry-id]') && (() => {
  const all = []
  const walk = (n) => { for (const c of n.children ?? []) { if (c.dataset?.entryId !== undefined) all.push(c); walk(c) } }
  walk(body)
  return all.find((c) => c.dataset.entryId === id) ?? null
})()

const card1 = cardOf('e1')
const card2 = cardOf('e2')
out.push(['entry cards', `${card1 === null ? 'missing' : 'ok'} ${card2 === null ? 'missing' : 'ok'}`])
out.push(['e1 buttons', buttonsIn(card1 ?? body).map((b) => b.textContent).join(' | ')])

// ── ② 删除：确认 → POST remove（match = 旧全文） ──
const delBtn = buttonsIn(card1).find((b) => b.textContent === '删除')
// 两步式确认：第一次点只上膛（不发请求），第二次点才真删。
clickOn(delBtn)
await tick()
out.push(['delete armed', `${writes.length} req, btn="${delBtn.textContent}"`])
clickOn(delBtn)
await tick(); await tick()
out.push(['remove payload', JSON.stringify(writes[0])])

// ── ③ 编辑 → 改文本 → 保存 ──
const editBtn = buttonsIn(cardOf('e1')).find((b) => b.textContent === '编辑')
clickOn(editBtn)
await tick()
const editor = doc.querySelector(body, '[data-edit-text]')
out.push(['editor opened', editor === null ? 'missing' : `value=${String(editor.value).slice(0, 12)}…`])
editor.value = '用户偏好：中文回复，直接执行不啰嗦。'
const saveBtn = buttonsIn(cardOf('e1')).find((b) => b.textContent === '保存')
clickOn(saveBtn)
await tick(); await tick()
out.push(['replace payload', JSON.stringify(writes[1])])

// ── ④ 新增：填表 → 提交 ──
const addText = doc.getElementById('mem-add-text')
addText.value = '新记忆：测试一行。'
const addSubmit = doc.getElementById('mem-add-submit')
addSubmit.dispatch('click', {})
await tick(); await tick()
out.push(['add payload', JSON.stringify(writes[2])])
out.push(['add status', String(doc.getElementById('mem-add-status')?.textContent ?? '')])

// ── ⑤ 失败态：服务端 409 → 状态行显示原因 ──
nextWrite = { ok: false, status: 409, body: { ok: false, code: 'AMBIGUOUS_MATCH', error: 'match is ambiguous' } }
addText.value = '再一条。'
addSubmit.dispatch('click', {})
await tick(); await tick()
out.push(['add failure line', String(doc.getElementById('mem-add-status')?.textContent ?? '')])

for (const [k, v] of out) console.log(k.padEnd(20), v)
