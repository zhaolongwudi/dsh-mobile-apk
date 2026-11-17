# 移植插件上游状态

> 本文件由 `port/tools/upstream-watch.mjs` 自动生成并在推送时覆盖，勿手改。

- 巡检时间：**2026-11-17 09:30:18 +08:00**
- 目标仓库：`zhaolongwudi/dsh-mobile-apk@main`（`port/` 目录）
- 本次结论：**现装体检无 FAIL**，上游有新版 3 个，其中 3 个可否直接升

## 一、总表

| kit | 本机钉住 | 上游最新 | 上游状态 | 现装体检 | overlay 漂移 | 可移植性 |
|---|---|---|---|---|---|---|
| `dsh-memento` | 0.5.30 | — | RETIRED | 跳过 | — | — |
| `dsh-purge` | 1.7.14 | 1.7.18 | OUTDATED | OK | — | READY |
| `jet-hub` | 2.25.261114 | 2.27.261116 | OUTDATED | OK | — | READY |
| `meow-memory` | 0.32.7 | 0.33.0 | OUTDATED | OK（WARN 2） | 0 缺 | READY |

## 二、二次复核明细

### dsh-memento

- 包：`dsh-memento`，本机 `0.5.30`，上游 `—`（已由 meow-memory 取代，不再跟踪）

### dsh-purge

- 包：`dsh-purge-community`，本机 `1.7.14`，上游 `1.7.18`（上游 1.7.18 > 本机 1.7.14）
- 上游仓库最新提交：`639c8934` 2026-11-16T09:57:13Z docs: refresh contributor avatars
- 现装体检：rc=0，FAIL 0 / WARN 0
- 上游试移植：**READY** —— 无补丁（纯载荷型 kit），按包内容与运行时直检；语法/结构测试/真实导入通过
  - 语法 `lib/index.js`：OK
  - 真实导入（在 profile 内 import 一次）：PASS EXPORTS 13

### jet-hub

- 包：`dsh-providers-hub`，本机 `2.25.261114`，上游 `2.27.261116`（上游 2.27.261116 > 本机 2.25.261114）
- 现装体检：rc=0，FAIL 0 / WARN 0
- 上游试移植：**READY** —— 无补丁（纯载荷型 kit），按包内容与运行时直检；语法/结构测试/真实导入通过
  - 语法 `lib/index.js`：OK
  - 真实导入（在 profile 内 import 一次）：PASS EXPORTS 7

### meow-memory

- 包：`meow-memory`，本机 `0.32.7`，上游 `0.33.0`（上游 0.33.0 > 本机 0.32.7）
- 上游仓库最新提交：`9ff78976` 2026-11-16T15:35:25Z chore: release 0.33.0 — 隐私倾向 / 首轮画像条数上限 / editHistory 编辑史列（大肥鱼三条建议）+ 宿主事件流兼容（ownEvents）
- 现装体检：rc=0，FAIL 0 / WARN 2 / 共 27 项
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
