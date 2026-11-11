# dsh-purge Community（破甲）在 dsh-mobile-apk 上的移植包

把 [kingcharleslzy-ai/dsh-purge](https://github.com/kingcharleslzy-ai/dsh-purge)（社区维护版「破甲」插件，
包名 `dsh-purge-community`）移植进本机 DeepCode（`com.dsharnessmobile.shell`），并且**不改 APK、不改上游
仓库、不影响每日从上游 fork 的持续迭代**。

## 这个 kit 的两份形态

| 形态 | 内含 | 用途 |
|---|---|---|
| **仓库里的那份**（`port/dsh-purge/`） | 只有脚本与文档，**不含 2.2 MB 载荷**（与 `port/jet-hub` 同一约定） | 版本化、跨机；缺载荷时 `fetch-payload.sh` 按 `manifest.json` 现取 |
| **设备上的那份**（本目录 `port-kit/`） | 脚本 + `payload.tar.gz`（离线载荷） | 断网可装、可直接 `port.sh install` |

两份内容一致，差别只在有没有载荷。仓库那份重建载荷并核对哈希：

```bash
bash fetch-payload.sh --pack     # 下载 → 解包 → 打包 → 与 manifest.payload.sha256 比对
```
实测（2026-11-10）：直连 `github.com` 的 release 下载在本机**超时**，脚本自动回落到
`https://gh-proxy.com/`（200 / 2,098,818 B / 1.5s）；重建出的载荷
**2221766 B / 555 files / sha256 `2f0c375e…0e52`**，与 `manifest.json` 记录**逐字节一致**。

当前状态：**已装好、宿主补丁已打、运行态已核对**（2026-11-11 同步到上游 1.6.88 后复验）。

| 证据 | 结果 |
|---|---|
| 引擎装配（`pluginManager/listPlugins`） | `include:dsh-purge` / `-redteam` / `-presets` / `-redteam-store` / `-redteam-ui` 全部 `enabled=true fiber=active` |
| 宿主补丁 | `port.sh verify` 第 6 段 `applied=71/72`；`selfcheck` = `state=ok ok=true na=9 skipped=3 off=0 missing_file=0 level=qualified`、宿主 24/25 层 ok（`layout` 层 Web 宿主预期 `na`） |
| 锚点搬家 | `reanchor list` 为 `drifted=2`，两条都是 `optional`（#54 / #76，设计内的「已到位」）→ 不需要重锚 |
| 权限预设（Android 必需项） | 固定后 `include:permission enabled=true fiber=active`，`engine.log` 无 `did not activate` |
| 客户端装配 | 服务页面引用 `dsh-purge-community/client.js&rev=…`（左侧栏 Purge 设置页） |
| 安装集完整 | 设备上的插件目录与 release 发布物**逐文件相等**（324/324，无 dev 件残留、无差异文件） |
| 离线重放 | `port.sh install` 不联网：从 `payload.tar.gz` 解出文件再铺进 profile，装配由脚本写 `package.json` |

---

## 1. 三处落点，为什么每日新构建物覆盖不掉它

| 落点 | 位置 | 更新时的命运 |
|---|---|---|
| 插件包与依赖 | `$DSH_HOME/profiles/web/node_modules/dsh-purge-community`、`…/node_modules/yaml` | 快照刷新是**合并**不是替换：工厂面没有同路径文件 ⇒ 原样保留 |
| 装配声明 | `$DSH_HOME/profiles/web/package.json`（`dependencies` + `dsh.profile.bundles`） | profile 根清单属**用户面**，按「用户优先、工厂只补缺」合并 |
| 权限固定 | `$DSH_HOME/profiles/web/cordis.patch.yml` 末尾 `- id: permission` | 同上：profile patch 的用户独有条目逐字节保留 |
| 插件状态 | `$DSH_HOME/dsh-purge/`、`dsh-purge-community/`、`redteam/`、`prompt-inject.md` | 未登记项按用户数据保留 |
| **宿主补丁（86 条）** | 运行时树 `files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/…` | **会被快照整体换掉**：每次 APK 更新后需要重打（`port.sh apply`），见 §4 |

依据（`dsh-mobile-apk` 源码）：`SnapshotTransaction.mergeProfiles()/mergeTree()` 不删 live 独有目录；
`FactoryProfilePatch.merge()` 保留 profile patch 的用户独有条目；`ProfilePackageManifest.merge()`
以 live 为基座补工厂键；`PluginMounts.ensureHardBundlesSelected()` 只补工厂 bundle 选择。

---

## 2. Android 上的第一处必改项：permission 预设固定（其余见 §8）

打上 86 条宿主补丁后，沙箱/审批默认值被改成「完全访问 / never」，官方预设表推不出默认入口，
`@deepseek-ai/dsh-permission-presets` 的构造函数直接抛错，**该 entry 不激活**：

```
dsh: warning: 1 entry did not activate
permission (@deepseek-ai/dsh-permission-presets): Error: permission: composed sandbox and approval
defaults match no preset; configure defaultPreset explicitly
```

修法（`port.sh install` / `port.sh pin` 自动做，幂等）：在 profile patch 末尾追加

```yaml
- id: permission
  config:
    defaultPreset: danger-full-access
    presets:
      danger-full-access:
        sandbox: danger-full-access
        approval: never
```

固定后实测：`include:permission enabled=true fiber=active`，`selfcheck` 权限层 `state=ok
sandbox=danger-full-access approval=never`。

---

## 3. 日常操作

```bash
K=/storage/emulated/0/Download/DSH/破甲移植/port-kit     # 或分支里的 port/dsh-purge
bash $K/port.sh status        # 只打印现状
bash $K/port.sh install       # 离线铺文件 + 注册装配 + 修 permission 固定（幂等）
bash $K/port.sh apply         # 给宿主打 86 条清洗补丁（写入前自动备份）+ 再修一次固定
bash $K/port.sh revert        # 宿主补丁回滚到备份原件
bash $K/port.sh verify        # 体检：文件/装配/模块/执行器补丁/固定/引擎 fiber/宿主补丁
bash $K/port.sh uninstall     # 卸载（保留 prompt-inject.md 与规则；--purge 连状态一起删）
bash $K/port.sh sync --check  # 查上游最新 release（不下载；顺带打印上游改动说明）
bash $K/port.sh sync          # 拉上游最新 release → 重建 payload → 重装（需要网络，带镜像回落）
```

三个旁路工具（都幂等、都可只读）：

```bash
NODE=/data/data/com.dsharnessmobile.shell/files/usr/bin/node
$NODE $K/tools/patch-android-exec.mjs $K/payload/node_modules/dsh-purge-community --node $NODE --check
                              # Android 执行器补丁：只判定不写盘（已打上=0，漂移=1）
bash $K/tools/protect.sh verify      # kit 自身指纹体检（只读；port/dsh-purge 那份可直接跑）
bash $K/tools/protect.sh snapshot    # 改过 kit 后重新登记指纹（仓库那份要在 git 里跑）
bash $K/tools/protect.sh heal        # 指纹不符/文件被删时从 git 历史恢复（仓库那份）
bash $K/tools/after-upstream.sh      # 拉上游后的只读自检（载荷 sha / profile 装配 / 宿主补丁）
```

`verify` 七段：

```
== 1. 文件 ==           插件包 + yaml 依赖
== 2. 装配 ==           dsh.profile.bundles 选择 + dependencies 无 registry 地雷键（见 §8.1）
== 3. 模块可加载 ==      import('dsh-purge-community') 成功
== 3b. 执行器补丁 ==     Android 上 spawn(process.execPath) 的 6 处改写是否在位（见 §8.3）
== 4. permission 固定 ==  profile patch 里有固定块
== 5. 引擎内 fiber ==    五条 dsh-purge 行 + permission 行 enabled/active
== 6. 宿主补丁 ==        selfcheck 计数与权限层状态
```

插件本体在引擎里有一套干净的入口：左侧栏 **Purge** 面板、命令 `/purge status|apply|revert|…`、
以及 `purge_status` / `purge_apply` / `purge_revert` 三个工具。`port.sh apply` 与面板里的「应用」
走同一条 `applyPatchesAllHosts` 路径。

---

## 4. 每次装完新 APK 之后（建议顺序）

1. 打开应用，等引擎起来（触发快照刷新时会久一点）。
2. `bash $K/port.sh verify`。
3. 第 2 段 FAIL → 顺着看原因：写的是「bundles 未登记」→ `port.sh install`；
   写的是「registry 地雷键」→ 也跑 `port.sh install`（它会去毒，见 §8.1）。
4. 第 3b 段 FAIL（执行器补丁漂移）→ `port.sh install`（重打那 6 处，见 §8.3）。
5. 第 4 段 FAIL → `port.sh install`；第 5 段 FAIL → 重启应用后再试，仍 FAIL 则 `port.sh install --force`。
6. 第 6 段 `applied=0`（说明运行时树被换掉了）→ `port.sh apply`，然后重启应用。
7. 第 5 段报 `permission enabled=false` → `port.sh pin` 后重启应用（快照把固定块冲掉时会发生）。

只想跑一条命令：`bash $K/tools/guard.sh`（装配体检 + 宿主补丁体检，漂移自己修；
只想看不想改就加 `--dry`）。

---

## 5. 与远端仓库的关系（不干扰持续迭代）

- 本 kit 放在 **fork 的独立分支 `port/dsh-purge`**，`main` 上零 diff：每日「拉上游 → 重建 → nightly」
  链路只动 `main` 与构建输入，扫不到 `port/` 目录。
- 目录不在 `app/src/main/assets/`、`scripts/`、`plugins/`、`snapshot-config/` 等任何注入/门禁链路上，
  不参与快照装配、不影响 ABI/签名/资产清单。
- 合并上游：`git fetch origin && git merge origin/main` 只会在 `port/` 目录外产生上游改动，不会与本 kit 冲突
  （kit 只新增文件，且不碰 `main` 的任何路径）。
- **上游插件持续迭代**：`port.sh sync` 直接跟 GitHub Release（`kingcharleslzy-ai/dsh-purge` 的
  `dsh-purge-community-<版本>.tgz`），校验 release 的 `sha256:` digest 后重建 `payload.tar.gz` 并重装；
  不需要动 dsh-mobile-apk 的任何构建输入。

---

## 6. 包里有什么

```
port-kit/  （仓库里是 port/dsh-purge/，两份内容一致，差别只在有没有 payload）
├─ port.sh                     安装 / 打补丁 / 固定 / 体检 / 状态 / 卸载 / 上游同步
├─ manifest.json               钉住的版本、依赖、载荷 SHA-256、Android 改动与验证记录
├─ payload.tar.gz ~2.2 MB      离线载荷（node_modules 布局：dsh-purge-community + yaml，557 个条目，无符号链接）
├─ fetch-payload.sh            按 manifest 从发布源重建载荷（直连不通时自动走镜像）
├─ githooks/post-merge         pull / merge 后自动跑 after-upstream.sh（只读，恒退出 0）
├─ githooks/post-checkout      切分支后同样跑一次
├─ tools/pack-payload.mjs      纯 Node 重打包器（本机 tar 依赖 exec 到 gzip，实测不可用，故自带）
├─ tools/patch-android-exec.mjs Android 执行器补丁：改写 spawn(process.execPath) 的 6 处调用点（见 §8.3）
├─ tools/protect.sh            kit 防覆盖：指纹登记 / 校验 / 自愈 / 装 hook（见 §8.5）
├─ tools/protected.sha256      15 个受管文件的指纹（随仓库走；改过 kit 必跑 snapshot）
├─ tools/guard.sh              移植件守卫：装配体检 → 宿主补丁体检 → 漂移就重打 → 复核 → 记日志
├─ tools/after-upstream.sh     拉上游后的移植件守卫（只读；供 git hook 调用）
├─ tools/sim-factory-overwrite.sh  隔离演练：模拟工厂覆盖并验证自愈能把状态拉回与真身一致
├─ tools/sim-upstream-merge.sh 隔离演练：模拟上游合并（-X theirs）对移植件的影响
├─ tools/probe-states.mjs      逐条补丁状态探针（只读，用于真身/演练场比对）
├─ tools/publish-kit-to-main.mjs  把 port-kit 内容发布到仓库 port/dsh-purge（镜像用）
├─ README.md                   本文件
├─ out/                        本地诊断日志（不进仓库、不进指纹）
└─ .unpacked/                  首次 install 时解出来的缓存（可删）
```

版本：`dsh-purge-community 1.6.88`（release tgz，含预构建 `lib/`、`client.js`、`presets/`、`skills/`）、
`yaml 2.9.1`；宿主 `dsh 0.2.2-rc.1`。

> 为什么用 release tgz 而不是仓库源码：源码装要在设备上跑构建链，Android 上少一步构建就少一类失败面。

---

## 7. 上游更新存活契约（2026-11-10 加固）

前提：**DSH 主体继续拉上游、继续出新的构建物**，本插件要在那之后仍然在位、仍然生效。
下面三层保证，每层都给源码依据，不靠记忆。

### 7.1 第一层：home 用户面，快照合并本来就不动它

| 落点 | 更新时的命运 |
|---|---|
| 插件包 `profiles/web/node_modules/dsh-purge-community`、`…/yaml` | 工厂面没有同路径文件 → 原样保留 |
| 装配声明 `profiles/web/package.json`（dependencies + dsh.profile.bundles） | 取并集，同名冲突保留用户 pin |
| 权限固定与启动自愈开关 `profiles/web/cordis.patch.yml` | profile 根清单走特殊合并，用户独有条目逐条保留 |
| 插件状态 `$DSH_HOME/dsh-purge/`、`dsh-purge-community/`、`redteam/`、`prompt-inject.md` | 未登记项按用户数据保留 |

依据（`fork` 仓源码，可自行 grep 复核）：

- `app/src/main/java/com/dsharnessmobile/shell/SnapshotTransaction.kt:660-666`
  「staged 没有的条目一律不动（live-only 的用户内容天然幸存）」；
  「`package.json`：dependencies 与 dsh.profile.bundles 取**并集**，同名冲突保留用户 pin」；
  「`cordis.patch.yml`：按 id 合并——live 内容为基，追加 live 缺失的工厂块」
- 同文件 `:1114` / `:1187`「递归合并：staged 权威 + live-only 不动；只有 userFacingFiles（profile 根清单）走特殊合并」
  「不做整目录替换（那会抹掉用户数据）」
- `FactoryProfilePatch.kt:37`「其它 live 独有条目（用户追加块、用户自建 profile 条目）**原样保留**」

**结论：插件包、装配声明、配置条目、状态数据这四类，上游更新冲不掉。**

### 7.2 第二层：宿主树一定会被换掉，靠启动自愈长回来

会被整体换掉的是运行时树 `files/usr/lib/node_modules/@deepseek-ai/dsh/` —— 共 68 个补丁落点：
`node_modules/@deepseek-ai/*` 62 个、`node_modules/@earendil-works/pi-ai` 3 个（#47/#49/#57）、`config/agent-presets` 3 个。

上游自带重打引擎（`lib/reapply.js`：`refreshStaleBaksForUpgrade` → `revertAll` → `applyPatchesAllHosts` → 盖戳），
其中 `refreshStaleBaksForUpgrade` 专治「新版宿主文件 + 旁边老 bak」——直接 revert 会把新宿主写成旧版原文、新旧混码必崩（`reapply.js:320-332` 注释即这条实测）。

但**启动自愈默认是关的**：

- `lib/index.js:65`　`DEFAULTS.autoApplyOnStart = false`
- `lib/index.js:976`　`if (config.autoApplyOnStart !== true) { … return "skip:boot-no-host-write"; }`

本移植在 **profile 层**显式打开（profile 层在所有 bundle 层之后按条目 id 定向应用，见 7.1 的合并规则）：

```yaml
- id: dsh-purge
  config:
    autoApplyOnStart: true
```

打开后，覆盖安装完只需**启动一次应用**，引擎 boot 时 settle 自动重打宿主补丁。

### 7.3 第三层：完整性校验与钩子

- `tools/guard.sh` —— 体检（selfcheck）→ 漂移就重打 → 若仍有 pending 补一次**完整 Apply** → 复核 → 记 `$DSH_HOME/port-backup/guard.log`。
  退出码 0/1，可直接挂进任何自动化。
- `tools/after-upstream.sh` —— 拉上游后的**只读**自检：载荷 sha256 / profile 装配三处 / 宿主补丁状态。
  退出码恒 0（不阻断 git），`DSH_PORT_GUARD_STRICT=1` 可改成严格。
- `port/dsh-purge/githooks/{post-merge,post-checkout}` —— 随分支走的 git hooks，拉取与切分支后自动跑上面的自检。
  启用：`git config core.hooksPath port/dsh-purge/githooks`。
  设备上注意：`/storage/emulated` 是 **noexec 且 FUSE 不支持 chmod**，仓库里的 hook 永远带不上 +x，
  所以本机把 `core.hooksPath` 指向一个可执行的本地目录，由那里委托到被跟踪的脚本；在 WSL/Windows/Linux 上直接用仓库那份即可。

**`port.sh apply` / `port.sh revert` 已改为不走 `community.js` 的 LEGACY 转发**，原因见 7.5 第 2 条。

### 7.4 实测证据：隔离演练（2026-11-10）

`tools/sim-factory-overwrite.sh` 把整棵 dsh 安装（309 MB）复制到演练场，还原 68 个 `.bak` 并删除备份
（= 工厂覆盖后的状态），然后跑与引擎 boot 相同的自愈入口。四路重定向隔离
（`DSH_BASE` / `DSH_HOME` / `HOME` / `PATH`），**真身零写盘**。

| 步骤 | 结果 |
|---|---|
| 复制 + 还原 68 个文件 | 残留 `[dsh-purge]` 标记文件 **0** 个 |
| 覆盖后自检 | `state=broken applied=6/73` |
| 启动自愈（`reapply-cli.js`） | `applied=62`，仍差客户端 bundle 2 条（见 7.5） |
| 补一次完整 Apply | 成功 |
| 自愈后自检 | `state=ok ok=true level=qualified`、`applied=71/72`、`missing_file=0 partial=0 off=0`、宿主层 **22/22** |
| 逐条状态比对 | 与真身**差异 0**（双方均 `applied=71 disabled=2 na=9 skipped=4`） |
| 标记文件数 | 46，等于真身基线 |
| 真身未被触碰 | 46 标记 / 68 bak，与基线一致 |

### 7.5 两个必须知道的边界

1. **客户端 bundle 这 2 条，启动自愈有意不打。**
   `core.js:2697-2705` 的 revert 对 `node_modules/@scope/pkg/lib/client.js` 直接跳过，注释写明理由：
   「启动自愈不能把前端 client.js 盖回去：copyFile 即使字节相同也会改 mtime（#63）」；
   `reapply.js:319/335` 与 `index.js:1112` 的 apply 同样带 `preserveClientBundles: true`。
   当前补丁表里落在 `lib/client.js` 的只有 **#56 REWIND_HIDE_CUT_ONLY / #77 REWIND_DROP_SENT_ON_APPEND**（conversation-client）。
   只有完整 Apply（`core.js:2159 ensureHostClean`，`preserveClientBundles: false`）才打上。
   **`guard.sh` 已内置这一步**，所以覆盖安装后跑一次 guard.sh 即可，无需人工点面板。
2. **`community.js` 的 LEGACY 转发在本机原本不可用（2026-11-11 已修，见 §8.3）。**
   它实现为 `spawnSync(process.execPath, [bin/dsh-purge.js, …])`（`bin/community.js:30`），
   而本机 `process.execPath` = `/apex/com.android.runtime/bin/linker64`
   （termux-exec 的 LD_PRELOAD 把 exec 重路由到 linker，Node 就把 execPath 报成 linker 路径），
   于是实际执行变成 `linker64 dsh-purge.js` → linker 拿 JS 当 ELF 加载 →
   `error: "…/dsh-purge.js" has bad ELF magic: 23212f75`（正是 shebang 字节 `23 21 2f 75`）。
   同款坑在项目里已有记录（`fork/docs/AGENTS/gotchas.md`，apk #83/#89/#96，marketplace B 的修法）。
   **`tools/patch-android-exec.mjs` 现在把这条转发也一起修好了**（正控 `legacy-status` rc=0、
   负控撤掉补丁 rc=1，见 §8.3）；`port.sh apply/revert` 仍**直接调 `bin/dsh-purge.js`**，
   少一层转发就少一类失败面 —— 这是刻意的选择，不是遗留问题。
3. **`dsh-purge.js --apply` 的退出码在本机是假阴性，不能当判据。**
   已在清洗过的宿主上重跑，它会打印「应用未完成 / Apply incomplete」并退出 1，
   原因是幂等重跑时 **#43 WEB_PRESET_IDENTITY_STRIP 的第二条替换锚点已不存在** →
   报 `pattern_not_found`，而该补丁带 `strictFiles: true` → `isPatchResultSoftOk`（`lib/core/verify.mjs:110-118`）判硬失败。
   实测此时真实状态完全干净：四个内置预设（standard / ptc / cordis / minimal）身份句**全部已剥离**、
   `patchStatus` 全部 `applied`、`selfcheck` 报 `state=ok applied=71/72 pending=0 missing_file=0`。
   **`port.sh apply` 已改为以 selfcheck 判成败**，apply 的退出码只当信息打印。

### 7.6 覆盖安装新 APK 之后的标准动作

```bash
# 1) 打开应用一次 —— 启动自愈（autoApplyOnStart）自动重打宿主补丁
# 2) 体检并补齐客户端 bundle 那两条（同时体检装配 / 依赖键 / 执行器补丁，漂移就自愈）
bash /storage/emulated/0/Download/DSH/破甲移植/port-kit/tools/guard.sh
# 3) 若第 2 步写了盘，再重启一次应用，让引擎加载重打后的宿主代码
```

只想确认不想改：`bash tools/guard.sh --dry`。

### 7.7 构建物来自 main 的日常节奏下，实际会怎样

你的链路（已核对 `.github/workflows/`）：

- `daily-sync.yml`：每天 UTC 20:00（北京 04:00）把上游 `kelai141/dsh-mobile-apk` 合进 **main**
  （`git merge -X theirs`，冲突一律取上游），再跑 `.github/scripts/inject-fork-patches.mjs` 重打 fork 补丁，然后 push。
- `build-apk.yml`：UTC 20:30（北京 04:30）读**默认分支最新代码**构建，产物由 `nightly-publish.yml` 发布。
- 你覆盖安装的就是这份产物。

所以每天真正会变的是**运行时树里的引擎与插件代码**，而移植件在 `port/dsh-purge` 分支上、且不是构建输入。
两者互不干扰，但会派生出一个必须盯的变量：

| 每天发生什么 | 插件受影响吗 |
|---|---|
| 引擎树被新构建物整体换新（68 个补丁落点） | 会被打回原样，靠 §7.2 启动自愈补回 |
| 引擎**版本号变了** | 86 条补丁的**锚点面**换了一片代码 → 可能部分打不上，这才是主要风险 |
| 插件包 / 装配声明 / 配置条目 / 状态数据 | 不受影响（§7.1 的合并规则） |

**结论：main 每天动冲不掉插件；可能出问题的是「补丁锚点搬家」。** 三件武器对应它：

1. `tools/after-upstream.sh` 第 ④ 段 —— **装之前**就能预警：读仓库钉的引擎版本
   （`scripts/snapshot-config/engine-overlay.json` 的 `engineVersion`）、设备在跑的版本、
   以及 86 条补丁的验证基线（`0.2.2-rc.1`），三者一比就知道下一份产物会不会换锚点面。
2. `tools/guard.sh` —— **装之后**给分类：
   - 无锚点搬家 → 自愈能解决，脚本自己做完；
   - 有非 optional 的锚点搬家 → 明确列出补丁号，并给出重锚命令。
3. `community.js reanchor apply <id> --yes` —— 重锚把新锚点写进**用户面的 overrides**，
   同样不会被快照合并覆盖。若跳的是引擎大版本、要重锚的补丁很多，
   更省事的是 `bash port.sh sync` 换一个自带新锚点的插件版本（`autoUpdateOnStart` 保持 false，不自动换）。

移植件在分支、构建物在 main，这个错位还给 hook 带来一个约束，已处理：
切到 main 时仓库里**没有** `port/dsh-purge/tools/`，所以设备本地 hook 会回落到仓库外的
`port-kit/tools/after-upstream.sh`（在临时仓库里实测过回落可用）。仓库内那份 hook 仍是给
WSL/Windows 用的规范版本。

### 7.8 如果把移植件合进 main，上游同步会不会覆盖它

`daily-sync.yml` 的动作是 `git fetch upstream main` + `git merge --no-edit -X theirs upstream/main`
+ `inject-fork-patches.mjs` + `git add -A` + push。逐项查证结果：

| 查什么 | 结论 | 依据 |
|---|---|---|
| 合并会不会删掉「只存在于我们这侧」的文件 | **不会**。删除只在对面删过时才传播 | `tools/sim-upstream-merge.sh` 场景 A：合并后 `port/dsh-purge/**` 逐字节一致 |
| 上游有没有占用同一路径 | **没有**。顶层 36 项里无 `port/` | GitHub API `contents/` 实测（2026-11-10） |
| `-X theirs` 何时判上游赢 | 只在**同一处两边都改了**的冲突里 | 同脚本场景 B：上游若也建同名文件，我们的内容被上游覆盖 |
| 上游删除 `port/` 会怎样 | 上游从未拥有该路径 → 相对基线是净零变动，移植件仍在 | 同脚本场景 C |
| `inject-fork-patches.mjs` 会不会重写移植件 | **不会**。99 行里只有两个 `writeFileSync` 目标：`README.md`、`.github/workflows/build-apk.yml` | 通读脚本 |
| `git add -A` 会不会动它 | 已跟踪且未修改 → 空操作 | git 语义 |
| LFS / 换行属性会不会改它 | **不会**。`git check-attr -a port/dsh-purge/payload.tar.gz` 无任何属性命中；且本仓本来就直存 `base/*.tar.xz` 大归档 | 实测 |
| PR 门禁会不会拦 | 冲突标记扫描只覆盖 `app/src docs .github scripts plugins vendor`，敏感信息扫描只覆盖 `app/src scripts` —— 都**不含** `port/` | `pr-gate.yml` 实测 |

**所以唯一真正的覆盖路径是：上游哪天自己建了同名路径。** 当前不可能，但不能排除它改布局。
两个可选加固：

1. 把目录从通用的 `port/` 改成**抗撞名**（如 `dsh-purge-port/`），把撞名概率压到可忽略；
2. 在同步链路里加一行撞名检测（`git ls-tree upstream/main | grep` 目标前缀），撞了就失败告警而不是静默取上游。

另一个必须知道的代价：合并进 main 意味着 `payload.tar.gz`（2.2 MB）进入 APK 仓的 git 历史，
且它会被 clone 到每一次构建。本仓已有同类大归档，可以接受，但它确实不再是「仓库外的东西」。
`port-kit/`（仓库外那份）始终是权威工作副本，分支/主干里的那份只是镜像。

---

## 8. 2026-11-11 实修：四类缺陷、两条上游更新线

这一轮做的是三件事：**核移植完整性**、**修掉实测缺陷**、**把上游新提交接上**。
下面每条都带证据与「怎么再验一遍」，不写推演。

### 8.1 缺陷：registry 形状的依赖键会把 pnpm 打成 404（已修）

- **现象**：`port.sh verify` 第 2 段 FAIL（装配缺项），`port.sh status` 报 `dep key : (缺少)`；
  profile 的 `pnpm-lock.yaml` 被重写，只剩 `@napi-rs/canvas*`。
- **真因**：`dsh-purge-community` **不在 npm registry 上**（`registry.npmjs.org` 与
  `registry.npmmirror.com` 都是 404），而早期 kit 把它按 registry 形状写进了
  `profiles/web/package.json` 的 `dependencies`。于是任何 pnpm 动作都会去 registry 拉它：
  ```
  ERR_PNPM_FETCH_404  GET https://registry.npmjs.org/dsh-purge-community: Not Found
  This error happened while installing a direct dependency of …/profiles/web
  ```
  实证位置：`profiles/web/.plugin-manager/logs/operation-*/pnpm.log`（2026-11-10 19:53 两次）。
  一次失败的事务会把整份清单重写，依赖键与 lockfile 一起丢 —— 装配判据失守就是从这里来的。
- **为什么可以不写依赖键**（源码依据，不是猜）：引擎装配 bundle 走的是**目录探测**，
  只要求 `node_modules/<名字>/package.json` 存在，与 `dependencies`/lockfile 无关 ——
  `@deepseek-ai/dsh-app-boot/lib/index.js:1817-1823`（`createRequire(anchor).resolve.paths` +
  `existsSync(join(candidate,"package.json"))`）与 `:1836-1842`（`resolveBundleDir` 两锚点）。
  `dependencies` 的唯一作用是插件管理器的「已安装 / 可移除 / 可更新」记账
  （`@deepseek-ai/dsh-plugin-manager/lib/index.js:2147`）。
  另外实测：pnpm 10.12.1 + `nodeLinker: hoisted` **不做 extraneous 扫描删除**，
  未登记的 `node_modules` 目录在 `pnpm install`（含 `--frozen-lockfile`）后仍存活；
  删除只发生在「曾被 lockfile 记录、现已从依赖里去掉」的包上。
- **修法**：只登记 `dsh.profile.bundles`，不写 registry 形状依赖键；
  `port.sh install` 发现地雷键就**自动删掉**（去毒），`verify` 第 2 段把它判 FAIL 防回流。
  `status` 现在会打印这条键的三种状态（无 / 本地 spec / registry 地雷）与 lockfile 情况。
  手工铺的包天然活在 lockfile 之外，这是本仓既有口径（`port/jet-hub/tools/lockfix.mjs` 头注释：
  完全缺席的包不擅自补 lockfile，只知情）。
- **再验**：`bash port.sh verify`（第 2 段 PASS）、`bash port.sh status`（`dep key : (无：设计如此…)`）。

### 8.2 缺陷：上游同步的直连超时（已修）

- **实测**（2026-11-11）：`https://github.com` 直连 **134 s 后连接失败**；
  `https://api.github.com` 200 / 0.5 s；`https://gh-proxy.com` 200 / 1.2 s；
  `https://registry.npmmirror.com` 200 / 0.3 s。早先 README §来源也记过同款（12 s 无响应）。
- **真因**：`fetch-payload.sh` 早有镜像回落，但 `port.sh sync` 的下载是裸 `curl` 直连。
- **修法**：`cmd_sync` 的下载改成回落链 —— 直连 → `DSH_PAYLOAD_MIRRORS`（默认
  `https://gh-proxy.com/ https://ghproxy.net/`）→ 逐条试，成功后打印实际来源与字节数；
  另外 `sync --check/sync` 现在会打印上游 release 说明的节选（改了什么一眼可见）。
- **再验**：`bash port.sh sync --check`（打印 `上游最新：v1.6.88` + 说明节选）。

### 8.3 缺陷：Android 上 `process.execPath` 是 linker，插件内部 spawn 必崩（已修）

- **实测**：`process.execPath` = `/apex/com.android.runtime/bin/linker64`（termux-exec 的
  LD_PRELOAD 把 exec 重路由到 linker）；直接 spawn 它：
  `error: expected absolute path: "-e"`；`community.js` 的 LEGACY 转发：
  `error: "…/dsh-purge.js" has bad ELF magic: 23212f75`。而真实解释器
  `/data/data/com.dsharnessmobile.shell/files/usr/bin/node` **可以直接 spawn 成功**（实测）。
- **受影响功能**（不改就是坏的）：面板「重启引擎」的分离助手（`lib/web.js`）、
  维护回滚事务里的干净进程校验（`lib/rollback-transaction.js`）、红队演练台重启脚本
  （`lib/redteam/ui.js`）、`bin/community.js` 的 apply/revert/uninstall/edit 转发。
- **修法**：`tools/patch-android-exec.mjs` 在**载荷落盘时**把这 4 个文件共 6 处
  `process.execPath` 改写成
  `(process.env.PURGE_NODE_EXEC||(process.getBuiltinModule("node:fs").existsSync(<烧入的绝对 node 路径>)?<该路径>:process.execPath))` ——
  即「环境变量覆盖 > 装机时实测的绝对路径 > 回落上游行为」，不会比现状更坏。
  幂等；每个文件声明**锚点期望次数**（`lib/web.js`=3、其余各 1），数量不符即明确失败
  （上游改形状时宁可红，不猜）；改完用 `node --check`（拷成 `.mjs` 纯解析）自证语法。
  `port.sh install`/`sync` 与 `tools/guard.sh` 三处都把这道判断题当关卡。
- **证据（正控 / 负控）**：
  ```
  正控（已打补丁）：node …/bin/community.js legacy-status   -> 正常输出，rc=0
  负控（同一文件撤掉补丁）：同一条命令                        -> bad ELF magic: 23212f75，rc=1
  ```
- **再验**：`$NODE tools/patch-android-exec.mjs <pkg> --node $NODE --check`（rc=0）。

### 8.4 缺陷：安装集与发布物不等（499 vs 322，已修）

- **现象**：设备上的 `dsh-purge-community` 有 499 个文件，release 发布物只有 322 个 ——
  多出 `test/` 106、`packages/` 54、`market/` 6、`.github/` 6、`release-notes.md`、
  `package-lock.json`、`NATIVE-PANEL.md`、`.npmignore`、`.gitignore` 共 177 个 dev 件。
  来源是早期用源码树铺过一次；`cp -R` 是叠加式，**上游删掉的文件不会随升级消失**。
- **修法**：`install` 改成**干净落位** —— 旧目录先 `mv` 到 `.purge-old-$$`，发布物整份铺入后
  再删旧目录（落位失败自动把旧目录移回）；重铺判据 = 与发布物**逐文件相等**（`comm` 比对），
  不等就重铺，并打印清掉了多少个非发布物文件。
- **再验**：`find <profile>/node_modules/dsh-purge-community -type f | wc -l` 与载荷一致，
  且两边文件集 `comm` 为空。本轮同步后：324/324，无差异文件。

### 8.5 防覆盖：三层防线补齐（与 port/jet-hub 同口径）

| 层 | 机制 | 管什么 |
|---|---|---|
| 属性 | 仓库根 `.gitattributes` 的 `port/** merge=ours`（已存在，覆盖本 kit） | 只在「双方都改同一文件」这一格生效 |
| 指纹 | `tools/protected.sha256`（15 个受管文件）+ `tools/protect.sh verify/snapshot/heal` | 上游改/删、有人强推 —— **发现**与**恢复** |
| 兜底 | `githooks/post-merge`、`post-checkout`（随仓库走）+ `.github/workflows/port-guard.yml` | 合并当下与 CI 侧各跑一次只读体检 |

`port-guard.yml` 本轮从「只管 jet-hub」扩成**两个 kit 各一段**（存在性 + 指纹），
定位仍是**告警不阻断**：移植件出问题不该让 APK 构建红掉，但必须当天被看见。

### 8.6 上游两条更新线：插件 release 与宿主 main

1. **插件上游**：`port.sh sync` 跟 `kingcharleslzy-ai/dsh-purge` 的 GitHub Release
   （`dsh-purge-community-<版本>.tgz`，校验 release 的 `sha256:` digest）。
   本轮 1.6.86 → **1.6.88**：变更 15 个文件（`client.js`、`lib/{community,desktop,maintenance-lock,preset-compat,rewind}.js`、
   `package.json`、README/docs 与 `docs/releases/1.6.87.md`、`1.6.88.md`）。
   **关键判据：`lib/patches/` 与 1.6.86 逐字节相同** → 宿主补丁表未变、锚点面未搬，
   所以不需要重锚、也不需要重打补丁（`selfcheck` 仍 `applied=71/72`）。
   上游这两版的内容（#171 回退误切历史、#172 弹窗层级、#173/#174/#178 文案与署名、
   #181 Windows 密封归档 CLI、Windows 维护锁瞬时错误重试）对 Android 的影响面：
   只有 #171（`lib/rewind.js`）落在运行时代码里，其余是 Windows/macOS 桌面路径。
2. **宿主仓库**：`fork` 那份 checkout 本轮 `git fetch origin` 后 **落后 origin/main 15 个提交**
   （MemoryBear / dsh-memento / Jet Hub 等其它 kit 的移植提交），已用
   `git merge --ff-only origin/main` 追平到 `8617207`，`port/dsh-purge` 在两轮之间**零改动**
   （`git log 7a68b3a..origin/main -- port/dsh-purge` 为空）—— 上游 main 动不影响本 kit。
   注意：本机直连 `github.com` 不可达（§8.2），promisor 拉 blob 会失败；拉取时逐条命令带镜像：
   ```bash
   cd /storage/emulated/0/Download/DSH/破甲移植/fork
   git -c url."https://gh-proxy.com/https://github.com/".insteadOf="https://github.com/" fetch origin
   git -c url."https://gh-proxy.com/https://github.com/".insteadOf="https://github.com/" merge --ff-only origin/main
   ```

### 8.7 本轮**没有**修、需要知情的项

1. **`#35 ESCALATION_NEVER_REJECT` 在 0.2.2-rc.1 上静默软通过**：状态 `skipped`，
   而 `patchStatusReady("skipped")===true` → 计入软通过、不进 broken；宿主该代的 escalation
   逻辑已搬到别处（`dsh-sandbox/lib/types/escalation.js` 不存在、"rejected escalating" 全宿主零命中）。
   不为了消项去改补丁表本体 —— 要处理就走上游的 `community.js reanchor`，或等上游对新宿主的适配。
2. **上游自己承认 0.2.2-rc.1 未完整适配的 6 条**（`#14/#17/#60/#62/#67/#74`，见上游
   `docs/maintenance-022-diagnostics.md`）：设备上 marker 全在、`#67` 已抽样确认语义成立，
   但**逐条语义对锚未做完**。这属于上游与新宿主之间的账，不是本 kit 的移植缺陷，先记账。
3. **`lib/core.js` 的 npm-cli 路径**（`path.dirname(process.execPath)/node_modules/npm/bin/npm-cli.js`）
   在 Android 上本来就取不到，那是**插件自升级**路径；本机更新走 `port.sh sync`，不依赖它。
4. **profile 的 `pnpm-lock.yaml` 与 `package.json` 目前不同步**（`dsh-memento` 在依赖里、
   lockfile 里没有）→ 引擎那条 `pnpm install --frozen-lockfile` 自动修复路径会
   `ERR_PNPM_OUTDATED_LOCKFILE`。这不是本 kit 的文件，按「各 kit 管各 kit」不动它，仅记账。
