# 移植插件上游状态

> 本文件由 `port/tools/upstream-watch.mjs` 自动生成并在推送时覆盖，勿手改。

- 巡检时间：**2026-11-26 11:36:13 +08:00**
- 目标仓库：`zhaolongwudi/dsh-mobile-apk@main`（`port/` 目录）
- 本次结论：**有 1 个 kit 现装体检 FAIL**，上游有新版 2 个，其中 1 个可否直接升

## 一、总表

| kit | 本机钉住 | 上游最新 | 上游状态 | 现装体检 | overlay 漂移 | 可移植性 |
|---|---|---|---|---|---|---|
| `dsh-memento` | 0.5.30 | — | RETIRED | 跳过 | — | — |
| `dsh-purge` | 1.7.20 | 1.7.20 | CURRENT | OK | — | — |
| `jet-hub` | 2.35.261124 | 2.36.261125 | OUTDATED | FAIL 1 | 1 缺 | READY |
| `meow-memory` | 0.33.2 | 0.33.3 | OUTDATED | OK（WARN 4） | 0 缺 | READY |

## 二、二次复核明细

### dsh-memento

- 包：`dsh-memento`，本机 `0.5.30`，上游 `—`（已由 meow-memory 取代，不再跟踪）

### dsh-purge

- 包：`dsh-purge-community`，本机 `1.7.20`，上游 `1.7.20`（与上游一致）
- 上游仓库最新提交：`e519253d` 2026-11-18T10:24:44Z docs: refresh contributor avatars
- 现装体检：rc=0，FAIL 0 / WARN 0

### jet-hub

- 包：`dsh-providers-hub`，本机 `2.35.261124`，上游 `2.36.261125`（上游 2.36.261125 > 本机 2.35.261124）
- 现装体检：rc=1，FAIL 1 / WARN 0
  - 未核销 `FAIL 有声明包与锁版本不符，跑 lockfix`
- overlay 结构：1 个文件，缺失 1（mobile.css）
- 上游试移植：**READY** —— 无补丁（纯载荷型 kit），按包内容与运行时直检；语法/结构测试/真实导入通过
  - 语法 `lib/index.js`：OK
  - 真实导入（在 profile 内 import 一次）：PASS EXPORTS 7

### meow-memory

- 包：`meow-memory`，本机 `0.33.2`，上游 `0.33.3`（上游 0.33.3 > 本机 0.33.2）
- 上游仓库最新提交：`0f698a1d` 2026-11-24T11:27:03Z chore: release 0.33.3 — #124 keywords schema 放宽 anyOf + 缺失自动提取（实现/文档/schema 三方对齐）
- 现装体检：rc=0，FAIL 0 / WARN 4 / 共 27 项
- overlay 结构：2 个文件，缺失 0
- 上游试移植：**READY** —— 补丁 3/3 全部可应用；语法/结构测试/真实导入通过
  - 已可应用：01-settings-responsive-and-pickers.patch, 02-projectdir-guard.patch, 03-picker-scope-homeDir-only.patch
  - 语法 `lib/index.js`：OK
  - 语法 `lib/client.js`：OK
  - 结构测试：PASS E④ 回退值是相对名 .dsh-meow | E④ 回退时响亮报错而非静默 | E④ 上游旧的裸默认值写法已移除 | 结论 PASS 33/33 全通过
  - 真实导入（在 profile 内 import 一次）：PASS EXPORTS 125

## 三、复查口径

「无 bug、修复可用」由两路独立证据合成，任一不足都算未确认：

1. **静态**：上游包解包后，kit 的补丁在 `patch --dry-run` 全通过才算「可移植」；随后 `node --check` 与 kit 自带结构断言（如 `test-settings-ui.mjs`）必须同时通过。
2. **运行时**：已装包跑 kit 自己的 `port.sh verify`，FAIL 必须为 0；WARN 逐条列在明细里，不吞。

只升「可移植性 = READY」的 kit；`NEEDS-PORT` 一律人工重制补丁后重跑本巡检。
