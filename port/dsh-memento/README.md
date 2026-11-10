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
| 漂移自愈反证 | 人为删掉 `dependencies.dsh-memento` 与 bundles 选择 → `guard.sh` 检出漂移并自动修复，package.json 逐字节还原 |

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
bash $K/fetch-payload.sh --pack     # 按 manifest 版本从 npm 重建 payload 并核对 sha256
```

- 载荷：`payload.tar.gz`，**226,887 B / 46 条目**，sha256 `0c8d7ee3b5a9a3cb96981c782abe1df86f8bbec7b1d68812e7165a15be0ae008`
- 布局：`node_modules/`（仅 `dsh-memento`，纯 JS，无原生绑定、无符号链接）
- 打包器：`tools/pack-payload.mjs`（确定性 ustar + 固定 mtime，不用系统 tar ——
  本机快照里的 tar 会 exec 到 gzip，实测 "Cannot exec: No such file or directory"）

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
