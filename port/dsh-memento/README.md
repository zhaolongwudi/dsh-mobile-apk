# dsh-memento（长期记忆）在 dsh-mobile-apk 上的移植包

把 [PerryLink/dsh-memento](https://github.com/PerryLink/dsh-memento)（DeepSeek Harness 的跨会话长期记忆插件，
包名 `dsh-memento`，Apache-2.0）移植进本机的 DeepCode（`com.dsharnessmobile.shell`），
并且**不改 APK、不改上游仓库、不影响每日从上游 fork 的持续迭代**。

当前状态：**已在本机装好并在运行**（2026-11-10 23:24 实测）。

| 证据 | 结果 |
|---|---|
| 引擎装配（`pluginManager/listPlugins`） | `include:memento` → `dsh-memento`，`enabled=true`，`fiberPhase=active`，`patchId=memento` |
| 插件元数据 | title/description/icon 全部取到（说明 bundle patch 已生效、apply 完成） |
| 模块可加载 | `import('dsh-memento')` 成功 |
| 存储层端到端 | `insertEntry`/`listEntries`/`queryEntries`/`bumpRecall`/`auditAppend`/`auditList` 全通过；关闭后重开数据仍在（持久化） |
| 平台适配 | `node:sqlite`（Node 内置）可用；全包 0 个 `.node/.so/.wasm`；无子进程、无网络调用 |
| 面板提案按钮 | `POST /api/memento/proposal-decide` 离线端到端 16 项通过（批准走协议通道/驳回/超预算 409/重复裁决 409/非 POST 405/缺参 400/会话级 never 403 且零写入/活会话溯源/审计口径）|
| 移植链可复现 | `tools/verify-overlay.mjs` 四段全 PASS：上游基线 → 补丁 → overlay → payload → 已装副本，逐字节一致 |
| 载荷可重建 | 删掉载荷后 `bash fetch-payload.sh --pack` 真从 npm 重建 → sha256 与 manifest 一致（`12edcc8e…`，232,297 B / 46 文件），两个本地补丁不丢 |
| 漂移自愈反证 | 本轮实测真实漂移（`profils/web/package.json` 缺 `dependencies.dsh-memento`）→ `guard.sh` 检出、`port.sh install` 补回、`guard.sh` 复核干净 |

---

## 1. 三处落点，为什么每日新构建物覆盖不掉它

插件的落点全部在 **app 私有数据**里，而工具链的更新只碰「运行环境」和「仓库」：

| 落点 | 位置 | 更新时的命运 |
|---|---|---|
| 插件包 | `$DSH_HOME/profiles/web/node_modules/dsh-memento` | 快照刷新是**合并**不是替换 ⇒ 原样保留 |
| 装配声明 | `$DSH_HOME/profiles/web/package.json`（`dependencies` + `dsh.profile.bundles`） | profile 根清单属**用户面**，按「用户优先、工厂只补缺」合并 ⇒ 原样保留 |
| 记忆库 | `$DSH_HOME/dsh-memento/memory.db` | 未登记项按用户数据保留 |

**这是读上游 Kotlin 源码逐行确认的，不是照抄别人的结论。**

### ① 插件包目录：`SnapshotTransaction.mergeTree()`

```kotlin
attrs.isDirectory -> {
  SnapshotFs.createDirectories(live)
  for (child in staged.listFiles() ?: emptyArray()) {      // ← 只遍历 staged（工厂）侧
    mergeTree(child, File(live, child.name), notes, userFacingFiles, preserveCopy, links)
  }
}
```

遍历方向是**单向的**：只递归工厂侧子项。live 里多出来的东西（我们的 `node_modules/dsh-memento`）
永远不会被枚举到，因此**没有任何删除路径**。源码注释亦明示本函数语义是
「staged 权威 + live-only 不动」，并特别声明**不做整目录替换**（「那会抹掉用户数据」）。

### ② 装配声明：`ProfilePackageManifest.merge()`

```kotlin
if (factoryDeps.length() > 0) {
  val deps = user.optJSONObject("dependencies") ?: ...
  for (key in factoryDeps.keys()) if (!deps.has(key)) deps.put(key, factoryDeps.getString(key))
  //                                 ↑ 只补「用户没有的键」，绝不覆盖已有键
}
...
return user.toString(2)        // ← 以用户清单为**基座**返回
```

函数体是三条**纯增量**规则（依赖补缺键、bundles 补缺项、其余字段原样），
最后 `return user.toString(2)` —— 用户清单是基座，工厂件只往里补缺。
所以 `dependencies.dsh-memento` 与 `bundles` 里的 `dsh-memento` **逐字节保留**。

### ③ 其余工厂件若覆盖 live：会留证

```kotlin
else -> {  // 非用户面文件（node_modules 子树内的工厂件）
  preserveOverwrittenUserFile(staged, live, notes, preserveCopy)   // ← 覆盖前另存 .pre-*
  Files.copy(staged.toPath(), live.toPath(), REPLACE_EXISTING, COPY_ATTRIBUTES)
}
```

我们这一项**不在 staged 里**，所以这条分支碰不到它。但值得一提的是：即便被覆盖，
上游（issue #274 ③）现在也会先把内容不同的 live 版本另存为同目录 `.pre-*` 并记入 notes，
**不再静默抹掉**。

### 与 port/dsh-purge 的关键区别

| | dsh-purge | **dsh-memento（本 kit）** |
|---|---|---|
| 宿主运行时树 | 打 **86 条补丁**（每次 APK 更新后必须重打） | **完全不碰** |
| 需要 guard 重打吗 | 需要（`guard.sh` + 启动自愈） | **不需要**：三处落点全是合并保留 |
| Android 专用修复 | 必须做 permission 预设固定 | **无需任何修复** |
| 客户端注入 | 5 项 `client.inject` | 无（`dsh.client.platform='web'`，未声明 inject） |

> 本 kit 的 `tools/guard.sh` 因此只做「体检 + 装配漂移自愈」，**不写宿主树**。
> 这是刻意的：纯 JS 插件不该去动宿主文件，那只会平白增加风险面。

---

## 2. 仓库侧会不会被上游合并冲掉（实测三场景）

`tools/sim-upstream-merge.sh` 复刻 `daily-sync.yml` 的真实动作
（`git merge --no-edit -X theirs upstream/main`），三个场景各自独立建仓：

| 场景 | 上游动作 | 实测结果 |
|---|---|---|
| **A** | 没碰 `port/` | 移植件**逐字节保留** ✓（sha256 前后一致） |
| **B** | 也改了同一文件 | `-X theirs` 判上游赢 → 我们的内容被改（**唯一真正的覆盖路径**） |
| **C** | 删除该路径 | `CONFLICT (modify/delete)`：合并**不完成**、需人工解决（本地版本留在工作区） |

脚本里写死了两条构造纪律（都是前几版踩过的坑）：每个场景独立建仓，且
`git branch upstream` 必须在**分叉点**执行——否则两侧同源，merge 退化成 fast-forward，
`-X theirs` 根本不上场，会得到假结论。

**结论**：只有当上游**恰好也管同一路径**时，仓库里的副本才受影响。
而设备上的移植件（profile 内已装文件 + 设备侧 kit 副本）**不依赖仓库路径**，
所以 B/C 都不影响已装好的功能——仓库那份只是版本化分发与跨机重建入口。

---

## 3. 日常操作

```bash
K=/storage/emulated/0/Download/DSH/记忆插件移植/port/dsh-memento   # 设备侧 kit
# 或仓库分支里的 port/dsh-memento

bash $K/port.sh status        # 只打印现状，不改任何东西
bash $K/port.sh verify        # 体检：文件 / 装配 / 模块加载 / 引擎内 fiber
bash $K/port.sh install       # 离线铺文件 + 修装配（幂等，默认跳过已同版本的文件）
bash $K/port.sh install --force    # 强制重铺
bash $K/port.sh install --enable   # 顺手清掉隔离（quarantine）禁用行
bash $K/port.sh uninstall          # 卸载（保留记忆库；--purge 连记忆库一起删）

bash $K/tools/guard.sh        # 防覆盖守卫：体检 → 漂移就自愈 → 复核 → 记日志
bash $K/tools/guard.sh --dry  # 只体检不写盘
bash $K/tools/sim-upstream-merge.sh   # 上游合并三场景实证

# 三条离线自测（都不碰真记忆库：各自建临时库 / 用 DOM 桩 / 用临时工作树）
node $K/tools/verify-overlay.mjs       # 移植链四段：上游基线→补丁→overlay→payload→已装副本（逐字节）
node $K/tools/test-decide-route.mjs    # 裁决路由 16 项：批准走协议通道/超预算409/重复409/非POST405/缺参400/never 403/活会话溯源
node $K/tools/test-client-panel.mjs    # 客户端：按钮渲染 + POST 载荷 + 失败态状态行
node $K/tools/make-patches.mjs         # 改了 overlay 后重新生成三个补丁（a/ b/ 相对路径）
```

`verify` 四段全部 PASS 才算在位：

```
== 1. 文件 ==           插件包 + bundle patch + client 半边 + 原生二进制计数（应为 0）
== 2. 装配 ==           dependencies 键与 dsh.profile.bundles 选择
== 3. 模块可加载 ==      import('dsh-memento') 成功
== 4. 引擎内 fiber ==     include:memento enabled=true fiber=active
```

### 每次装完新 APK 之后

1. 打开应用，等引擎起来。
2. 跑 `bash $K/port.sh verify`。
3. 若第 4 段 FAIL：先 `install --enable`，重启应用后再 `verify`。
   （预期**不需要**这一步——本插件不改宿主树，三处落点都是合并保留。）

---

## 3.1 面板里的「批准 / 驳回」按钮

面板「待审批提案」区现在每条提案带两个按钮：

- **批准**：真正落一条记忆（先过预算门，超限 409 响亮失败，绝不截断），写审计行 `add`，
  提案状态转 `approved`。
- **驳回**：只改状态为 `dismissed`，写审计行 `proposal-dismissed`，不写记忆。

按钮走 `POST /api/memento/proposal-decide` `{id, action:"approve"|"dismiss"}`，
写盘语义与 `/memory proposals approve|dismiss <id>` 完全一致，差别只是触发者是人点按钮。

> 为什么之前没有：面板上游只有三条**只读**路由（entries/audit/proposals），
> 裁决入口只存在于 `/memory` 命令。这不是渲染故障，是没有这条通路。
> 详见 `patches/README.md` 的 `panel-proposal-decide`。

两条路都可用，按场景挑：日常点按钮，脚本化/批量用 `/memory` 命令。

---

## 3.2 面板里的「编辑 / 删除 / 新增」（2026-11-12）

上游面板只是浏览器：能看条目、看预算、看审计、看提案，**一条也改不了**。手机上要改一条记忆
就得回忆起子串、记得住 track/scope、还要在键盘挡着列表时敲 `/memory replace <子串> => <新文本>`。
本轮把增删改做进面板（第 4、5 号补丁）：

| 位置 | 操作 | 行为 |
|---|---|---|
| 每条记忆卡片 | **编辑** | 就地展开 textarea（整条替换，不做 diff 猜测），保存/取消 |
| 每条记忆卡片 | **删除** | 二次确认后删除；审计行 `remove` 保留 |
| 面板顶部「＋ 新增记忆」 | **新增** | 选 track / scope / 工作区，填文本，提交即落盘 |

全部走 `POST /api/memento/entry-write`，服务端把这些 op 转成 `service.add / replace / remove`
——**审批门、预算门、唯一子串定位、审计行、会话事件、usage 返回值与命令面/工具面完全同形**，
不复制任何写语义（上游日后改协议，面板自动跟随）。

### 定位方式：用「该条全文」当 match

`/memory` 与协议通道都按**唯一子串**定位条目，而面板拿得到 id。这里刻意不猜子串（会撞多命中），
而是把该条目的**完整文本**作为 `match`：

- 完整文本必然唯一 → 命中；
- 若真有两条一模一样的条目 → 服务端回 `409 AMBIGUOUS_MATCH`，**响亮失败**而不是悄悄改错一条。

### 三条失败封闭（都有离线用例）

| 场景 | 结果 |
|---|---|
| `scope=workspace` 但没给 workspaceKey | `400` 且零写入 —— 无键条目任何会话都看不见，等于写进黑洞 |
| 会话级 `writePolicy: never` | `403`，零写入（与命令面同一道门，按钮不是后门） |
| 编辑/删除定位不到或命中多条 | `409 ENTRY_NOT_FOUND` / `409 AMBIGUOUS_MATCH`，原文不动 |

### 移动端形态

- 抽屉窄屏改 `100vw`（原来是 `92vw`，右侧留缝）；
- 条目按钮加大点击区（`padding: 7px 14px`）；
- **设置页**的数值输入框窄屏从固定 `240px` 改为整行（原来 label 与输入框被挤成多行碎块），
  footer 的保存/放弃按钮也换行显示。

### 自测（可重跑）

```sh
node tools/test-entry-write.mjs      # 18 项：add/replace/remove/缺键/空文本/不存在/多命中/405/400/never 403/workspaces
node tools/test-client-entries.mjs   # 客户端：编辑/删除/新增的真实 POST 载荷 + 失败态状态行
node tools/verify-overlay.mjs        # 五段逐字节：上游 → 5 个补丁 → overlay → payload → 已装副本
```

> ⚠️ 与 3.1 同一个前提：`node_modules` 不进 HMR，**必须重启一次 DeepCode**，
> 面板才会出现这三组按钮。落盘未重启时引擎仍跑旧模块（`POST /api/memento/entry-write` 回纯文本 `unauthorized`）。

---

## 4. ⚠️ 开箱默认值需要改

| 配置 | 默认 | 建议 | 影响 |
|---|---|---|---|
| `writePolicy` | `'ask'` | `'auto'` | 默认**每次写记忆都弹审批**，日常非常烦 |
| `language` | `'en'` | `'zh'` | 快照文案与工具描述语言 |
| `retrieval.vector` | `false` | 保持 `false` | 开它需要 embedding provider，Android 上不建议 |
| `snapshotOrder` | `-50` | 默认即可 | 注入在 harness identity(-100) 之后、persona(0) 之前 |

配置走 profile 的 patch 层，热生效。`writePolicy: 'ask'` 本就是为可审计设计的
（每次写入走审批瀑布、被拒也留 `*-denied` 审计行），只在需要严格把关时切回 `ask`。

### 改法（二选一）

**推荐：设置页改。** memento 用 `ctx.configForms.get(entryId)` 注册了实时表单
（`dsh.configForms` 由 `dsh-client-ui-settings` 提供，0.2.2-rc.1 实测在位），
表单里的可编辑字段都是 `.volatile()`，提交后**热生效、不需要重启**。

**备选：profile patch 写死。** 在 `$DSH_HOME/profiles/web/cordis.patch.yml` 末尾追加：

```yaml
- id: memento
  config:
    writePolicy: auto
    language: zh
```

> **本机已按此落盘**（2026-11-11 00:04）：设置页写入后，宿主自动把它合并进
> `profiles/web/cordis.patch.yml`，内容即上面这段，属用户面 patch 条目，重启后保留。
> 等效地也可以直接在设置页里点选（`settings/mutate` → `memento` 命名空间），
> 两条路径落到同一个地方。

### `language: zh` 生效范围（实测逐层核对）

| 层面 | 是否跟随 `language` | 备注 |
|---|---|---|
| 悬浮窗/抽屉文案 | ✅ | 按钮 `🧠 Memory` → **`🧠 记忆`**；面板 373 条中文词条 |
| 快照注入文案 | ✅ | `SNAPSHOT_HEADER` / `GROUP_TITLES` / `PROPOSAL_HEADER` 均有 zh 表 |
| `/memory` 命令输出 | ✅ | 热生效 |
| 面板条目渲染 | ✅ | 语言来自 `/api/memento/entries` 的 `language` 字段 |
| **`memory` 工具描述** | ⚠️ **不跟随** | 注册期固定（`makeMemoryTool(service, language)` 在挂载时定型），改语言后需**重启应用**才换 |

> ⚠️ **坑（实测）**：客户端文案只在**页面加载时探测一次**
> （`probePanelState()` → `installPanel(state)`，`S = STRINGS[state.language] ?? STRINGS.en`）。
> 所以改完配置**必须刷新一次页面**，悬浮窗才会从英文变中文。
> 服务端此时已正确返回 `{"language":"zh"}`（已用 `/api/memento/entries` 核实）。

> 本 kit **不自动写这一条**，是刻意的：它会改 profile 的用户面 patch，
> 而你那份 patch 里已经有 dsh-purge 的 permission 固定与 `autoApplyOnStart`，
> 无谓的追加只增加与上游合并的冲突面。要固定行为时再手工加，加了也属「用户独有条目」，
> 按 `FactoryProfilePatch.kt` 的「其它 live 独有条目原样保留」不会被动。

---

## 5. 载荷与可复现性

```bash
bash $K/fetch-payload.sh --pack     # 按 manifest 钉住的版本从 npm 重建载荷并核对 sha256
node $K/tools/verify-overlay.mjs    # 不下载也能核对：上游基线↔补丁↔overlay↔payload↔已装副本
```

- 载荷：`payload.tar.gz`，**232,297 B / 46 文件**，sha256 `12edcc8e2c9d608babe2d49aac51aeb073df48955e620b7b856f9e6ba0114628`
- 布局：`node_modules/`（仅 `dsh-memento`，纯 JS，无原生绑定、无符号链接）
- 组成：**上游 + overlay 覆盖层**（两个文件被本地补丁改写：`index.mjs`、`client/client.js`）
- 打包器：`tools/pack-payload.mjs`（确定性 ustar + 固定 mtime，不用系统 tar ——
  本机快照里的 tar 会 exec 到 gzip，实测 "Cannot exec: No such file or directory"）

### 三层结构与各自的 sha256（`manifest.json`）

| 层 | 内容 | 记在哪 |
|---|---|---|
| `upstream` | npm tarball 里的两份原始文件（**基线**） | `manifest.upstream.files` + `tarballSha256` |
| `patches/*.patch` | 三个相对路径补丁（可 `patch -p1` / `git apply -p1`） | `manifest.patches[].sha256` |
| `overlay/` | 补丁后态（**kit 的安装源**） | `manifest.overlay.files` |
| `payload.tar.gz` | 上游 + overlay 打成的离线包 | `manifest.payload.sha256` |

重建路径：下载上游 → **按 `upstream.files` 核对基线** → 覆盖 `overlay/` → 按 `overlay.files` 复核 → 打包 → 核对 `payload.sha256`。
任一环节不符即响亮失败（不静默用错基线）。

---

## 6. 为什么选它（选型依据摘要）

| 插件 | dsh 引擎声明 | 0.2.2 实测 | 原生依赖 | 自动化方式 |
|---|---|---|---|---|
| **dsh-memento** | ✅ 显式含 `>=0.2.2-0 <0.3.0` | 装成功 + 挂载成功 + 存储冒烟全绿 | **零** | 模型主动写（默认 `ask`） |
| meow-memory | ❌ 未声明（自称 0.1.5） | 记忆可用，**设置页静默失效** | 零 | 全自动（每消息命中 + dream） |
| dsh-mnemon | `… <0.3.0-0` | **semver 判定 false** | — | — |

关键鉴别：0.1.7 起宿主把设置注册面整体换成 `ctx.configForms`，
核心里 `installSection` / `settingsScope` / `settings.register` **全都不存在**。
dsh-memento 写的是**真双分支**（`configForms.get(entryId)` 优先、旧 `settingsScope` 兜底），
因此在 0.2.2-rc.1 上设置面与记忆功能都完整可用。

---

## 7. 移植缺陷与修复（2026-11-11 第二轮：独立审计）

审计方式：读 npm 真源码 + 读 0.2.2-rc.1 宿主符号 + 隔离复现 + 实机状态核对。
每条都带**可复现证据**，不靠结论复述。

### ① 装配漂移（真实存在，已修）

`profiles/web/package.json` 里 `dsh.profile.bundles` 有 `dsh-memento`，
但 `dependencies` **没有** `dsh-memento` 键。

```
$ bash port.sh verify
== 2. 装配（package.json）==
  FAIL  package.json 里缺依赖键或 bundles 选择（重跑 install）
$ bash tools/guard.sh --dry
  ② [!] 装配漂移（依赖键或 bundles 选择丢了）
```

危害：插件目录靠 bundles 选择仍能挂载（引擎实测 `fiber=active`），但 **profile 的依赖树里没有它**——
任何真正的包管理器操作（`pnpm install`、插件管理器的 inventory/prune）都可能把它当无关目录清掉。
文档里「三处落点天然合并保留」的前提是**装配声明在用户清单里**，漂移后这个前提就没了。

修：`bash port.sh install`（装配步无条件执行）→ 现在 `dependencies.dsh-memento: 0.5.30` 在位，
`guard.sh` 复核「干净（三处落点全在位）」。

### ② 载荷重建会丢补丁（最严重的一条，已修）

旧 README 记的载荷指纹是 `226,887 B / sha256 0c8d7ee3…`，
而 kit 里实际分发的 `payload.tar.gz` 是 `231,190 B / 423a1dd1…`。实测复现：

```
# 把 npm 上游单独打一份载荷
node tools/pack-payload.mjs --root <上游树> --out /tmp/unpatched.tar.gz
→ entries 46, bytes 226887, sha256 0c8d7ee3b5a9a3cb96981c782abe1df86f8bbec7b1d68812e7165a15be0ae008
```

也就是说：**旧 README 记的那份就是「没打补丁的上游」**。而 `fetch-payload.sh` 恰好只做一件事——
从 npm 拉上游。于是：

- 新机/换机/清空 `payload/` 后重建 → 得到未打补丁的包 → **设置页只读 + 面板没有审批按钮**两个修复全部消失；
- 而脚本紧接着按 `manifest.payload.sha256` 自检 → 必然不一致 → 报错退出。
  → 「离线兜底路径」在真实场景里等于不可用。

修：载荷 = **上游 + `overlay/` 覆盖层**，重建时先核对 `upstream.files` 再覆盖 overlay 再复核
（`copyFileSync`，不依赖 git/patch）。实测：

```
$ rm -rf payload payload.tar.gz && bash fetch-payload.sh --pack
fetch dsh-memento@0.5.30 … 0.22 MB, 46 files
base  index.mjs ✓          base  client/client.js ✓
overlay index.mjs ✓        overlay client/client.js ✓
{"entries":46,"bytes":232297,"sha256":"12edcc8e2c9d608babe2d49aac51aeb073df48955e620b7b856f9e6ba0114628"}
载荷 sha256 与 manifest 一致：12edcc8e…
```

### ③ 补丁不可移植（已修）

旧补丁的头部：

```
--- /storage/emulated/0/Download/DSH/记忆插件移植/port/dsh-memento/patches/index.mjs.orig2
+++ /data/data/com.dsharnessmobile.shell/files/home/.dsh/profiles/web/node_modules/dsh-memento/index.mjs
```

`---` 侧指向生成时的**临时文件名**，`+++` 侧是**设备绝对路径**。
`git apply -p1` 只有在 `cwd=/` 时才可能命中（且要路径逐字一致），换设备/换 DSH_HOME 立刻失效；
`port.sh install` 也从不应用补丁（补丁只是文档）。实测对上游工作树应用旧补丁：全部 `No such file or directory`。

修：`tools/make-patches.mjs` 统一生成 `diff --git a/<相对路径> b/<相对路径>` 形式，
`patch -p1` / `git apply -p1` 通用；`tools/verify-overlay.mjs` 逐字节证明
「上游 + 三个补丁 = overlay」，并核对 overlay = payload = 已装副本。

### ④ 面板批准绕过协议写通道（已修）

第一版 `POST /api/memento/proposal-decide` 直接 `store.insertEntry` + 手写审计行。
它在「能用」这一层没问题（离线 8 项全绿），但**复制了协议逻辑**，于是少了一整套写路径语义：
`#validateEntry`、预算复审、`#appendWriteEvent`（`memory/added` 会话事件）、`usage` 返回、
并发裁决时「写已成功就不改用提案状态错误掩盖」、以及会话级 `never` 不可绕过。

现已改为走 `service.add()`，gate 表达「人的点击 = 一次性放行」，
`never` 策略 403 且**零写入**（离线自测 16 项覆盖，含 `add-denied` 审计行）。
详见 `patches/README.md` 的对照表。

### ⑤ 安装目录残留与文档数字漂移（已修）

- `profiles/web/node_modules/dsh-memento/client/client.js.prememento.bak`：升级残留，
  已删除（补丁基线在 kit 的 `patches/`，不需要在 profile 里留备份）。
- `patches/` 里同时存在 `*.orig` / `*.pre-decide` / `*.post-decide` / `*.orig2` 四套同内容文件，
  命名互相矛盾。现已规范为 `*.upstream`（上游基线）、`client.js.softwait`（补丁①后态）、
  `overlay/`（全部补丁后态）、`patches/archive/`（历史存档）。

### ⑥ 复核未发现缺陷的项（避免「凭印象报缺陷」）

| 疑点 | 实测结论 |
|---|---|
| `ctx.get('connection')?.requestRejection(req)` 是否真存在 | ✅ `dsh-client-connection/lib/index.js:737`，放行返回 `undefined`，拒返回 403/401（补丁的失败封闭写法正确） |
| 宿主是否收录 `memory/*` 会话事件 | ❌ 不收录（上游注释已说明）⇒ 会话事件本来就 `skipped-unknown-type`，不是移植引入的缺口 |
| 面板 client 半边是否真的被服务到浏览器 | ✅ boot 图含 `dsh-memento`（application 批次合并请求），取回的 bundle（57,993 B）含 `mem-approve`/`mem-dismiss`/`proposal-decide`/`rebind`/`记忆` 标记 |
| 引擎内是否真的活跃 | ✅ `include:memento → dsh-memento enabled=true fiber=active`；`/api/memento/proposals` 200；`proposal-decide` GET 405（路由在位） |
| 载荷条目数 46 是否为错 | ✅ 正确：`pack-payload.mjs` 只数常规文件，tar 里另有 9 个目录项（46+9=55） |
| 是否有原生二进制/网络/子进程 | ✅ 0 个 `.node/.so/.wasm`，无网络调用 |

### ⚠️ 生效前提

`node_modules` 下的文件被 HMR **默认忽略**（`ignored: ["**/node_modules"]`），
所以本轮对 `index.mjs` 的改动（协议通道版裁决路由）**必须重启一次应用**才生效；
在重启前，运行中的引擎仍执行上一版路由（同样可用，只是少上面④里列的语义）。
