# 移植插件上游状态

> 本文件由 `port/tools/upstream-watch.mjs` 自动生成并在推送时覆盖，勿手改。

- 巡检时间：**2026-11-13 02:34:45 +08:00**
- 目标仓库：`zhaolongwudi/dsh-mobile-apk@main`（`port/` 目录）
- 本次结论：**有 1 个 kit 现装体检 FAIL**，上游有新版 3 个，其中 2 个可否直接升

## 一、总表

| kit | 本机钉住 | 上游最新 | 上游状态 | 现装体检 | overlay 漂移 | 可移植性 |
|---|---|---|---|---|---|---|
| `dsh-memento` | 0.5.30 | — | RETIRED | 跳过 | — | — |
| `dsh-purge` | 1.6.88 | 1.6.97 | OUTDATED | OK | — | READY |
| `jet-hub` | 2.21.261110 | 2.23.261112 | OUTDATED | FAIL 4（另有 7 条误报已核销） | — | READY |
| `meow-memory` | 0.32.6 | 0.32.7 | OUTDATED | OK（WARN 2） | 0 缺 | READY |

## 二、二次复核明细

### dsh-memento

- 包：`dsh-memento`，本机 `0.5.30`，上游 `—`（已由 meow-memory 取代，不再跟踪）

### dsh-purge

- 包：`dsh-purge-community`，本机 `1.6.88`，上游 `1.6.97`（上游 1.6.97 > 本机 1.6.88）
- 上游仓库最新提交：`003ae687` 2026-11-12T17:40:20Z Release 1.6.97: import ensureToolExecutor in the redteam entry
- 现装体检：rc=0，FAIL 0 / WARN 0
- 上游试移植：**READY** —— 无补丁（纯载荷型 kit），按包内容与运行时直检；语法/结构测试/真实导入通过
  - 语法 `lib/index.js`：OK
  - 真实导入（在 profile 内 import 一次）：PASS EXPORTS 12

### jet-hub

- 包：`dsh-providers-hub`，本机 `2.21.261110`，上游 `2.23.261112`（上游 2.23.261112 > 本机 2.21.261110）
- 现装体检：rc=1，FAIL 12 / WARN 0（净 FAIL 4：7 条「缺少依赖」经核对装在包内 node_modules，属 kit verify 在 profile 根上找造成的误报）
  - 未核销 `FAIL package.json 里缺依赖键或 bundles 选择（重跑 install）`
  - 未核销 `FAIL 声明 ≠ 实装 2.22.261111（重跑 install）`
  - 未核销 `FAIL pnpm-lock.yaml 记的是 (未登记)，实装 2.22.261111 —— 跑 lockfix（否则 pnpm 重装会静默降级）`
  - 未核销 `FAIL .modules.yaml 记的是 (未登记)，实装 2.22.261111 —— 跑 lockfix`
  - 误报核销：`jose` 实在于 `$DSH_HOME/profiles/web/node_modules/dsh-providers-hub/node_modules/jose` —— 装在包内 node_modules（嵌套布局），verify 在 profile 根上找属误报
  - 误报核销：`undici` 实在于 `$DSH_HOME/profiles/web/node_modules/dsh-providers-hub/node_modules/undici` —— 装在包内 node_modules（嵌套布局），verify 在 profile 根上找属误报
  - 误报核销：`wreq-js` 实在于 `$DSH_HOME/profiles/web/node_modules/dsh-providers-hub/node_modules/wreq-js` —— 装在包内 node_modules（嵌套布局），verify 在 profile 根上找属误报
  - 误报核销：`@wreq-js/binding-android-arm64` 实在于 `$DSH_HOME/profiles/web/node_modules/dsh-providers-hub/node_modules/@wreq-js/binding-android-arm64` —— 装在包内 node_modules（嵌套布局），verify 在 profile 根上找属误报
  - 误报核销：`@deepseek-ai/cosmokit` 实在于 `$DSH_HOME/profiles/web/node_modules/dsh-providers-hub/node_modules/@deepseek-ai/cosmokit` —— 装在包内 node_modules（嵌套布局），verify 在 profile 根上找属误报
  - 误报核销：`@deepseek-ai/schemastery` 实在于 `$DSH_HOME/profiles/web/node_modules/dsh-providers-hub/node_modules/@deepseek-ai/schemastery` —— 装在包内 node_modules（嵌套布局），verify 在 profile 根上找属误报
  - 误报核销：`wreq-js.android-arm64.node` 实在于 `$DSH_HOME/profiles/web/node_modules/dsh-providers-hub/node_modules/@wreq-js/binding-android-arm64/wreq-js.android-arm64.node` —— arm64 上 dlopen 实测全部成功（1/1），「加载失败」是 kit 从 profile 根找不到绑定路径造成的误报
- 上游试移植：**READY** —— 无补丁（纯载荷型 kit），按包内容与运行时直检；语法/结构测试/真实导入通过
  - 语法 `lib/index.js`：OK
  - 真实导入（在 profile 内 import 一次）：PASS EXPORTS 7

### meow-memory

- 包：`meow-memory`，本机 `0.32.6`，上游 `0.32.7`（上游 0.32.7 > 本机 0.32.6）
- 上游仓库最新提交：`4b885996` 2026-11-12T05:25:04Z chore: release 0.32.7 — 0.2.2 契约 delegate 双路径（#110）/ 滚动贴底（#109）/ dream_log.changes 接线（#108）/ dream 组标记分段（#95）
- 现装体检：rc=0，FAIL 0 / WARN 2 / 共 27 项
- overlay 结构：2 个文件，缺失 0
- 上游试移植：**READY** —— 补丁 3/3 全部可应用；语法/结构测试/真实导入通过
  - 已可应用：01-settings-responsive-and-pickers.patch, 02-projectdir-guard.patch, 03-picker-scope-homeDir-only.patch
  - 语法 `lib/index.js`：OK
  - 语法 `lib/client.js`：OK
  - 结构测试：PASS E④ 回退值是相对名 .dsh-meow | E④ 回退时响亮报错而非静默 | E④ 上游旧的裸默认值写法已移除 | 结论 PASS 33/33 全通过
  - 真实导入（在 profile 内 import 一次）：PASS EXPORTS 123

## 三、复查口径

「无 bug、修复可用」由两路独立证据合成，任一不足都算未确认：

1. **静态**：上游包解包后，kit 的补丁在 `patch --dry-run` 全通过才算「可移植」；随后 `node --check` 与 kit 自带结构断言（如 `test-settings-ui.mjs`）必须同时通过。
2. **运行时**：已装包跑 kit 自己的 `port.sh verify`，FAIL 必须为 0；WARN 逐条列在明细里，不吞。

只升「可移植性 = READY」的 kit；`NEEDS-PORT` 一律人工重制补丁后重跑本巡检。
