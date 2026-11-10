#!/bin/bash
# ============================================================================
# after-upstream.sh —— 拉上游提交之后的移植件守卫（只读，不写盘）
#
# 由 githooks/post-merge、githooks/post-checkout 调用。检查三件事：
#   ① 移植件完整性：payload.tar.gz 的 sha256 是否仍与 manifest.json 一致
#   ② profile 装配三处是否还在（插件依赖与 bundle 选择 / dsh-purge 条目与启动自愈 / permission 固定）
#   ③ 宿主补丁状态（真身树）—— 覆盖安装新 APK 后必然为「漂移」，这里只报不修
#
# 只报不修是刻意的：拉代码 ≠ 装 APK。真正需要修复的时机是「新 APK 装完」，
# 那时跑 bash port-kit/tools/guard.sh（或面板里点一次 Apply）。
#
# 退出码恒为 0（不阻断 git 操作）。用 DSH_PORT_GUARD_STRICT=1 可改成失败即非零。
# ============================================================================
set -u

STRICT=${DSH_PORT_GUARD_STRICT:-0}
HERE=$(cd "$(dirname "$0")" && pwd)                 # .../port/dsh-purge/tools
KIT=$(cd "$HERE/.." && pwd)                         # .../port/dsh-purge
DSH_HOME=${DSH_HOME:-/data/user/0/com.dsharnessmobile.shell/files/home/.dsh}
PROFILE="$DSH_HOME/profiles/web"
HOST_D=/data/data/com.dsharnessmobile.shell/files/usr/lib/node_modules/@deepseek-ai/dsh
HOST_BASE="$HOST_D/node_modules/@deepseek-ai"
NODE=$(command -v node 2>/dev/null || true)

# 仓库根：本脚本可能在仓库里（port/dsh-purge/tools），也可能是仓库外的 port-kit 拷贝。
REPO=${DSH_PORT_REPO:-}
[ -n "$REPO" ] || REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO" ] || REPO=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO" ]; then
  for c in "$KIT/../.." /storage/emulated/0/Download/DSH/破甲移植/fork; do
    [ -d "$c/.git" ] && REPO="$c" && break
  done
fi
# 86 条补丁的验证基线（port-kit/manifest.json 的 runtime 字段）
PATCH_BASELINE_ENGINE=0.2.2-rc.1

ok=0
say() { printf '  %s\n' "$*"; }
bad() { printf '  [!] %s\n' "$*"; ok=1; }

printf '\n[dsh-purge 移植件守卫] 拉取后自检\n'

# ① 移植件完整性
if [ -f "$KIT/manifest.json" ] && [ -f "$KIT/payload.tar.gz" ]; then
  want=$(grep -o '"sha256"[^,]*' "$KIT/manifest.json" | head -1 | sed 's/.*: *"//;s/".*//')
  have=$(sha256sum "$KIT/payload.tar.gz" 2>/dev/null | cut -d' ' -f1)
  if [ -n "$want" ] && [ "$want" = "$have" ]; then
    say "① 载荷 sha256 对齐"
  else
    bad "① 载荷 sha256 不一致（want=$want have=$have）—— 移植包被改动过"
  fi
else
  bad "① 找不到 port/dsh-purge/{manifest.json,payload.tar.gz}"
fi

# ② profile 装配三处
PKGJSON="$PROFILE/package.json"
PATCHYML="$PROFILE/cordis.patch.yml"
if [ -f "$PKGJSON" ]; then
  if [ -n "$NODE" ] && "$NODE" -e '
      const fs=require("fs");
      const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const dep=Boolean(j.dependencies&&j.dependencies["dsh-purge-community"]);
      const b=j.dsh&&j.dsh.profile&&j.dsh.profile.bundles;
      const bun=Array.isArray(b)&&b.includes("dsh-purge-community");
      process.exit(dep&&bun?0:1);
    ' "$PKGJSON" 2>/dev/null; then
    say "② profile 依赖键 + bundle 选择在位"
  else
    # 没有 node 时退回文本判据：依赖键与 bundles 数组里都要有
    if grep -q '"dsh-purge-community"' "$PKGJSON" && grep -q '"dsh-purge-community"' "$PKGJSON"; then
      say "② profile 里能看到 dsh-purge-community（文本判据，未能结构化确认）"
    else
      bad "② profile/package.json 缺 dsh-purge-community（依赖键或 bundles 选择）"
    fi
  fi
else
  bad "② 找不到 $PKGJSON"
fi

if [ -f "$PATCHYML" ]; then
  # 注意窗口：条目里 config 有多行，autoApplyOnStart 大约在条目行之后第 15-22 行，
  # 所以这里用 -A30；早期用 -A3 得到的是假阴性。
  if grep -A30 '^- id: dsh-purge$' "$PATCHYML" | grep -q 'autoApplyOnStart: true'; then
    say "② 启动自愈已武装（autoApplyOnStart: true）"
  else
    bad "② 启动自愈未武装：profile patch 的 dsh-purge 条目缺 autoApplyOnStart: true"
  fi
  # permission 条目：defaultPreset 在 - id 行之后第 2 行
  if grep -A4 '^- id: permission$' "$PATCHYML" | grep -q 'defaultPreset: danger-full-access'; then
    say "② permission 预设已固定"
  else
    bad "② permission 预设固定丢失（Android 必需项：没有它 permission entry 不激活）"
  fi
else
  bad "② 找不到 $PATCHYML"
fi

# ③ 宿主补丁状态（只报不修）。基线按**整个 dsh 包**算：46 个标记文件 / 68 个 .bak。
if [ -d "$HOST_D" ]; then
  bak=$(find "$HOST_D" -name '*.dshpurge.bak' 2>/dev/null | wc -l)
  mk=$(grep -rl '\[dsh-purge\]' "$HOST_D" --include=*.js --include=*.yml 2>/dev/null | wc -l)
  if [ "$bak" -ge 60 ] && [ "$mk" -ge 40 ]; then
    say "③ 宿主补丁在位：.bak=$bak 标记文件=$mk"
  else
    bad "③ 宿主补丁疑似丢失：.bak=$bak 标记文件=$mk（基线 68 / 46）"
    say "   -> 覆盖安装新 APK 后的正常中间态；修复：bash \"$KIT/tools/guard.sh\"（或面板点一次 Apply）"
  fi
else
  bad "③ 找不到宿主树 $HOST_D"
fi

# ④ 引擎版本预测（针对「构建物来自 main、main 每天随上游动」这条链路）
# 这是最有效的早期信号：引擎版本一变，86 条补丁的锚点就换了一片代码，
# 补丁能不能打上要重新验；而不是等到装完发现功能不对再回头查。
OVERLAY="${REPO:-}/scripts/snapshot-config/engine-overlay.json"
if [ -n "${REPO:-}" ] && [ -f "$OVERLAY" ]; then
  next=""
  [ -n "$NODE" ] && next=$("$NODE" -e 'try{process.stdout.write(String(require(process.argv[1]).engineVersion||""))}catch(e){}' "$OVERLAY" 2>/dev/null)
  [ -n "$next" ] || next=$(grep -o '"engineVersion"[^,]*' "$OVERLAY" | head -1 | sed 's/.*: *"//;s/".*//')
  live=""
  [ -n "$NODE" ] && live=$("$NODE" -e 'try{process.stdout.write(String(require(process.argv[1]).version||""))}catch(e){}' "$HOST_D/package.json" 2>/dev/null)
  [ -n "$live" ] || live=$(grep -o '"version": *"[^"]*"' "$HOST_D/package.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//')
  say "④ 引擎版本：仓库钉 ${next:-?} / 设备在跑 ${live:-?} / 补丁验证基线 $PATCH_BASELINE_ENGINE"
  if [ -n "$next" ] && [ -n "$live" ] && [ "$next" != "$live" ]; then
    bad "④ 版本将变（$live -> $next）：86 条补丁锚点未经该版本回归，装完必须跑 guard.sh，并看 reanchor list"
  elif [ -n "$next" ] && [ "$next" != "$PATCH_BASELINE_ENGINE" ]; then
    bad "④ 仓库已钉到 $next（基线 $PATCH_BASELINE_ENGINE）：装完后跑 guard.sh 复核锚点，必要时 reanchor"
  else
    say "④ 引擎版本与补丁验证基线一致，锚点面预期不变"
  fi
else
  say "④ 未定位仓库根（${REPO:-none}），跳过引擎版本预测"
fi

printf '  —— %s\n\n' "$([ "$ok" -eq 0 ] && echo '全部通过' || echo '有需要处理的项（见上）')"
[ "$STRICT" = "1" ] && exit "$ok"
exit 0
