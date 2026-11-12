# meow-memory（跨会话长期记忆）在 dsh-mobile-apk 上的移植包

把 [Phant0Meow/dsh-meow-memory](https://github.com/Phant0Meow/dsh-meow-memory)（npm 包名 `meow-memory`，MIT）
移植进本机 DeepCode（`com.dsharnessmobile.shell`）。

> **2026-11-12 上岗，取代 `port/dsh-memento`。** 旧包已卸载，见文末「与 port/dsh-memento 的关系」。

当前状态：**已在本机装好并在运行。**

---

## 一、基线（本机实测）

| 项 | 值 |
|---|---|
| 包版本 | `meow-memory@0.32.6` |
| DSH 内核 | `0.2.2-rc.1` |
| Node | `v24.18.0`（内置 `node:sqlite` 实测可用） |
| 架构 | `aarch64` / arm64-v8a，**Bionic libc** |
| 运行时依赖 | **零**（`dependencies` 为空） |
| 原生产物 | **零**（全包无 `.node/.so/.wasm`，纯 JS + `node:sqlite`） |
| 记忆语言 | profile patch pin `promptLang: zh` |
| 客户端产物 | **上游 + port 补丁**（设置页响应式 / 模型下拉 / 目录选择器） |

---

## 二、实测证据

| 证据 | 结果 |
|---|---|
| 装配（两处都在） | `profiles/web/package.json` 的 `dependencies.meow-memory` **与** `dsh.profile.bundles` 均含 `meow-memory` |
| 引擎内 fiber | 插件已挂载；会话内 `memory_*` 工具组可用 |
| 记忆写入 | 11 条落库：`user 2 / project 5 / fact 1 / lesson 3`（`soul/topic/rules` 为 0） |
| 检索召回 | `memory_search` 命中已写入条目（BM25 路径通） |
| 注入链路 | `<workspace>/.dsh-meow/dream-debug.log` 记录 `pre-step first` 与 `turn-stopping`；重启后 pid 已更换 |
| 存储层 | `<workspace>/.dsh-meow/memory.db`（WAL），表齐全：`soul/user/project/fact/lesson/topic/rules` + `dream_log/dream_meta/dream_skip/windows` |
| 冷启动持久化 | 进程重启后条目仍在 |

自检命令：

```sh
bash port/meow-memory/port.sh verify        # 四段体检
bash port/meow-memory/port.sh status        # 包/装配/记忆库一览
```

---

## 三、缺陷与风险（本轮独立核查）

### 已确认正常（推翻了旧报告的静态结论）

**设置页可用。** `lib/client.js` 里是**双路兜底**，不是只走旧的注册面：

```js
const settingsScope = softService(ctx, "settingsScope");
if (settingsScope !== void 0) return mountWithScope(settingsScope.bind({ namespace: SETTINGS_NS }));
// ↓ 拿不到就走新注册面，并轮询软等待
const attach = () => {
  const configForms = softService(ctx, "configForms");
  if (configForms === void 0 || typeof configForms.get !== "function") return;
  mountDisposer = mountWithScope(configForms.get(SETTINGS_NS));
  stopPoll();
};
attach();
if (mountDisposer === null) pollTimer2 = setInterval(() => { attach(); attempts += 1; ... }, ...);
```

`0.2.2` 上 `settingsScope` 已整体移除、而 `configForms` 仍在（由 `dsh-client-ui-settings` 提供）
⇒ 走兜底分支即可注册。`记忆插件适配报告.md` 里「meow-memory 设置面 ❌ 静默失效」的**静态结论对 0.32.6 不成立**
（那份报告只看到 `settingsScope` 命中就下了结论，漏了 `configForms` 分支）。
**唯一需要肉眼确认的一步**：设置页里能否看到 meow-memory 段（见文末待办）。

### 未修项 / 已知差异

| # | 项 | 现象 | 影响 | 处置 |
|---|---|---|---|---|
| ① | **无 `engines` 声明** | `package.json` 里 `engines` 为 `undefined`；对照 memento 声明了 `engines.dsh` 版本范围 + `engines.node` | 宿主版本闸门不校验它；将来换内核版本时**没有预警** | 不修补包（下次 `pnpm` 操作会被覆盖）；升级内核后先跑 `port.sh verify` |
| ② | `dsh` 清单缺字段 | 只有 `bundle.patch` + `client.platform`；memento 另有 `manifestVersion/capabilities/labels` | 能力面声明缺失（实测不影响加载与运行） | 记为已知差异 |
| ③ | 记忆库落在**工作区** | 默认 `projectDir: ".dsh-meow"`（相对工作区）⇒ 落 `/storage/emulated/0/...` 的 sdcard 共享存储 | 权限面比 `$DSH_HOME` 私有目录宽（media_rw 可读） | **可选加固**：patch 里把 `projectDir` 指到私有绝对路径并把现有 DB 搬过去；改前必须备份。见第四节 |
| ④ | dream 依赖进程存活 | 空闲整理跑在 DSH 进程内（3h 空闲触发，北京高峰时段抑制） | Android 后台进程被杀即不触发 | 平台限制，无需修 |

---

## 四、配置

配置走 profile 的 patch 层（`$DSH_HOME/profiles/web/cordis.patch.yml`）：

```yaml
- id: meow-memory
  config:
    promptLang: zh
```

> ⚠️ **`config` 是整体替换不是深合并**（与 `agent-default-model` 那条同一个坑：`{a,b}` 打 `{b}` 只剩 `{b}`）。
> 以后要加键，必须把本段**所有**键给全。

可用键（取自插件 `lib/index.js` 的 schemastery 定义）：

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 总开关 |
| `promptLang` | `zh`（未识别值静默回落 zh） | 注入导引/工具描述/记忆书写语言 |
| `projectDir` | `".dsh-meow"` | **相对工作区**的项目记忆目录 |
| `homeDir` | `""` | `''`=平台用户主目录；预设标记或绝对路径 |
| `hitTopK` | `2` | 每条消息关键词召回上限 |
| `titleMax` / `reflect` / `reflectTurns` | `40` / `true` / `7` | 标题截断、反思开关与轮次 |
| `autoMigrate` | `true` | 旧库自动迁移 |
| `disabledWorkspaces` | `[]` | 停用工作区列表 |
| `dream.enabled` / `dream.idleMinutes` | `true` / `180` | 空闲整理 |

### ③ 的可选加固（**旧方案已作废**，2026-11-12 事故后改写）

> ⛔ **不要再把 `projectDir` 设成绝对路径来挪库。**
>
> 2026-11-12 照旧方案执行：`projectDir` 被设成 `/storage/emulated/0/Download/DSH/记忆保存目录`，
> 而 `memoryDbPath = join(工作区, projectDir)` **不会**让绝对路径覆盖 base，而是拼成
> `<workspace>/storage/emulated/0/.../记忆保存目录/memory.db` 的**嵌套库** ⇒
> 主库 `<workspace>/.dsh-meow` 的 **24 条记忆全部静默失联**（插件还当自己是新库，
> 在会话里播报「首次建库」）。恢复：把 `projectDir` 改回相对名 `.dsh-meow` 后重载即可，
> 数据本体未受损。
>
> kit 已加**双重防护**，再犯也拦得住：
> · `overlay/lib/index.js` 的 `normalizeProjectDir()` —— 绝对路径/盘符/UNC 一律回退 `.dsh-meow` 并响亮报错（对 patch 层直写同样生效）
> · 设置页目录选择器**只挂 `homeDir` 行**（`projectDir` 行不再提供一键选目录）

**正确做法（二选一）**

```sh
# A) 什么都不做 —— 记忆库留在 <workspace>/.dsh-meow
#    projectDir 只能是相对名；打开 backup.enabled 后 dream 收尾会产出 memory.db.bak 快照。

# B) 真想让它离开 sdcard —— 移的是【工作区整体】，不是 projectDir：
#    把工作区放到 app 私有目录（如 $DSH_HOME/ws/<name>）再作为工作区打开，记忆库随工作区过去；
#    或等上游支持跨工作区库。

# 无论哪种，改库位置前先冷备（db + -wal + -shm 三件一起，别只复制 .db）：
cp -av "<workspace>/.dsh-meow" "$HOME/.dsh/port-backup/meow-store-$(date +%Y%m%d-%H%M%S)"
```

---

## 五、安装 / 卸载

```sh
K=port/meow-memory
bash $K/port.sh install     # 幂等：补装配声明 + 装包（优先本地离线包）
bash $K/port.sh verify      # 四段体检应全 PASS
bash $K/port.sh status      # 一览
bash $K/port.sh uninstall   # 卸包，保留记忆库
bash $K/port.sh uninstall --purge   # 连记忆库一起删
```

离线包：`pkg/meow-memory-0.32.6.tgz`（sha256 `92b1e73f…`）。
`port.sh install` 优先用它，断网可用。

装完/改完配置后：

- **配置改动**：在 dsh 设置里重载该插件，或重启应用；
- **`node_modules` 下的代码改动**：HMR 默认忽略（`ignored: ["**/node_modules"]`），**必须重启应用**。

---

## 六、与 port/dsh-memento 的关系

| | dsh-memento | meow-memory |
|---|---|---|
| 写入门槛 | 默认 `writePolicy: ask`，每次写入走审批瀑布 | **全自动**（每消息关键词命中 + 空闲 dream） |
| 记忆检索 | substring 默认（vector 可选，Android 不建议开） | BM25 关键词 + 分层 |
| 引擎声明 | ✅ 显式声明 `engines.dsh` 范围 | ❌ 无声明（缺陷①） |
| 记忆库位置 | `$DSH_HOME/dsh-memento/memory.db`（私有） | `<workspace>/.dsh-meow/memory.db`（sdcard） |
| 本机状态 | **2026-11-12 已卸载**，数据已归档 | 在运行 |

**卸载明细（2026-11-12）**——已核对无残留：

```
① 包             node_modules/dsh-memento          已移除（pnpm remove）
② 装配声明       package.json dependencies/bundles 已移除
③ profile patch  cordis.patch.yml 的 - id: memento  已移除
④ 悬空软链       node_modules/.bin/dsh-memento-mcp  已移除
⑤ 陈旧状态文件   $DSH_HOME/port-state-memento.json  已归档
⑥ 数据目录       $DSH_HOME/dsh-memento/             已归档（memory.db 73,728 B）
⑦ lockfile       pnpm-lock.yaml                     0 处引用
```

归档位置：`~/.dsh/port-backup/memento-pre-replace-20261112-123902/`（首次备份）、
`~/.dsh/port-backup/memento-final-20261112-125348/`（最终态 + 数据目录整体）。
kit 本体 `port/dsh-memento/` 保留在仓库里备查（该 kit 的 `port.sh install` 仍可重装旧插件）。

---

## 七、设置页三项移植修复（2026-11-12 用户实机反馈）+ 事故后的三项加固

用户在手机上打开「喵记忆」设置页，报了三个问题：

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| ① | 「反思/梦境换模型」等标签被挤成**竖排**（中文逐字换行） | `.meowmm_set_row` 是 flex 行，`.meowmm_set_ctrl{flex:none}` 内含 190px 输入框 + 徽标 + 按钮 ≈340px；窄屏（≈390px）下左侧 `.meowmm_set_rowtext` 只能分到约 40px。**上游代码里没有任何断点/响应式规则** | rowtext 加 `flex:1 1 200px`；ctrl 改 `flex:0 0 auto` + `flex-wrap`；新增 `@media (max-width:600px)`：行纵向堆叠、控件占满整行、输入框全宽 |
| ② | 模型**只能手填字符串**，没得选、易填错 | `delegate.model` 字段类型是 `str`（纯文本框） | 新增字段类型 `model`，渲染 `<select>`；选项取自宿主 `ctx.remote.session.modelCatalog()`（按 provider 分组 `<optgroup>`）；**选项值统一拼成 `provider/model`**（宿主 `parseModelSpec` 按第一个 `/` 切成 `{provider, model}`，裸 id 会丢 provider 路由）；留空 = 用主模型；未知旧值保留不被静默清空；目录模块级缓存，加载失败安全回落空列表 |
| ③ | 记忆保存目录**无法选择** | `projectDir` / `homeDir` 同为纯文本框 | 新增 `hostPickDirectory()`（主路径 `ctx.uiWorkspace.pickDirectory()`，兜底 `ctx.directoryPicker.pick()`）；选择器不可用时给提示而不是静默 |

### 事故后的三项加固（2026-11-12 全屋修复）

上面的 ③ 把目录选择器**同时**挂到了 `projectDir` 和 `homeDir`，直接导致当天的事故：
点一下「记忆目录」行的选择器就把绝对路径写进了本该相对的 `projectDir` ⇒ 记忆库漂移、
24 条记忆失联。修复如下：

| # | 改动 | 文件 | 作用 |
|---|---|---|---|
| ④ | `normalizeProjectDir()` 兜底 | `overlay/lib/index.js`（服务端半边，**新增**） | 绝对路径/盘符/UNC 一律回退 `.dsh-meow` 并报错；`validateConfigUserLayer` 只覆盖设置页写入链，拦不住 `cordis.patch.yml` 直写，这个兜底能 |
| ⑤ | 选择器只挂 `homeDir` | `overlay/lib/client.js` | 去掉「记忆目录」行的一键选目录（误操作入口） |
| ⑥ | `cmd_overlay` 遍历 `overlay/` | `port.sh` | 原来硬编码只铺 `client.js` ⇒ 新增的 `index.js` 兜底铺不上（纳管漏洞） |

`verify.mjs` 的「port 补丁已铺」也改为**遍历 overlay/** 逐文件核对，同类漏洞不会再静默。

### 补丁与复现

```
port/meow-memory/
├── patches/01-settings-responsive-and-pickers.patch   上游 → 01 后态（-p1 通用，8 hunks）
├── patches/02-projectdir-guard.patch                  index.js：加 normalizeProjectDir 兜底
├── patches/03-picker-scope-homeDir-only.patch         client.js：选择器只挂 homeDir
├── patches/client.js.upstream / index.js.upstream     上游原文（离线重建用）
├── patches/client.js.patched01                        01 后态（03 的 baseline 证据）
└── overlay/lib/{client.js,index.js}                   补丁后态（install/overlay 铺这两个）
```

指纹链（`verify.mjs` 段 1 逐字节核对）：

```
上游 client.js 1805a799931c670a
  ├ 01 补丁（8 hunks）→ client.js.patched01  c5ff126990867ded
  └ 03 补丁（收窄选择器）→ overlay/lib/client.js  917f0c22bafb62ae ← 已装副本

上游 index.js  c1b99f9de90174f2
  └ 02 补丁（加兜底）→ overlay/lib/index.js        d0cc1bf9c58c910f ← 已装副本
```

复现：

```sh
bash port.sh overlay                       # 幂等铺 overlay/ 全部文件（install 也会自动铺）
node tools/test-settings-ui.mjs            # 结构测试：① ② ③ + ④（兜底）断
node tools/verify.mjs --workspace <WS>     # 四段体检
bash tools/protect.sh verify               # kit 自身指纹核对
```

> ⚠️ `node_modules` 下的改动**不走 HMR**，改完要**重启应用**（或至少重载插件）才看得到；
> 而纯**配置**改动（`cordis.patch.yml`）用 `plugin_manager` disable→enable 就能当场生效。
> ⚠️ `pnpm` 任何一次操作都会把 `lib/client.js`、`lib/index.js` 还原成上游原文
> ⇒ 记得重跑 `bash port.sh overlay`。

### 本测试没覆盖什么

`test-settings-ui.mjs` 是**结构断言**（语法可编译 + 三条代码路径在位 + 旧的塌陷写法已移除），
不是像素级渲染测试。真机观感仍需肉眼确认一次。

---

## 八、待办

1. **重启应用后肉眼确认设置页**：① 标签不再竖排 ② 模型变成下拉 ③ 只有「全局数据目录」行有「选择目录…」按钮（「记忆目录」行**不再**有 —— 2026-11-12 事故后的收窄）。
2. `promptLang: zh` 已写进 profile patch；重载/重启后落进运行态（重载前它以默认 zh 运行，行为无变化）。
3. `lib/index.js` 的 `normalizeProjectDir()` 兜底要**重启**才进进程（ESM 模块缓存）；纯配置改动不受此限，`plugin_manager` disable→enable 即可当场生效。
4. 记忆库现落在 `<workspace>/.dsh-meow`（sdcard 上）；`backup.enabled=true` 已开，dream 收尾会产出 `memory.db.bak`。**不要**用 projectDir 绝对路径挪库 —— 见 §四 ③。
5. 若 `pnpm` 动过插件，重跑 `bash port.sh overlay` 并 `node tools/test-settings-ui.mjs` 复核（两处改动都在 overlay/ 里，会被 pnpm 还原）。
