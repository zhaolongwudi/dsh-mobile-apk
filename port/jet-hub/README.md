# Jet Hub（dsh-providers-hub）在 dsh-mobile-apk 上的移植包

把 [deepseek-harness-codearts / dsh-providers-hub](https://gitee.com/iJetLi/deepseek-harness-codearts)
移植进本机的 DeepCode（`com.dsharnessmobile.shell`），并且**不依赖改 APK、不改仓库、不影响每日从上游
fork 重建的迭代**。

当前状态：**已在本机装好并正在运行**。

| 证据 | 结果 |
|---|---|
| 引擎装配（`pluginManager/listPlugins`） | `include:codearts-auth` → `dsh-providers-hub`，`enabled=true`，`fiberPhase=active` |
| 客户端装配（`index.html` 的 `__DSH_BOOT__.entries`） | 含 `dsh-providers-hub/client.js`（rev `1818433586e3`），inject 已对上 settings / model-selection |
| 本地 OpenAI 兼容网关 | `127.0.0.1:8326/v1/models` → `401 invalid_api_key`（无 key 时的正常应答，说明在监听） |
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
- `PERSISTENT-DATA.md`：APK 覆盖安装保留 app 私有数据；快照刷新合并 profile 与 `.dsh`，只保证不碰
  `sessions/storages/workspaces/...` 这类显式清单。

所以：**每天装新 APK → 数据保留 → 插件和它的装配声明都还在**，而工具本身的源码与构建输入零改动。

---

## 2. 日常操作

脚本是 `port.sh`（纯 bash + 运行时自带的 node，不联网）。

```bash
K=/data/data/com.dsharnessmobile.shell/files/home/dsh-port   # 装机内副本
bash $K/port.sh status      # 看落点与版本，不改任何东西
bash $K/port.sh verify      # 体检：文件 / 装配 / 模块加载 / 引擎内 fiber / 网关端口
bash $K/port.sh install     # 离线重铺 + 修装配（幂等，默认跳过已同版本的文件）
bash $K/port.sh install --force   # 强制重铺文件
bash $K/port.sh install --enable  # 顺手清掉 quarantine 禁用行（Safe Mode/隔离后用它）
bash $K/port.sh uninstall         # 卸载，保留账号状态；加 --purge 连账号一起删
```

`verify` 的五个段全部 PASS 才算在位：

```
== 1. 文件 ==              依赖齐全
== 2. 装配（package.json）==  依赖键与 dsh.profile.bundles 都在
== 3. 模块可加载 ==          import('dsh-providers-hub') 成功
== 4. 引擎内 fiber ==       include:codearts-auth enabled=true fiberPhase=active
== 5. 本地网关 ==           127.0.0.1:8326 在监听
```

### 每次装完新 APK 之后（建议顺序）

1. 打开应用，等引擎起来（这次更新若触发快照刷新，会久一点）。
2. 跑 `bash $K/port.sh verify`。
3. 若第 4 段 FAIL：先 `install --enable`，再 `verify`。
4. 若第 5 段 WARN `EADDRINUSE`：8326 被别的程序占了（本机现在没占；之前实测过一次是并行起了第二个引擎），
   在 Jet Hub 的网关设置里换端口即可，不影响插件本体。

---

## 3. 已知的“会被动掉”的两种情形（都有对应修法）

| 情形 | 现象 | 修法 |
|---|---|---|
| **Safe Mode**（工具自己的故障恢复）会把非工厂 bundle 选择从 `dsh.profile.bundles` 里摘掉 | `verify` 第 2 段 FAIL：bundles 里没有 `dsh-providers-hub` | `install`（会补回选择行，文件不动） |
| **UndoGate 隔离**（插件自身加载失败时）会往 `$DSH_HOME/cordis.patch.yml` 追加 `# dsh-mobile-quarantine-v1` + `disabled: true` | `verify` 第 4 段 FAIL：`enabled=false fiber=null`，网关也不监听 | `install --enable`（删禁用行；清空后连空 patch 文件一起删——0 字节的 home patch 会让这一层整体组合失败，这一点已实测） |

这两种都只发生在「工具/插件出故障」时，日常覆盖升级不触发。

---

## 4. 包里有什么

```
port-kit/
├─ port.sh                     安装 / 体检 / 状态 / 卸载
├─ manifest.json               钉住的版本、依赖清单、载荷 SHA-256、验证记录
├─ payload.tar.gz ~9.9 MB      离线载荷（node_modules 布局，1566 个条目，无符号链接）
├─ README.md                   本文件
└─ .unpacked/                  首次 install 时解出来的缓存（可删）
```

载荷里的版本（钉死，可复现）：

| 包 | 版本 |
|---|---|
| dsh-providers-hub | **2.20.261109**（npm 发布版，含预构建 `lib/` 与 `lib/client/jet-hub.js`） |
| jose / undici / wreq-js | 6.2.17 / 8.12.4 / 3.2.0 |
| @wreq-js/binding-android-arm64 | 3.2.0（Android arm64 原生绑定，本机可用） |
| @deepseek-ai/cosmokit / schemastery | 1.9.0 / 3.19.0 |

> 为什么用 npm 包而不是从 gitee 源码装：源码装的 `prepare` 要在设备上跑 `tsc` + esbuild 重建 `lib/`，
> 而 npm 包已经带好产物；Android 上少一次构建就少一类失败面。设备端实测导入耗时约 1.2 s。

---

## 5. 升级到新版本（可选）

```bash
R=/data/data/com.dsharnessmobile.shell/files
export PATH=$R/usr/bin:$PATH HOME=$R/home
cd $R/home/.dsh/profiles/web
pnpm add dsh-providers-hub@<新版本>
# 重新导出载荷，覆盖 kit 里的 payload.tar.gz 与 manifest.json 版本号即可
```

升级后同样跑 `bash $K/port.sh verify`；`dsh.profile.bundles` 里的选择不用重写（同包名）。

---

## 6. 远端同步（已在 main 上）与换机重放

你的覆盖安装物来自 `main`，所以 kit 直接放在 **`main` 的 `port/jet-hub/`**：

```
port/jet-hub/
├─ port.sh              安装 / 体检 / 状态 / 卸载
├─ fetch-payload.sh     按 manifest.json 从 npm 重建载荷（不依赖 pnpm / npm / git）
├─ manifest.json        钉住的版本、SHA-256、验证记录
└─ README.md            本文件
```

10 MB 的 `payload.tar.gz` **没有**放进 `main`：它会让每天 `fetch-depth: 0` 的检出永久多背一份二进制。
离线副本在分支 `port/jet-hub`、本机 `/storage/emulated/0/Download/DSH/Jethub 移植/port-kit/`
与机内 `/data/data/com.dsharnessmobile.shell/files/home/dsh-port/`。

### 为什么放进 main 也不干扰每日迭代

| 关注点 | 事实 |
|---|---|
| `daily-sync.yml` | 用 `git merge --no-edit -X theirs upstream/main` 再 `git add -A`；`port/` 是**新增路径**，不产生冲突，也不会被上游内容覆盖 |
| PR Gate | 冲突标记与敏感信息扫描的范围是 `app/src docs .github scripts plugins vendor`，**不含** `port/` |
| 构建链 | gradle、快照装配、`scripts/check-*.mjs` 都不读 `port/`；APK 内容零变化 |
| 代码面 | `main` 上除 `port/jet-hub/` 的 4 个文件外零 diff |
| 唯一风险 | 若哪天自动化改成 `git reset --hard upstream/main` 或强推 `main`，本目录会被抹掉——用分支 `port/jet-hub` 或本机副本回放即可 |

### 换机 / 重装后重放（上机三步）

```bash
git clone --depth 1 https://github.com/zhaolongwudi/dsh-mobile-apk.git
K=dsh-mobile-apk/port/jet-hub

bash "$K/port.sh" install    # 无载荷时自动调 fetch-payload.sh（约 34 MB / 10 秒）
bash "$K/port.sh" verify
```

应用要先首次启动一次（让 `files/home/.dsh/profiles/web` 存在）再跑 `install`。
无网络的机器改用带 `payload.tar.gz` 的副本：分支 `port/jet-hub` 或本机外部存储那份。
