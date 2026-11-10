# dsh-purge Community（破甲）在 dsh-mobile-apk 上的移植包

把 [kingcharleslzy-ai/dsh-purge](https://github.com/kingcharleslzy-ai/dsh-purge)（社区维护版「破甲」插件，
包名 `dsh-purge-community`）移植进本机 DeepCode（`com.dsharnessmobile.shell`），并且**不改 APK、不改上游
仓库、不影响每日从上游 fork 的持续迭代**。

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
├─ README.md                   本文件
└─ .unpacked/                  首次 install 时解出来的缓存（可删）
```

版本：`dsh-purge-community 1.6.86`（release tgz，含预构建 `lib/`、`client.js`、`presets/`、`skills/`）、
`yaml 2.9.1`；宿主 `dsh 0.2.2-rc.1`。

> 为什么用 release tgz 而不是仓库源码：源码装要在设备上跑构建链，Android 上少一步构建就少一类失败面。
