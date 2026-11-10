#!/bin/bash
# ============================================================================
# sim-upstream-merge.sh —— 「拉上游会不会冲掉移植件」的实证
#
# 复刻 daily-sync.yml 的真实动作：
#   git fetch upstream main && git merge --no-edit -X theirs upstream/main
# 检查移植件（port/dsh-memento/**）在合并结果里是否还在、是否逐字节保留。
#
# 两条**必须遵守**的构造纪律（都是本脚本前几版踩过的坑，写在这里防止复现）：
#   ① 每个场景一个独立临时仓库。同一仓库连跑三场景会让后一场景跑在上一场景遗留的
#      未解决冲突态上 ⇒ 假结论。
#   ② `git branch upstream` 必须在**分叉点**执行。若在本地提交之后才建 upstream 分支，
#      该分支会包含本地提交 ⇒ 两侧同源 ⇒ merge 退化成 fast-forward，
#      `-X theirs` 根本不上场（实测会打印 "not something we can merge" 或直接 FF）。
#      正确顺序：祖先提交 → 建 upstream 分支 → 两侧各自提交。
#
# 不用两个仓 clone：本机本地路径传输是坏的（termux-exec + linker64 的 argv 重写把
# git-upload-pack 搞坏，报 "is not a git command"），双分支拓扑不需要任何传输。
#
# 三场景结论完全不同：
#   A 上游没碰 port/    -> 移植件原样保留（只存在于我们这侧的路径，合并不会删）
#   B 上游也改同一文件  -> -X theirs 判上游赢（唯一真正的覆盖路径）
#   C 上游删除该路径    -> 上游的删除会传播（同一路径两侧都在管时）
#
# 用法：bash tools/sim-upstream-merge.sh
# ============================================================================
set -u

ROOT=/data/user/0/com.dsharnessmobile.shell/files/home/.dsh/port-backup/memento-merge-sim
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
say() { printf '%s\n' "$*"; }

newrepo() { rm -rf "$1"; mkdir -p "$1"; cd "$1" || exit 1; git init -q -b main . 2>/dev/null; }
plant_kit() {
  mkdir -p port/dsh-memento/tools
  printf '{"sha256":"LOCAL"}\n' > port/dsh-memento/manifest.json
  printf 'guard\n' > port/dsh-memento/tools/guard.sh
  printf 'after\n' > port/dsh-memento/tools/after-upstream.sh
  printf 'payload\n' > port/dsh-memento/payload.tar.gz
}
sum_kit() { find port/dsh-memento -type f 2>/dev/null | sort | xargs cat 2>/dev/null | sha256sum | cut -d' ' -f1; }

rm -rf "$ROOT"; mkdir -p "$ROOT"

# ─────────── A：上游改动与 port/ 完全无关 ───────────
newrepo "$ROOT/scenA"
printf 'readme v1\n' > README.md; mkdir -p scripts; printf 'x\n' > scripts/a.mjs
git add -A; git commit -qm "A base"
git branch -q upstream                 # ← 分叉点（纪律②）
plant_kit; printf 'fork patch\n' >> README.md
git add -A; git commit -qm "feat(port): dsh-memento 移植包"
before=$(sum_kit)
git checkout -q upstream
printf 'upstream feature\n' > scripts/b.mjs; printf 'readme v2\n' > README.md
git add -A; git commit -qm "upstream: unrelated feature"
git checkout -q main
git merge -q --no-edit -X theirs upstream/main 2>/dev/null
after=$(sum_kit)
say "场景 A（上游没碰 port/）："
say "  before=$before"
say "  after =$after"
[ "$before" = "$after" ] && say "  => 移植件逐字节保留 ✓（$(find port/dsh-memento -type f | wc -l) 个文件）" \
                         || say "  => 移植件被改动 ✗"

# ─────────── B：上游也改同一个文件（真实分叉） ───────────
newrepo "$ROOT/scenB"
mkdir -p port/dsh-memento
printf '{"sha256":"ANCESTOR"}\n' > port/dsh-memento/manifest.json
git add -A; git commit -qm "A base（manifest 两侧共管）"
git branch -q upstream                 # ← 分叉点
printf '{"sha256":"LOCAL"}\n' > port/dsh-memento/manifest.json
git add -A; git commit -qm "feat(port): 本地版本"
git checkout -q upstream
printf '{"sha256":"FROM-UPSTREAM"}\n' > port/dsh-memento/manifest.json
git add -A; git commit -qm "upstream: 也改了同一文件"
git checkout -q main
git merge -q --no-edit -X theirs upstream 2>/dev/null
say ""
say "场景 B（上游也改同一文件 + -X theirs）："
if grep -q "FROM-UPSTREAM" port/dsh-memento/manifest.json 2>/dev/null; then
  say "  => 上游内容赢：manifest.json = FROM-UPSTREAM ⇒ **唯一真正的覆盖路径**"
else
  say "  => 本地内容仍在：$(cat port/dsh-memento/manifest.json)"
fi

# ─────────── C：上游删除该路径（两侧共管） ───────────
newrepo "$ROOT/scenC"
plant_kit
git add -A; git commit -qm "A base（含 port/dsh-memento）"
git branch -q upstream                 # ← 分叉点
printf 'local tweak\n' >> port/dsh-memento/manifest.json
git add -A; git commit -qm "feat(port): 本地微调"
git checkout -q upstream
git rm -rq port; git commit -qm "upstream: 删除 port/"
git checkout -q main
if git merge -q --no-edit -X theirs upstream 2>/dev/null; then
  merged=1
else
  merged=0
fi
say ""
say "场景 C（上游删除 port/，两侧都在管）："
if [ "$merged" = 1 ]; then
  say "  => 合并成功；port/dsh-memento $([ -d port/dsh-memento ] && echo '仍在' || echo '被删掉')"
else
  # 实测：删除 + 本地修改 = modify/delete 冲突。合并**不完成**，本地版本留在工作区，
  # 需要人工 `git add` / `git rm` 解决。文件没被静默删掉，但流程是阻塞的。
  say "  => CONFLICT (modify/delete)：合并未完成、需人工解决"
  say "     本地版本留在工作区：$([ -f port/dsh-memento/manifest.json ] && echo 'manifest.json 仍在' || echo '已删')"
  say "     注意：这是**阻塞态**，不是干净的保留。"
  git merge --abort 2>/dev/null || true
fi

say ""
say "── 结论 ──"
say "只有当上游**恰好也管同一路径**（B/C）时，仓库里的副本才会被上游合并影响。"
say "设备上的移植件（profile 内已装文件 + 设备侧 port-kit 副本）不依赖仓库路径，"
say "所以 B/C 都不影响已装好的功能；仓库那份只是版本化分发与跨机重建入口。"
