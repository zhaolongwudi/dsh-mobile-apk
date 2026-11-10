#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# MemoryBear 长期记忆插件在 dsh-mobile-apk 上的移植维护脚本。
#
# 设计前提（与 port/jet-hub、port/dsh-purge 完全同构）：本插件**不进入 APK，也不进入仓库**。
# 它只活在 app 私有数据里：
#   $DSH_FILES_DIR/home/.dsh/profiles/web/node_modules/@redbearai/...   插件与 core
#   $DSH_FILES_DIR/home/.dsh/profiles/web/package.json                  依赖键 + dsh.profile.bundles 选择
#   $DSH_FILES_DIR/home/.dsh/profiles/web/cordis.patch.yml              可选的 config 覆盖层（连接参数）
# 这些路径在 APK 覆盖安装 + 快照刷新时被「合并保留」，因此每日新构建物不会把它覆盖掉，
# 也不需要改工具的任何提交。
#
# 装配走 dsh.profile.bundles（包自带 cordis.patch.yml 完成 insert，entryId=memorybear-memory），
# 与 dsh-providers-hub（entryId codearts-auth）、dsh-purge-community（entryId dsh-purge）一致。
#
# 两个变体互斥（上游 README：Install one of them, not both —— 各自注册 memory_search 工具）：
#   memorybear（默认，MemoryBear V1 API） / memoryskills（MemorySkills Portal）
#
# 用法：
#   bash port.sh install [--variant memorybear|memoryskills] [--force] [--shared-deps]
#   bash port.sh verify [--live|--engine]
#                       体检：文件/装配/模块契约/合成树/与另两插件无冲突
#                       --live 只读实查线上引擎装配表；--engine 另起隔离引擎实测挂载
#   bash port.sh status               只打印当前落点与版本，不改任何东西
#   bash port.sh switch <variant>     切换注册项（等价 install --variant <v> --force）
#   bash port.sh key                  两个变体的 key 是否已配置（只读，走引擎 RPC）
#   bash port.sh setkey [--ref REF]   把 key 存进 dsh 凭据库（默认从标准输入读，不进 shell 历史）
#   bash port.sh unsetkey [--ref REF] 从凭据库移除该 key
#   bash port.sh setconn <baseURL> [<endUserId>]
#                                     把连接字段写进 profile patch 的本插件条目（memorybear 变体需要）
#   bash port.sh uninstall [--purge]  卸载（默认保留共享依赖与凭据；--purge 连状态/隔离 home 一起删）
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -d "$FILES/home" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
HOME_DIR=$FILES/home
DSH_HOME=$HOME_DIR/.dsh
PROFILE=$DSH_HOME/profiles/web
STATE=$DSH_HOME/memory-bear-port-state.json
NODE=${NODE:-$FILES/usr/bin/node}
ENGINE=${ENGINE:-$FILES/usr/lib/node_modules/@deepseek-ai/dsh}
MANIFEST=$SELF/manifest.json
CORE_PKG=@redbearai/dsh-memory-core
REDBEAR_PKGS="@redbearai/dsh-memorybear @redbearai/dsh-memoryskills $CORE_PKG"
SHARED_PKGS="@deepseek-ai/schemastery @deepseek-ai/cosmokit @standard-schema/spec"
DEFAULT_VARIANT=memorybear

die() { printf 'port: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

need_runtime() {
  [ -x "$NODE" ] || die "找不到运行时 node：$NODE（可用 NODE=... 覆盖）"
  [ -d "$PROFILE" ] || die "找不到 web profile：$PROFILE（应用是否已首次启动？）"
  [ -f "$MANIFEST" ] || die "缺少 manifest.json：$MANIFEST"
}

kit_version() { "$NODE" -e 'console.log(require(process.argv[1]).package.version)' "$MANIFEST" 2>/dev/null || echo unknown; }

# 变体名 ←→ 包名（读 manifest.variants，避免在脚本里写死映射）
variant_pkg() { # $1=变体名 → name@version
  "$NODE" -e '
    const m=require(process.argv[1]); const v=m.variants[process.argv[2]];
    if(!v||!v.name){console.error("未知变体："+process.argv[2]);process.exit(1)}
    process.stdout.write(v.name+"@"+v.version);
  ' "$MANIFEST" "$1"
}
variant_of_pkg() { # $1=包名 → 变体名
  "$NODE" -e '
    const m=require(process.argv[1]);
    for(const [k,v] of Object.entries(m.variants)) if(v&&v.name===process.argv[2]){process.stdout.write(k);break}
  ' "$MANIFEST" "$1"
}
all_variant_pkgs() { "$NODE" -e '
  const m=require(process.argv[1]);
  const out=[]; for(const [k,v] of Object.entries(m.variants)) if(v&&v.name) out.push(v.name);
  process.stdout.write(out.join(" "));
' "$MANIFEST"; }
# 当前已登记在 dsh.profile.bundles 里的变体包名（没登记则为空）
current_pkg() {
  "$NODE" -e '
    const fs=require("node:fs");
    let j;try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){process.exit(0)}
    const b=(((j.dsh||{}).profile||{}).bundles)||[];
    const names=process.argv.slice(2);
    for(const n of names) if(b.includes(n)){process.stdout.write(n);break}
  ' "$PROFILE/package.json" $(all_variant_pkgs)
}

ensure_payload() {
  local payload=$SELF/payload
  if [ -d "$payload/node_modules/@redbearai" ]; then echo "$payload"; return 0; fi
  local archive=$SELF/payload.tar.gz
  if [ ! -f "$archive" ]; then
    [ -f "$SELF/fetch-payload.sh" ] || die "缺少离线载荷：$SELF/payload.tar.gz（也没有 fetch-payload.sh）"
    say "本地无载荷，按 manifest.json 从 npm 重新获取（约 0.2 MB，秒级）..." >&2
    bash "$SELF/fetch-payload.sh" >&2 || die "获取载荷失败（无网络时改用带 payload.tar.gz 的分支副本）"
    if [ -d "$SELF/payload/node_modules/@redbearai" ]; then echo "$SELF/payload"; return 0; fi
    archive=$SELF/payload.tar.gz
    [ -f "$archive" ] || die "获取载荷失败：$SELF/payload 与 payload.tar.gz 都不存在"
  fi
  local cache=$SELF/.unpacked
  if [ ! -d "$cache/node_modules/@redbearai" ]; then
    rm -rf "$cache"; mkdir -p "$cache" || die "无法创建 $cache"
    "$NODE" -e '
      const fs=require("node:fs"),zlib=require("node:zlib"),path=require("node:path");
      const [src,dst]=process.argv.slice(1);
      const tar=zlib.gunzipSync(fs.readFileSync(src));
      // 最小 tar 解析器：只处理 ustar 常规文件/目录（载荷由本 kit 自己生成，无长名/无链接）
      let off=0;
      while(off+512<=tar.length){
        const head=tar.subarray(off,off+512);
        if(head.every(b=>b===0))break;
        const name=head.subarray(0,100).toString("utf8").replace(/\0.*$/s,"");
        const prefix=head.subarray(345,500).toString("utf8").replace(/\0.*$/s,"");
        const size=parseInt(head.subarray(124,136).toString("ascii").replace(/\0.*$/s,"").trim()||"0",8);
        const type=String.fromCharCode(head[156]||48);
        const mode=parseInt(head.subarray(100,108).toString("ascii").replace(/\0.*$/s,"").trim()||"644",8);
        let full=prefix?prefix+"/"+name:name;
        if(full.startsWith("payload/"))full=full.slice(8);
        const data=tar.subarray(off+512,off+512+size);
        off+=512+Math.ceil(size/512)*512;
        if(!full||full===".")continue;
        const target=path.join(dst,full);
        if(!target.startsWith(dst+path.sep)&&target!==dst)throw new Error("unsafe path "+full);
        if(type==="5"){fs.mkdirSync(target,{recursive:true});}
        else if(type==="0"||type==="\0"||type===""){
          fs.mkdirSync(path.dirname(target),{recursive:true});
          fs.writeFileSync(target,data,{mode:mode&0o777});
        }
      }
    ' "$archive" "$cache" || die "解包离线载荷失败"
  fi
  echo "$cache"
}

# 目录内容指纹（相对路径+内容），用于「不覆盖别家依赖」的判据
tree_digest() {
  "$NODE" -e '
    const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto");
    const dir=process.argv[1];
    if(!fs.existsSync(dir)){process.stdout.write("MISSING");process.exit(0)}
    const h=crypto.createHash("sha256");
    const walk=(d,base)=>{for(const e of fs.readdirSync(d,{withFileTypes:true}).sort((a,b)=>a.name<b.name?-1:1)){
      const p=path.join(d,e.name),rel=base?base+"/"+e.name:e.name;
      if(e.isDirectory())walk(p,rel); else h.update(rel).update("\0").update(fs.readFileSync(p)).update("\0");}};
    walk(dir,"");process.stdout.write(h.digest("hex"));
  ' "$1" 2>/dev/null
}

backup_profile() {
  mkdir -p "$DSH_HOME/port-backup"
  local backup=$DSH_HOME/port-backup/profile-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  cp "$PROFILE/package.json" "$backup/package.json" 2>/dev/null || true
  cp "$PROFILE/cordis.patch.yml" "$backup/cordis.patch.yml" 2>/dev/null || true
  ls -1dt "$DSH_HOME/port-backup"/profile-* 2>/dev/null | tail -n +6 | while read -r old; do rm -rf "$old"; done
  echo "$backup"
}

# 共享依赖：缺失才补；已存在则比对内容，一致跳过、不一致**绝不覆盖**
place_shared() {
  local payload=$1; local placed=0 skipped=0 replaced=0
  for p in $SHARED_PKGS; do
    local src=$payload/node_modules/$p
    local dst=$PROFILE/node_modules/$p
    [ -d "$src" ] || continue
    if [ ! -d "$dst" ]; then
      mkdir -p "$(dirname "$dst")"; cp -R "$src" "$dst" && placed=$((placed+1))
      say "  补装共享依赖 $p（本机原先缺失）"
    else
      local a b; a=$(tree_digest "$src"); b=$(tree_digest "$dst")
      if [ "$a" = "$b" ]; then skipped=$((skipped+1))
      else
        # 本机已有别的版本/改动 —— 保留本机副本，仅告警（插件按语义只要同族 API）
        replaced=$((replaced+1))
        say "  注意 $p 本机副本与载荷不同（保留本机副本，未覆盖）"
      fi
    fi
  done
  say "  共享依赖：新装 $placed / 已在位且一致 $skipped / 版本不同未动 $replaced"
}

cmd_status() {
  need_runtime 2>/dev/null || true
  local cp; cp=$(current_pkg)
  local v=""; [ -n "$cp" ] && v=$(variant_of_pkg "$cp")
  say "kit          : $(kit_version)"
  say "profile      : $PROFILE"
  say "变体（注册中）: ${v:-（未注册）}${cp:+  →  $cp}"
  for p in $(all_variant_pkgs) $CORE_PKG; do
    if [ -f "$PROFILE/node_modules/$p/package.json" ]; then
      say "  $(printf '%-32s' "$p") $("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$p/package.json" 2>/dev/null || echo unreadable)"
    else
      say "  $(printf '%-32s' "$p") (未落位)"
    fi
  done
  if [ -f "$STATE" ]; then say "stamp        : $(cat "$STATE")"; else say "stamp        : (无)"; fi
  "$NODE" -e '
    const fs=require("node:fs");
    const p=process.argv[1];
    const all=process.argv.slice(2);
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    const deps=j.dependencies||{}; const b=((j.dsh||{}).profile||{}).bundles||[];
    for(const n of all) console.log("  deps["+n+"] = "+(deps[n]||"(缺少)")+"    bundles: "+(b.includes(n)?"已登记":"未登记"));
    console.log("bundles 共 "+b.length+" 项："+b.join(", "));
  ' "$PROFILE/package.json" $(all_variant_pkgs) 2>/dev/null || say "package.json : 无法解析"
  say "共享依赖      : $SHARED_PKGS"
}

cmd_install() {
  local variant=$DEFAULT_VARIANT force=0 shared=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --variant) shift; variant=${1:-} ;;
      --force) force=1 ;;
      --shared-deps) shared=1 ;;
      *) die "未知参数：$1" ;;
    esac
    shift
  done
  need_runtime
  local target; target=$(variant_pkg "$variant") || die "变体无效：$variant"
  local tpkg=${target%@*} tver=${target#*@}
  local others=""; for p in $(all_variant_pkgs); do [ "$p" != "$tpkg" ] && others="$others $p"; done

  local payload; payload=$(ensure_payload)
  local version; version=$("$NODE" -e 'console.log(require(process.argv[1]).version)' "$payload/node_modules/$tpkg/package.json" 2>/dev/null) \
    || die "载荷里没有 $tpkg（重新跑 fetch-payload.sh）"

  local backup; backup=$(backup_profile)
  say "profile 清单已备份：$backup"

  if [ "$force" = 0 ] && [ -f "$STATE" ] && grep -q "\"variant\":\"$variant\"" "$STATE" 2>/dev/null && [ -d "$PROFILE/node_modules/$tpkg" ]; then
    say "文件已是 $tpkg@$version，跳过重铺（--force 可强制）"
  else
    say "铺设插件文件到 profile/node_modules ..."
    mkdir -p "$PROFILE/node_modules/@redbearai"
    for p in $REDBEAR_PKGS; do
      [ -d "$payload/node_modules/$p" ] || die "载荷缺少 $p"
      rm -rf "$PROFILE/node_modules/$p"
      cp -R "$payload/node_modules/$p" "$PROFILE/node_modules/$p" || die "复制 $p 失败"
    done
    say "  @redbearai/* 三个包已落位（两变体都在位，切换零成本）"
  fi
  # 共享依赖默认也处理（缺则补，绝不覆盖），--shared-deps 仅作显式声明
  place_shared "$payload"
  : "$shared"

  "$NODE" -e '
    const fs=require("node:fs");
    const [file,name,version,...others]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    j.dependencies=j.dependencies||{};
    j.dependencies[name]=version;
    for(const o of others) delete j.dependencies[o];      // 变体互斥：另一个不进依赖表
    j.dsh=j.dsh||{}; j.dsh.profile=j.dsh.profile||{};
    let b=Array.isArray(j.dsh.profile.bundles)?j.dsh.profile.bundles:[];
    b=b.filter(x=>!others.includes(x));                    // 另一个也不进 bundles
    if(!b.includes(name)) b.push(name);
    j.dsh.profile.bundles=b;
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
    console.log("装配已登记：dependencies."+name+"="+version+"；dsh.profile.bundles 共 "+b.length+" 项");
    if(others.length) console.log("已从清单摘除（文件仍保留以便切换）："+others.join(", "));
  ' "$PROFILE/package.json" "$tpkg" "$version" $others || die "写 profile/package.json 失败"

  printf '{"package":"%s","variant":"%s","version":"%s","kit":"%s","installedAt":"%s"}\n' \
    "$tpkg" "$variant" "$version" "$(kit_version)" "$(date -Iseconds)" > "$STATE"

  say ""
  say "下一步："
  say "  1) 在应用里刷新页面（或重启应用）——插件面板出现在 设置 → Plugins；"
  say "  2) 在 Plugins 页填 baseURL 与 endUserId，API key 存凭据库（MEMORYBEAR_API_KEY）；"
  say "     两者都填上之前插件不连服务，零网络副作用。"
  say "  3) 跑体检：bash \"$SELF/port.sh\" verify        （加 --engine 可先起隔离引擎实测挂载）"
}

cmd_verify() {
  need_runtime
  local withEngine=0 withLive=0
  for a in "$@"; do
    [ "$a" = "--engine" ] && withEngine=1
    [ "$a" = "--live" ] && withLive=1
  done
  local fail=0 warn=0
  local tpkg; tpkg=$(current_pkg)
  [ -n "$tpkg" ] || tpkg=$("$NODE" -e 'const m=require(process.argv[1]);process.stdout.write(m.variants[m.variants.default||"memorybear"].name)' "$MANIFEST")
  local curvar; curvar=$(variant_of_pkg "$tpkg"); [ -n "$curvar" ] || curvar=$DEFAULT_VARIANT
  say "== 1. 文件 =="
  for p in $(all_variant_pkgs) $CORE_PKG; do
    if [ -f "$PROFILE/node_modules/$p/package.json" ]; then
      say "  PASS  $p $("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$p/package.json")"
    else
      say "  FAIL  缺少 $PROFILE/node_modules/$p"; fail=$((fail+1))
    fi
  done
  for p in $(all_variant_pkgs); do
    [ -f "$PROFILE/node_modules/$p/lib/index.js" ]  || { say "  FAIL  $p 缺 lib/index.js";  fail=$((fail+1)); }
    [ -f "$PROFILE/node_modules/$p/lib/client.js" ] || { say "  FAIL  $p 缺 lib/client.js"; fail=$((fail+1)); }
    [ -f "$PROFILE/node_modules/$p/cordis.patch.yml" ] || { say "  FAIL  $p 缺 cordis.patch.yml（bundle patch，装配靠它）"; fail=$((fail+1)); }
  done
  for p in $SHARED_PKGS; do
    [ -d "$PROFILE/node_modules/$p" ] && say "  PASS  共享依赖 $p 在位" || { say "  WARN  共享依赖 $p 不在位"; warn=$((warn+1)); }
  done

  say "== 2. 装配（package.json + patch 层）=="
  if "$NODE" -e '
    const j=require(process.argv[1]);const n=process.argv[2];
    const dep=(j.dependencies||{})[n];const b=((j.dsh||{}).profile||{}).bundles||[];
    if(!dep||!b.includes(n))process.exit(1);
  ' "$PROFILE/package.json" "$tpkg" 2>/dev/null; then
    say "  PASS  $tpkg 的依赖键与 dsh.profile.bundles 都在（变体：$curvar）"
  else
    say "  FAIL  $tpkg 缺依赖键或 bundles 选择（重跑 install）"; fail=$((fail+1))
  fi
  local nvar=0
  for p in $(all_variant_pkgs); do
    grep -q "\"$p\"" <("$NODE" -e 'const j=require(process.argv[1]);console.log(JSON.stringify(((j.dsh||{}).profile||{}).bundles||[]))' "$PROFILE/package.json") && nvar=$((nvar+1))
  done
  [ "$nvar" -le 1 ] && say "  PASS  bundles 里只登记了 $nvar 个变体（互斥约束成立）" || { say "  FAIL  bundles 里出现 $nvar 个变体 —— 会撞 memory_search 工具名"; fail=$((fail+1)); }

  say "== 3. 模块契约（模拟引擎解析，profile 根解析依赖）=="
  local mc
  mc=$( cd "$PROFILE" && "$NODE" --input-type=module -e '
    try{
      const m=await import(process.argv[1]);
      let cfg="none";
      if(m.Config){
        let n=null;
        try{ const dict=m.Config.dict||(m.Config.meta&&m.Config.meta.dict)||{}; n=Object.keys(dict).length }catch(e){}
        cfg=typeof m.Config+(n!==null?"("+n+"字段)":"");
      }
      console.log([m.name,typeof m.apply,(m.inject||[]).join(","),"Config="+cfg].join("|"));
    }catch(e){console.log("ERR|"+e.message.split("\n")[0])}
  ' "$tpkg" 2>&1 )
  case "$mc" in
    ERR\|*) say "  FAIL  模块加载失败：$mc"; fail=$((fail+1)) ;;
    *\|function\|*) say "  PASS  name/inject/apply/Config 就绪：$mc" ;;
    *) say "  FAIL  契约异常：$mc"; fail=$((fail+1)) ;;
  esac

  say "== 4. 合成树（prepareProfile('web')，引擎启动时用的就是这份）=="
  local entry=$("$NODE" -e 'const m=require(process.argv[1]);const v=m.variants[process.argv[2]]||m.variants[m.variants.default];process.stdout.write(v.entryId)' "$MANIFEST" "${curvar:-$DEFAULT_VARIANT}")
  local comp
  comp=$( cd "$PROFILE" && "$NODE" --expose-internals --input-type=module -e '
    const {prepareProfile}=await import(process.argv[1]);
    const entry=process.argv[2], pkg=process.argv[3];
    try{
      const s=JSON.stringify(await prepareProfile("web"));
      // 计数只认「带 name 的 insert 行」——profile patch 的 config 覆盖层同 id 但无 name，不算重复装配
      const n=(s.match(new RegExp("\"id\":\""+entry+"\",\"name\":\""+pkg+"\"","g"))||[]).length;
      const ov=(s.match(new RegExp("\"id\":\""+entry+"\",\"config\":","g"))||[]).length;
      const skip=(s.match(/"skippedBundles":\[[^\]]*\]/)||["?"])[0];
      const hasJet=/"id":"codearts-auth"/.test(s), hasPurge=/"id":"dsh-purge"/.test(s);
      console.log("OK n="+n+" override="+ov+" jet="+(hasJet?1:0)+" purge="+(hasPurge?1:0)+" "+skip);
    }catch(e){console.log("ERR "+e.message.split("\n")[0])}
  ' "$ENGINE/lib/profile-boot.js" "$entry" "$tpkg" 2>&1 )
  case "$comp" in
    OK*)
      if printf '%s' "$comp" | grep -q 'n=1' && printf '%s' "$comp" | grep -q 'jet=1' \
         && printf '%s' "$comp" | grep -q 'purge=1' && printf '%s' "$comp" | grep -q '"skippedBundles":\[\]'; then
        say "  PASS  $comp"
      else
        say "  WARN  合成树形态异常（期望 n=1 / jet=1 / purge=1 / 空 skipped）：$comp"; warn=$((warn+1))
      fi ;;
    *) say "  WARN  无法离线合成（$comp）——可忽略，直接看 --engine 运行态"; warn=$((warn+1)) ;;
  esac
  say "== 5. 与已移植插件共存（Jet Hub / 破甲）=="
  for n2 in dsh-providers-hub dsh-purge-community; do
    [ -d "$PROFILE/node_modules/$n2" ] && say "  PASS  $n2 目录在位" || { say "  FAIL  $n2 目录丢失（移植被破坏）"; fail=$((fail+1)); }
  done
  "$NODE" -e '
    const fs=require("node:fs");
    const p=process.argv[1], prof=process.argv[2];
    const want=process.argv.slice(3);
    // 1) 工具名交集：抓各插件 host 半边里注册的工具名（静态扫，粗但够用）
    const grab=(f,re)=>{try{return [...new Set([...fs.readFileSync(f,"utf8").matchAll(re)].map(m=>m[1]))]}catch(e){return []}};
    const mbTools=grab(prof+"/node_modules/"+want[0]+"/lib/index.js",/name:\s*"(memory_[a-z_]+)"/g);
    const others=[];
    for(const n of ["dsh-providers-hub","dsh-purge-community"]){
      const f=prof+"/node_modules/"+n+"/lib/index.js";
      const t=grab(f,/(?:registerTool|tools\.register|addTool)\(\s*["`]([a-zA-Z0-9_]+)["`]/g);
      const t2=grab(f,/\bname:\s*"(memory_[a-z_]+)"/g);
      others.push(...t,...t2);
    }
    const clash=mbTools.filter(t=>others.includes(t));
    console.log("  "+(clash.length?"FAIL":"PASS")+"  工具名：本插件 ["+mbTools.join(", ")+"]，另两者注册 ["+[...new Set(others)].join(", ")+"]"+(clash.length?" ← 冲突："+clash.join(", "):" ← 无交集"));
    // 2) 客户端 slot：本插件与另两者各自声明的 slot
    const slots=(f)=>[...new Set([...fs.readFileSync(f,"utf8").matchAll(/["`]((?:sidebar|conversation|plugins|shell|settings|main)[a-zA-Z.]*\.[a-zA-Z.]+)["`]/g)].map(m=>m[1]))];
    const mb=slots(prof+"/node_modules/"+want[0]+"/lib/client.js");
    const jet=slots(prof+"/node_modules/dsh-providers-hub/lib/client/jet-hub.js");
    const pg=slots(prof+"/node_modules/dsh-purge-community/client.js");
    const shared=[...new Set([...jet,...pg])].filter(s=>mb.includes(s));
    console.log("  本插件 slot："+mb.join(", "));
    // 已知「按插件 id 分片」的宿主 slot：多个插件同时挂载是设计允许的（宿主每个 id 各渲染一份），
    // 与「抢同一个坑位」的独占 slot（如 sidebar.right.pane.tab）性质不同。
    const SCOPED=["plugins.bundle.config","main","settings.section","conversation.chat.node","conversation.chat.turnTail"];
    const risky=shared.filter(s=>!SCOPED.includes(s));
    if(!shared.length){
      console.log("  PASS  与另两者无共同 slot");
    }else if(!risky.length){
      console.log("  PASS  共同 slot "+shared.join(", ")+" 均为按插件 id 分片的命名空间（宿主各自渲染，非抢位）");
    }else{
      console.log("  WARN  共同 slot 含非分片项（可能抢位）："+risky.join(", "));
    }
    // 3) HTTP 路由
    const routes=(f)=>[...new Set([...fs.readFileSync(f,"utf8").matchAll(/["`](\/api\/[a-zA-Z0-9_\/-]+)["`]/g)].map(m=>m[1]))];
    const mbR=routes(prof+"/node_modules/"+want[0]+"/lib/index.js");
    console.log("  本插件路由："+mbR.join(", ")+"（Jet Hub /api/subscription/*、破甲 /dsh-purge/*、/redteam/api —— 无交集）");
  ' "$MANIFEST" "$PROFILE" "$tpkg" 2>&1 | sed 's/^/  /'

  say "== 6. 配置与状态 =="
  # 「覆盖层」= profile patch 里真正生效的条目（形如 `- id: memorybear-memory`），
  # 只出现注释不算 —— 注释块是留档，不参与装配。
  local entryId="$("$NODE" -e 'const m=require(process.argv[1]);const v=m.variants[process.argv[2]]||m.variants[m.variants.default];process.stdout.write(v.entryId)' "$MANIFEST" "${curvar:-$DEFAULT_VARIANT}")"
  if grep -qE "^[[:space:]]*-[[:space:]]*id:[[:space:]]*${entryId}[[:space:]]*$" "$PROFILE/cordis.patch.yml" 2>/dev/null; then
    say "  PASS  profile patch 有生效的 config 覆盖条目（id: $entryId）"
    grep -n -A8 "^- id: ${entryId}" "$PROFILE/cordis.patch.yml" 2>/dev/null | head -12 | sed 's/^/        /'
  else
    say "  PASS  profile patch 无覆盖条目（用包内默认值；连接参数在 Plugins 页填即可）"
  fi
  [ -f "$STATE" ] && say "  PASS  kit 版本戳：$(cat "$STATE")" || { say "  WARN  无版本戳（$STATE）"; warn=$((warn+1)); }

  if [ "$withEngine" = 1 ]; then
    say "== 7. 隔离引擎实启（不动线上 4145 进程）=="
    cmd_engine_check || fail=$((fail+1))
  elif [ "$withLive" = 1 ]; then
    say "== 7. 线上引擎实查（127.0.0.1:<endpoint>）=="
    cmd_live_check || fail=$((fail+1))
  else
    say "== 7. 运行态 =="
    say "  SKIP  未加 --engine/--live。两种查法："
    say "        --live    直接问线上引擎（只读 RPC，不重启）：bash port.sh verify --live"
    say "        --engine  用隔离 DSH_HOME 起独立引擎（:4799）实测挂载，完全不碰线上"
  fi

  say ""
  if [ "$fail" = 0 ]; then say "结论：移植在位（FAIL=0，WARN=$warn）。"; else say "结论：有 $fail 项失败，先跑 install 修复，再复查。"; fi
  return "$fail"
}

# 用隔离的 DSH_HOME 起一个独立引擎，验证插件真能被引擎装配并激活；不触碰线上进程与线上状态。
# 只杀命令行里明确带 `bin.js web --port <port>` 的进程：绝不误伤线上引擎（它绑的是 4145）。
# 引擎 fork 出的子进程命令行相同、且收 SIGTERM 后可能还在优雅收尾，所以：
#   ① 按命令行扫（不依赖 $! 那一个 pid）；② 最多 12 轮，每轮 TERM；③ 仍活着就 -9 收尾。
# 注意：本函数只在脚本文件里被执行时安全 —— 若把匹配串直接写在**内联 bash -c 命令**里，
# 该进程自己的 cmdline 会含这个串而被自己匹配到（实测会自杀）。用变量拼接可规避。
kill_stale_engine() {
  local port=$1 found=0 round pid c p
  for round in 1 2 3 4 5 6 7 8 9 10 11 12; do
    local alive=0
    for p in $(ls -d /proc/[0-9]* 2>/dev/null); do
      [ -r "$p/cmdline" ] || continue
      c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
      case "$c" in
        *"bin.js web --port $port"*)
          pid=${p#/proc/}; alive=1; found=1
          if [ "$round" -ge 8 ]; then kill -9 "$pid" 2>/dev/null; else kill "$pid" 2>/dev/null; fi ;;
      esac
    done
    [ "$alive" = 0 ] && break
    sleep 1
  done
  [ "$found" = 1 ] && say "  已清掉残留独立引擎（:$port）"
  # 收尾后确认端口真的空出来了（只报，不阻塞）
  if ! "$NODE" -e '
    const net=require("net");const s=net.createServer();
    s.once("error",()=>process.exit(1));
    s.once("listening",()=>{s.close();process.exit(0)});
    s.listen(Number(process.argv[1]),"127.0.0.1");
  ' "$port" 2>/dev/null; then
    say "  注意 端口 :$port 仍被占用（可能是别的程序，不是本 kit 的引擎）"
  fi
  return 0
}

cmd_engine_check() {
  local port=${MB_ENGINE_PORT:-4799}
  local base=$DSH_HOME/port-backup/mb-engine
  local iso=$base/home/.dsh
  local log=$base/engine-$port.log
  rm -rf "$base"; mkdir -p "$iso/profiles/web" "$base"
  kill_stale_engine "$port"
  # 隔离 home：软链真 node_modules（只读用），复制两个清单文件
  ln -s "$PROFILE/node_modules" "$iso/profiles/web/node_modules"
  cp -a "$PROFILE/package.json"    "$iso/profiles/web/package.json"
  cp -a "$PROFILE/cordis.patch.yml" "$iso/profiles/web/cordis.patch.yml"
  cp -a "$PROFILE/cordis.yml"      "$iso/profiles/web/cordis.yml" 2>/dev/null || true
  cp -a "$PROFILE/pnpm-workspace.yaml" "$iso/profiles/web/pnpm-workspace.yaml" 2>/dev/null || true

  say "  启动独立引擎 :$port（DSH_HOME=$iso）"
  # 与线上引擎（APK 拉起的那条）逐字对齐：node --expose-internals bin.js web --port P --no-open
  # 少了 --expose-internals 会在 node-addon-require-builtin 回退路径上挂在 'internal/modules/esm/loader'。
  ( cd "$ENGINE" && nohup env DSH_HOME="$iso" HOME="$HOME_DIR" PATH="$FILES/usr/bin:$PATH" \
      "$NODE" --expose-internals "$ENGINE/lib/bin.js" web --port "$port" --no-open >"$log" 2>&1 & echo $! > "$base/pid" )
  local pid; pid=$(cat "$base/pid" 2>/dev/null)
  # 首次启动要给 node 编译缓存热身，实测 6～32s 都有；给足 120s，并按秒轮询启动日志里的 ?token=。
  # 提前中断只认「真致命」：启动失败 / fatal / 本端口被占。
  # 注意别把 `EADDRINUSE 127.0.0.1:8326` 当致命 —— 那是 Jet Hub 的本地网关在第二个引擎里必然抢不到端口，
  # 只是 warn（双引擎并存时的正常现象），本插件与它无关。
  local i=0 token="" limit=120 aborted=""
  while [ $i -lt $limit ]; do
    token=$(grep -aoE "token=[A-Za-z0-9_-]+" "$log" 2>/dev/null | tail -1 | cut -d= -f2)
    [ -n "$token" ] && break
    if grep -qiE "startup failed|dsh: fatal|Failed plugins" "$log" 2>/dev/null; then aborted="启动失败"; break; fi
    if grep -qiE "address already in use 127\.0\.0\.1:$port|EADDRINUSE.*:$port" "$log" 2>/dev/null; then aborted="本端口被占"; break; fi
    sleep 1; i=$((i+1))
  done
  if [ -z "$token" ]; then
    say "  FAIL  独立引擎未就绪（等了 ${i}s${aborted:+，因「$aborted」提前判定}；pid=$pid），日志尾部："
    tail -14 "$log" 2>/dev/null | sed 's/^/        /'
    kill_stale_engine "$port" >/dev/null
    return 1
  fi
  say "  引擎就绪（$((i+1))s），查询 pluginManager/listPlugins …"
  local rc=0
  "$NODE" -e '
    const http=require("node:http");
    const [port,token,entryId]=process.argv.slice(1);
    const req=(opts,body)=>new Promise((ok,no)=>{
      const r=http.request(opts,x=>{let d="";x.on("data",c=>d+=c);x.on("end",()=>ok({x,d}))});
      r.on("error",no); if(body)r.write(body); r.end();
    });
    (async()=>{
      // 1) 用启动日志里的 ?token= 做一次登录握手，换取 dsh-auth-* 会话 cookie
      const a=await req({host:"127.0.0.1",port:Number(port),path:"/?token="+encodeURIComponent(token),method:"GET"});
      const raw=a.x.headers["set-cookie"]||[];
      const cookie=String(Array.isArray(raw)?raw[0]:raw).split(";")[0];
      if(!cookie||!cookie.includes("=")){console.log("  FAIL  登录握手未拿到 cookie（鉴权形态变了？）");process.exit(1)}
      // 2) 带上 cookie 调 pluginManager/listPlugins
      const payload=JSON.stringify({type:"client-request",rpcId:"mb-verify",method:"pluginManager/listPlugins",payload:{args:{}}});
      const r=await req({host:"127.0.0.1",port:Number(port),path:"/api/pluginManager/listPlugins",method:"POST",
        headers:{"content-type":"application/json",cookie,"content-length":Buffer.byteLength(payload)}},payload);
      let j;try{j=JSON.parse(r.d)}catch(e){console.log("  FAIL  引擎应答不是 JSON："+r.d.slice(0,200));process.exit(1)}
      const rows=j&&j.result&&j.result.value;
      if(!Array.isArray(rows)){console.log("  FAIL  引擎拒绝列出插件："+JSON.stringify((j&&j.result&&j.result.error)||j).slice(0,240));process.exit(1)}
      const bare=(v)=>String(v||"").replace(/^include:/,"");
      const hit=rows.filter(x=>bare(x.entryId)===bare(entryId)||/redbearai\/dsh-memory/.test(x.moduleName||""));
      if(!hit.length){console.log("  FAIL  装配里没有 "+entryId+" 行（bundles 选择丢了？重跑 install）");process.exit(1)}
      let ok=true;
      for(const x of hit){
        const good=x.enabled&&x.fiberPhase==="active";
        if(!good)ok=false;
        console.log("  "+(good?"PASS":"FAIL")+"  "+x.entryId+" → "+x.moduleName+" enabled="+x.enabled+" fiber="+x.fiberPhase+(x.error?" error="+x.error:""));
      }
      const others=rows.filter(x=>["codearts-auth","dsh-purge"].includes(bare(x.entryId)));
      const allOk=others.length===2&&others.every(x=>x.enabled&&x.fiberPhase==="active");
      console.log("  "+(allOk?"PASS":"WARN")+"  共存复核（同一引擎内）："+others.map(x=>x.entryId+"="+x.fiberPhase).join(" / "));
      process.exit(ok?0:1);
    })().catch(e=>{console.log("  FAIL  "+e.message);process.exit(1)});
  ' "$port" "$token" "$entry" || rc=1

  grep -iE "memorybear-memory|memoryskills-memory" "$log" 2>/dev/null | tail -3 | sed 's/^/        /'
  kill_stale_engine "$port"
  say "  独立引擎已停止；隔离 home 留在 $iso"
  return "$rc"
}

# 只读查询**线上引擎**的装配表：不动进程、不改状态。端口取 .engine-endpoint.json，
# 会话 cookie 取 app 的 shared_prefs（引擎用 dsh-auth-* 名字；两种 XML 形态都兜）。
cmd_live_check() {
  local entryId="$("$NODE" -e 'const m=require(process.argv[1]);const v=m.variants[process.argv[2]]||m.variants[m.variants.default];process.stdout.write(v.entryId)' "$MANIFEST" "${curvar:-$DEFAULT_VARIANT}")"
  "$NODE" -e '
    const fs=require("node:fs"),http=require("node:http");
    const [FILES, entry]=process.argv.slice(1);
    let cookie="";
    try{
      const s=fs.readFileSync("/data/data/com.dsharnessmobile.shell/shared_prefs/dsh_engine_auth.xml","utf8");
      if(/name="cookie"/.test(s)) cookie=(s.match(/name="cookie">([^<]+)</)||["",""])[1];
      else { const k=s.match(/name="([^"]+)"/), v=s.match(/<string[^>]*>([^<]+)</); if(k&&v) cookie=k[1]+"="+v[1]; }
    }catch(e){}
    if(!cookie){console.log("  FAIL  读不到引擎会话 cookie（shared_prefs/dsh_engine_auth.xml）");process.exit(1)}
    let port=4145; try{port=JSON.parse(fs.readFileSync(FILES+"/.engine-endpoint.json","utf8")).port}catch(e){}
    const payload=JSON.stringify({type:"client-request",rpcId:"mb-live",method:"pluginManager/listPlugins",payload:{args:{}}});
    const req=http.request({host:"127.0.0.1",port,path:"/api/pluginManager/listPlugins",method:"POST",
      headers:{"content-type":"application/json",cookie,"content-length":Buffer.byteLength(payload)}},res=>{
      let d="";res.on("data",c=>d+=c);res.on("end",()=>{
        let j;try{j=JSON.parse(d)}catch(e){console.log("  FAIL  非 JSON 应答（鉴权？）："+d.slice(0,120));process.exit(1)}
        const rows=j&&j.result&&j.result.value;
        if(!Array.isArray(rows)){console.log("  FAIL  引擎拒绝： "+JSON.stringify((j&&j.result&&j.result.error)||j).slice(0,200));process.exit(1)}
        const bare=(v)=>String(v||"").replace(/^include:/,"");
        console.log("  线上引擎端口 :"+port+"（只读查询，未重启）");
        let ok=true;
        for(const w of [entry,"codearts-auth","dsh-purge"]){
          const r=rows.find(x=>bare(x.entryId)===w || /redbearai\/dsh-memory/.test(x.moduleName||""));
          if(!r){console.log("  "+(w===entry?"FAIL":"WARN")+"  "+w+" → 不在装配表里"); if(w===entry)ok=false; continue}
          const good=r.enabled&&r.fiberPhase==="active";
          if(!good&&w===entry)ok=false;
          console.log("  "+(good?"PASS":"WARN")+"  "+r.entryId+" → "+r.moduleName+" enabled="+r.enabled+" fiber="+r.fiberPhase);
        }
        process.exit(ok?0:1);
      });
    });
    req.on("error",e=>{console.log("  FAIL  连不上线上引擎："+e.message);process.exit(1)});
    req.end(payload);
  ' "$FILES" "$entryId" || return 1
  return 0
}

# ── 连接与密钥（走引擎自己的 RPC，和网页版 Plugins 页同一条路）────────────────────
# 网页版 Plugins 页写 key 用的是 remote.credentials.set → HTTP RPC `credentials/set`；
# 这里直接调同一个 RPC，所以 key 同样落进 dsh 凭据库（.credentials.yaml 的 refs 段），
# 不写进 cordis.patch.yml，也不需要重启。
engine_rpc() { # $1=method  $2=JSON args  —— 只读/写凭据用，端口与 cookie 与线上引擎一致
  local method=$1 args=$2
  "$NODE" -e '
    const fs=require("node:fs"),http=require("node:http");
    const [FILES,method,argsJson]=process.argv.slice(1);
    let cookie="";
    try{
      const s=fs.readFileSync("/data/data/com.dsharnessmobile.shell/shared_prefs/dsh_engine_auth.xml","utf8");
      if(/name="cookie"/.test(s)) cookie=(s.match(/name="cookie">([^<]+)</)||["",""])[1];
      else { const k=s.match(/name="([^"]+)"/), v=s.match(/<string[^>]*>([^<]+)</); if(k&&v) cookie=k[1]+"="+v[1]; }
    }catch(e){}
    if(!cookie){console.error("read-no-cookie");process.exit(2)}
    let port=4145; try{port=JSON.parse(fs.readFileSync(FILES+"/.engine-endpoint.json","utf8")).port}catch(e){}
    const payload=JSON.stringify({type:"client-request",rpcId:"mb-cli",method,payload:{args:JSON.parse(argsJson)}});
    const req=http.request({host:"127.0.0.1",port,path:"/api/"+method,method:"POST",
      headers:{"content-type":"application/json",cookie,"content-length":Buffer.byteLength(payload)}},res=>{
      let d="";res.on("data",c=>d+=c);res.on("end",()=>process.stdout.write(d));
    });
    req.on("error",e=>{console.error("rpc-failed: "+e.message);process.exit(3)});
    req.write(payload);req.end();
  ' "$FILES" "$method" "$args" 2>/dev/null
}

var_keyref() { # $1=变体名 → 该变体默认的凭据引用名（apiKeyEnv）
  case "$1" in
    memoryskills) echo MEMORYSKILLS_API_KEY ;;
    memorybear|*) echo MEMORYBEAR_API_KEY ;;
  esac
}

cmd_key() { # 只读：报告两个变体的 key 是否已配置
  need_runtime
  local curvar="$1"
  say "凭据引用状态（来源：线上引擎 credentials/describe，只读）"
  local out; out=$(engine_rpc "credentials/describe" '{"refs":["MEMORYBEAR_API_KEY","MEMORYSKILLS_API_KEY"]}')
  if [ -z "$out" ]; then say "  FAIL  读不到（引擎未运行或 cookie 不可读）"; return 1; fi
  printf '%s' "$out" | "$NODE" -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      const j=JSON.parse(d); const v=j&&j.result&&j.result.value;
      if(!v){console.log("  FAIL  引擎应答异常："+d.slice(0,200));process.exit(1)}
      const cur=process.argv[1];
      const map={MEMORYBEAR_API_KEY:"memorybear",MEMORYSKILLS_API_KEY:"memoryskills"};
      for(const [ref,st] of Object.entries(v)){
        const me=map[ref]===cur?"  ← 当前变体":"";
        console.log("  "+(st.configured?"已配置":"未配置").padEnd(4)+"  "+ref+(st.writable?"":"（只读：来自启动环境变量）")+me);
      }
    })' "$curvar"
  say ""
  say "填写方式二选一："
  say "  ① 网页版：设置 → Plugins → $curvar 面板 → API Key 填进去（保存即生效，key 进凭据库）"
  say "  ② 终端：  bash \"$SELF/port.sh\" setkey        （从标准输入读，不进 shell 历史）"
}

cmd_setkey() { # 写入：把 key 存进凭据库（默认取当前变体的引用名）
  need_runtime
  local ref="" curvar="$1"; shift 2>/dev/null || true
  while [ $# -gt 0 ]; do case "$1" in --ref) shift; ref=${1:-} ;; *) die "未知参数：$1" ;; esac; shift; done
  [ -n "$ref" ] || ref=$(var_keyref "$curvar")
  local key=""
  if [ -t 0 ]; then
    printf '粘贴 %s 的 key（不回显，回车确认）: ' "$ref" >&2
    stty -echo 2>/dev/null || true; IFS= read -r key; stty echo 2>/dev/null || true; printf '\n' >&2
  else
    IFS= read -r key
  fi
  key=$(printf '%s' "$key" | tr -d ' \t\r\n')
  [ -n "$key" ] || die "没读到内容（用法：printf '%s' \"sk-mem-…\" | bash port.sh setkey）"
  if [ "$ref" = MEMORYSKILLS_API_KEY ]; then
    case "$key" in sk-mem-*) ;; *) say "  注意：MemorySkills 的个人 key 以 sk-mem- 开头，你给的不像（仍照写，插件侧会拒绝）" ;; esac
  fi
  local out; out=$(engine_rpc "credentials/set" "$("$NODE" -e 'console.log(JSON.stringify({ref:process.argv[1],value:process.argv[2]}))' "$ref" "$key")")
  case "$out" in
    *'"ok":true'*) say "  PASS  已写入 $ref（存进 dsh 凭据库，唯一长度=$(printf '%s' "$key" | wc -c) 字节）" ;;
    *) say "  FAIL  写入失败：$(printf '%s' "$out" | head -c 300)"; return 1 ;;
  esac
  key=""
  say "  插件侧不用重启：配置页打开即显示「已配置密钥」；连接字段也填好后 engine.log 会记 loaded。"
}

cmd_unsetkey() {
  need_runtime
  local ref="" curvar="$1"; shift 2>/dev/null || true
  while [ $# -gt 0 ]; do case "$1" in --ref) shift; ref=${1:-} ;; *) die "未知参数：$1" ;; esac; shift; done
  [ -n "$ref" ] || ref=$(var_keyref "$curvar")
  local out; out=$(engine_rpc "credentials/unset" "$("$NODE" -e 'console.log(JSON.stringify({ref:process.argv[1]}))' "$ref")")
  case "$out" in
    *'"ok":true'*) say "  PASS  已从凭据库移除 $ref" ;;
    *) say "  FAIL  移除失败：$(printf '%s' "$out" | head -c 300)"; return 1 ;;
  esac
}

# 连接字段（baseURL / endUserId / portalURL）写进 profile patch 的本插件条目里。
# 这是**配置层**、不是密钥：与网页版 Plugins 页保存 volatile 字段等价（都落 profile patch）。
cmd_setconn() {
  need_runtime
  local baseURL=${1:-} endUserId=${2:-}
  [ -n "$baseURL" ] || die "用法：bash port.sh setconn <baseURL> [<endUserId>]    例：setconn https://mem.example.com/v1 8f0c…"
  local entry=memorybear-memory
  cp "$PROFILE/cordis.patch.yml" "$PROFILE/cordis.patch.yml.pre-setconn.bak" 2>/dev/null || true
  "$NODE" -e '
    const fs=require("node:fs");
    const [file,entry,baseURL,endUserId]=process.argv.slice(1);
    const text=fs.readFileSync(file,"utf8");
    const lines=text.split(/\r?\n/);
    const start=lines.findIndex((l)=>new RegExp("^[\\s]*-[\\s]*id:[\\s]*"+entry+"[\\s]*$").test(l));
    if(start<0){console.error("no-entry");process.exit(1)}
    let end=start+1;
    while(end<lines.length && !/^-[ ]/.test(lines[end])) end++;
    const head=lines.slice(0,start);
    const tail=lines.slice(end);
    const block=["- id: "+entry,"  config:","    enabled: true",
      "    baseURL: "+JSON.stringify(baseURL),
      ...(endUserId?["    endUserId: "+JSON.stringify(endUserId)]:[])];
    fs.writeFileSync(file,[...head,...block,...tail].join("\n").replace(/\n+$/,"\n"));
    console.log("已写入 profile patch："+entry+" 的 baseURL"+(endUserId?" / endUserId":""));
  ' "$PROFILE/cordis.patch.yml" "$entry" "$baseURL" "$endUserId" || die "改 profile patch 失败（先看 $PROFILE/cordis.patch.yml.pre-setconn.bak）"
  say "  备份：$PROFILE/cordis.patch.yml.pre-setconn.bak"
  say "  刷新页面（或重启应用）后插件连服务；engine.log 应出现「[memorybear-memory] loaded; endUser=…」"
}

cmd_uninstall() {
  local purge=0
  for a in "$@"; do [ "$a" = "--purge" ] && purge=1; done
  need_runtime
  local backup; backup=$(backup_profile)
  "$NODE" -e '
    const fs=require("node:fs");
    const [file,...names]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    for(const n of names){ if(j.dependencies) delete j.dependencies[n]; }
    const b=(((j.dsh||{}).profile||{}).bundles)||[];
    if(Array.isArray(b)) j.dsh.profile.bundles=b.filter(x=>!names.includes(x));
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
  ' "$PROFILE/package.json" $(all_variant_pkgs) || die "改 package.json 失败"
  for p in $REDBEAR_PKGS; do rm -rf "$PROFILE/node_modules/$p"; done
  rm -f "$STATE"
  say "已卸载：profile 清单已回滚，@redbearai/* 已删除，备份在 $backup"
  say "共享依赖（$SHARED_PKGS）**保持原样**——它们与 Jet Hub 共用，删了会连带破坏别的插件。"
  [ "$purge" = 1 ] && { rm -rf "$DSH_HOME/port-backup/mb-engine" "$DSH_HOME/memory-bear"; say "已清掉隔离引擎 home 与插件状态目录（--purge）。"; }
  say "刷新页面或重启应用生效。"
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  status)    shift; cmd_status "$@" ;;
  switch)    shift; cmd_install --variant "${1:-}" --force ;;
  key)       shift; cmd_key "$(variant_of_pkg "$(current_pkg)")" ;;
  setkey)    shift; cmd_setkey "$(variant_of_pkg "$(current_pkg)")" "$@" ;;
  unsetkey)  shift; cmd_unsetkey "$(variant_of_pkg "$(current_pkg)")" "$@" ;;
  setconn)   shift; cmd_setconn "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
