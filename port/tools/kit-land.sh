#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# kit-land.sh —— 移植插件「落地器」：把巡检判 READY 的新版本真正装到本机
#
# 补的是链条的第三段。前两段已存在：
#   ① 远端同步   daily-sync(04:00) 合并上游 → build-apk(04:30) → nightly-publish
#   ② 可用性复核 port/tools/upstream-watch.mjs（每两天 05:00）现装体检 + 上游试移植 → state.json
#   ③ 本地落地   ← 本脚本：读 ② 的判定，对 READY 的 kit 执行升版并验证
#
# 判据（缺席或不过即不动作，绝不猜）：
#   A 巡检状态在场且新鲜（state.json 存在；默认 72 小时内，--max-age 可调）
#   B 该 kit state=OUTDATED 且 portState=READY（CURRENT 跳过；NEEDS-PORT/BLOCKED 明确报出不动手）
#   C 该 kit 具备升版能力（见下表）；没有的报 NEEDS-AUTOMATION 并跳过，不硬来
#   D 升版后 port.sh verify 必须 rc=0；不过 → 从留档回滚该 kit 并报红
#
# 具备升版能力的 kit（自带 sync/提版子命令）：
#   dsh-purge   port.sh sync
# 尚无升版能力的 kit（此处只报告，需先给 kit 补能力）：
#   jet-hub     需要：拉 npm 最新 → 重建 payload → 改 manifest → 重装（可仿 dsh-purge 的 sync）
#   meow-memory 需要：改 manifest(version/source/integrity) → 装 → 重制 overlay 补丁（版本绑定）
#
# 用法：
#   bash port/tools/kit-land.sh                # 落地所有可自动升版的 kit
#   bash port/tools/kit-land.sh --dry-run      # 只报计划，不动任何东西
#   bash port/tools/kit-land.sh --kit dsh-purge
#   bash port/tools/kit-land.sh --no-push      # 升版+验证，但不推远端
#
# 退出码：0=全部处理完成（含「无需动作」）／1=有 kit 升版或验证失败（已回滚）／2=环境错误
# ============================================================================
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
PORT=$(dirname "$SELF")
REPO=$(dirname "$PORT")
DSH_HOME_DIR=${DSH_HOME:-/data/user/0/com.dsharnessmobile.shell/files/home/.dsh}
KIT_LAND_HOME="$DSH_HOME_DIR/port-land"
LOG_DIR="$KIT_LAND_HOME/logs"; mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/$STAMP.log"
exec > >(tee -a "$LOG") 2>&1

STATE_FILE=${STATE_FILE:-"$DSH_HOME_DIR/port-upstream/reports/state.json"}
MAX_AGE_HOURS=72
DRY=0; PUSH=1; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --no-push) PUSH=0 ;;
    --kit) ONLY=${2:-}; shift ;;
    --max-age) MAX_AGE_HOURS=${2:-72}; shift ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
hdr() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---- 判据 A：巡检状态在场且新鲜 ----
[ -f "$STATE_FILE" ] || { say "✘ 判据 A 未过：找不到巡检状态 $STATE_FILE（先跑 upstream-watch）"; exit 2; }
AGE_H=$(${NODE:-node} -e '
const fs=require("fs");const f=process.argv[1];
const j=JSON.parse(fs.readFileSync(f,"utf8"));
const t=Date.parse((j.at||"").replace(/ ([+-]\d{2}):(\d{2})$/,"$1$2").replace(" ","T"));
process.stdout.write(Number.isFinite(t)?String(((Date.now()-t)/3600000).toFixed(1)):"NaN");' "$STATE_FILE")
case "$AGE_H" in NaN) say "✘ 判据 A 未过：state.json 的 at 字段无法解析"; exit 2 ;; esac
if [ "${AGE_H%.*}" -gt "$MAX_AGE_HOURS" ]; then
  say "✘ 判据 A 未过：巡检状态已 $AGE_H 小时（阈值 ${MAX_AGE_HOURS}h），先重跑 upstream-watch"
  exit 2
fi
say "✔ 判据 A：巡检状态在场且新鲜（$AGE_H 小时前）"

# ---- 逐 kit 处理 ----
BACKUP_ROOT="$KIT_LAND_HOME/backup"; mkdir -p "$BACKUP_ROOT"
RC=0
PROCESSED=0; LANDED=""; SKIPPED=""; FAILED=""

for kit in $(ls "$PORT" | grep -v '^tools$'); do
  [ -f "$PORT/$kit/manifest.json" ] || continue
  [ -n "$ONLY" ] && [ "$ONLY" != "$kit" ] && continue
  read -r state portstate upstream pinned <<EOF
$(${NODE:-node} -e '
const j=require(process.argv[1]).kits||{};const k=j[process.argv[2]]||{};
process.stdout.write([k.state||"-",k.portState||"-",k.upstream||"-",k.pinned||"-"].join(" "));' "$STATE_FILE" "$kit")
EOF
  echo
  printf '\033[1m── %s ──\033[0m 钉住=%s 上游=%s 状态=%s 可移植=%s\n' "$kit" "$pinned" "$upstream" "$state" "$portstate"

  if [ "$state" = "RETIRED" ]; then say "  · 已退役，跳过"; SKIPPED="$SKIPPED $kit"; continue; fi
  if [ "$state" = "CURRENT" ]; then say "  · 已是最新（$pinned），无需动作"; SKIPPED="$SKIPPED $kit"; continue; fi
  if [ "$portstate" != "READY" ]; then
    say "  ✘ 判据 B 未过：可移植性=$portstate —— 不自动升（NEEDS-PORT 需人工重制补丁，BLOCKED 需先查失败原因）"
    SKIPPED="$SKIPPED $kit($portstate)"; continue
  fi

  case "$kit" in
    dsh-purge) UPCMD="sync" ;;
    *) say "  ⚠ 判据 C 未过：该 kit 尚无自动升版能力（NEEDS-AUTOMATION）"; \
       say "     需要补什么：jet-hub 仿 dsh-purge 的 sync（拉 npm 最新→重建 payload→改 manifest→重装）；meow-memory 另需重制版本绑定的 overlay 补丁"
       SKIPPED="$SKIPPED $kit(无升版能力)"; continue ;;
  esac
  PROCESSED=$((PROCESSED+1))

  BK="$BACKUP_ROOT/$kit-$STAMP"
  if [ "$DRY" = "1" ]; then say "  (dry-run) 将执行: port/$kit/port.sh $UPCMD；随后 port.sh verify；留档到 $BK"; continue; fi

  say "  · 留档 → $BK"; cp -a "$PORT/$kit" "$BK" || { say "  ✘ 留档失败，跳过"; FAILED="$FAILED $kit"; RC=1; continue; }

  say "  · 升版：port.sh $UPCMD"
  if ! ( cd "$REPO" && bash "port/$kit/port.sh" "$UPCMD" ); then
    say "  ✘ 升版失败 → 从留档回滚"
    rm -rf "$PORT/$kit" && cp -a "$BK" "$PORT/$kit" && ( cd "$REPO" && bash "port/$kit/port.sh" install --force >/dev/null 2>&1 || true )
    FAILED="$FAILED $kit(升版失败)"; RC=1; continue
  fi

  say "  · 可用性确认：port.sh verify"
  if ! ( cd "$REPO" && bash "port/$kit/port.sh" verify ); then
    say "  ✘ 判据 D 未过：升版后 verify 失败 → 从留档回滚并重装旧版"
    rm -rf "$PORT/$kit" && cp -a "$BK" "$PORT/$kit" && ( cd "$REPO" && bash "port/$kit/port.sh" install --force >/dev/null 2>&1 || true )
    FAILED="$FAILED $kit(verify 失败已回滚)"; RC=1; continue
  fi
  say "  ✔ $kit 已升到 $upstream 且 verify 通过"
  LANDED="$LANDED $kit($pinned→$upstream)"
done

# ---- 推远端（远端先记录新版本；失败不影响本机已装好的事实，但要报出来）----
hdr "同步到远端"
if [ "$DRY" = "1" ]; then
  say "（dry-run：不推送）"
elif [ "$PUSH" = "0" ]; then
  say "（--no-push：跳过）"
else
  cd "$REPO" || exit 2
  if git diff --quiet -- port/ && git diff --cached --quiet -- port/ && [ -z "$(git status --porcelain -- port/)" ]; then
    say "port/ 无变化，无需推送"
  else
    git add port/
    git commit -q -m "port: 自动落地升版（$(date +%Y-%m-%d)）" || say "（无内容可提交）"
    ok=0
    for i in 1 2 3; do
      if timeout 110 git push origin HEAD:main 2>&1 | tail -2; then ok=1; break; fi
      say "  推送失败，重试 $i/3"; sleep 10
    done
    if [ "$ok" = "1" ]; then say "✔ 已推送到远端 main"; else say "✘ 推送失败（本机已装好；远端记录待补，可重跑 --no-push 之外的方式重推）"; RC=1; fi
  fi
fi

# ---- 汇报 ----
hdr "本轮结论"
[ -n "$LANDED" ] && say "  已落地:$LANDED" || say "  已落地: 无"
[ -n "$SKIPPED" ] && say "  跳过:$SKIPPED"
[ -n "$FAILED" ] && say "  失败:$FAILED"
say "  日志: $LOG"
exit $RC
