# MemoryBear（`@redbearai/dsh-memorybear`）在 dsh-mobile-apk 上的移植包

把 [SuanmoSuanyangTechnology/MemoryBearDSHPlugin](https://github.com/SuanmoSuanyangTechnology/MemoryBearDSHPlugin)
（上游 Apache-2.0）移植进本机的 DeepCode（`com.dsharnessmobile.shell`），并与已移植的
**dsh-providers-hub**（[port/jet-hub](../jet-hub)）、**dsh-purge-community**（[port/dsh-purge](../dsh-purge)）
三者共存、互不影响。**不依赖改 APK、不改仓库构建链、不影响每日从上游 fork 重建的迭代。**

| 项 | 值 |
|---|---|
| 上游 | `https://github.com/SuanmoSuanyangTechnology/MemoryBearDSHPlugin`（Apache-2.0，分支 `dev`） |
| 钉住版本 | **`@redbearai/dsh-memorybear@0.2.4`**（npm 发布版，含预构建 `lib/`；无 `prepare` hook，安装不需构建授权） |
| 同包备选 | **`@redbearai/dsh-memoryskills@0.2.4`**（同仓另一条产品线，payload 里同样备好，按需切换） |
| 共享 core | `@redbearai/dsh-memory-core@0.1.3`（两插件的真依赖） |
| 运行时 | dsh **0.2.2-rc.1**（随 APK 快照），Node v24.18.0 |
| 载荷 | `payload.tar.gz` 141 KB / 119 个文件 / 解包 527 KB，`sha256 e5ec4d10…`（`fetch-payload.sh --pack` 可复现） |
| 装配 | profile `dsh.profile.bundles` → 包自带 `cordis.patch.yml` 完成 insert（`id: memorybear-memory`） |
| 落点 | 全部在 **app 私有数据**内，main 分支只放 4 个脚本 |

> 上游自测环境是 dsh 0.2.0-rc.2；本机 0.2.2-rc.1。本 kit 的 `verify --engine` 补上了本机实测运行态。

---

## 1. 为什么每日新构建物覆盖不掉它

落点全部在 **app 私有数据**，而工具链的更新只碰「运行环境」和「仓库」：

| 落点 | 位置 | 更新时的命运 |
|---|---|---|
| 插件包 | `files/home/.dsh/profiles/web/node_modules/@redbearai/{dsh-memorybear,dsh-memoryskills,dsh-memory-core}` | 快照刷新是**合并**不是替换：工厂面没有同路径文件 ⇒ 原样保留 |
| 装配声明 | `files/home/.dsh/profiles/web/package.json`（`dependencies` + `dsh.profile.bundles`） | `SnapshotTransaction.kt:660-666`：dependencies 与 bundles 取并集、同名冲突保留用户 pin |
| 共享依赖 | `node_modules/@deepseek-ai/schemastery`、`@deepseek-ai/cosmokit`、`@standard-schema/spec` | install 时**已在位且逐字节一致就不动**；uninstall 时**永不删** |
| 连接配置 | 网页版 Plugins 页写入的 profile patch 层 | 用户独有条目，`FactoryProfilePatch.merge()` 逐字节保留 |

**为什么走 `dsh.profile.bundles` 而不是手工 patch insert**：与 Jet Hub、破甲**完全同构** ——
包自带 `dsh.bundle.patch`（`package.json` → `cordis.patch.yml`），由它完成 `insert`，
本层只保留「按 id 覆盖 config」的能力。这样客户端半边（`lib/client.js`）才能按插件身份挂载，
配置页的 volatile 热更新也才走得通。

**唯一风险**：若哪天自动化改成 `git reset --hard upstream/main` 或强推 `main`，`port/` 会被抹掉 ——
用分支 `port/memory-bear` 或本机副本回放即可（见第 6 节）。

---

## 2. 与另两个已移植插件的共存契约

三者**没有任何命名空间交集**（`port.sh verify` 第 5 段每次都会复验）：

| 维度 | **memory-bear** | dsh-providers-hub | dsh-purge-community |
|---|---|---|---|
| 工具名 | `memory_search`（+ `preferenceMode: tool` 时 `memory_preferences`） | 不注册全局工具 | 不注册全局工具 |
| HTTP 路由 | `/api/memorybear/insights`、`/api/memorybear/update` | `/api/subscription/*`、本地网关 `:8326` | `/dsh-purge/*`、`/redteam/api` |
| 客户端 slot | `plugins.bundle.config`（按 id 分片）、`sidebar.right.pane.tab`（右侧栏「记忆」页） | `main`、`settings.section`、`plugins.bundle.config` | `conversation.input.right`、`shell.overlay`、`main`、`plugins.bundle.config` |
| 自定义服务 | 无（只 `inject: agents, sessions`） | `officeaceAuth`、`accountPool` 等 | 无 |
| IO 依赖 | 零（deps 只有 `@deepseek-ai/schemastery` + `@redbearai/dsh-memory-core`，两份都已在本机） | 自带 `jose`/`undici`/`wreq-js` | 自带 `yaml@2.9.1` |
| 状态文件 | `$DSH_HOME/memory-bear-port-state.json` | `$DSH_HOME/port-state.json` | `$DSH_HOME/purge-port-state.json` |

两处需要说明的**刻意不冲突**：

1. **`plugins.bundle.config` 是三方共用 slot，但它是按插件 id 分片的命名空间** ——
   宿主为每个 id 各渲染一份配置面板（Jet Hub 渲染 `#dsh-providers-hub`、破甲 `#dsh-purge`、
   本插件 `#redbearai/dsh-memorybear`），不是抢同一个坑位。Jet Hub 与破甲本来就已经共存于该 slot。
2. **`sidebar.right.pane.tab` 是独占坑位**，本插件用它做右侧栏「记忆」页 ——
   该坑位此前由已卸载的 `@nanmicoder/dsh-agent-teams` 占用，现已空出，Jet Hub / 破甲都没碰它。
   复验方式见 `port.sh verify` 第 5 段（它会把独占坑位的冲突单独标 WARN）。

**同一个引擎内的实测共存**（隔离引擎，2026-11-10）：

```
PASS  include:memorybear-memory → @redbearai/dsh-memorybear enabled=true fiber=active
PASS  共存复核（同一引擎内）：include:codearts-auth=active / include:dsh-purge=active
```

---

## 3. 两个变体：为什么同时备好、只能挂一个

上游 monorepo 里是两条产品线，**各自注册同名 `memory_search` 工具**，上游 README 明写
「Install one of them, not both」。因此本 kit：

- payload 里**两个变体都备齐**（切换零成本）；
- `dsh.profile.bundles` / `dependencies` 里**任何时候只登记一个**（`verify` 第 2 段会断言这一点）。

| 变体 | 包 | 后端 | 要配什么 | 额外路由 |
|---|---|---|---|---|
| `memorybear`（默认） | `@redbearai/dsh-memorybear` | MemoryBear Enterprise V1 API | `baseURL`、`endUserId`、`MEMORYBEAR_API_KEY` | `/api/memorybear/insights`（记忆面板） |
| `memoryskills` | `@redbearai/dsh-memoryskills` | MemorySkills Portal | `portalURL`（默认 `https://memoryskills.redbearai.com`）、`MEMORYSKILLS_API_KEY` | 无面板 |

切换：`bash port.sh switch memoryskills`（等价 `install --variant memoryskills --force`）。

---

## 4. 安装 / 状态 / 体检 / 卸载

```bash
KIT=/data/data/com.dsharnessmobile.shell/files/home/dsh-memory-bear-port   # 本机工作副本
bash "$KIT/port.sh" install                 # 离线安装/修复（幂等）；--variant 切变体；--force 强制重铺
bash "$KIT/port.sh" status                  # 只打印落点与版本
bash "$KIT/port.sh" verify                  # 离线体检：文件/装配/模块契约/合成树/与另两插件无冲突
bash "$KIT/port.sh" verify --live           # 追加：只读查询线上引擎（4145）的装配表，不动进程、不重启
bash "$KIT/port.sh" verify --engine         # 追加：隔离 DSH_HOME 起独立引擎（:4799）实测挂载，完全不碰线上
bash "$KIT/port.sh" uninstall [--purge]     # 卸载；共享依赖永不删
```

仓库里不背二进制载荷：`bash fetch-payload.sh` 会按 `manifest.json` 钉住的版本从 npm 重新拉，
并用 `sha256` 逐个核验；`bash fetch-payload.sh --pack` 用
`GNU tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner + gzip -9` 打回同样的确定性载荷。

---

## 5. 凭据与连接：先拿 key，再填两处

### 5.1 拿 key —— 看你走哪条产品线

| | **memoryskills**（个人入口，自助） | **memorybear**（企业 V1，需租户） |
|---|---|---|
| 入口 | <https://memoryskills.redbearai.com/#/login> | 你自己的 MemoryBear 服务（`https://<host>/v1`） |
| 注册 | **邮箱验证码登录即注册**：输入邮箱 → 发送验证码 → 填 6 位验证码 → 登录。首次登录出「记忆熊凭证已生成」页，点**复制全部凭证** | 在 MemoryBear 控制台/管理接口里取 **workspace API key**，并**先建好一个 end_user**（插件不会创建 end_user） |
| key 形态 | `sk-mem-…`（插件会校验这个前缀） | 控制台签发的 workspace key |
| 事后找回 | 底部「我的记忆」→ **Memory API Key**（"注册时签发一把，登录时返回同一把 Key"；刷新页面后完整 Key 会从浏览器内存清除，重新登录即可） | 控制台可重新查看/轮换 |
| 还要填 | Portal 地址（默认 `https://memoryskills.redbearai.com`，一般不用改） | `baseURL` + `endUserId`（end_user UUID） |
| 额度 | 有写入次数概念（注册赠送 / 可购买，用尽后暂停写入） | 按你自己的部署 |

**当前本机挂的是 `memorybear` 变体**。没有 MemoryBear 租户就直接切到自助那条：

```bash
bash ~/dsh-memory-bear-port/port.sh switch memoryskills
```

### 5.2 填 key —— 两处，各管一件事

| 填什么 | 填哪儿 | 存到哪 |
|---|---|---|
| **key**（敏感） | 网页版 `设置 → Plugins → MemoryBear / MemorySkills` 面板的 **API Key** 字段 | **dsh 凭据库**（`.credentials.yaml` 的 `refs` 段，引用名 `MEMORYBEAR_API_KEY` / `MEMORYSKILLS_API_KEY`）。页面原文："保存在 dsh 凭据库（{ref}），不写进设置文件。留空表示保持当前密钥。" |
| **连接字段**（`baseURL`+`endUserId` / `portalURL`） | 同一个面板的对应输入框 | profile `cordis.patch.yml` 的 `- id: memorybear-memory` 条目（volatile 字段，保存即热更新） |

**终端等价操作**（走引擎自己的 `credentials/set` RPC —— 和网页版那条路完全一样）：

```bash
bash ~/dsh-memory-bear-port/port.sh key                    # 只读：两个变体的 key 是否已配置
printf '%s' 'sk-mem-你的key' | bash ~/dsh-memory-bear-port/port.sh setkey
bash ~/dsh-memory-bear-port/port.sh setconn https://<host>/v1 <end_user-uuid>   # 仅 memorybear 需要
bash ~/dsh-memory-bear-port/port.sh unsetkey               # 想换/撤销时
```

`setkey` 默认从**标准输入**读（不进 shell 历史、不进命令行参数）；用 `--ref NAME` 可指向别的引用名。

### 5.3 填完怎么确认

1. 配置页应显示 **「已配置密钥（来源：…）」**（未配置时是"未配置密钥；配置之前读写记忆都会被拒绝"）。
2. `engine.log` 里应有插件自报：

```
[memorybear-memory] loaded; endUser=<uuid>; profile=false recall=true preferences=auto write=true/turn tool=true
```

3. 想立刻试：问它一句"我上次说我喜欢什么？"，或直接看右侧栏「记忆」标签页是否有数据。

**几个坑**：

- key 若来自**启动环境变量**，面板字段会**锁死**（"密钥由启动环境变量 {ref} 提供，这里不能改"）——要改得从启动环境改。
- `baseURL`/`endUserId` **都填上**之前插件**不连任何服务**（召回/写入关闭、`memory_search` 返回"未配置"），所以默认挂载是零网络副作用的。
- 两变体**不可同装**（同名 `memory_search`）：`port.sh switch` 会把另一个从 `dependencies`/`bundles` 里摘掉，文件保留以便随时切回。
- MemoryBear 侧的 **end_user 必须事先存在**，插件只写不建。

---

## 6. 验收记录（2026-11-10，本机实测）

| 段 | 结果 |
|---|---|
| 模块契约（profile 根解析依赖） | `memorybear-memory｜function｜agents,sessions｜Config=function(29字段)` |
| 合成树 `prepareProfile('web')` | `n=1 override=1 jet=1 purge=1 "skippedBundles":[]`（本插件 1 条 insert + 1 条同 id config 覆盖，另两插件都在，无跳过 bundle） |
| 共享依赖 | 新装 0 / **已在位且逐字节一致 3**（schemastery 3.19.0、cosmokit 1.9.0、@standard-schema/spec 1.1.0） |
| 工具名交集 | 本插件 `[memory_preferences, memory_search]`，另两者 `[]` ← 无交集 |
| 路由交集 | `/api/memorybear/*` vs `/api/subscription/*` `/dsh-purge/*` ← 无交集 |
| 隔离引擎实启 | `include:memorybear-memory → @redbearai/dsh-memorybear enabled=true fiber=active`；同引擎内 `codearts-auth=active`、`dsh-purge=active` |
| **线上引擎实查** | **线上 4145 也已挂载**（`verify --live`）：<br>`include:memorybear-memory → @redbearai/dsh-memorybear enabled=true fiber=active`<br>`include:codearts-auth → dsh-providers-hub enabled=true fiber=active`<br>`include:dsh-purge → dsh-purge-community enabled=true fiber=active` |

**不需要重启**：loader 已经把新的 bundles 选择与 patch 组合进来了（线上查询即为此证）。
若哪天行为可疑，`bash port.sh verify --live` 是零副作用的复核手段；重启一次也能重新走同一份合成树。

隔离引擎的启动参数与线上那条**逐字对齐**（`node --expose-internals …/lib/bin.js web --port <P> --no-open`）；
少了 `--expose-internals` 会在 `node-addon-require-builtin` 的回退路径上挂在
`Cannot find module 'internal/modules/esm/loader'` 这类错上。它用**隔离的 DSH_HOME**
（`$DSH_HOME/port-backup/mb-engine/home/.dsh`，`node_modules` 软链真目录）和**独立端口**，
所以线上 4145 与其状态完全不受影响。

引擎日志中应能看到本插件自报的一行（`endUser=` 为空属正常 —— 还没配连接参数）：

```
[memorybear-memory] not configured (missing baseURL, endUserId); memory recall/write are off until set on the Plugins page or in the profile patch
[memorybear-memory] loaded; endUser=; profile=false recall=true preferences=auto write=true/turn tool=true
```

---

## 7. 目录与本机副本

| 路径 | 内容 |
|---|---|
| `README.md` | 本文件 |
| `manifest.json` | 钉住的版本、哈希、装配方式、共存契约（脚本都从它读，不写死） |
| `fetch-payload.sh` | 从 npm 重建离线载荷（带 sha256 核验） |
| `port.sh` | install / verify / status / switch / uninstall |
| `payload/`、`payload.tar.gz` | 二进制载荷（**不进 main**，见 `.gitignore` 的 `port/*/payload*`） |

本机工作副本：`$DSH_FILES_DIR/home/dsh-memory-bear-port`
离线载荷归档分支：`port/memory-bear`（`main` 只留脚本，与 `port/jet-hub`、`port/agent-teams` 同惯例）
