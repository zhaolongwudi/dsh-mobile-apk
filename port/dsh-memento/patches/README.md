# 本地补丁

三个补丁，`git apply -p1` / `patch -p1` 都能应用（路径一律是 `a/<相对路径>` → `b/<相对路径>`）。

| 补丁 | 目标 | 基线 → 结果 |
|---|---|---|
| `01-client-configforms-softwait.patch` | `client/client.js` | `patches/client.js.upstream` → `patches/client.js.softwait` |
| `02-client-panel-decide-buttons.patch` | `client/client.js` | `patches/client.js.softwait` → `overlay/client/client.js` |
| `03-panel-proposal-decide.patch` | `index.mjs` | `patches/index.mjs.upstream` → `overlay/index.mjs` |

基线（`*.upstream`）与 npm tarball 逐字节一致，sha256 记在 `manifest.json → upstream.files`。
补丁后态（`overlay/`）的 sha256 记在 `manifest.json → overlay.files`。

```bash
bash port.sh verify                 # 四段体检
node tools/verify-overlay.mjs       # 移植链四段逐字节核对（上游→补丁→overlay→payload→已装副本）
node tools/make-patches.mjs         # 改了 overlay 之后重新生成这三个补丁
```

> ⚠️ **上一轮的坑（已修）**：旧补丁的 `---/+++` 头是**设备绝对路径**
> （`/data/data/com.dsharnessmobile.shell/files/home/.dsh/profiles/web/node_modules/dsh-memento/index.mjs`），
> 甚至指向生成时的临时文件（`index.mjs.orig2`）。那种补丁只有 `cwd=/` 时才勉强能应用，
> 换设备、换 `DSH_HOME`、换 npm 安装位置立刻失效 —— 严格说它是「文档」而不是「补丁」。
> 现在由 `tools/make-patches.mjs` 统一生成，路径是相对的，并且有 `verify-overlay.mjs`
> 逐字节证明「打补丁的结果 = overlay = payload = 已装副本」。

---

## 1. client-configforms-softwait（设置页只读）

### 现象（实测）
设置页打开 dsh-memento 卡片，顶部显示：

```
Read-only (settings service unavailable).
```

且 Discard / Save 均不可用，整个表单是空的。

### 根因
`client/client.js` 的 `apply(ctx)` 里**一次性**解析设置句柄：

```js
const controller = new MementoCardController(resolveSettingsScope(ctx))
```

`resolveSettingsScope` 依次尝试：
1. `ctx.get('configForms')?.get(entryId)`（0.1.7+ 线）
2. `ctx.get('settingsScope')?.bind(...)`（旧线）
3. 都不在场 → `UNAVAILABLE_SCOPE`

`UNAVAILABLE_SCOPE.getSnapshot()` 返回 `{status:'unavailable', writable:false}`，
于是卡片渲染 `readOnly` 提示；`CardForm.save()` 里
`if (snapshot.status !== 'ready' || !snapshot.writable) return` 直接把保存挡掉。

**为什么那一刻服务没就绪**：`dsh-memento` 的客户端插件声明是 `inject: ['slots']`，
只等 slots。而提供 `configForms` 的是 `@deepseek-ai/dsh-client-ui-settings`，
两者在客户端装配图里是不同节点，`inject` 中没有该依赖
⇒ cordis 不保证 ui-settings 的 `Service` 注册先于 memento 的 `apply` 执行。

上游注释解释了为什么不敢写进 inject：

> 两者都**不写进 inject**：对面那条线的服务在另一侧宿主上永不到场，写进去会让
> fiber 永久 PENDING——整个客户端插件（含只读面板）都不会挂载。缺席即降级为只读。

这个顾虑是对的（旧线上 `configForms` 永不到场），但代价是新线上也退化成只读。

### 修法
不动 `inject` 声明（面板必须无条件挂载），改用 **cordis 软等待**：

```js
ctx.inject(['configForms'], (inner) => {
  const scope = resolveSettingsScope(inner)
  if (!scope || scope === UNAVAILABLE_SCOPE) return
  controller.rebind(scope)
})
```

配套新增两个方法：

- `MementoCardController#rebind(scope)`：用真实句柄重建 `CardForm`，
  清空并重建 `listeners` 里的投影闭包（必须读 `this.form` 而非捕获旧实例），
  再 `store.set(projection())` 让已挂载的订阅者立即拿到新快照。
- `MementoCardController#release()`：幂等释放，由 `inner.effect` 的清理器调用。

---

## 2. 面板裁决（「没有审批按钮」）

### 现象
面板「待审批提案」区能看到提案内容（`[id] track/scope · 文本…`），
但**没有任何可点的确认入口**——没有批准、没有驳回。设置页也一样。

### 根因（不是渲染 bug，是根本没有这条通路）
面板只有三条**只读**路由：

| 路由 | 方法 | 用途 |
|---|---|---|
| `/api/memento/entries` | GET | 条目 + 预算 |
| `/api/memento/audit` | GET | 审计尾 |
| `/api/memento/proposals` | GET | pending 提案列表 |

`index.mjs` 原注释：

> 只读：仅列出 pending 提案；approve/dismiss 走 `/memory` 命令（用户动作 + 审批门）。

`client.js` 的 `renderProposals` 也只拼一行 `.mem-audit` 文本。
所以「能看见内容、没有按钮」是**设计使然**——裁决入口只存在于 `/memory proposals approve|dismiss <id>` 命令行。

### 修法

**服务端**（`index.mjs`）新增 `POST /api/memento/proposal-decide`：

- 准入：`ctx.get('connection')?.requestRejection(req)`（宿主给插件用的公开判定，
  与 `@dsh-android/dsh-session-delete` 同一做法）。返回 `undefined` = 放行，
  数字 = 拒（403 Host/Origin 围栏、401 未认证）；判定不可读时按未授权处理（失败封闭）。
- 入参 `{id, action: 'approve'|'dismiss'}`；`GET` → 405，缺参 → 400。
- `dismiss`：`store.proposalDecide(id,'dismissed')` + 审计行 `proposal-dismissed`。
- `approve`：**走 `service.add()` 协议通道**（见下）→ 审计行 `add` → 提案状态转 `approved`。
- 领域错误按 code 回 409（预算超限/提案已裁决）、403（会话级硬拒）、500。

**批准为什么必须走 `service.add()`**（本轮修掉的真实缺陷）：
第一版实现是「直接 `store.insertEntry` + 手写审计行」，看起来能用，但它**复制了协议逻辑**，
于是悄悄少了一整条写路径的语义：

| 协议通道做的事 | 第一版面板路径 |
|---|---|
| `#validateEntry`（track/scope 白名单、文本非空、tags 归一化） | ❌ 无 |
| 预算预检 **+ 预算复审**（两次） | ⚠️ 只做一次 |
| 审计行经 `#auditWrite`（outcome 文案与命令/工具面同形） | ❌ 自造 `approved (panel decision)` |
| `#appendWriteEvent`（`memory/added` 会话事件） | ❌ 无 |
| 返回 `usage`（该层 used/limit） | ❌ 无 |
| 并发裁决时「写已成功就不改用提案状态错误掩盖」 | ❌ 未处理 ⇒ 写成功却回 409 |
| 会话级 `never` 硬拒不可绕过 | ❌ 绕过 |

现在面板批准构造一个写上下文交给协议：

```js
{
  agent: { session: panelSessionFor(ctx, proposal.sessionId) },
  gate: async () => effective === 'never'
    ? throw new WriteDeniedError('rejected', '…policy "never"')
    : 'allowed-once',
}
```

- **人的点击就是那次审批**，所以 gate 不再弹审批窗，但保留 `makeCommandGate` 的会话级预检：
  `approval.overrideOf(session) ?? approval.config.policy ?? 'ask'`，`never` 直接 403 且零写入。
- outcome 用审批 seam 的既有词汇 `allowed-once`，审计行文案与命令/工具面同形
  （`allowed-once (via write gate)`）。
- **会话溯源**：宿主的 `sessions` 服务（`SessionStore`）能按 id 取活会话，
  于是审计行与 `memory/*` 事件挂在正确会话上；提案所属会话已不在内存时（引擎重启后）
  退化为只带 id 的会话壳（`append` 显式 no-op），保住 `sessionId` 溯源，且绝不在写已落盘后再抛错。
- 上游日后改协议，面板自动跟随——不再有第二条会悄悄走偏的写路径。

**客户端**（`client/client.js`）：

- `renderProposals` 每条多渲染一个 `.mem-proposal-actions`，含「批准 / 驳回」两按钮 + 状态行。
- 点击走 `decideProposal(button)`：进入 pending（禁用同组按钮）→ POST → 成功 `refresh()`
  整页刷新，失败把服务端原因写进状态行并解禁。
- 监听用**事件委托**挂在稳定的 `#mem-body` 上——提案槽每次刷新都重写 `innerHTML`，
  逐个绑会随刷新累积泄漏。
- 文案补 `approve/dismiss/deciding/decideFailed` 两组（en/zh）。

### 验证（离线端到端，`node tools/test-decide-route.mjs`，16 项）

```
approve ok             {"status":200,"ok":true,"entryId":"…","usage":{"track":"agent","scope":"workspace","used":18,"limit":4000}}
entry written          1
usage returned         {"track":"agent","scope":"workspace","used":18,"limit":4000}
audit outcome          allowed-once (via write gate)      ← 与命令/工具面同形
audit sessionId        s1                                 ← 溯源不丢
approve over-budget    {"status":409,"code":"BUDGET_EXCEEDED",…}
dismiss already-decided{"status":409,"code":"PROPOSAL_NOT_FOUND",…}
GET rejected           {"status":405,…}
dismiss ok             {"status":200,…}
missing id             {"status":400,…}
never → 403            {"status":403,"code":"WRITE_DENIED",…}
never wrote nothing    true
never still pending    true
live session ok        true
live sessionId used    s-live#live                        ← 活会话在场时取活会话
audit rows             add,add-denied,proposal-dismissed,add
```

（`add-denied` 是协议在拒绝时补的审计行——第一版面板路径同样没有这一条。）

`bash port.sh verify` 四段全 PASS；`node tools/verify-overlay.mjs` 四段全 PASS。

### 回滚
```sh
cp overlay/client/client.js client/client.js   # 面板按钮/软等待都回滚到上游？不行 —— 见下
```

正确姿势是「分层回滚」：

```sh
# ② 只摘写路由（回只读面板）：用第一轮存档 + 上游 client
cp patches/archive/index.mjs.round1.mjs <profile>/node_modules/dsh-memento/index.mjs
# ③ 完全回上游（无任何补丁）
cp patches/index.mjs.upstream        <profile>/node_modules/dsh-memento/index.mjs
cp patches/client.js.upstream        <profile>/node_modules/dsh-memento/client/client.js
# 回到「软等待已修、但无按钮」的中间态
cp patches/client.js.softwait        <profile>/node_modules/dsh-memento/client/client.js
```

命名约定：
- `*.upstream` = npm 上游未打补丁原版
- `client.js.softwait` = 打了补丁①（设置页可编辑）之后的状态
- `overlay/` = 全部补丁后的规范态（kit 的安装源）
- `patches/archive/index.mjs.round1.mjs` = 第一轮面板路由实现（直接写库那版），仅供回滚

---

## 2026-11-12 追加：04 / 05 号补丁（面板条目控制面）

| 补丁 | 基线 | 结果 | 内容 |
|---|---|---|---|
| `04-panel-entry-controls.patch` | `patches/client.js.decide` | `overlay/client/client.js` | 每条记忆「编辑 / 删除」+ 内联 textarea 编辑器 + 「＋ 新增记忆」表单 + 窄屏全宽抽屉 + 设置卡窄屏整行 |
| `05-panel-entry-write.patch` | `patches/index.mjs.decide` | `overlay/index.mjs` | `POST /api/memento/entry-write`（add/replace/remove 全走 service 协议通道）+ `entries` 响应补 `workspaces` / `writePolicy` |

补丁链现在是五段、顺序敏感：

```
client.js.upstream --01--> client.js.softwait --02--> client.js.decide --04--> overlay/client/client.js
index.mjs.upstream --03--> index.mjs.decide --05--> overlay/index.mjs
```

`tools/make-patches.mjs` 的 jobs 表就是这个顺序；`tools/verify-overlay.mjs` 按 `manifest.patches`
逐个 `patch -p1` 后与 overlay 逐字节比对，任何一环错位都会 FAIL。

修订纪律（与前三号补丁一致）：**不改已发布补丁的语义**，新增能力一律追加新号补丁 +
新的基线快照（`patches/*.decide`），这样 `manifest.patches` 顺序本身即完整可复现的施工图。
