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

当前状态：**已装好、宿主补丁已打、运行态已核对**。

| 证据 | 结果 |
|---|---|
| 引擎装配（`pluginManager/listPlugins`） | `include:dsh-purge` / `-redteam` / `-presets` / `-redteam-store` / `-redteam-ui` 全部 `enabled=true fiber=active` |
| 宿主补丁 | `apply` 后 applied=64 / already=7；`selfcheck` 宿主 22/22 层 ok、补丁 applied=71/72 |
| 权限预设（Android 必需项） | 固定后 `include:permission enabled=true fiber=active`，`engine.log` 无 `did not activate` |
| 客户端装配 | 服务页面引用 `dsh-purge-community/client.js&rev=…`（左侧栏 Purge 设置页） |
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

## 2. Android 上唯一必须加的改动：permission 预设固定

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
bash $K/port.sh verify        # 体检：文件/装配/模块/固定/引擎 fiber/宿主补丁
bash $K/port.sh uninstall     # 卸载（保留 prompt-inject.md 与规则；--purge 连状态一起删）
bash $K/port.sh sync --check  # 查上游最新 release（不下载）
bash $K/port.sh sync          # 拉上游最新 release → 重建 payload → 重装（需要网络）
```

`verify` 六段：

```
== 1. 文件 ==           插件包 + yaml 依赖
== 2. 装配 ==           dependencies 键与 dsh.profile.bundles 选择
== 3. 模块可加载 ==      import('dsh-purge-community') 成功
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
3. 第 4 段 FAIL → `port.sh install`；第 5 段 FAIL → 重启应用后再试，仍 FAIL 则 `port.sh install --force`。
4. 第 6 段 `applied=0`（说明运行时树被换掉了）→ `port.sh apply`，然后重启应用。
5. 第 5 段报 `permission enabled=false` → `port.sh pin` 后重启应用（快照把固定块冲掉时会发生）。

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
port-kit/
├─ port.sh                     安装 / 打补丁 / 固定 / 体检 / 状态 / 卸载 / 上游同步
├─ manifest.json               钉住的版本、依赖、载荷 SHA-256、Android 改动与验证记录
├─ payload.tar.gz ~2.2 MB      离线载荷（node_modules 布局：dsh-purge-community + yaml，555 个文件，无符号链接）
├─ tools/pack-payload.mjs      纯 Node 重打包器（本机 tar 依赖 exec 到 gzip，实测不可用，故自带）
├─ tools/guard.sh              宿主补丁守卫：体检 → 漂移就重打 → 复核 → 记日志
├─ tools/after-upstream.sh     拉上游后的移植件守卫（只读；供 git hook 调用）
├─ tools/sim-factory-overwrite.sh  隔离演练：模拟工厂覆盖并验证自愈能把状态拉回与真身一致
├─ tools/probe-states.mjs      逐条补丁状态探针（只读，用于真身/演练场比对）
├─ README.md                   本文件
└─ .unpacked/                  首次 install 时解出来的缓存（可删）
```

版本：`dsh-purge-community 1.6.86`（release tgz，含预构建 `lib/`、`client.js`、`presets/`、`skills/`）、
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
2. **`community.js` 的 LEGACY 转发在本机不可用。**
   它实现为 `spawnSync(process.execPath, [bin/dsh-purge.js, …])`（`bin/community.js:30`），
   而本机 `process.execPath` = `/apex/com.android.runtime/bin/linker64`
   （termux-exec 的 LD_PRELOAD 把 exec 重路由到 linker，Node 就把 execPath 报成 linker 路径），
   于是实际执行变成 `linker64 dsh-purge.js` → linker 拿 JS 当 ELF 加载 →
   `error: "…/dsh-purge.js" has bad ELF magic: 23212f75`（正是 shebang 字节 `23 21 2f 75`）。
   同款坑在项目里已有记录（`fork/docs/AGENTS/gotchas.md`，apk #83/#89/#96，marketplace B 的修法）。
   **所以本 kit 一律直接调 `bin/dsh-purge.js --apply/--revert`，不经过转发。**
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
# 2) 体检并补齐客户端 bundle 那两条
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
