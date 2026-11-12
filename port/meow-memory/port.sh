#!/usr/bin/env bash
# port.sh —— meow-memory（跨会话长期记忆）在 dsh-mobile-apk 上的移植控制脚本
#
# 子命令：
#   install [--force]   幂等：补装配声明 + 装包（优先本地离线包）
#   verify              四段体检（转发 tools/verify.mjs）
#   status              包/装配/记忆库一览
#   uninstall [--purge] 卸包，默认保留记忆库；--purge 连记忆库一起删
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG="meow-memory"
VERSION="0.32.6"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE="${PROFILE:-web}"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
PKG_DIR="$PROFILE_DIR/node_modules/$PKG"
NODE="${NODE:-node}"

c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
c_bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
c_warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
hdr()    { printf '\n\033[1m%s\033[0m\n' "$1"; }

find_tarball() {
  for c in "$KIT_DIR/pkg/$PKG-$VERSION.tgz" \
           "$KIT_DIR/../pkg/$PKG-$VERSION.tgz" \
           "$KIT_DIR/../../pkg/$PKG-$VERSION.tgz" \
           "/storage/emulated/0/Download/DSH/记忆插件移植/pkg/$PKG-$VERSION.tgz"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

installed_version() {
  [ -f "$PKG_DIR/package.json" ] || return 1
  "$NODE" -e 'process.stdout.write(require(process.argv[1]).version)' "$PKG_DIR/package.json" 2>/dev/null
}

cmd_status() {
  hdr "meow-memory 移植状态"
  printf '  期望版本   : %s\n' "$VERSION"
  printf '  DSH_HOME   : %s\n' "$DSH_HOME"
  printf '  profile    : %s\n' "$PROFILE"

  hdr "① 包"
  if v="$(installed_version)"; then
    if [ "$v" = "$VERSION" ]; then c_ok "node_modules/$PKG = $v"; else c_warn "版本不符：实装 $v ≠ 期望 $VERSION"; fi
  else
    c_bad "未安装：$PKG_DIR"
  fi

  hdr "② 装配声明"
  "$NODE" -e '
    const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const dep=!!(p.dependencies||{})["meow-memory"];
    const bnd=((p.dsh||{}).profile||{}).bundles||[];
    console.log((dep?"  \x1b[32m✓\x1b[0m ":"  \x1b[31m✗\x1b[0m ")+"dependencies.meow-memory");
    console.log((bnd.includes("meow-memory")?"  \x1b[32m✓\x1b[0m ":"  \x1b[31m✗\x1b[0m ")+"dsh.profile.bundles 含 meow-memory");
    console.log((!Object.keys(p.dependencies||{}).some(k=>/memento/.test(k))?"  \x1b[32m✓\x1b[0m ":"  \x1b[31m✗\x1b[0m ")+"dependencies 无 dsh-memento 残留");
  ' "$PROFILE_DIR/package.json" 2>/dev/null || c_bad "读不到 $PROFILE_DIR/package.json"

  hdr "③ profile 配置（promptLang）"
  if grep -q -- "- id: meow-memory" "$PROFILE_DIR/cordis.patch.yml" 2>/dev/null; then
    c_ok "cordis.patch.yml 有 - id: meow-memory 条目"
    sed -n '/- id: meow-memory/,/^-\s/p' "$PROFILE_DIR/cordis.patch.yml" 2>/dev/null | sed 's/^/      /' | head -8
  else
    c_warn "cordis.patch.yml 无 meow-memory 条目（将用插件出厂默认值，promptLang 默认 zh）"
  fi

  hdr "④ 记忆库（当前工作区）"
  WS="${WORKSPACE:-$PWD}"
  DB="$WS/.dsh-meow/memory.db"
  if [ -f "$DB" ]; then
    c_ok "库文件：$DB（$(du -h "$DB" | cut -f1)）"
    "$NODE" -e '
      const {DatabaseSync}=require("node:sqlite");
      const db=new DatabaseSync(process.argv[1],{readOnly:true});
      const ts=db.prepare("select name from sqlite_master where type=\"table\"").all().map(r=>r.name);
      console.log("      表: "+ts.join(", "));
      let total=0;
      for(const n of ["soul","user","project","fact","lesson","topic","rules"]){
        if(!ts.includes(n)) continue;
        const c=db.prepare(`select count(*) c from "${n}"`).get().c; total+=c;
        console.log(`      ${n.padEnd(8)} ${c}`);
      }
      console.log("      合计 "+total+" 条");
    ' "$DB" 2>&1 | sed 's/^/  /' || c_warn "库读取失败（可能被占用）"
  else
    c_warn "本工作区尚无记忆库：$DB"
  fi
}

cmd_install() {
  hdr "安装 meow-memory@$VERSION"
  mkdir -p "$DSH_HOME/port-backup"
  [ -f "$PROFILE_DIR/package.json" ] && cp -av "$PROFILE_DIR/package.json" \
    "$DSH_HOME/port-backup/package.json.pre-meow-$(date +%Y%m%d-%H%M%S).bak" >/dev/null
  [ -f "$PROFILE_DIR/cordis.patch.yml" ] && cp -av "$PROFILE_DIR/cordis.patch.yml" \
    "$DSH_HOME/port-backup/cordis.patch.yml.pre-meow-$(date +%Y%m%d-%H%M%S).bak" >/dev/null
  c_ok "已备份 package.json / cordis.patch.yml"

  if tb="$(find_tarball)"; then
    c_ok "使用本地离线包：$tb"
    ( cd "$PROFILE_DIR" && dsh plugin --profile "$PROFILE" add "file:$tb" ) || \
      ( cd "$PROFILE_DIR" && pnpm add "file:$tb" )
  else
    c_warn "未找到离线包，改从 npm 拉取"
    dsh plugin --profile "$PROFILE" add "$PKG@$VERSION"
  fi

  if v="$(installed_version)"; then c_ok "已装：$PKG@$v"; else c_bad "安装未生效"; return 1; fi

  cmd_overlay

  if ! grep -q -- "- id: meow-memory" "$PROFILE_DIR/cordis.patch.yml" 2>/dev/null; then
    c_warn "配置段未写：请在 $PROFILE_DIR/cordis.patch.yml 末尾追加（config 是整体替换，键要给全）"
    printf '\n- id: meow-memory\n  config:\n    promptLang: zh\n'
  fi
  hdr "下一步"
  echo "  1) 重载插件或重启应用（node_modules 改动不走 HMR）"
  echo "  2) bash port/meow-memory/port.sh verify"
}

cmd_overlay() {
  # 把 kit 的 overlay/ 铺到已装包上（幂等：先比 sha256，一致就不动）。
  # overlay 是「移植补丁」的落点，逐文件遍历 —— 硬编码单个文件会漏铺（2026-11-12 的教训：
  # 当时只铺 client.js，新加的 index.js 兜底就铺不上）：
  #   (a) lib/client.js  设置页响应式 + 模型下拉 + 目录选择器（只给 homeDir）
  #   (b) lib/index.js   projectDir 绝对路径兜底 normalizeProjectDir（记忆库漂移事故后加）
  [ -d "$KIT_DIR/overlay" ] || { c_warn "kit 无 overlay/，跳过"; return 0; }
  [ -d "$PKG_DIR" ] || { c_bad "未装包，先 install"; return 1; }
  local n=0 f rel ov dst want got
  while IFS= read -r f; do
    rel="${f#"$KIT_DIR/overlay/"}"
    ov="$f"; dst="$PKG_DIR/$rel"
    n=$((n + 1))
    if [ ! -f "$dst" ]; then
      c_bad "已装包缺 $rel —— 包结构与 kit 期望不符"
      continue
    fi
    want=$(sha256sum "$ov" | cut -d' ' -f1)
    got=$(sha256sum "$dst" | cut -d' ' -f1)
    if [ "$want" = "$got" ]; then
      c_ok "overlay 已就位（$rel ${want:0:16}…）"
    else
      cp -f "$dst" "$DSH_HOME/port-backup/meow-$rel-preoverlay-$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1 || true
      cp -f "$ov" "$dst"
      c_ok "overlay 已铺（$rel → ${want:0:16}…）"
    fi
  done < <(find "$KIT_DIR/overlay" -type f | sort)
  [ "$n" -gt 0 ] || c_warn "overlay/ 为空"
}

cmd_verify() {
  hdr "四段体检"
  "$NODE" "$KIT_DIR/tools/verify.mjs" "$@"
}

cmd_uninstall() {
  PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1
  hdr "卸载 meow-memory"
  dsh plugin --profile "$PROFILE" remove "$PKG" 2>&1 | tail -5 || true

  if grep -q -- "- id: meow-memory" "$PROFILE_DIR/cordis.patch.yml" 2>/dev/null; then
    cp -av "$PROFILE_DIR/cordis.patch.yml" \
      "$DSH_HOME/port-backup/cordis.patch.yml.pre-meow-uninstall-$(date +%Y%m%d-%H%M%S).bak" >/dev/null
    c_warn "cordis.patch.yml 里的 meow-memory 条目需手动删除（本工具不自动改配置结构）"
  fi

  WS="${WORKSPACE:-$PWD}"
  if [ "$PURGE" = "1" ]; then
    if [ -d "$WS/.dsh-meow" ]; then
      BK="$DSH_HOME/port-backup/meow-store-$(date +%Y%m%d-%H%M%S)"
      cp -av "$WS/.dsh-meow" "$BK" >/dev/null && c_ok "记忆库已归档：$BK"
      rm -rf "$WS/.dsh-meow" && c_ok "已删除 $WS/.dsh-meow"
    fi
  else
    c_ok "保留记忆库：$WS/.dsh-meow（--purge 才删）"
  fi
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  overlay)   cmd_overlay ;;
  verify)    shift; cmd_verify "$@" ;;
  status)    cmd_status ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
