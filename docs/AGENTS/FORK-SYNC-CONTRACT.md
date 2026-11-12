# fork 同步契约（跟随上游 + 移植件安全边界）

本仓是 [`kelai141/dsh-mobile-apk`](https://github.com/kelai141/dsh-mobile-apk) 的 fork。
这份文档写清「上游怎么进来、什么不许被动、出问题怎么兜底」，以及每条约定的**机器判据**在哪。

## 1. 链条与时序（北京时间）

| 时刻 | 工作流 | 干什么 |
|---|---|---|
| 04:00 | `daily-sync.yml` | 抓上游 `main` → `git merge --no-edit -X theirs` → 重打 fork 补丁 → 推 `main` |
| 04:30 | `build-apk.yml` | 读最新 `main` 构建（**它不触发上游同步**；分开是故意的：同一 workflow 里的 job 用的是触发时的旧提交） |
| 构建后 | `nightly-publish.yml` | 把双 ABI 产物发布到 `nightly` 固定直链 |

## 2. fork 侧改动的唯一落点：`inject-fork-patches.mjs`

**不要直接改 `.github/workflows/build-apk.yml`** —— 同步用 `-X theirs`，冲突时取上游版本；fork 侧的改动必须由
[`.github/scripts/inject-fork-patches.mjs`](../../.github/scripts/inject-fork-patches.mjs) **幂等重打**，这样即使被上游覆盖，下次同步也会自动补回来。

现有三处补丁：

| 序号 | 目标 | 内容 | 为什么 |
|---|---|---|---|
| ① | `README.md` | 维护 `dsh-nightly:begin/end` 标记区块（双 ABI 下载直链） | fork 的发布入口 |
| ② | `build-apk.yml` | 补 `schedule: '30 20 * * *'`；把 `if: inputs.version_code != ''` 改成带 `github.event_name == 'workflow_dispatch'` 的判定 | 上游没有 schedule；`schedule` 事件下 `inputs` 为空 |
| ③ | `build-apk.yml` | `matrix.abi` 在非 dispatch 事件下兜底为 `'both'` | 同上：`schedule` 下 `inputs.abi` 是空串，`fromJSON` 会展开成 `[""]`，底座路径被拼成 `base-usr-.tar.xz` 而判红（2026-11-11、11-12 两次定时构建都死在这里） |

三处都带「已修 / 无变化 / 写法已变化→警告」三分支，幂等，可反复跑。

## 3. 移植件安全边界（`port/**`）

`port/` 是 fork 独有内容 —— 上游**整个历史从未碰过这个路径**（可复核：
`git log --oneline <上游> -- port/` 为空）。因此这条边界不会误伤正常同步。

`daily-sync` 在合并前后各取一次 `HEAD:port` 的子树哈希：

```
合并前  PORT_BEFORE=$(git rev-parse "HEAD:port")
合并后  PORT_AFTER=$(git rev-parse "HEAD:port")   # 不一致就 ::error 并中止推送
```

tree 哈希覆盖**内容、文件名、模式、增删**，所以覆盖、替换、改名、删除、内容改写任一发生都会判红，
并且**在推送之前**中止（runner 上不留半成品）。判据失效（`port/` 整个不存在）时只发 warning 不判红 ——
那说明进来之前就已经没有移植件了，不是这次同步造成的。

## 4. 推送判据：比 `HEAD` 与远端 `main`

2026-11-12 的故障：旧脚本用 `git diff --cached --quiet` 当「要不要推送」的判据。
`git merge` 成功时 merge 提交已经写完、暂存区与 HEAD 必然一致，那个判据**恒为「无变化」** →
脚本在 `push` 之前 `exit 0`，job 报 `success` 而同步从未落地（fork main 曾一路落后上游 54 个提交）。

现在：暂存区判据只决定「补丁刷新要不要补一个提交」；推送判据是
`git rev-parse HEAD` vs 远端 `main` 的实际位置。取不到远端点时按「需要推送」处理 ——
无事可推时 git 自己会报 up-to-date，而「探测失败就跳过」会退化成同一种静默丢同步。

## 5. 权限：推 `.github/workflows/**` 需要 `workflows` 权限

`GITHUB_TOKEN` 是 GitHub App 令牌，**拿不到** `workflows` 权限。当某一批上游提交里含
`.github/workflows/**` 改动时，push 会被 GitHub 拒绝：

```
! [remote rejected] HEAD -> main (refusing to allow a GitHub App to create or update
  workflow `.github/workflows/pr-gate.yml` without `workflows` permission)
```

对策（二选一）：

1. **配 secret `SYNC_TOKEN`**（推荐）：Settings → Secrets and variables → Actions →
   New repository secret，值用 PAT（classic 勾 `repo` + `workflow`，或 fine-grained 给
   Contents 读写 + Workflows 读写）。`daily-sync` 的 checkout 已写成
   `token: ${{ secrets.SYNC_TOKEN || github.token }}`，配了就自动用它；没配则回落。
   注意：PAT 推的提交**会**触发 push 类工作流（`GITHUB_TOKEN` 推的不会），这是它和默认行为的一个差别。
2. **手工同步一次**（兜底）：`bash .github/scripts/sync-upstream-now.sh` —— 与 CI 等价，
   带同一套判据，用本机凭据（带 workflow 权限）推。

未配置时，批里不含工作流改动的同步照常自动完成；含改动的那次会**明确失败并打印修法**，不会静默。

## 6. 怎么确认「同步是好的」

三条都能过，才算同步成功：

```bash
git fetch origin main
git rev-parse origin/main                      # 远端点
git merge-base --is-ancestor <上游tip> origin/main && echo '上游已全部并入'
git rev-parse origin/main:port                 # 与同步前比对，必须一致
```

CI 侧看 `daily-sync` 的日志三行：`检测到上游新提交，开始合并` → `port 树哈希未变：…` →
`已推送到 main：…`。若看到 `上游无新提交，只刷新补丁` 而后面是 `无需推送`，说明本次没有活要干。

## 7. 已知边界与待办

- 上游若哪天开始也往 `port/` 放东西，§3 的判据会**判红拦住**（而不是悄悄合并）——这是设计意图，
  届时需人工决定是改判据还是挪目录。
- `-X theirs` 在冲突时一律取上游：除 §2 的两个受管文件外，fork 与上游目前**没有任何共同改动的文件**
  （2026-11-12 实测交集为 0），所以该策略眼下是安全的；一旦出现共同改动，冲突处会静默取上游，
  需要人工复核。
- 被上游覆盖的 workflow 改动（如 `pr-gate.yml`）**照常并入**：fork 不在这一层做取舍，
  只保证推送链路能把它送上去（§5）。
