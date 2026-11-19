# 移植插件上游状态

> 本文件由 `port/tools/upstream-watch.mjs` 自动生成并在推送时覆盖，勿手改。

- 巡检时间：**2026-11-20 07:30:45 +08:00**
- 目标仓库：`zhaolongwudi/dsh-mobile-apk@main`（`port/` 目录）
- 本次结论：**有 1 个 kit 现装体检 FAIL**，上游有新版 0 个

## 一、总表

| kit | 本机钉住 | 上游最新 | 上游状态 | 现装体检 | overlay 漂移 | 可移植性 |
|---|---|---|---|---|---|---|
| `dsh-memento` | 0.5.30 | — | RETIRED | 跳过 | — | — |
| `dsh-purge` | 1.7.20 | 1.7.20 | CURRENT | OK | — | — |
| `jet-hub` | 2.30.261119 | 2.30.261119 | CURRENT | FAIL 1 | — | — |
| `meow-memory` | 0.33.1 | 0.33.1 | CURRENT | OK（WARN 4） | 0 缺 | — |

## 二、二次复核明细

### dsh-memento

- 包：`dsh-memento`，本机 `0.5.30`，上游 `—`（已由 meow-memory 取代，不再跟踪）

### dsh-purge

- 包：`dsh-purge-community`，本机 `1.7.20`，上游 `1.7.20`（与上游一致）
- 上游仓库最新提交：`e519253d` 2026-11-18T10:24:44Z docs: refresh contributor avatars
- 现装体检：rc=0，FAIL 0 / WARN 0

### jet-hub

- 包：`dsh-providers-hub`，本机 `2.30.261119`，上游 `2.30.261119`（与上游一致）
- 现装体检：rc=1，FAIL 1 / WARN 0
  - 未核销 `FAIL 引擎服 rev=8e3d816097a5，磁盘是 rev=538a2a4da4d2 —— 磁盘已换但引擎仍在服旧包。`

### meow-memory

- 包：`meow-memory`，本机 `0.33.1`，上游 `0.33.1`（与上游一致）
- 上游仓库最新提交：`435b26d3` 2026-11-17T16:58:03Z chore: release 0.33.1 — #117 事件流访问链硬化+失败响一次 / #118 egress fuse 止损+还原主模型 / #116 注销挂 ctx.effect + FAQ 安装坑
- 现装体检：rc=0，FAIL 0 / WARN 4 / 共 27 项
- overlay 结构：2 个文件，缺失 0

## 三、复查口径

「无 bug、修复可用」由两路独立证据合成，任一不足都算未确认：

1. **静态**：上游包解包后，kit 的补丁在 `patch --dry-run` 全通过才算「可移植」；随后 `node --check` 与 kit 自带结构断言（如 `test-settings-ui.mjs`）必须同时通过。
2. **运行时**：已装包跑 kit 自己的 `port.sh verify`，FAIL 必须为 0；WARN 逐条列在明细里，不吞。

只升「可移植性 = READY」的 kit；`NEEDS-PORT` 一律人工重制补丁后重跑本巡检。
