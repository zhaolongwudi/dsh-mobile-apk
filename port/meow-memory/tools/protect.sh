#!/usr/bin/env bash
# protect.sh —— meow-memory kit 指纹登记与核验
# 与 port/dsh-purge/tools/protect.sh 同约定：指纹行格式 <sha256>  <相对路径>，
# 与 `sha256sum -c` 兼容。CI（.github/workflows/port-guard.yml）判据取自本文件。
#
#   bash protect.sh snapshot   # 重新登记当前状态（改过 kit 后必跑，并随提交入库）
#   bash protect.sh verify     # 逐文件核验 + 报未登记文件
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$(dirname "$SELF_DIR")"
REG="$SELF_DIR/protected.sha256"

list_files() {
  ( cd "$KIT_DIR" && find . -type f \
      ! -name '*.sha256.new' ! -name '*.bak' ! -name '*~' ! -name '*.swp' \
      ! -path './tools/protected.sha256' \
      | sed 's|^\./||' | sort )
}

cmd_snapshot() {
  : > "$REG"
  while IFS= read -r f; do
    [ "$f" = "tools/protected.sha256" ] && continue
    h=$(sha256sum "$KIT_DIR/$f" | cut -d' ' -f1)
    printf '%s  %s\n' "$h" "$f" >> "$REG"
  done < <(list_files)
  printf '已登记 %s 个文件 -> tools/protected.sha256\n' "$(wc -l < "$REG" | tr -d ' ')"
  printf '记得把 tools/protected.sha256 一起提交，否则下一轮无人能校验。\n'
}

cmd_verify() {
  [ -f "$REG" ] || { printf '缺 %s\n' "$REG" >&2; exit 1; }
  local fail=0
  while read -r want f; do
    [ -z "${f:-}" ] && continue
    if [ ! -f "$KIT_DIR/$f" ]; then printf '  ✗ 缺文件            %s\n' "$f"; fail=1; continue; fi
    got=$(sha256sum "$KIT_DIR/$f" | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then printf '  ✓ %s\n' "$f"; else printf '  ✗ 指纹不符          %s\n' "$f"; fail=1; fi
  done < "$REG"
  while IFS= read -r f; do
    grep -q "  $f\$" "$REG" || printf '  ! 未登记（有意新增请跑 snapshot）  %s\n' "$f"
  done < <(list_files)
  [ "$fail" = "0" ] && printf '结论：干净\n' || printf '结论：有文件缺失或指纹不符\n'
  exit "$fail"
}

case "${1:-snapshot}" in
  snapshot) cmd_snapshot ;;
  verify)   cmd_verify ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
