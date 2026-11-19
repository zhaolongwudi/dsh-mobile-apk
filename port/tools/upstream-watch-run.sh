#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# upstream-watch-run.sh —— 定时任务入口（每两天执行一次）
#
# 做三件事（2026-11-20 修正：补上「真落地」这一段）：
#   1) node port/tools/upstream-watch.mjs           # 只检测，不推送
#      拉上游最新 → 二次确认（现装体检 + overlay 漂移 + 上游试移植 + 真实导入）
#      → 写 port/UPSTREAM-STATUS.md + state.json
#   2) node port/tools/autoland.mjs --publish       # 真落地：把 READY 的版本固化到
#      kit、重装进本机 profile、verify 通过后把整个 port/ 推到远端 main
#   3) 保留每轮日志（近 20 份），失败不改写仓库里已发布的报告
#
# 为什么拆成「检测 / 落地」两步：
#   旧版这里直接调 upstream-watch --publish，只把检测报告推上去就结束了 ——
#   判出 READY 也从不固化、从不重装、从不更新已装版本，于是每两天都在重复报告
#   「检测到新版 + 可以升级」，本地和远端却一直停在旧版。autoland 补上这段。
#
# 为什么要有这层壳而不让定时任务直接调 node：
#   · 定时任务的 prompt 只能写命令，日志与退出码没人收；这层把两者落到磁盘
#   · 网络抖动时先重试一次再判失败，避免「每两天一次」的节奏被单次超时毁掉
#   · 令牌优先级固定：GITHUB_TOKEN 环境 > 仓库 origin 里的 credential
#
# 用法：
#   bash port/tools/upstream-watch-run.sh              # 正常一轮（检测 + 落地 + 推远端）
#   bash port/tools/upstream-watch-run.sh --no-publish # 检测 + 落地，但不推远端
#   bash port/tools/upstream-watch-run.sh --detect-only# 只检测（旧行为），不落地不推
# ============================================================================
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
PORT=$(dirname "$SELF")
REPO=$(dirname "$PORT")
NODE=${NODE:-node}
# 运行期产物放仓库外：仓库工作树只留 port/ 里要提交的东西
DSH_HOME_DIR=${DSH_HOME:-/data/user/0/com.dsharnessmobile.shell/files/home/.dsh}
RUN_HOME="$DSH_HOME_DIR/port-upstream"
LOG_DIR="$RUN_HOME/logs"
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/$STAMP.log"

PUBLISH=1
DETECT_ONLY=0
for a in "$@"; do
  [ "$a" = "--no-publish" ] && PUBLISH=0
  [ "$a" = "--detect-only" ] && DETECT_ONLY=1
done

# 令牌：环境里有就用，否则交给脚本自己从 origin 解析（脚本已处理 user:token 形状）
if [ -z "${GITHUB_TOKEN:-}" ]; then
  url=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
  case "$url" in
    https://*@*)
      cred=${url#https://}; cred=${cred%%@*}
      GITHUB_TOKEN=${cred#*:}
      export GITHUB_TOKEN
      ;;
  esac
fi

# 第一段：只检测（不推送）。0=正常；1=有 kit 现装 FAIL（结论已写报告，不算运行失败）；其余=环境/网络错误
detect_once() {
  "$NODE" "$PORT/tools/upstream-watch.mjs" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

# 第二段：真落地。读第一段刚写的 state.json，把 READY 的 kit 固化+重装+verify+推远端
land_once() {
  local extra=""
  [ "$PUBLISH" -eq 0 ] && extra="--no-push"
  "$NODE" "$PORT/tools/autoland.mjs" $extra 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

{
  echo "=== $(date '+%F %T %z') 上游巡检开始（detect$( [ "$DETECT_ONLY" -eq 0 ] && echo ' + autoland' )$( [ "$PUBLISH" -eq 1 ] && echo ' + publish' )）==="
} >> "$LOG"

# ---- 第一段：检测（网络抖动重试一次）----
detect_once
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  echo "--- 检测首次退出码 $rc，30 秒后重试一次 ---" | tee -a "$LOG"
  sleep 30
  detect_once
  rc=$?
fi

# ---- 第二段：真落地（检测本身失败就不落地，避免拿旧 state 误操作）----
LAND_RC=0
if [ "$DETECT_ONLY" -eq 0 ]; then
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    land_once
    LAND_RC=$?
    if [ "$LAND_RC" -ne 0 ]; then rc=$LAND_RC; fi
  else
    echo "--- 检测失败（rc=$rc），跳过落地 ---" | tee -a "$LOG"
  fi
fi

{
  echo "=== $(date '+%F %T %z') 结束 rc=$rc（detect + land=$LAND_RC）==="
  echo "日志：$LOG"
} >> "$LOG"

# 只留最近 20 份日志（每两天一份 = 约 40 天）
ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +21 | while read -r old; do rm -f "$old"; done

tail -n 40 "$LOG"
exit "$rc"
