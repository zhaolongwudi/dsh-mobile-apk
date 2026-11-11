# Jet Hub（dsh-providers-hub）在 dsh-mobile-apk 上的移植包

把 [deepseek-harness-codearts / dsh-providers-hub](https://gitee.com/iJetLi/deepseek-harness-codearts)
移植进本机的 DeepCode（`com.dsharnessmobile.shell`），并且**不依赖改 APK、不改仓库、不影响每日从上游
fork 重建的迭代**。

当前状态：**已在本机装好并正在运行（2.21.261110）**。

| 证据 | 结果 |
|---|---|
| 引擎装配（`pluginManager/listPlugins`） | `include:codearts-auth` → `dsh-providers-hub`，`enabled=true`，`fiberPhase=active` |
| 客户端装配（`index.html` 的 `__DSH_BOOT__.entries`） | 含 `dsh-providers-hub/client.js`，inject 已对上 settings / model-selection |
| 客户端产物一致（新） | 引擎服的 bundle 是磁盘上这份（rev 相同、999503 字节、含 2.21 的 marvis） |
| 本地 OpenAI 兼容网关 | `127.0.0.1:8326/v1/models` → `401 invalid_api_key`（无 key 时的正常应答，说明在监听） |
| pnpm 账本一致（新） | `pnpm-lock.yaml` / `.modules.yaml` / `.pnpm/lock.yaml` 与实装同版本 |
| 隔离/修复反证 | 人为写入隔离禁用行 → 插件立即失活、`verify` 判 FAIL；`install --enable` → 恢复 `active` |

---

## 1. 为什么每日新构建物覆盖不掉它

插件的落点全部在 **app 私有数据**里，而工具链的更新只碰「运行环境」和「仓库」：

| 落点 | 位置 | 更新时的命运 |
|---|---|---|
| 插件包与依赖 | `files/home/.dsh/profiles/web/node_modules/{dsh-providers-hub,jose,undici,wreq-js,@wreq-js,@deepseek-ai/*}` | 快照刷新是**合并**不是替换：工厂面没有同路径文件 ⇒ 原样保留 |
| 装配声明 | `files/home/.dsh/profiles/web/package.json`（`dependencies` + `dsh.profile.bundles`） | profile 根的两个清单属**用户面**，按「用户优先、工厂只补缺」合并 |
| 账号/网关状态 | `files/home/.dsh/jet-hub/`、`files/home/.dsh/openai-gateway/` | 未登记项一律按用户数据保留 |

依据（`dsh-mobile-apk` 源码）：

- `SnapshotTransaction.mergeProfiles()` / `mergeTree()`：live 独有的包目录**不删**，工厂件只覆盖同名文件；
  `node_modules` 里的第三方包正是「live 独有」。
- `FactoryProfilePatch.merge()`：profile `cordis.patch.yml` 的用户独有条目逐字节保留。
- `ProfilePackageManifest.merge()`：profile `package.json` 以 live 为基座，工厂新增键补入，用户键保留。
- `PluginMounts.ensureHardBundlesSelected()`：每次启动只**补**工厂 bundle，对非工厂选择（本插件）原样保留。
- `PERSISTENT-DATA.md`：APK 覆盖安装保留 app 私有数据；快照刷新合并 profile 与 `.dsh`。

所以：**每天装新 APK → 数据保留 → 插件和它的装配声明都还在**，而工具本身的源码与构建输入零改动。

---

## 2. 日常操作

脚本是 `port.sh`（纯 bash + 运行时自带的 node，装态操作不联网）。

```bash
K=/data/data/com.dsharnessmobile.shell/files/home/dsh-port   # 装机内副本
bash $K/port.sh status      # 看落点与版本，不改任何东西
bash $K/port.sh verify      # 体检：文件 / 装配 / 模块 / 引擎 fiber / 客户端产物 / 网关 / pnpm 账本
bash $K/port.sh install     # 离线重铺 + 修装配 + 对齐账本（幂等，默认跳过已同版本的文件）
bash $K/port.sh install --force   # 强制重铺文件
bash $K/port.sh install --enable  # 顺手清掉 quarantine 禁用行（Safe Mode/隔离后用它）
bash $K/port.sh lockfix     # 只把 pnpm 三个账本对齐到实装版本
bash $K/port.sh uninstall         # 卸载，保留账号状态；加 --purge 连账号一起删
```

`verify` 的七段全部 PASS 才算在位：

```
== 1. 文件 ==                     包与依赖齐全，原生绑定匹配本机 ABI
== 2. 装配（package.json）==       依赖键与 dsh.profile.bundles 都在，声明版本 == 实装版本
== 3. 模块可加载 ==               import('dsh-providers-hub') 成功；原生绑定 dlopen 成功
== 4. 引擎内 fiber ==             include:codearts-auth enabled=true fiberPhase=active
== 5. 客户端产物一致 ==           引擎服的 bundle rev == 磁盘产物 rev
== 6. 本地网关 ==                 127.0.0.1:8326 在监听
== 7. pnpm 账本一致性 ==          lockfile / .modules.yaml 与实装同版本
== 8. 其余手工移植包账本 ==        dsh-purge / dsh-memento 等是否也掉在账本外（只报不修）
```

### 每次装完新 APK 之后（建议顺序）

1. 打开应用，等引擎起来（这次更新若触发快照刷新，会久一点）。
2. 跑 `bash $K/port.sh verify`。
3. 若第 4 段 FAIL：先 `install --enable`，再 `verify`。
4. 若第 5 段 FAIL：磁盘换了但引擎还在服旧包 —— **重启应用**（刷新页面不够，见 §3）。
5. 若第 6 段 WARN `EADDRINUSE`：8326 被别的程序占了，在 Jet Hub 的网关设置里换端口即可。
6. 若第 7 段 FAIL：跑 `lockfix`。

---

## 3. 已知的「会被动掉」的四种情形（都有对应修法）

| 情形 | 现象 | 修法 |
|---|---|---|
| **Safe Mode**（工具自己的故障恢复）会把非工厂 bundle 选择从 `dsh.profile.bundles` 里摘掉 | `verify` 第 2 段 FAIL：bundles 里没有 `dsh-providers-hub` | `install`（会补回选择行，文件不动） |
| **UndoGate 隔离**（插件自身加载失败时）会往 `$DSH_HOME/cordis.patch.yml` 追加 `# dsh-mobile-quarantine-v1 reason=loader-failure` + `disabled: true` | `verify` 第 4 段 FAIL：`enabled=false fiber=null`，网关也不监听 | `install --enable`（删禁用行；清空后连空 patch 文件一起删——0 字节的 home patch 会让这一层整体组合失败，这一点已实测） |
| **引擎的 client bundle 缓存**（本次新查明） | 第 5 段 FAIL：界面还是上一版；`verify` 前四段却全绿 | **重启应用**。引擎启动时把 client bundle 的 mtime/ctime/size 记成 `artifactRevision` 缓存进内存（`dsh-client-modules` 的 `rebuilt`/`artifactRevision`），换磁盘文件**不会**让它重读；刷新页面也不够 |
| **pnpm 账本滞后**（本次新查明） | 第 7 段 FAIL：`lockfile` 记的是旧版本 | `lockfix`。手工铺文件绕过了 pnpm，而 App 内「插件」页的安装/卸载走 `pnpm add`/`pnpm remove` —— 一旦有人点了它，pnpm 按 lockfile 的旧版本重新解析，把手工装的版本**静默降级**回 lockfile 里那一版（版本号不同不触发告警，只有 integrity 不符才会） |

前两种只在「工具/插件出故障」时发生；后两种是**手工铺包这种移植方式的固有代价**，每次升级版本都要过一遍。

### 手工铺包的共性缺陷：掉在 pnpm 账本之外

`verify` 第 8 段会扫全部声明包，把同一类受害者都列出来。本机当下的实况：

```
absent  dsh-purge-community: 实装 1.6.86，锁里完全没有
absent  dsh-memento:         实装 0.5.30，锁里完全没有
```

含义：这三家（连同 Jet Hub）都是手工铺进 `node_modules` 的，`pnpm-lock.yaml` 的 `importers` 段里
根本没有它们。而 pnpm 的 `install`/`prune` 是**以 lockfile 为目标状态**做收敛的——
用户在 App 的「插件」页点一下安装或卸载任何插件，pnpm 都会把「锁里没有的包」当成多余目录清掉，
不报错、不提示。这跟 Jet Hub 的版本偏离是同一个根因（绕过 pnpm 铺文件）的两种表现。

**为什么不在这里一并补上**：补一个 importer 条目需要同时有 `packages`/`snapshots` 条目
（含 integrity 与完整依赖解析链）。只写 importer 会让 pnpm 在下一次 `install` 时解析失败，
或自行编造解析结果——比不补更危险。正确做法是各包自己的 port 脚本按自身 `manifest.json` 补齐。
所以第 8 段**只报不修**，且不判 `FAIL`（它不影响 Jet Hub 可用性，但会影响那几个插件）。

给 `dsh-purge` / `dsh-memento` 补这一课时的做法：照 `port/dsh-purge/tools/pack-payload.mjs`
与 `manifest.json` 的现有结构，加一个 `lockfix` 步骤调用本目录的 `lockfix.mjs` 即可复用同一套逻辑。

---

## 4. 包里有什么

```
port-kit/
├─ port.sh                     安装 / 体检 / 状态 / 卸载 / lockfix
├─ lockfix.mjs                 把 pnpm 三个账本对齐到实装版本（独立文件，可单独跑）
├─ manifest.json               钉住的版本、integrity、依赖清单、载荷 SHA-256、验证记录
├─ payload.tar.gz ~9.9 MB      离线载荷（node_modules 布局，1518 个条目，无符号链接）
├─ README.md                   本文件
└─ .unpacked/                  首次 install 时解出来的缓存（可删）
```

载荷里的版本（钉死，可复现）：

| 包 | 版本 |
|---|---|
| dsh-providers-hub | **2.21.261110**（npm 发布版，含预构建 `lib/` 与 `lib/client/jet-hub.js`） |
| jose / undici / wreq-js | 6.2.17 / 8.12.4 / 3.2.0 |
| @wreq-js/binding-android-arm64 | 3.2.0（Android arm64 原生绑定，本机可用） |
| @deepseek-ai/cosmokit / schemastery | 1.9.0 / 3.19.0 |

> 为什么用 npm 包而不是从 gitee 源码装：源码装的 `prepare` 要在设备上跑 `tsc` + esbuild 重建 `lib/`，
> 而 npm 包已经带好产物；Android 上少一次构建就少一类失败面。设备端实测导入耗时约 1.2 s。

### 2.20.261109 → 2.21.261110 的差异

上游两个提交（`1d12f80` 腾讯 Marvis provider、`6ad2e24` README 修正）都已在 2.21.261110 里：
新增 32 个 `marvis-*` 文件（QQ / 微信 OAuth、auto 槽位、钱包额度），改 50 个既有文件，
**删除 0 个**。第二个提交是纯文档（README 的「走余额分档 14 家」自相矛盾修正），无代码面影响。

正因为「删除 0 个」，旧 `install` 的 `cp -R` 覆盖式铺法在这一版看不出问题；但 `cp -R` **只增不删**，
一旦上游将来删文件，残留会让 `.js` 与 `.d.ts` 的版本面不一致。新版 `install` 改成**整包替换**
（先 `rm -rf` 包目录再铺），从根上消掉这一类。

---

## 5. 升级到新版本

```bash
# 1) 拿新版本的 integrity 与依赖清单
curl -s https://registry.npmjs.org/dsh-providers-hub/<版本> | node -e '...'

# 2) 更新 manifest.json 的 package.version / package.integrity / payload.sha256
# 3) 重建载荷（联网，约 34 MB）：
bash fetch-payload.sh --pack
# 4) 上机
bash port.sh install --force
bash port.sh verify           # 第 5 段会 FAIL，这是预期的：重启应用后再复查
```

`install` 结束会自动跑一次 `lockfix`，所以第 7 段通常已绿。

---

## 6. 远端同步（已在 main 上）与换机重放

你的覆盖安装物来自 `main`，所以 kit 直接放在 **`main` 的 `port/jet-hub/`**：

```
port/jet-hub/
├─ port.sh              安装 / 体检 / 状态 / 卸载 / lockfix
├─ lockfix.mjs          pnpm 账本对齐（独立文件）
├─ fetch-payload.sh     按 manifest.json 从 npm 重建载荷（不依赖 pnpm / npm / git）
├─ manifest.json        钉住的版本、integrity、SHA-256、验证记录
├─ tools/protect.sh     防覆盖：指纹登记 / 校验 / 自愈 / 装 hook
├─ tools/protected.sha256  8 个受管文件的指纹（随仓库走）
├─ githooks/            post-merge / post-checkout（install-hooks 装进 .git/hooks）
├─ README.md            本文件
└─ payload.tar.gz       仅离线副本有，仓库里没有
```

10 MB 的 `payload.tar.gz` **没有**放进仓库：它会让每天 `fetch-depth: 0` 的检出永久多背一份二进制。
离线副本在本机 `/storage/emulated/0/Download/DSH/Jethub 移植/port-kit/`
与机内 `/data/data/com.dsharnessmobile.shell/files/home/dsh-port/`。

### 为什么放进 main 也不干扰每日迭代

| 关注点 | 事实 |
|---|---|
| `daily-sync.yml` | 用 `git merge --no-edit -X theirs upstream/main` 再 `git add -A`。上游 kelai141 **目前没有 `port/` 路径**（API 实测 36 个顶层项里没有），所以合并不碰移植件 |
| PR Gate | 冲突标记与敏感信息扫描的范围是 `app/src docs .github scripts plugins vendor`，**不含** `port/` |
| 构建链 | gradle、快照装配、`scripts/check-*.mjs` 都不读 `port/`；APK 内容零变化 |
| 守卫 workflow | `port-guard.yml` 只读 `port/**`，不参与任何构建 job |

## 7. 防上游覆盖：三层防线

「上游没有 port/ 路径」是**现状**，不是保证。上游哪天也建 `port/`、或删掉它，下面三种机制按顺序接住。

### 先看事实：四格矩阵

`bash tools/protect.sh sim` 在本机复刻 `daily-sync.yml` 的合并命令，得到：

| 场景 | 只有 `merge=ours` 时 | 谁接住 |
|---|---|---|
| ① 双方都改同一文件 | **取 ours，挡住** | `.gitattributes` |
| ② 只有上游改（我们这侧没动） | 上游内容传入 | 指纹层 |
| ③ 上游删除文件 / 整个目录 | 删除传播，文件消失 | hook 自愈 / CI |
| ④ 上游在 `port/` 下新建文件 | 直接进来 | 指纹层的「未登记文件」 |

**`merge=ours` 只在 ① 生效**，这是 git 的语义（属性只在双方冲突时介入），不是配置写错。
只靠属性会漏掉三格，所以另有两层。

### 三层各管什么

| 层 | 机制 | 何时触发 | 覆盖 |
|---|---|---|---|
| 1. 属性 | `.gitattributes` 的 `port/** merge=ours` | 合并当下 | 仅场景 ① |
| 2. 指纹 | `tools/protected.sha256` + `protect.sh verify/heal` | 手动跑 / hook 调用 | ②③④ 的**发现**，以及 ②③ 的**恢复** |
| 3. CI | `.github/workflows/port-guard.yml` | push / PR / 每天 04:20 | 换机、CI、hook 未装时的兜底 |

`merge=ours` 需要 `git config merge.ours.driver true` 才生效（空 driver 即「保留 ours」）。
GitHub 侧的 3-way merge 不读本地 config，所以 CI 侧靠 `port-guard` 而不是靠这个属性。

### 日常用法

```bash
bash tools/protect.sh verify          # 体检：指纹是否一致（只读）
bash tools/protect.sh snapshot        # 改过 kit 后重新登记，并随提交入库
bash tools/protect.sh heal            # 从最近一次登记一致的提交恢复被改/被删的文件
bash tools/protect.sh install-hooks   # 装 post-merge / post-checkout（换机后跑一次）
bash tools/protect.sh sim             # 跑四格矩阵实证，不动真仓
```

**`install-hooks` 只在本机克隆生效**（`.git/hooks` 不随仓库走）。换机后重跑一次。

### 「守卫被守卫对象一起删掉」这一条

上游删除整个 `port/` 时，`protect.sh` 自己也不存在了——所以 `githooks/` 下那两份 hook
**不依赖 `protect.sh` 存在**，自带最小恢复逻辑：目录没了就直接
`git checkout <最后一个含 port/jet-hub 的提交> -- port/jet-hub`。
这份逻辑刻意写成独立文件而不是在 `protect.sh` 里拼字符串，因为拼字符串要跨 bash/sh 三层
引用，实测极易把 `$` 吃成字面量。

### 防线边界（说清楚，别指望它做不到的事）

- **强推 / `git reset --hard`**：任何仓库内的机制都拦不住。只能靠 `origin/main` 上的历史 + `protected.sha256` 事后发现。
- **上游改了 `port/` 但内容恰好也让指纹相同**：理论上不可能（sha256），实务上不必考虑。
- **`payload.tar.gz` 不在指纹里**：10 MB 二进制，且可由 `fetch-payload.sh` 从 npm 重建。它的完整性由 `manifest.json` 的 sha256 单独校验。
- **故意改 kit 后忘了 snapshot**：`verify` 会 FAIL 并提示「若改动是你有意做的，跑 snapshot」。这是刻意设计——宁可误报也不放过真改动。

### 换机 / 重装后重放（上机三步）

```bash
git clone --depth 1 https://github.com/zhaolongwudi/dsh-mobile-apk.git
K=dsh-mobile-apk/port/jet-hub

bash "$K/tools/protect.sh" install-hooks   # 先武装守卫
bash "$K/port.sh" install                  # 无载荷时自动调 fetch-payload.sh（约 34 MB / 10 秒）
bash "$K/port.sh" verify
```

应用要先首次启动一次（让 `files/home/.dsh/profiles/web` 存在）再跑 `install`。
无网络的机器换成带 `payload.tar.gz` 的本机外部存储那份。
