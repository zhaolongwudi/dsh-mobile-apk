#!/usr/bin/env bash
# sync-upstream-now.sh —— 手工执行一次与 daily-sync **完全等价**的上游同步。
#
# 什么时候用：
#   · daily-sync 的 push 被 GitHub 拒（批次里含 .github/workflows/** 改动而 GITHUB_TOKEN
#     没有 workflows 权限），而你又不想等到配好 SYNC_TOKEN —— 见
#     docs/AGENTS/FORK-SYNC-CONTRACT.md。
#   · 只想立刻把上游提交拉进来，不等北京 04:00 的定时。
#
# 为什么敢手工做：用的是与 CI 同一套判据 ——
#   ① port/ 子树的 tree 哈希必须前后逐字节一致（移植件不许被覆盖/替换/删除）；
#   ② 上游 tip 必须成为合并结果的祖先（不许「以为同步了」）；
#   ③ 补丁由 inject-fork-patches.mjs 幂等重打，不在文件里手改。
#
# 用法：
#   bash .github/scripts/sync-upstream-now.sh [上游仓库 URL]
#   合并与推送只发生在临时 worktree 里；主工作树、分支引用由 git worktree 保证隔离。
set -euo pipefail

UPSTREAM_URL=${1:-https://github.com/kelai141/dsh-mobile-apk.git}
REPO=$(git rev-parse --show-toplevel)
cd "$REPO"

BR="sync-now-$$"
WT="$(git rev-parse --git-dir)/sync-now-wt-$$"   # 放 .git 里：不会被 git add -A 收进提交
cleanup() {
  # 必须先离开临时 worktree：cwd 落在待删目录里时，后续 git 命令会因 cwd 失效而静默失败
  cd "$REPO" 2>/dev/null || true
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  git branch -D "$BR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== 抓上游 =="
git fetch --no-tags "$UPSTREAM_URL" main
UP=$(git rev-parse FETCH_HEAD)
echo "上游 main: $UP"

PORT0=$(git rev-parse --verify -q "HEAD:port" || echo '')
[ -n "$PORT0" ] && echo "port 树哈希（合并前）: ${PORT0:0:12}" \
  || echo "::warning::HEAD 下没有 port/，跳过移植件不变性判据"

echo
echo "== 临时 worktree 里合并（--no-edit -X theirs，与 CI 同参数）=="
git worktree add -b "$BR" "$WT" HEAD >/dev/null
cd "$WT"
if git merge-base --is-ancestor "$UP" HEAD; then
  echo "上游无新提交，只刷新补丁"
else
  git merge --no-edit -X theirs "$UP"
fi

node .github/scripts/inject-fork-patches.mjs
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: 刷新 fork 补丁（上游 ${UP:0:8}）"
fi

echo
echo "== 判据 =="
PORT1=$(git rev-parse --verify -q "HEAD:port" || echo '')
if [ -n "$PORT0" ] && [ "$PORT1" != "$PORT0" ]; then
  echo "✘ 判红：这次同步动了 port/（${PORT0:0:12} -> ${PORT1:0:12}）—— 已中止，不推送"
  git diff --stat "$PORT0" "$PORT1" || true
  exit 1
fi
[ -n "$PORT0" ] && echo "✔ port 树哈希未变：${PORT1:0:12}"
git merge-base --is-ancestor "$UP" HEAD || { echo "✘ 判红：上游 tip 未并入"; exit 1; }
echo "✔ 上游 tip ${UP:0:8} 已是合并结果的祖先"

echo
echo "== 推送 =="
git fetch --no-tags origin main
REMOTE=$(git rev-parse FETCH_HEAD)
if [ "$(git rev-parse HEAD)" = "$REMOTE" ]; then
  echo "本地 HEAD 与远端 main 一致（$(git rev-parse --short HEAD)），无需推送"
  exit 0
fi
MERGED=$(git rev-parse HEAD)
git push origin HEAD:main
echo "已推送到 main：${REMOTE:0:8} -> $(git rev-parse --short HEAD)"

# 让主工作树的本地 main 跟上（失败不影响已有推送）
git -C "$REPO" fetch --no-tags origin main
git -C "$REPO" merge --ff-only FETCH_HEAD >/dev/null 2>&1 \
  && echo "本地 main 已快进到 ${MERGED:0:9}" \
  || echo "（本地 main 未自动快进：工作树可能有未提交改动，请手动 git pull --ff-only）"
