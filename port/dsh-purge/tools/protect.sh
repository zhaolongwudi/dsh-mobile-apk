#!/bin/bash
# ============================================================================
# protect.sh —— dsh-purge（破甲）移植件的防护：登记 / 校验 / 修复 / 安装 hook
#
# 为什么需要它（三种覆盖路径，实测结论，不是推演）：
#
#   路径 ①「上游改了我们的文件」——`.gitattributes` 的 `merge=ours` 能挡住，
#           但**只在双方都改同一文件时**才生效。实测矩阵（git 2.47，本机）：
#             · main 未改 / up 改了      -> 取上游（merge=ours 不生效）
#             · main 也改了 / up 改了    -> 取 ours（生效）
#             · up 删除文件              -> 删除传播，文件消失（不生效）
#             · up 在 port/ 下新建文件   -> 直接进来（不生效）
#           结论：属性只在「双方冲突」这一个格子有效，不能当唯一防线。
#
#   路径 ②「上游删掉整个 port/」——实测会传播，整目录消失。
#           daily-sync 用的是 `git merge -X theirs`，没有 `-X renormalize` 之类的挽回项。
#
#   路径 ③「有人 git reset/强推」——任何防线都拦不住，只能靠本文件里的指纹登记来检测。
#
# 本脚本的对策分两层：
#   A) **登记**：把 port/dsh-purge 下每个文件的 sha256 写进 tools/protected.sha256，
#      登记文件本身随仓库走。任何路径导致的改动，下一轮都能被指纹比对发现。
#   B) **自愈**：指纹不符 / 文件缺失 / 目录整个消失时，从 git 历史里最近一次
#      「登记一致」的提交恢复（`git checkout <rev> -- port/dsh-purge`），再复核。
#      上游没碰过 port/ 的话，恢复源就是 main 上现有的提交，不依赖任何外部备份。
#
# 不做的事（刻意）：
#   · 不修改 daily-sync.yml 的合并策略。改了就成了「fork 与上游的唯一分歧点」，
#     每天都要 merge 一次，反而制造冲突；而 merge=ours + 本脚本已经覆盖了全部四种格子。
#   · 不把 payload.tar.gz 纳入仓库（10 MB 二进制会让每天的 fetch-depth: 0 永久变慢）。
#     载荷的完整性由 manifest.json 里的 sha256 校验，缺了可由 fetch-payload.sh 重建。
#
# 用法：
#   bash protect.sh verify          # 体检：指纹是否一致（只读，不写盘）
#   bash protect.sh snapshot        # 重新登记当前状态（改过 kit 后必跑，并随提交入库）
#   bash protect.sh heal            # 从最近一次登记一致的提交恢复被改动/被删的文件
#   bash protect.sh install-hooks   # 装 post-merge / post-checkout，合并后自动体检
#   bash protect.sh uninstall-hooks # 卸掉上面两个 hook（只删本脚本装的）
#   bash protect.sh sim             # 在本机跑四种覆盖场景的实证（不动真仓）
#
# 退出码：verify/heal 不一致或修复失败 = 1；一切正常或已修好 = 0。
# ============================================================================
set -u

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)      # .../port/dsh-purge/tools
KIT=$(cd -- "$SELF_DIR/.." && pwd)                 # .../port/dsh-purge
REPO=$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null || true)
REG="$SELF_DIR/protected.sha256"
REL=$(git -C "$KIT" rev-parse --show-prefix 2>/dev/null || true)  # port/dsh-purge/
REL=${REL%/}
[ -n "$REL" ] || REL=.

say() { printf '%s\n' "$*"; }
ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; }
warn(){ printf '  WARN  %s\n' "$*"; }

need_repo() {
  [ -n "$REPO" ] || { echo "不在 git 仓库里（$KIT）"; exit 1; }
}

# 受管文件清单：kit 的全部内容，排除两类不参与指纹的东西：
#   · payload.tar.gz —— 10 MB 二进制，指纹在 manifest.json 里另有登记
#   · .unpacked/ 与 payload/ —— 运行时解包缓存/重建产物，随时可重生成
list_files() {
  ( cd "$KIT" && find . -type f \
      ! -name 'payload.tar.gz' \
      ! -path './.unpacked/*' \
      ! -path './payload/*' \
      ! -path './out/*' \
      ! -path './.sync/*' \
      ! -name '*.tmp' \
      ! -name '*.sha256.new' \
      ! -name '*.bak-*' \
      ! -name '.DS_Store' \
    | sed 's|^\./||' | LC_ALL=C sort )
}

# 指纹行格式：<sha256>  <相对路径>。与 sha256sum -c 的格式一致，可直接互验。
fingerprint() {
  ( cd "$KIT" && list_files | while IFS= read -r f; do
      [ -f "$f" ] || continue
      # 登记文件自己不进指纹（否则改一次登记就等于自证）
      case "$f" in tools/protected.sha256) continue ;; esac
      h=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
      [ -n "$h" ] && printf '%s  %s\n' "$h" "$f"
    done )
}

cmd_snapshot() {
  need_repo
  local tmp=$REG.new
  fingerprint > "$tmp" || { rm -f "$tmp"; echo "生成指纹失败"; exit 1; }
  local n; n=$(wc -l < "$tmp" | tr -d ' ')
  if [ -f "$REG" ] && cmp -s "$tmp" "$REG"; then
    rm -f "$tmp"
    say "指纹无变化（$n 个文件）"
    return 0
  fi
  mv "$tmp" "$REG"
  say "已登记 $n 个文件的指纹 -> tools/protected.sha256"
  say "记得把 tools/protected.sha256 一起提交，否则下一轮无人能校验。"
}

cmd_verify() {
  # 这里**不**要求 git 仓库：指纹比对只用 sha256，离线副本（如从外部存储带过来的
  # port-kit 目录）也要能体检。只有 heal / install-hooks 才必须找到仓库。
  [ -f "$REG" ] || { bad "缺 tools/protected.sha256（跑 snapshot 生成）"; return 1; }
  local fail=0 changed=0 missing=0 extra=0
  # ① 逐条比对登记过的文件
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local want=${line%%  *}
    local rel=${line#*  }
    if [ ! -f "$KIT/$rel" ]; then
      bad "缺失：$rel"
      missing=$((missing+1)); fail=1
    else
      local have; have=$(sha256sum "$KIT/$rel" 2>/dev/null | cut -d' ' -f1)
      if [ "$have" != "$want" ]; then
        bad "被改动：$rel"
        changed=$((changed+1)); fail=1
      fi
    fi
  done < "$REG"
  # ② 找出登记之外的新增文件（上游塞进来的，或本地忘了登记）
  local cur; cur=$(mktemp)
  fingerprint > "$cur"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local rel=${line#*  }
    grep -q "  $rel\$" "$REG" 2>/dev/null || { warn "未登记的新文件：$rel"; extra=$((extra+1)); }
  done < "$cur"
  rm -f "$cur"

  [ "$changed" -eq 0 ] && [ "$missing" -eq 0 ] && ok "全部 $(wc -l < "$REG" | tr -d ' ') 个登记文件指纹一致"
  [ "$extra" -gt 0 ] && say "        未登记文件不判 FAIL：可能是你刚加的，跑 snapshot 登记即可。"
  if [ "$fail" -ne 0 ]; then
    say ""
    say "修复：bash tools/protect.sh heal"
    say "若改动是你有意做的：bash tools/protect.sh snapshot 后一起提交。"
    return 1
  fi
  return 0
}

# 在 git 历史里找最近一次「该提交的 port/dsh-purge 内容与登记指纹完全一致」的 rev。
# 找不到就退化为「最近的提交」——那样至少能把被删的文件拿回来，改动过的内容另说。
find_good_rev() {
  local rev
  for rev in $(git -C "$REPO" log --format=%H -40 -- "$REL" 2>/dev/null); do
    local okall=1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local want=${line%%  *}
      local rel=${line#*  }
      local blob
      blob=$(git -C "$REPO" show "$rev:$REL/$rel" 2>/dev/null) || { okall=0; break; }
      local have; have=$(printf '%s' "$blob" | sha256sum | cut -d' ' -f1)
      # git show 会补一个结尾换行，纯文本可能因此差一字节；用 git 自己的 hash-object 更准
      local gith; gith=$(git -C "$REPO" rev-parse "$rev:$REL/$rel" 2>/dev/null)
      if [ -n "$gith" ]; then
        # 用 worktree 里同名文件做一次对比基准：直接把该 blob 写到临时文件算 sha256
        local tf; tf=$(mktemp)
        git -C "$REPO" cat-file blob "$gith" > "$tf" 2>/dev/null
        have=$(sha256sum "$tf" | cut -d' ' -f1); rm -f "$tf"
      fi
      [ "$have" = "$want" ] || { okall=0; break; }
    done < "$REG"
    [ "$okall" -eq 1 ] && { printf '%s' "$rev"; return 0; }
  done
  # 退化：最近一次碰过 port/dsh-purge 的提交
  git -C "$REPO" log --format=%H -1 -- "$REL" 2>/dev/null
}

cmd_heal() {
  need_repo
  [ -f "$REG" ] || { bad "缺 tools/protected.sha256，无法判断该恢复成什么"; return 1; }
  local rev; rev=$(find_good_rev)
  [ -n "$rev" ] || { bad "git 历史里找不到 port/dsh-purge 的任何提交"; return 1; }
  say "恢复源：${rev:0:7}  $(git -C "$REPO" log -1 --format=%s "$rev" 2>/dev/null)"
  # 只恢复受管文件，不整目录覆盖（避免把 .unpacked/ 之类缓存也一起改）
  local restored=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local want=${line%%  *}
    local rel=${line#*  }
    local cur=""
    [ -f "$KIT/$rel" ] && cur=$(sha256sum "$KIT/$rel" | cut -d' ' -f1)
    if [ "$cur" != "$want" ]; then
      if git -C "$REPO" checkout "$rev" -- "$REL/$rel" 2>/dev/null; then
        say "  已恢复 $rel"
        restored=$((restored+1))
      else
        bad "  恢复失败 $rel（该提交里没有这个文件）"
      fi
    fi
  done < "$REG"
  if [ "$restored" -eq 0 ]; then
    say "没有需要恢复的文件。"
  fi
  say ""
  say "复核："
  cmd_verify
}

# 装 git hook。用 post-merge 而不是 pre-merge：合并已发生，只做只读体检，
# 恒退出 0（绝不阻断 git 操作 —— 阻断会让人直接 --no-verify，防线等于没有）。
cmd_install_hooks() {
  need_repo
  local hd; hd=$(git -C "$REPO" rev-parse --git-path hooks)
  case "$hd" in /*) ;; *) hd="$REPO/$hd" ;; esac
  mkdir -p "$hd" || { echo "建不了 $hd"; exit 1; }
  # hook 内容是 githooks/ 下那份的逐字拷贝。为什么不在脚本里拼字符串：
  #   ① 拼字符串时要跨 bash/node/sh 三层引用，实测极易把 \$ 吃成字面量；
  #   ② 那份 hook 必须在 port/dsh-purge 整个被删时仍能工作，所以它自带恢复逻辑，
  #      展开成一行行的 echo 只会让「它自己也可能出错」更难查。
  local src="$KIT/githooks"
  [ -d "$src" ] || { bad "缺 githooks/ 源文件"; return 1; }
  for h in post-merge post-checkout; do
    local f="$hd/$h"
    [ -f "$src/$h" ] || { bad "缺 githooks/$h"; continue; }
    if [ -f "$f" ] && ! grep -q "dsh-purge-protect-v1" "$f" 2>/dev/null; then
      cp "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
      say "已备份原有 $h"
    fi
    cp "$src/$h" "$f" && chmod +x "$f" && ok "已装 $h"
  done
  say ""
  say "之后每次 pull/merge/切分支都会自动体检；port/dsh-purge 整个消失时 hook 会从 git 历史捞回来。"
  say "注意：hook 只在**本机克隆**生效，不进仓库（.git/hooks 不随 git 走）。"
  say "换机后重跑一次 install-hooks 即可；CI 侧另有 workflow 兜底。"
}

cmd_uninstall_hooks() {
  need_repo
  local hd; hd=$(git -C "$REPO" rev-parse --git-path hooks)
  case "$hd" in /*) ;; *) hd="$REPO/$hd" ;; esac
  for h in post-merge post-checkout; do
    local f="$hd/$h"
    if [ -f "$f" ] && grep -q "dsh-purge-protect-v1" "$f" 2>/dev/null; then
      rm -f "$f" && ok "已卸 $h"
      local b; b=$(ls -1t "$f".bak-* 2>/dev/null | head -1)
      [ -n "$b" ] && mv "$b" "$f" && ok "已还原原有 $h"
    else
      say "  跳过 $h（不是本脚本装的）"
    fi
  done
}

# 四种覆盖场景的实证。在临时目录里建双分支拓扑，绝不碰真仓。
cmd_sim() {
  local R; R=$(mktemp -d) || exit 1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  say "演练场：$R"
  say "（复刻 daily-sync.yml 的 git merge --no-edit -X theirs upstream/main）"
  say ""

  setup() { # setup <attr?>
    rm -rf "$R/w"; mkdir -p "$R/w"; cd "$R/w" || exit 1
    git init -q -b main . 2>/dev/null
    git config merge.ours.driver true
    [ "$1" = "attr" ] && printf 'port/** merge=ours\n' > .gitattributes
    mkdir -p port/dsh-purge
    printf 'MY KIT v2\n' > port/dsh-purge/port.sh
    printf 'keep\n' > port/dsh-purge/keep.sh
    printf 'readme v1\n' > README.md
    git add -A; git commit -qm base
    git checkout -q -b up
  }

  run_case() { # run_case <名称> <期望> <up 侧的动作函数>
    local name=$1 expect=$2 act=$3
    setup "$4"
    $act
    git add -A; git commit -qm upchange
    git checkout -q main
    git merge --no-edit -X theirs up >/dev/null 2>&1
    local got
    got=$($act.verify 2>/dev/null || echo "")
    printf '  %-28s %s\n' "$name" "$(eval "$5")"
  }

  # ① 双方都改同一文件
  setup attr
  printf 'UPSTREAM v9\n' > port/dsh-purge/port.sh; git add -A; git commit -qm up1
  git checkout -q main; printf 'MY KIT v3\n' > port/dsh-purge/port.sh; git add -A; git commit -qm m1
  git merge --no-edit -X theirs up >/dev/null 2>&1
  say "① 双方都改同一文件（有 merge=ours）"
  say "   port.sh = $(cat port/dsh-purge/port.sh)  -> $([ "$(cat port/dsh-purge/port.sh)" = "MY KIT v3" ] && echo 'ours 胜，已挡住' || echo '上游胜，被覆盖')"

  # ② 只有上游改（我们没动）
  setup attr
  printf 'UPSTREAM v9\n' > port/dsh-purge/port.sh; git add -A; git commit -qm up1
  git checkout -q main
  git merge --no-edit -X theirs up >/dev/null 2>&1
  say "② 只有上游改（我们这侧没动）"
  say "   port.sh = $(cat port/dsh-purge/port.sh)  -> $([ "$(cat port/dsh-purge/port.sh)" = "UPSTREAM v9" ] && echo '上游传入，merge=ours 不生效' || echo '已挡住')"

  # ③ 上游删除文件
  setup attr
  git rm -q port/dsh-purge/keep.sh; git add -A; git commit -qm up1
  git checkout -q main
  git merge --no-edit -X theirs up >/dev/null 2>&1
  say "③ 上游删除 port/ 下的文件"
  say "   keep.sh 存在？$([ -f port/dsh-purge/keep.sh ] && echo '在' || echo '已被删——删除会传播')"

  # ④ 上游在 port/ 下新建文件
  setup attr
  printf 'INTRUDER\n' > port/dsh-purge/UPSTREAM.txt; git add -A; git commit -qm up1
  git checkout -q main
  git merge --no-edit -X theirs up >/dev/null 2>&1
  say "④ 上游在 port/ 下新建文件"
  say "   UPSTREAM.txt 存在？$([ -f port/dsh-purge/UPSTREAM.txt ] && echo '在——无冲突即直接进来' || echo '否')"

  say ""
  say "结论：merge=ours 只覆盖场景 ①。②③④ 都会让移植件变形/消失，"
  say "      这正是 protect.sh verify/heal 存在的理由——用指纹登记兜住属性管不到的格子。"
  cd /; rm -rf "$R"
}

case "${1:-verify}" in
  verify)          cmd_verify ;;
  snapshot)        cmd_snapshot ;;
  heal)            cmd_heal ;;
  install-hooks)   cmd_install_hooks ;;
  uninstall-hooks) cmd_uninstall_hooks ;;
  sim)             cmd_sim ;;
  *)
    echo "用法：bash protect.sh {verify|snapshot|heal|install-hooks|uninstall-hooks|sim}"
    exit 2 ;;
esac
