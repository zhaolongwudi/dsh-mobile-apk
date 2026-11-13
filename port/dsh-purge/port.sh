#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# dsh-purge-community 在 dsh-mobile-apk（Android 壳）上的移植维护脚本。
#
# 设计前提（与 port/jet-hub 同一套路）：插件**不进 APK、不进 main**，只活在 app 私有数据里：
#   $DSH_HOME/profiles/web/node_modules/dsh-purge-community      插件本体
#   $DSH_HOME/profiles/web/package.json                          依赖键 + dsh.profile.bundles 选择
#   $DSH_HOME/profiles/web/cordis.patch.yml                      permission 预设固定（必需，见下）
#   <宿主> node_modules/@deepseek-ai/<pkg>/lib/*.js              86 条宿主补丁（apply 写入）
# 前三者按「用户面优先、工厂只补缺」被快照刷新合并保留；第四者在每次 APK 更新/快照刷新后需要重打。
#
# 用法：
#   bash port.sh install            离线铺文件 + 注册装配 + 修 permission 固定（幂等）
#   bash port.sh install --force    忽略版本戳强制重铺
#   bash port.sh apply              给宿主打 86 条清洗补丁（写入前自动备份）+ 再修一次固定
#   bash port.sh revert             回滚宿主补丁到备份原件
#   bash port.sh pin                只修 permission 预设固定（补丁后宿主组合非法时的必需项）
#   bash port.sh verify             体检：文件/装配/模块/引擎 fiber/客户端条目/补丁/固定
#   bash port.sh status             只打印现状，不改任何东西
#   bash port.sh uninstall          卸载（保留 prompt-inject.md 与用户规则；--purge 连状态一起删）
#   bash port.sh sync --check       查上游最新 release，不下载
#   bash port.sh sync               拉上游最新 release，重建 payload 并重装（需要网络）
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -d "$FILES/home" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
HOME_DIR=$FILES/home
DSH_HOME=${DSH_HOME:-$HOME_DIR/.dsh}
PROFILE=$DSH_HOME/profiles/web
NODE=${NODE:-$FILES/usr/bin/node}
PKG=dsh-purge-community
MANIFEST=$SELF/manifest.json
STATE=$DSH_HOME/purge-port-state.json
PIN_MARK="# dsh-purge port (Android): pin the permission preset explicitly."

die() { printf 'port: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
jq_node() { "$NODE" -e "$1" "${@:2}"; }

# ---------------------------------------------------------------------------
# 依赖键政策（2026-11-11 修，设备实证）
#
# dsh-purge-community **不在 npm registry 上**（registry.npmjs.org 与 npmmirror
# 都是 404）。若把它按 registry 形状写进 profile/package.json 的 dependencies
# （裸版本号或范围），任何 pnpm 动作都会去 registry 拉它 →
#   ERR_PNPM_FETCH_404 GET https://registry.npmjs.org/dsh-purge-community
# → **整次安装事务失败**（实证：profile/.plugin-manager/logs/operation-*/pnpm.log
#   2026-11-10 19:53 两次；2026-11-11 一次事务把它与 lockfile 一起重写掉了）。
#
# 引擎侧装配 bundle **不需要** dependencies 键：dsh-app-boot 的 loadProfileDirectory
# 逐个 bundle 调 resolveBundleDir → packageDirFromAnchor 做的是**目录探测**
# （createRequire(anchor).resolve.paths + 目录里有没有 package.json），与
# dependencies / lockfile 无关（dsh-app-boot/lib/index.js:1817-1823、1836-1842）。
# dependencies 只影响插件管理器「已安装 / 可移除 / 可更新」的记账（dsh-plugin-manager
# lib/index.js:2147）。
#
# 所以本 kit 的口径：**只登记 dsh.profile.bundles，不写 registry 形状的依赖键**；
# 发现地雷键就自动去掉（de-poison），verify 里把它判 FAIL 防止再长回来。
# 手工铺的包天然活在 lockfile 之外，这是本仓既有口径（见 port/jet-hub/tools/lockfix.mjs
# 头注释：完全缺席的包不擅自补 lockfile，只知情）。
# ---------------------------------------------------------------------------
spec_is_registry() { # $1=spec；rc=0 表示「registry 形状」（会触发 registry 解析）
  case "$1" in
    ""|file:*|link:*|git*|http:*|https:*|/*|.*|workspace:*) return 1 ;;
    *) return 0 ;;
  esac
}

need_runtime() {
  [ -x "$NODE" ] || die "找不到运行时 node：$NODE（可用 NODE=... 覆盖）"
  [ -d "$PROFILE" ] || die "找不到 web profile：$PROFILE（应用是否已首次启动？）"
}

kit_version() { jq_node 'console.log(require(process.argv[1]).package.version)' "$MANIFEST" 2>/dev/null || echo unknown; }

# 宿主 @deepseek-ai 目录：只有含 dsh-agent-instructions/lib 的才算（与插件 probeAiBase 同判据）
host_base() {
  local c
  for c in \
    "$FILES/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai" \
    "$DSH_HOME/profiles/web/node_modules/@deepseek-ai"; do
    [ -d "$c/dsh-agent-instructions/lib" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

ensure_payload() {
  # 载荷三级回落（与 port/jet-hub 同一约定）：仓库里的 kit 不背二进制，所以缺载荷
  # 时按 manifest.json 钉住的版本现取一份（fetch-payload.sh）。
  #   ① 已展开的 payload/node_modules/$PKG 目录（fetch-payload.sh 或 sync 的产物）
  #   ② 本地 payload.tar.gz（离线副本）
  #   ③ 现场获取 → 再回到 ①/②
  local payload=$SELF/payload
  if [ -d "$payload/node_modules/$PKG" ]; then printf '%s' "$payload"; return 0; fi
  local archive=$SELF/payload.tar.gz
  if [ ! -f "$archive" ]; then
    [ -f "$SELF/fetch-payload.sh" ] || die "缺少离线载荷：$archive（也没有 fetch-payload.sh）"
    say "本地无载荷，按 manifest.json 从发布源重新获取…" >&2
    bash "$SELF/fetch-payload.sh" >&2 || die "获取载荷失败（无网络时改用带 payload.tar.gz 的分支副本）"
    if [ -d "$payload/node_modules/$PKG" ]; then printf '%s' "$payload"; return 0; fi
    archive=$SELF/payload.tar.gz
    [ -f "$archive" ] || die "获取载荷失败：payload/ 与 payload.tar.gz 都不存在"
  fi
  local cache=$SELF/.unpacked
  if [ ! -d "$cache/node_modules/$PKG" ]; then
    rm -rf "$cache"; mkdir -p "$cache" || die "无法创建 $cache"
  "$NODE" -e '
    const fs=require("node:fs"),zlib=require("node:zlib"),path=require("node:path");
    const [src,dst]=process.argv.slice(1);
    const tar=zlib.gunzipSync(fs.readFileSync(src));
    let off=0;
    while(off+512<=tar.length){
      const head=tar.subarray(off,off+512);
      if(head.every(b=>b===0))break;
      const name=head.subarray(0,100).toString("utf8").replace(/\0.*$/s,"");
      const size=parseInt(head.subarray(124,136).toString("ascii").replace(/\0.*$/s,"").trim()||"0",8);
      const type=String.fromCharCode(head[156]||48);
      const mode=parseInt(head.subarray(100,108).toString("ascii").replace(/\0.*$/s,"").trim()||"644",8);
      const data=tar.subarray(off+512,off+512+size);
      off+=512+Math.ceil(size/512)*512;
      if(!name||name===".")continue;
      const target=path.join(dst,name);
      if(!target.startsWith(dst+path.sep)&&target!==dst)throw new Error("unsafe path "+name);
      if(type==="5")fs.mkdirSync(target,{recursive:true});
      else{fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,data,{mode:mode&0o777});}
    }
  ' "$archive" "$cache" || die "解包离线载荷失败"
  fi
  printf '%s' "$cache"
}

# permission 预设固定：宿主补丁把组合改成「完全访问 / never」后，官方预设表推不出默认值，
# dsh-permission-presets 会以 "composed sandbox and approval defaults match no preset" 拒绝激活。
ensure_pin() {
  local file=$PROFILE/cordis.patch.yml
  [ -f "$file" ] || { say "  - 没有 profile patch，跳过固定"; return 0; }
  if grep -qF "$PIN_MARK" "$file"; then say "  - permission 固定已在位"; return 0; fi
  cp -a "$file" "$file.purge-port.bak" 2>/dev/null || true
  cat >> "$file" <<EOF

$PIN_MARK
# After the 86 host patches the composed sandbox/approval defaults no longer match any
# preset table entry, so dsh-permission-presets refuses to activate. Pinning
# defaultPreset removes the inference and keeps the preset service alive.
- id: permission
  config:
    defaultPreset: danger-full-access
    presets:
      danger-full-access:
        sandbox: danger-full-access
        approval: never
EOF
  say "  ✓ 已写入 permission 固定（备份 $file.purge-port.bak）"
}

cmd_pin() { need_runtime; say "== permission 预设固定 =="; ensure_pin; }

cmd_status() {
  need_runtime 2>/dev/null || true
  local installed=none
  [ -f "$PROFILE/node_modules/$PKG/package.json" ] && \
    installed=$(jq_node 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json" 2>/dev/null || echo unreadable)
  local host; host=$(host_base 2>/dev/null || echo "(未定位)")
  say "kit          : $(kit_version)"
  say "profile      : $PROFILE"
  say "installed    : $installed"
  say "host base    : $host"
  [ -f "$STATE" ] && say "stamp        : $(cat "$STATE")" || say "stamp        : (无)"
  jq_node '
    const fs=require("node:fs");const [f,n,lock]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(f,"utf8"));
    const dep=(j.dependencies||{})[n];
    const local=/^(file:|link:|git\+?|https?:|\/|\.)/.test(String(dep||""));
    console.log("dep key      : "+(dep===undefined?"(无：设计如此，registry 上没有这个包)":(local?"本地/远端 spec "+dep:"registry spec "+dep+"  <- 地雷，会让 pnpm 404")));
    const b=((j.dsh||{}).profile||{}).bundles||[];
    console.log("bundles      : "+(b.includes(n)?"已登记 ("+b.length+" 项)":"未登记 ("+b.length+" 项)"));
    let lockHas=false;
    try{ const s=fs.readFileSync(lock,"utf8"); lockHas=new RegExp("(^|[^a-z-])"+n+"@","m").test(s); }catch(e){}
    console.log("lockfile     : "+(fs.existsSync(lock)?(lockHas?"有 "+n+" 条目":"无 "+n+" 条目（手工铺的包，按项目口径不擅自补）"):"无 pnpm-lock.yaml"));
  ' "$PROFILE/package.json" "$PKG" "$PROFILE/pnpm-lock.yaml" 2>/dev/null || say "package.json : 无法解析"
  grep -qF "$PIN_MARK" "$PROFILE/cordis.patch.yml" 2>/dev/null && say "permission   : 已固定" || say "permission   : 未固定（补丁后权限预设会拒绝激活 → 跑 pin）"
  local inject_state='(尚未生成)'
  if [ -s "$DSH_HOME/prompt-inject.md" ]; then inject_state="($(wc -c <"$DSH_HOME/prompt-inject.md") 字节)"; fi
  say "inject file  : $DSH_HOME/prompt-inject.md $inject_state"
  local q=$([ -f "$DSH_HOME/cordis.patch.yml" ] && grep -c "quarantine-v1" "$DSH_HOME/cordis.patch.yml" || echo 0)
  say "quarantine   : $q 条隔离标记（home patch）"
}

cmd_install() {
  local force=0
  for a in "$@"; do case "$a" in --force) force=1 ;; *) die "未知参数：$a" ;; esac; done
  need_runtime
  local payload; payload=$(ensure_payload)
  local version; version=$(jq_node 'console.log(require(process.argv[1]).version)' "$payload/node_modules/$PKG/package.json")
  local stamp="{\"package\":\"$PKG\",\"version\":\"$version\",\"kit\":\"$(kit_version)\",\"installedAt\":\"$(date -Iseconds)\"}"

  mkdir -p "$DSH_HOME/port-backup"
  local backup=$DSH_HOME/port-backup/purge-profile-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  cp "$PROFILE/package.json" "$backup/package.json" 2>/dev/null || true
  cp "$PROFILE/cordis.patch.yml" "$backup/cordis.patch.yml" 2>/dev/null || true
  ls -1dt "$DSH_HOME/port-backup"/purge-profile-* 2>/dev/null | tail -n +6 | while read -r old; do rm -rf "$old"; done

  # 干净落位判据（2026-11-11 加）：装出来的目录必须**逐文件等于发布物**。
  # 为什么需要：早期用源码树铺过一次，发布物 322 个文件，落出来的目录却有 499 个
  # （多出 test/ 106、packages/ 54、market/ 6、.github/ 6、release-notes.md、
  #  package-lock.json、NATIVE-PANEL.md、.npmignore、.gitignore 共 177 个 dev 件）。
  # 多出来的文件功能上不致命，但会：① 版本升级时**旧版残件残留**（上游删掉的文件
  # 不会跟着消失）；② 让「装的是不是发布物」变得无法用文件集判据核。
  # cp -R 是叠加式，天然不会删旧文件 —— 所以这里改成「旧目录先移走，再整份铺」。
  local pkgdir=$PROFILE/node_modules/$PKG
  local cur_ver=""
  [ -f "$pkgdir/package.json" ] && cur_ver=$(jq_node 'console.log(require(process.argv[1]).version)' "$pkgdir/package.json" 2>/dev/null || echo unreadable)
  local extras=1
  if [ -d "$pkgdir" ]; then
    local plist=$DSH_HOME/port-backup/.purge-pay.list ilist=$DSH_HOME/port-backup/.purge-inst.list
    ( cd "$payload/node_modules/$PKG" && find . -type f | LC_ALL=C sort ) > "$plist" 2>/dev/null
    ( cd "$pkgdir" && find . -type f | LC_ALL=C sort ) > "$ilist" 2>/dev/null
    extras=$(comm -23 "$ilist" "$plist" 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$extras" ] || extras=1
  fi

  if [ "$force" = 0 ] && [ -f "$STATE" ] && [ "$cur_ver" = "$version" ] && [ "$extras" = 0 ]; then
    say "文件已是 $version 且与发布物逐文件一致，跳过重铺（--force 可强制）"
  else
    say "铺设插件文件（干净落位：旧目录先移走再整份铺；清掉 $extras 个非发布物/残留文件）..."
    local stage=$PROFILE/node_modules/.purge-stage-$$ old=$PROFILE/node_modules/.purge-old-$$
    rm -rf "$stage" "$old"
    mkdir -p "$stage" || die "无法创建暂存目录 $stage"
    cp -R "$payload/node_modules/." "$stage/" || die "复制插件文件到暂存失败"
    [ -d "$pkgdir" ] && mv "$pkgdir" "$old"
    mv "$stage/$PKG" "$pkgdir" || { [ -d "$old" ] && mv "$old" "$pkgdir"; die "落位失败（已把旧目录移回）"; }
    rm -rf "$old" "$stage"
    if [ -d "$PROFILE/node_modules/yaml" ]; then
      say "  依赖 yaml 已在位（不动它：可能由 pnpm 或其它 kit 管理）"
    else
      cp -R "$payload/node_modules/yaml" "$PROFILE/node_modules/yaml" || die "复制 yaml 依赖失败"
      say "  依赖 yaml 已铺入"
    fi
    printf '%s\n' "$stamp" > "$STATE"
    say "文件落位完成：$version"
  fi

  say "== Android 执行器补丁（spawn 不能用 process.execPath）=="
  # 本机 process.execPath = /apex/com.android.runtime/bin/linker64（termux-exec 的 LD_PRELOAD
  # 把 exec 重路由到 linker），插件内部凡 spawn/execFile(process.execPath, …) 的路径——
  # 面板「重启」「回滚」、「红队演练台」、community.js 的 LEGACY 转发——都会变成
  # `linker64 <js>` → "expected absolute path" / "bad ELF magic"。帧内修不了上游源码，
  # 所以在**载荷落盘后**按固定锚点打一层可重入补丁（见 tools/patch-android-exec.mjs）。
  if [ -f "$SELF/tools/patch-android-exec.mjs" ]; then
    "$NODE" "$SELF/tools/patch-android-exec.mjs" "$PROFILE/node_modules/$PKG" --node "$NODE" || \
      die "Android 执行器补丁未打上（插件内部 spawn 会崩）"
  else
    say "  - 缺 tools/patch-android-exec.mjs，跳过"
  fi

  "$NODE" -e '
    const fs=require("node:fs");
    const [file,name,version]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    j.dependencies=j.dependencies||{};
    const spec=j.dependencies[name];
    let dropped=null;
    if(typeof spec==="string" && !/^(file:|link:|git\+?|https?:|\/|\.)/.test(spec)){ dropped=spec; delete j.dependencies[name]; }
    j.dsh=j.dsh||{}; j.dsh.profile=j.dsh.profile||{};
    const b=Array.isArray(j.dsh.profile.bundles)?j.dsh.profile.bundles:[];
    if(!b.includes(name)) b.push(name);
    j.dsh.profile.bundles=b;
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
    console.log("装配已登记：dsh.profile.bundles 含 "+name+"（共 "+b.length+" 项）");
    if(dropped) console.log("已去毒：移除 dependencies."+name+"=\""+dropped+"\"（registry 上 404，会让 pnpm 整次安装失败）");
    else console.log("dependencies 里不放 "+name+"（registry 上没有它；装配只靠 bundles + node_modules 目录）");
  ' "$PROFILE/package.json" "$PKG" "$version" || die "写 profile/package.json 失败"

  say "== permission 预设固定 =="
  ensure_pin

  say ""
  say "下一步：bash \"$SELF/port.sh\" verify ；再到设置面板里点「应用」或跑 bash \"$SELF/port.sh\" apply 打宿主补丁。"
}

cmd_apply() {
  need_runtime
  local host; host=$(host_base) || die "未定位宿主 @deepseek-ai 目录"
  say "宿主：$host"
  # 坑（2026-11-10 本机实锤）：不能走 community.js 的 LEGACY 转发。
  # 它的实现是 spawnSync(process.execPath, [bin/dsh-purge.js, "--apply", …])，
  # 而本机 process.execPath = /apex/com.android.runtime/bin/linker64
  # （termux-exec 的 LD_PRELOAD 把 exec 重路由到 linker，Node 就把 execPath 报成 linker 路径）
  # → 实际执行变成 `linker64 dsh-purge.js` → linker 拿 JS 当 ELF 加载
  # → error: "…/dsh-purge.js" has bad ELF magic: 23212f75（正是 shebang 字节 23 21 2f 75）。
  # 同款坑的既有记录：fork docs/AGENTS/gotchas.md（apk #83/#89/#96，marketplace B 修法）。
  # 因此这里直接调目标脚本本身，绕开转发这一层。
  #
  # 另一个坑（2026-11-10 本机实锤）：**不能用它的退出码判成败**。
  # 已清洗过的宿主上重跑 apply 会退出 1 并打印「应用未完成」，原因是幂等重跑时
  # #43 WEB_PRESET_IDENTITY_STRIP 的第二条替换锚点已不存在 → 报 pattern_not_found，
  # 而该补丁带 strictFiles: true → isPatchResultSoftOk 判硬失败（verify.mjs:110-118）。
  # 实测此时实际状态完全干净：四个内置预设身份句全部已剥离、patchStatus 全部 applied、
  # selfcheck 报 state=ok applied=71/72 pending=0 missing_file=0。
  # 所以下面只把 apply 的输出当信息，**成败以 selfcheck 为准**。
  DSH_BASE="$host" DSH_HOME="$DSH_HOME" HOME="$HOME_DIR" PATH="$FILES/usr/bin:$PATH" \
    "$NODE" "$PROFILE/node_modules/$PKG/bin/dsh-purge.js" --apply || \
    say "（apply 自评非 0，按上面的坑可能只是幂等重跑；下面用 selfcheck 判真实状态）"
  local sc
  sc=$(DSH_BASE="$host" DSH_HOME="$DSH_HOME" HOME="$HOME_DIR" PATH="$FILES/usr/bin:$PATH" \
       "$NODE" "$PROFILE/node_modules/$PKG/bin/community.js" selfcheck --json 2>/dev/null |
       "$NODE" -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{let j={};try{j=JSON.parse(d)}catch(e){}
         const p=j.patch||{},s=(j.summary&&j.summary.pending)||{};
         process.stdout.write([j.state||"?",String(j.ok===true),(p.applied!=null?p.applied:"?"),String(p.total!=null?p.total:"?"),(s.patches!=null?s.patches:"?")].join(" "));});')
  set -- $sc
  local st="${1:-?}" okf="${2:-false}" ap="${3:-?}" tt="${4:-?}" pd="${5:-?}"
  say "selfcheck: state=$st ok=$okf applied=$ap/$tt pending=$pd"
  if [ "$st" != "ok" ] || [ "$okf" != "true" ] || { [ -n "$pd" ] && [ "$pd" != "0" ]; }; then
    die "apply 后自检仍不干净（state=$st ok=$okf pending=$pd）"
  fi
  say "== permission 预设固定 =="
  ensure_pin
  say ""
  say "补丁已写入磁盘，自检通过；重启 dsh（或点面板「应用」后的提示）后完全生效。"
}

cmd_revert() {
  need_runtime
  local host; host=$(host_base) || die "未定位宿主 @deepseek-ai 目录"
  # 同上：绕开 community.js 的 LEGACY 转发（execPath=linker64 会把 JS 交给 linker 加载）。
  # 退出码同样不作判据，交给 verify/status 看实际状态。
  DSH_BASE="$host" DSH_HOME="$DSH_HOME" HOME="$HOME_DIR" PATH="$FILES/usr/bin:$PATH" \
    "$NODE" "$PROFILE/node_modules/$PKG/bin/dsh-purge.js" --revert || \
    say "（revert 自评非 0；用 bash port.sh verify 看实际状态）"
}

# 运行中引擎的插件清单：cookie 来自 shell 的 shared_prefs，端口来自 .engine-endpoint.json
live_rows() {
  local pref=/data/data/com.dsharnessmobile.shell/shared_prefs/dsh_engine_auth.xml
  [ -f "$pref" ] || return 1
  local cookie; cookie=$(jq_node 'const s=require("node:fs").readFileSync(process.argv[1],"utf8");const m=s.match(/name="cookie">([^<]+)</);if(!m)process.exit(1);console.log(m[1])' "$pref" 2>/dev/null) || return 1
  local port; port=$(jq_node 'try{console.log(require(process.argv[1]).port)}catch(e){}' "$FILES/.engine-endpoint.json" 2>/dev/null)
  [ -n "$port" ] || port=4145
  "$NODE" -e '
    const http=require("node:http");
    const [port,cookie]=process.argv.slice(1);
    const payload=JSON.stringify({type:"client-request",rpcId:"purge-port-verify",method:"pluginManager/listPlugins",payload:{args:{}}});
    const req=http.request({host:"127.0.0.1",port:Number(port),path:"/api/pluginManager/listPlugins",method:"POST",
      headers:{"content-type":"application/json",cookie,"content-length":Buffer.byteLength(payload)}},res=>{
      let d="";res.on("data",c=>d+=c);res.on("end",()=>process.stdout.write(d));});
    req.on("error",e=>{console.error(e.message);process.exit(1)});
    req.end(payload);
  ' "$port" "$cookie"
}

cmd_verify() {
  need_runtime
  mkdir -p "$DSH_HOME/port-backup"
  local fail=0
  say "== 1. 文件 =="
  if [ -f "$PROFILE/node_modules/$PKG/package.json" ]; then
    say "  PASS  $PKG $(jq_node 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json")"
  else say "  FAIL  缺少 $PROFILE/node_modules/$PKG"; fail=1; fi
  [ -d "$PROFILE/node_modules/yaml" ] && say "  PASS  依赖 yaml（自带载荷）" || { \
    [ -d "$DSH_HOME/profiles/node_modules/yaml" ] && say "  PASS  依赖 yaml（profile 共享层）" || { say "  FAIL  缺 yaml"; fail=1; }; }

  say "== 2. 装配（package.json）=="
  # 判据三条（2026-11-11 起）：① dsh.profile.bundles 已选；② dependencies 里没有
  # registry 形状的地雷键（有 → 下一次 pnpm 安装必 404，实测证据见文件头）；
  # ③ node_modules 里是实体（不是空壳）。dependencies 缺席是**设计如此**，不判 FAIL。
  if jq_node '
    const j=require(process.argv[1]);const n=process.argv[2];
    const b=((j.dsh||{}).profile||{}).bundles||[];
    const dep=(j.dependencies||{})[n];
    const poisoned=typeof dep==="string" && !/^(file:|link:|git\+?|https?:|\/|\.)/.test(dep);
    if(!b.includes(n)||poisoned)process.exit(1);
  ' "$PROFILE/package.json" "$PKG" 2>/dev/null; then say "  PASS  dsh.profile.bundles 已登记；dependencies 无 registry 地雷键"
  else
    local poison; poison=$(jq_node '
      const j=require(process.argv[1]);const n=process.argv[2];
      const b=((j.dsh||{}).profile||{}).bundles||[];
      const dep=(j.dependencies||{})[n];
      const poisoned=typeof dep==="string" && !/^(file:|link:|git\+?|https?:|\/|\.)/.test(dep);
      if(poisoned)console.log(String(dep)); else if(!b.includes(n))console.log("(bundles 未登记)");
    ' "$PROFILE/package.json" "$PKG" 2>/dev/null)
    case "$poison" in
      "(bundles 未登记)") say "  FAIL  dsh.profile.bundles 里没有 $PKG（重跑 install）" ;;
      ?*)                 say "  FAIL  dependencies.$PKG=$poison 是 registry 形状 → 任何 pnpm 安装都会 404（跑 install 去毒）" ;;
      *)                  say "  FAIL  装配判据不通过（重跑 install）" ;;
    esac
    fail=1
  fi

  say "== 3. 模块可加载 =="
  if ( cd "$PROFILE" && "$NODE" --input-type=module -e "await import('$PKG')" 2>"$DSH_HOME/port-backup/.purge-import.err" ); then
    say "  PASS  import('$PKG') 成功"
  else say "  FAIL  模块导入失败："; sed 's/^/        /' "$DSH_HOME/port-backup/.purge-import.err" | head -8; fail=1; fi
  if [ -f "$SELF/tools/patch-android-exec.mjs" ]; then
    if "$NODE" "$SELF/tools/patch-android-exec.mjs" "$PROFILE/node_modules/$PKG" --node "$NODE" --check >/dev/null 2>&1; then
      say "  PASS  Android 执行器补丁在位（4 个文件 6 处 spawn 已改写）"
    else
      say "  FAIL  Android 执行器补丁缺失/漂移 → 面板「重启/回滚」与演练台会崩（跑 install 重打）"; fail=1
    fi
  fi

  say "== 4. permission 预设固定 =="
  if grep -qF "$PIN_MARK" "$PROFILE/cordis.patch.yml" 2>/dev/null; then
    say "  PASS  已固定 defaultPreset=danger-full-access"
  else say "  FAIL  未固定：打补丁后 dsh-permission-presets 会拒绝激活（跑 pin）"; fail=1; fi

  say "== 5. 引擎内 fiber =="
  local body
  if body=$(live_rows 2>/dev/null) && printf '%s' "$body" | "$NODE" -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let j;try{j=JSON.parse(d)}catch(e){console.log("  FAIL  引擎应答非 JSON："+d.slice(0,160));process.exit(1);}
      const rows=j&&j.result&&j.result.value;
      if(!Array.isArray(rows)){console.log("  FAIL  拒绝列出插件："+JSON.stringify((j&&j.result&&j.result.error)||j).slice(0,200));process.exit(1);}
      const ids=["include:dsh-purge","include:dsh-purge-redteam","include:dsh-purge-presets","include:dsh-purge-redteam-store","include:dsh-purge-redteam-ui"];
      let bad=0;
      for(const id of ids){const r=rows.find(x=>x.entryId===id);
        if(!r){console.log("  FAIL  缺少 "+id);bad++;continue;}
        const ok=r.enabled&&r.fiberPhase==="active";
        if(!ok)bad++;
        console.log("  "+(ok?"PASS":"FAIL")+"  "+r.entryId+" enabled="+r.enabled+" fiber="+r.fiberPhase);}
      const perm=rows.find(x=>(x.moduleName||"")==="@deepseek-ai/dsh-permission-presets");
      if(perm){const ok=perm.enabled&&perm.fiberPhase==="active";if(!ok)bad++;console.log("  "+(ok?"PASS":"FAIL")+"  permission enabled="+perm.enabled+" fiber="+perm.fiberPhase);}
      else{console.log("  WARN  引擎清单里没有 permission 行");}
      const act=(rows||[]).length;console.log("  info  插件行合计 "+act);
      process.exit(bad?1:0);
    });
  '; then :; else say "  FAIL  引擎里没有全部活跃的 dsh-purge 行（重启应用后再试）"; fail=1; fi

  say "== 6. 宿主补丁 =="
  local host; host=$(host_base) || { say "  FAIL  未定位宿主"; fail=1; }
  if [ -n "${host:-}" ]; then
    local sc
    if sc=$(DSH_BASE="$host" DSH_HOME="$DSH_HOME" HOME="$HOME_DIR" PATH="$FILES/usr/bin:$PATH" \
        "$NODE" "$PROFILE/node_modules/$PKG/bin/community.js" selfcheck --json 2>/dev/null); then
      printf '%s' "$sc" | "$NODE" -e '
        let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
          let j;try{j=JSON.parse(d)}catch(e){console.log("  WARN  selfcheck 输出无法解析");process.exit(0);}
          const p=j.patch||{};
          console.log("  info  补丁 applied="+p.applied+"/"+p.total+"（na="+p.na+" skipped="+p.skipped+"）");
          const c=(j.layers||[]).find(l=>l.kind==="config")||{};
          console.log("  info  权限层 state="+(c.state||"?")+" sandbox="+(c.detail&&c.detail.sandbox||"?")+" approval="+(c.detail&&c.detail.approval||"?"));
          if(p.applied===0)console.log("  WARN  宿主补丁尚未应用：跑 bash port.sh apply");
        });
      '
    else say "  WARN  selfcheck 未跑通（插件文件/宿主可能不全）"; fi
  fi

  say ""
  if [ "$fail" = 0 ]; then say "结论：移植在位且运行态正常。"; else say "结论：有检查项失败，先跑 install / pin 修复，再复查。"; fi
  return "$fail"
}

cmd_uninstall() {
  local purge=0
  for a in "$@"; do [ "$a" = "--purge" ] && purge=1; done
  need_runtime
  local backup=$DSH_HOME/port-backup/purge-uninstall-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  cp "$PROFILE/package.json" "$backup/package.json" 2>/dev/null || true
  cp "$PROFILE/cordis.patch.yml" "$backup/cordis.patch.yml" 2>/dev/null || true
  "$NODE" -e '
    const fs=require("node:fs");
    const [file,name]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    if(j.dependencies)delete j.dependencies[name];
    const b=((j.dsh||{}).profile||{}).bundles;
    if(Array.isArray(b))j.dsh.profile.bundles=b.filter(x=>x!==name);
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
  ' "$PROFILE/package.json" "$PKG" || die "改 package.json 失败"
  rm -rf "$PROFILE/node_modules/$PKG"
  rm -f "$STATE"
  [ "$purge" = 1 ] && rm -rf "$DSH_HOME/dsh-purge" "$DSH_HOME/dsh-purge-community" "$DSH_HOME/redteam"
  say "已卸载装配与文件（备份 $backup）；宿主补丁仍在磁盘上——要还原请先跑 revert。"
  [ "$purge" = 1 ] && say "插件状态目录已按 --purge 删除（prompt-inject.md 保留）。"
}

cmd_sync() {
  local check=0
  for a in "$@"; do [ "$a" = "--check" ] && check=1; done
  local api=https://api.github.com/repos/kingcharleslzy-ai/dsh-purge/releases/latest
  local json; json=$(curl -sSL --max-time 60 "$api") || die "拉取上游 release 失败"
  local tag url sha
  tag=$(printf '%s' "$json" | "$NODE" -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);console.log(j.tag_name||"")})')
  url=$(printf '%s' "$json" | "$NODE" -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);const a=(j.assets||[]).find(x=>/dsh-purge-community-.*\.tgz$/.test(x.name));console.log(a?a.browser_download_url:"")})')
  sha=$(printf '%s' "$json" | "$NODE" -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);const a=(j.assets||[]).find(x=>/dsh-purge-community-.*\.tgz$/.test(x.name));const dg=(a&&(a.digest||""))||"";console.log(dg.startsWith("sha256:")?dg.slice(7):"")})')
  [ -n "$tag" ] || die "上游没有 release（或超出限流）"
  say "上游最新：$tag"
  say "kit 当前：$(kit_version)"
  # 上游这次改了什么 —— 同步前先看清（这也是判断「补丁表是否变了」的第一手材料）。
  printf '%s' "$json" | "$NODE" -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let j={};try{j=JSON.parse(d)}catch(e){}
      const body=(j.body||"").split("\n").map(s=>s.trimEnd()).filter(Boolean).slice(0,14);
      if(body.length){console.log("上游说明（节选）：");for(const l of body)console.log("  "+l);}
    });'
  if [ "$tag" = "v$(kit_version)" ]; then say "已是最新，无需同步。"; return 0; fi
  [ "$check" = 1 ] && { say "（--check：只查不下载）"; return 0; }
  [ -n "$url" ] || die "该 release 没有 dsh-purge-community tgz 资产"
  local tmp=$SELF/.sync; rm -rf "$tmp"; mkdir -p "$tmp"
  say "下载 $url"
  # 下载回落链（2026-11-11 实测）：直连 github.com 会超时（一次 134 s 后连接失败），
  # 前缀式镜像 https://gh-proxy.com/ 正常（1.2 s / 200）。npm registry 类 URL 不走镜像。
  # 覆盖：DSH_PAYLOAD_MIRRORS="https://gh-proxy.com/ https://ghproxy.net/"
  local mirrors=${DSH_PAYLOAD_MIRRORS:-"https://gh-proxy.com/ https://ghproxy.net/"}
  local cands=("$url") m got_from=""
  case "$url" in
    https://github.com/*|https://objects.githubusercontent.com/*)
      for m in $mirrors; do cands+=("$m$url"); done ;;
  esac
  for m in "${cands[@]}"; do
    say "  试 $m"
    if curl -sSL --max-time 300 --connect-timeout 15 -o "$tmp/plugin.tgz" "$m" && [ -s "$tmp/plugin.tgz" ]; then
      got_from=$m; break
    fi
    rm -f "$tmp/plugin.tgz"
  done
  [ -n "$got_from" ] || die "下载失败（直连与镜像都取不到 $url）"
  say "  来源：$got_from（$(wc -c <"$tmp/plugin.tgz") 字节）"
  if [ -n "$sha" ]; then
    local got; got=$(sha256sum "$tmp/plugin.tgz" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || die "SHA-256 校验失败（期望 $sha，实得 $got）"
    say "SHA-256 校验通过"
  fi
  # 全新 / 无载荷状态下 payload/node_modules 还不存在，而 mv **不会**自动建中间目录：
  # 2026-11-13 实测，这一行让「自动升版」在干净状态必然失败
  # （mv: cannot move ... to .../payload/node_modules/dsh-purge-community: No such file or directory）。
  mkdir -p "$SELF/payload/node_modules"
  rm -rf "$SELF/payload/node_modules/$PKG"
  tar xzf "$tmp/plugin.tgz" -C "$tmp" || die "解包失败"
  mv "$tmp/package" "$SELF/payload/node_modules/$PKG" || die "无法替换载荷目录"
  # Android 执行器补丁要在**打包之前**落在载荷上，否则 install 之后每台机都得再打一次；
  # 这里先打一遍（幂等），install 时还会再核一次。
  if [ -f "$SELF/tools/patch-android-exec.mjs" ]; then
    "$NODE" "$SELF/tools/patch-android-exec.mjs" "$SELF/payload/node_modules/$PKG" --node "$NODE" || \
      die "Android 执行器补丁未打上（载荷里的 spawn 锚点变了？看 tools/patch-android-exec.mjs 的锚点表）"
  fi
  # 补齐 bundledDependencies（与 fetch-payload.sh 同口径）。sync 只解了插件本体，
  # 载荷里若少了依赖，重打包出的 payload.tar.gz 与「fetch-payload.sh --pack」不一致，
  # 换机时 install 会因为缺 yaml 装不起来。此刻插件目录已在场，fetch-payload.sh 会
  # 跳过它、只补缺的那些依赖；依赖已存在则直接 skip（幂等）。
  if [ -f "$SELF/fetch-payload.sh" ]; then
    bash "$SELF/fetch-payload.sh" >&2 || say "  ! 依赖补齐失败（网络？）：载荷可能缺 bundledDependencies，换机前请重跑"
  fi
  "$NODE" "$SELF/tools/pack-payload.mjs" > "$tmp/pack.json" || die "重打包失败"
  cat "$tmp/pack.json"
  local newsver; newsver=$(jq_node 'console.log(require(process.argv[1]).version)' "$SELF/payload/node_modules/$PKG/package.json")
  "$NODE" -e '
    const fs=require("node:fs");const [mp,ver,pack]=process.argv.slice(1);
    const m=JSON.parse(fs.readFileSync(mp,"utf8"));
    const p=JSON.parse(fs.readFileSync(pack,"utf8"));
    m.package.version=ver; m.package.source="https://github.com/kingcharleslzy-ai/dsh-purge/releases/download/v"+ver+"/dsh-purge-community-"+ver+".tgz";
    m.payload.sha256=p.sha256; m.payload.bytes=p.bytes; m.payload.entries=p.entries;
    m.verifiedAt=new Date().toISOString();
    fs.writeFileSync(mp,JSON.stringify(m,null,2)+"\n");
  ' "$MANIFEST" "$newsver" "$tmp/pack.json"
  rm -rf "$SELF/.unpacked"
  say "载荷已更新到 $newsver；现在重装："
  cmd_install --force
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  revert) shift; cmd_revert "$@" ;;
  pin) shift; cmd_pin "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  status) shift; cmd_status "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
