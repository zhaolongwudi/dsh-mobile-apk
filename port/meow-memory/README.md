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

### ③ 的可选加固（把记忆库挪出 sdcard）

```sh
K=$(dirname "$0")          # port/meow-memory
W=<workspace 绝对路径>
# 1) 先备份
cp -av "$W/.dsh-meow" "$HOME/.dsh/port-backup/meow-store-$(date +%Y%m%d-%H%M%S)"
# 2) 在 cordis.patch.yml 的 meow-memory 段加 projectDir（绝对路径，键要给全）
#    - id: meow-memory
#      config:
#        promptLang: zh
#        projectDir: /data/data/com.dsharnessmobile.shell/files/home/.dsh/meow-store
# 3) 搬库后再重载插件，然后 port.sh verify 复核条目数
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

## 七、待办

1. **肉眼确认设置页**：dsh 设置页里应出现 meow-memory 段（本轮已从代码层证明走 `configForms` 兜底，
   但没截到 UI 图）。若看不到，回看第三节的兜底分支与 `SETTINGS_NS` 是否等于 entry id。
2. 配置改动后重载插件/重启应用，使 `promptLang: zh` 落进运行态（在重载前它本来就以 zh 默认值运行，
   所以行为无变化）。
