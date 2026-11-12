#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# upstream-watch-run.sh —— 定时任务入口（每两天执行一次）
#
# 做两件事：
#   1) node port/tools/upstream-watch.mjs --publish
#      拉上游最新 → 二次确认（现装体检 + overlay 漂移 + 上游试移植 + 真实导入）
#      → 写 port/UPSTREAM-STATUS.md → 把 port/ 的实质变化推到远端 main
#   2) 保留每轮日志（近 20 份），失败不改写仓库里已发布的报告
#
# 为什么要有这层壳而不让定时任务直接调 node：
#   · 定时任务的 prompt 只能写命令，日志与退出码没人收；这层把两者落到磁盘
#   · 网络抖动时先重试一次再判失败，避免「每两天一次」的节奏被单次超时毁掉
#   · 令牌优先级固定：GITHUB_TOKEN 环境 > 仓库 origin 里的 credential
#
# 用法：
#   bash port/tools/upstream-watch-run.sh              # 正常一轮
#   bash port/tools/upstream-watch-run.sh --no-publish # 只体检，不推远端
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

PUBLISH_ARG="--publish"
for a in "$@"; do [ "$a" = "--no-publish" ] && PUBLISH_ARG=""; done

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

run_once() {
  "$NODE" "$PORT/tools/upstream-watch.mjs" $PUBLISH_ARG 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

{
  echo "=== $(date '+%F %T %z') 上游巡检开始（$PUBLISH_ARG）==="
} >> "$LOG"

run_once
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  # 0 = 正常；1 = 有 kit 现装 FAIL（结论已写进报告，不算运行失败）；其余＝环境/网络问题，重试一次
  echo "--- 首次退出码 $rc，30 秒后重试一次 ---" | tee -a "$LOG"
  sleep 30
  run_once
  rc=$?
fi

{
  echo "=== $(date '+%F %T %z') 结束 rc=$rc ==="
  echo "日志：$LOG"
} >> "$LOG"

# 只留最近 20 份日志（每两天一份 = 约 40 天）
ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +21 | while read -r old; do rm -f "$old"; done

tail -n 40 "$LOG"
exit "$rc"
