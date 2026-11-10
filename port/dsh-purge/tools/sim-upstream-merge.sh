#!/bin/bash
# ============================================================================
# sim-upstream-merge.sh —— 「拉上游会不会冲掉移植件」的实证
#
# 复刻 daily-sync.yml 的真实动作：
#   git fetch upstream main && git merge --no-edit -X theirs upstream/main
# 然后看移植件（port/dsh-purge/**）在合并结果里是否还在、是否逐字节保留。
#
# 实现方式：同仓双分支拓扑（upstream / main 两个分支，共同祖先 A）。
# 为什么不用两个仓 clone：本机**本地路径传输是坏的**——git fetch 本地 remote 要起
# git-upload-pack，被 termux-exec + linker64 的 argv 重写搞坏，报
# "git: '<path>/.git' is not a git command" / "Could not read from remote repository"，
# 于是 clone 失败、后面的 merge 根本没发生（会得到假绿）。双分支不需要任何传输。
#
# 三个场景，结论完全不同：
#   A 上游没碰 port/      -> 移植件原样保留（只存在于我们这侧的文件，合并不会删）
#   B 上游也建了同名路径  -> -X theirs 判上游赢，我们的内容被改（唯一真正的覆盖路径）
#   C 上游删除整个 port/  -> 上游的删除会传播（因为同一路径两侧都在管）
#
# 用法：bash tools/sim-upstream-merge.sh
# ============================================================================
set -u

R=/data/user/0/com.dsharnessmobile.shell/files/home/.dsh/port-backup/merge-sim
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
say() { printf '%s\n' "$*"; }
sum_kit() { find port/dsh-purge -type f 2>/dev/null | sort | xargs cat 2>/dev/null | sha256sum | cut -d' ' -f1; }

rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b main .

# ---------- A：共同祖先（上游与 fork 分叉点）----------
printf 'upstream readme v1\n' > README.md
mkdir -p scripts && printf 'x\n' > scripts/a.mjs
git add -A && git commit -qm "A base"

# ---------- main：fork 侧 = main + 移植件 ----------
git checkout -q -b upstream            # 先把上游分支架在 A 上
git checkout -q main
printf 'fork readme patch\n' >> README.md
mkdir -p port/dsh-purge/tools
printf '{"sha256":"abc"}\n' > port/dsh-purge/manifest.json
printf 'guard\n' > port/dsh-purge/tools/guard.sh
printf '#!/bin/bash\n' > port/dsh-purge/tools/after-upstream.sh
git add -A && git commit -qm "feat(port): 移植包"
BEFORE=$(sum_kit)

# ---------- 上游动了一轮：改 README + 加新文件 ----------
git checkout -q upstream
printf 'upstream readme v2\n' > README.md
printf 'y\n' > scripts/b.mjs
git add -A && git commit -qm "up-2"

say "== 场景 A：上游没碰 port/，跑 daily-sync 那两条命令 =="
git checkout -q main
git merge --no-edit -X theirs upstream >/dev/null 2>&1
say "  合并后 port/dsh-purge："; find port/dsh-purge -type f | sort | sed 's/^/    /'
AFTER=$(sum_kit)
[ "$BEFORE" = "$AFTER" ] && say "  移植件逐字节一致：是" || say "  移植件被改动：before=$BEFORE after=$AFTER"
say "  README 首行：$(head -1 README.md)  （-X theirs 判上游赢，随后由 inject-fork-patches 重打）"
say "  上游新文件是否进来：$(ls scripts | tr '\n' ' ')"

say ""
say "== 场景 B：上游也在 port/dsh-purge 下建同名文件 =="
git checkout -q upstream
mkdir -p port/dsh-purge/tools
printf 'UPSTREAM WINS\n' > port/dsh-purge/tools/guard.sh
printf '{"sha256":"upstream"}\n' > port/dsh-purge/manifest.json
git add -A && git commit -qm "up-3 collision"
git checkout -q main
git merge --no-edit -X theirs upstream >/dev/null 2>&1
say "  guard.sh     -> $(cat port/dsh-purge/tools/guard.sh)"
say "  manifest.json-> $(cat port/dsh-purge/manifest.json)"
say "  （只有上游主动占同一路径时才会被动；路径不撞则永远安全）"

say ""
say "== 场景 C：上游删除整个 port/ 目录 =="
git checkout -q upstream
git rm -rq port && git commit -qm "up-4 delete port" >/dev/null
git checkout -q main
git merge --no-edit -X theirs upstream >/dev/null 2>&1
if [ -d port/dsh-purge ]; then say "  移植件仍在（我们这侧没删，合并保留）"; else say "  移植件被删除（上游的删除传播了）"; fi

say ""
say "真仓对应事实：上游 kelai141/dsh-mobile-apk 顶层 36 项里没有 port/ 路径（API 实测）。"
