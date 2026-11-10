#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# guard.sh —— dsh-purge 宿主补丁守卫（体检 → 漂移就重打 → 复核 → 记日志）
#
# 分工：
#   引擎启动自愈（profile 里 autoApplyOnStart: true）负责「开机后自己长回来」；
#   本脚本负责「在覆盖发生的那一瞬间就发现」，并在需要时用**完全相同的入口**补回去，
#   再补上启动自愈**有意不打**的那一类（见下）。
#
# 用引擎 boot 时 settle 的同一入口：lib/reapply-cli.js → reapplyInstalled()
# 它比直接 apply 多一步 refreshStaleBaksForUpgrade：新版 APK 带来的是新版宿主文件，
# 旁边却留着老 .bak；直接 revert 会把新宿主写成旧版原文 → 新旧混码直接崩
# （reapply.js:320-332 的注释就是这条实测）。
#
# 已知边界（务必读懂，否则会误判「已修好」）：
#   启动自愈对 watched client bundle 一律跳过
#     （reapply.js:319/335、index.js:1112 都带 preserveClientBundles: true；
#       core.js:2697-2705 的 revert 也跳过，理由：copyFile 即使字节相同也会改 mtime，#63）
#   命中集合 = node_modules/@scope/pkg/lib/client.js，当前补丁表里只有
#     #56 REWIND_HIDE_CUT_ONLY / #77 REWIND_DROP_SENT_ON_APPEND（conversation-client）
#   所以本脚本在 reapply 之后会再看一次 pending，不为 0 就补一次完整 Apply。
#
# 另一个坑：不能走 community.js 的 LEGACY 转发（`community.js apply`）——
# 它实现为 spawnSync(process.execPath, [bin/dsh-purge.js, ...])，而本机
# process.execPath = /apex/com.android.runtime/bin/linker64（termux-exec 的 LD_PRELOAD
# 把 exec 重路由到 linker），于是变成 `linker64 dsh-purge.js` → linker 拿 JS 当 ELF
# → "has bad ELF magic: 23212f75"。所以这里一律直接调 bin/dsh-purge.js。
# 同款坑的项目记录：fork docs/AGENTS/gotchas.md（apk #83/#89/#96）。
#
# 退出码：0 = 干净或已修复；1 = 需要人工介入。
# 用法：
#   bash guard.sh            # 体检，漂移则自动修复
#   bash guard.sh --dry      # 只体检，不写盘
#   bash guard.sh --quiet    # 只输出结论
#   DSH_GUARD_HOST_BASE=...  # 只用于自检/负控：把宿主根指到别处（如演练场）
# ============================================================================
set -u

REAL_HOME=${DSH_HOME:-/data/user/0/com.dsharnessmobile.shell/files/home/.dsh}
HOST_D=/data/data/com.dsharnessmobile.shell/files/usr/lib/node_modules/@deepseek-ai/dsh
HOST_BASE=${DSH_GUARD_HOST_BASE:-$HOST_D/node_modules/@deepseek-ai}
PKG="$REAL_HOME/profiles/web/node_modules/dsh-purge-community"
# DSH_HOME 被指到演练场时那边没有插件包；插件代码与宿主根无关，回落到系统 profile。
[ -f "$PKG/lib/reapply-cli.js" ] || PKG=/data/user/0/com.dsharnessmobile.shell/files/home/.dsh/profiles/web/node_modules/dsh-purge-community
NODE=$(command -v node)
LOG="$REAL_HOME/port-backup/guard.log"
DRY=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --dry) DRY=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

mkdir -p "$(dirname "$LOG")"
stamp=$(date '+%F %T %z')
log() { printf '%s  %s\n' "$stamp" "$*" >> "$LOG"; }
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

[ -x "$NODE" ] || { echo "找不到 node"; exit 1; }
[ -f "$PKG/lib/reapply-cli.js" ] || { echo "找不到插件：$PKG"; exit 1; }

# 在守卫环境里跑插件的 Node 入口
run_pkg() { # run_pkg <js> [args...]
  local f="$1"; shift
  env -u DSH_WORKSPACE -u DSH_SESSION_ID -u DSH_WRITE_MODE -u DSH_PROFILE_DIR -u DSH_WEB_URL \
    DSH_HOME="$REAL_HOME" DSH_BASE="$HOST_BASE" DSH_PROFILE=web \
    "$NODE" "$f" "$@"
}

# 关键判据全部取自 selfcheck 的权威字段：
#   state / ok                      总判决
#   summary.pending.patches         待打补丁数（注意不是 hints，那个是建议列表）
#   patch.applied / total           已打 / 可适用
#   patch.missing_file              目标文件缺失数（安装完整性）
parse_selfcheck() { # 从 stdin 的 selfcheck JSON 输出一行 "state ok applied total pending missing"
  "$NODE" -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let j={};try{j=JSON.parse(d)}catch(e){}
      const p=j.patch||{}, s=(j.summary&&j.summary.pending)||{};
      process.stdout.write([
        j.state||"?",
        String(j.ok===true),
        (p.applied!=null?p.applied:"?"),
        (p.total!=null?p.total:"?"),
        (s.patches!=null?s.patches:"?"),
        (p.missing_file!=null?p.missing_file:"?")
      ].join(" "));
    });'
}

check() { run_pkg "$PKG/bin/community.js" selfcheck --json 2>/dev/null | parse_selfcheck; }

# 锚点漂移分类。区分两种完全不同的病：
#   ① 补丁丢失（工厂覆盖）——锚点还在，自愈能打回来；
#   ② 锚点搬家（上游/引擎代码变了）——自愈打不上，必须重新锚定（reanchor 会写进
#      用户面的 overrides，快照合并不会覆盖）。
# 只列非 optional 的：optional 漂移（当前是 #76/#54）是设计内的「已到位」，不该当故障。
drift_rows() { # 输出 "id<TAB>name"
  run_pkg "$PKG/bin/community.js" reanchor list 2>/dev/null | "$NODE" -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let j={};try{j=JSON.parse(d)}catch(e){}
      for(const r of (j.drifted||[])) if(!r.optional) process.stdout.write(r.id+"\t"+r.name+"\n");
    });'
}

# ---------- 一、体检 ----------
read -r STATE OK APPLIED TOTAL PENDING MISSING <<EOF
$(check)
EOF
[ -n "${STATE:-}" ] || { echo "selfcheck 无输出，宿主可能已损坏"; log "selfcheck empty -> FAIL"; exit 1; }

say "宿主: $HOST_BASE"
say "状态: state=$STATE ok=$OK applied=$APPLIED/$TOTAL pending=$PENDING missing_file=$MISSING"

need=0
[ "$OK" = "true" ] || need=1
[ "$STATE" = "ok" ] || need=1
[ "$PENDING" != "0" ] && [ -n "$PENDING" ] && need=1
[ "$MISSING" != "0" ] && [ -n "$MISSING" ] && need=1

if [ "$need" -eq 0 ]; then
  say "结论: 干净，无需处理。"
  log "clean state=$STATE applied=$APPLIED/$TOTAL pending=$PENDING"
  exit 0
fi

say "结论: 检测到漂移（覆盖安装或 DSH 自升级后的必然中间态）。"
# 先分类，再决定「能不能自愈」。这一步是给「构建物来自 main、每天随上游动」的节奏用的：
# 上游动代码 → 锚点搬家 → 自愈再怎么跑也打不上，必须重新锚定。
HARD_DRIFT=$(drift_rows)
if [ -n "$HARD_DRIFT" ]; then
  say "分类: 存在**锚点搬家**（非 optional，自愈打不上，需要重新锚定）："
  printf '%s\n' "$HARD_DRIFT" | while IFS="	" read -r i n; do say "    #$i $n"; done
else
  say "分类: 无锚点搬家（漂移都在 optional/已到位那一类）-> 自愈应能解决。"
fi
if [ "$DRY" -eq 1 ]; then
  say "--dry：不写盘。修复请去掉 --dry。"
  log "drift (dry) state=$STATE applied=$APPLIED/$TOTAL pending=$PENDING missing=$MISSING"
  exit 1
fi

# ---------- 二、修复：与引擎 boot 同一入口 ----------
say "修复: 走 reapply-cli（refreshStaleBaksForUpgrade -> revertAll -> applyPatches -> 盖戳）..."
RA=$(run_pkg "$PKG/lib/reapply-cli.js" 2>&1)
say "  $RA"
log "reapply: $RA"

# ---------- 三、补打启动自愈有意跳过的那一类 ----------
read -r STATE2 OK2 APPLIED2 TOTAL2 PENDING2 MISSING2 <<EOF
$(check)
EOF
say "复查: state=$STATE2 applied=$APPLIED2/$TOTAL2 pending=$PENDING2"
if [ "${PENDING2:-0}" != "0" ]; then
  say "补打: 仍有 ${PENDING2} 条 pending（客户端 bundle 是已知一类），走完整 Apply..."
  FA=$(run_pkg "$PKG/bin/dsh-purge.js" --apply 2>&1 | tail -6)
  say "  $FA"
  log "full-apply: $(printf '%s' "$FA" | tr '\n' ' ')"
fi

# ---------- 四、复核 ----------
read -r STATE3 OK3 APPLIED3 TOTAL3 PENDING3 MISSING3 <<EOF
$(check)
EOF
markers=$(grep -rl '\[dsh-purge\]' "$HOST_BASE" --include=*.js --include=*.yml 2>/dev/null | wc -l)
say "复核: state=$STATE3 ok=$OK3 applied=$APPLIED3/$TOTAL3 pending=$PENDING3 标记文件=$markers"

if [ "$OK3" = "true" ] && [ "$STATE3" = "ok" ] && [ "${PENDING3:-0}" = "0" ]; then
  say "结论: 已修复。**引擎需要重启一次才会加载重打后的宿主代码**（重启应用即可）。"
  log "healed state=$STATE3 applied=$APPLIED3/$TOTAL3 pending=$PENDING3 markers=$markers"
  exit 0
fi
say "结论: 修复未完成，需人工介入（看上面 reapply 报错与 $LOG）。"
HD2=$(drift_rows)
if [ -n "$HD2" ]; then
  say "原因分类: 以下补丁锚点已搬家（上游/引擎代码变了），必须重新锚定："
  printf '%s\n' "$HD2" | while IFS="	" read -r i n; do
    say "    #$i $n"
    say "       处理: $NODE $PKG/bin/community.js reanchor apply $i --yes"
  done
  say "  重锚写进用户面的 overrides，快照合并不会覆盖它。"
else
  say "原因分类: 无锚点搬家；看 $LOG 里 reapply 的具体报错（可能是目标文件缺失/版本不匹配）。"
fi
log "heal FAILED state=$STATE3 applied=$APPLIED3/$TOTAL3 pending=$PENDING3 hard_drift=$(printf '%s' "$HD2" | tr '\n' ',')"
exit 1
