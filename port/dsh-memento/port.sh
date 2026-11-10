#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# dsh-memento（长期记忆插件）在 dsh-mobile-apk 上的移植维护脚本。
#
# 设计前提（与 port/jet-hub 同一约定）：本插件**不进入 APK，也不进入上游仓库**。
# 它只活在 app 私有数据里：
#   $DSH_FILES_DIR/home/.dsh/profiles/web/node_modules/dsh-memento   插件包
#   $DSH_FILES_DIR/home/.dsh/profiles/web/package.json               依赖键 + dsh.profile.bundles 选择
#   $DSH_FILES_DIR/home/.dsh/dsh-memento/                            记忆库（memory.db）与状态
# 这些路径在 APK 覆盖安装 + 快照刷新时被「合并保留」（见 README 的机制一节），
# 因此每日新构建物不会把它覆盖掉，也不需要改工具的任何提交。
#
# 与 port/dsh-purge 的关键区别：本插件是**纯 JS 插件**，不改宿主运行时树
# （dsh-purge 那 86 条宿主补丁与本 kit 无关，本 kit 不读也不写它们）。
#
# 用法：
#   bash port.sh install            从本地 payload 离线安装/修复（幂等）
#   bash port.sh install --force    忽略版本戳，强制重铺文件
#   bash port.sh install --enable   同时清掉隔离（quarantine）禁用行，恢复启用
#   bash port.sh verify             体检：文件 / 装配 / 模块加载 / 引擎内 fiber
#   bash port.sh status             只打印当前落点与版本，不改任何东西
#   bash port.sh uninstall          卸载（保留记忆库；--purge 连记忆库一起删）
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -d "$FILES/home" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
HOME_DIR=$FILES/home
DSH_HOME=$HOME_DIR/.dsh
PROFILE=$DSH_HOME/profiles/web
STATE=$DSH_HOME/port-state-memento.json
NODE=${NODE:-$FILES/usr/bin/node}
PKG=dsh-memento
# 本插件 dependencies 为空，peerDependencies 全由宿主运行时解析，故无随包依赖。
PKG_DEPS=""
MEM_HOME=$DSH_HOME/dsh-memento
MANIFEST=$SELF/manifest.json

die() { printf 'port: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

need_runtime() {
  [ -x "$NODE" ] || die "找不到运行时 node：$NODE（可用 NODE=... 覆盖）"
  [ -d "$PROFILE" ] || die "找不到 web profile：$PROFILE（应用是否已首次启动？）"
}

kit_version() {
  "$NODE" -e 'const m=require(process.argv[1]);console.log(m.package.version)' "$MANIFEST" 2>/dev/null || echo unknown
}

ensure_payload() {
  local payload=$SELF/payload
  if [ -d "$payload/node_modules/$PKG" ]; then
    echo "$payload"
    return 0
  fi
  local archive=$SELF/payload.tar.gz
  if [ ! -f "$archive" ]; then
    # 仓库里的 kit 不背二进制载荷：缺载荷时按 manifest.json 钉住的版本从 npm 重新拉一份。
    [ -f "$SELF/fetch-payload.sh" ] || die "缺少离线载荷：$SELF/payload.tar.gz（也没有 fetch-payload.sh）"
    say "本地无载荷，按 manifest.json 从 npm 重新获取..." >&2
    bash "$SELF/fetch-payload.sh" >&2 || die "获取载荷失败（无网络时改用带 payload.tar.gz 的分支副本）"
    if [ -d "$SELF/payload/node_modules/$PKG" ]; then echo "$SELF/payload"; return 0; fi
    archive=$SELF/payload.tar.gz
    [ -f "$archive" ] || die "获取载荷失败：$SELF/payload 与 payload.tar.gz 都不存在"
  fi
  local cache=$SELF/.unpacked
  if [ ! -d "$cache/node_modules/$PKG" ]; then
    rm -rf "$cache"
    mkdir -p "$cache" || die "无法创建 $cache"
    "$NODE" -e '
      const fs=require("node:fs"),zlib=require("node:zlib"),path=require("node:path");
      const [src,dst]=process.argv.slice(1);
      const tar=zlib.gunzipSync(fs.readFileSync(src));
      // 最小 tar 解析器：只处理 ustar 常规文件/目录（载荷由本 kit 的 pack-payload.mjs 生成）
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

cmd_status() {
  need_runtime 2>/dev/null || true
  local installed=none
  if [ -f "$PROFILE/node_modules/$PKG/package.json" ]; then
    installed=$("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json" 2>/dev/null || echo unreadable)
  fi
  say "kit          : $(kit_version)"
  say "profile      : $PROFILE"
  say "installed    : $installed"
  if [ -f "$STATE" ]; then say "stamp        : $(cat "$STATE")"; else say "stamp        : (无)"; fi
  "$NODE" -e '
    const fs=require("node:fs");
    const p=process.argv[1], name=process.argv[2];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    const dep=(j.dependencies||{})[name]||"(缺少)";
    const b=((j.dsh||{}).profile||{}).bundles||[];
    console.log("dep key      : "+dep);
    console.log("bundles      : "+(b.includes(name)?"已登记 ("+b.length+" 项)":"未登记 ("+b.length+" 项)"));
  ' "$PROFILE/package.json" "$PKG" 2>/dev/null || say "package.json : 无法解析"
  local q=$(grep -c "dsh-mobile-quarantine-v1" "$DSH_HOME/cordis.patch.yml" 2>/dev/null || echo 0)
  say "quarantine   : $q 条隔离标记（home patch）"
  say "memory.db    : $([ -f "$MEM_HOME/memory.db" ] && echo "存在 ($(du -h "$MEM_HOME/memory.db" 2>/dev/null | cut -f1))" || echo "(尚未生成，首次写入记忆后才出现)")"
}

cmd_install() {
  local force=0 enable=0
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      --enable) enable=1 ;;
      *) die "未知参数：$a" ;;
    esac
  done
  need_runtime
  local payload; payload=$(ensure_payload)
  local version; version=$("$NODE" -e 'console.log(require(process.argv[1]).version)' "$payload/node_modules/$PKG/package.json")
  local stamp="{\"package\":\"$PKG\",\"version\":\"$version\",\"kit\":\"$(kit_version)\",\"installedAt\":\"$(date -Iseconds)\"}"

  mkdir -p "$DSH_HOME/port-backup"
  local backup=$DSH_HOME/port-backup/memento-profile-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  cp "$PROFILE/package.json" "$backup/package.json" 2>/dev/null || true
  cp "$PROFILE/cordis.patch.yml" "$backup/cordis.patch.yml" 2>/dev/null || true
  # 只留最近 5 份 profile 备份
  ls -1dt "$DSH_HOME/port-backup"/memento-profile-* 2>/dev/null | tail -n +6 | while read -r old; do rm -rf "$old"; done

  if [ "$force" = 0 ] && [ -f "$STATE" ] && grep -q "\"version\":\"$version\"" "$STATE" 2>/dev/null; then
    say "文件已是 $version，跳过重铺（--force 可强制）"
  else
    say "铺设插件文件到 profile/node_modules ..."
    mkdir -p "$PROFILE/node_modules"
    # 不经过 pnpm：本 profile 的 lockfile 因 dsh-purge-community 在 npm 上 404 而失同步，
    # 任何 pnpm 操作都会被它挡住（ERR_PNPM_FETCH_404）。直接铺文件即可，宿主按目录解析。
    rm -rf "$PROFILE/node_modules/$PKG"
    cp -R "$payload/node_modules/$PKG" "$PROFILE/node_modules/$PKG" || die "复制插件文件失败"
    printf '%s\n' "$stamp" > "$STATE"
    say "文件落位完成：$version"
  fi

  "$NODE" -e '
    const fs=require("node:fs");
    const [file,name,version]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    j.dependencies=j.dependencies||{};
    j.dependencies[name]=version;
    j.dsh=j.dsh||{}; j.dsh.profile=j.dsh.profile||{};
    const b=Array.isArray(j.dsh.profile.bundles)?j.dsh.profile.bundles:[];
    if(!b.includes(name)) b.push(name);
    j.dsh.profile.bundles=b;
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
    console.log("装配已登记：dependencies."+name+"="+version+"；dsh.profile.bundles 共 "+b.length+" 项");
  ' "$PROFILE/package.json" "$PKG" "$version" || die "写 profile/package.json 失败"

  if [ "$enable" = 1 ]; then
    "$NODE" -e '
      const fs=require("node:fs");
      const [file,id,name]=process.argv.slice(1);
      if(!fs.existsSync(file)){console.log("home patch 不存在，无需清理");process.exit(0);}
      const text=fs.readFileSync(file,"utf8");
      const lines=text.split(/\r?\n/);
      const out=[];let i=0;let dropped=0;
      while(i<lines.length){
        if(lines[i].includes("dsh-mobile-quarantine-v1")){
          const head=lines[i+1]||"";
          const isTarget=/^-\s+id:/.test(head)&&head.includes(id)&&
            (lines[i+2]||"").includes(name);
          if(isTarget){
            let j=i+1;
            while(j<Math.min(i+6,lines.length)&&!/^\s*disabled:\s*true\s*$/.test(lines[j]))j++;
            if(j<Math.min(i+6,lines.length)){
              i=j+1;while(i<lines.length&&lines[i].trim()==="")i++;
              dropped++;continue;
            }
          }
        }
        out.push(lines[i]);i++;
      }
      if(dropped){fs.writeFileSync(file,out.join("\n"));console.log("已清理隔离块 "+dropped+" 处");}
      else console.log("未发现本插件的隔离块");
    ' "$DSH_HOME/cordis.patch.yml" "memento" "$PKG" || true
  fi

  say ""
  say "安装完成。重启 dsh web（或刷新页面）后新会话生效。"
  say "建议随后改两个默认值：writePolicy=auto、language=zh（默认 ask/en 会每次写记忆都弹审批）。"
}

cmd_verify() {
  need_runtime
  mkdir -p "$DSH_HOME/port-backup"
  local fail=0
  say "== 1. 文件 =="
  if [ -f "$PROFILE/node_modules/$PKG/package.json" ]; then
    say "  PASS  $PKG $("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json")"
  else
    say "  FAIL  缺少 $PROFILE/node_modules/$PKG"; fail=1
  fi
  if [ -f "$PROFILE/node_modules/$PKG/cordis.patch.yml" ]; then
    say "  PASS  bundle patch 在位（cordis.patch.yml）"
  else
    say "  FAIL  缺 cordis.patch.yml（bundle 无法挂载）"; fail=1
  fi
  if [ -d "$PROFILE/node_modules/$PKG/client" ]; then
    say "  PASS  client 半边在位（client/client.js）"
  else
    say "  WARN  无 client 目录（面板设置页将不可用，记忆功能不受影响）"
  fi
  local nat
  nat=$(find "$PROFILE/node_modules/$PKG" -type f \( -name '*.node' -o -name '*.so' -o -name '*.wasm' \) 2>/dev/null | wc -l)
  say "  INFO  原生二进制 $nat 个（应为 0：纯 JS，Android/Bionic 可跑）"

  say "== 2. 装配（package.json）=="
  if "$NODE" -e '
    const j=require(process.argv[1]);const n=process.argv[2];
    const dep=(j.dependencies||{})[n];const b=((j.dsh||{}).profile||{}).bundles||[];
    if(!dep||!b.includes(n))process.exit(1);
  ' "$PROFILE/package.json" "$PKG" 2>/dev/null; then
    say "  PASS  依赖键与 dsh.profile.bundles 都在"
  else
    say "  FAIL  package.json 里缺依赖键或 bundles 选择（重跑 install）"; fail=1
  fi

  say "== 3. 模块可加载（模拟引擎解析）=="
  local linked=()
  local eng=$FILES/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai
  if [ -d "$eng" ]; then
    mkdir -p "$PROFILE/node_modules/@deepseek-ai"
    for e in "$eng"/*; do
      local n; n=$(basename "$e")
      if [ ! -e "$PROFILE/node_modules/@deepseek-ai/$n" ]; then
        ln -s "$e" "$PROFILE/node_modules/@deepseek-ai/$n" 2>/dev/null && linked+=("$PROFILE/node_modules/@deepseek-ai/$n")
      fi
    done
  fi
  if ( cd "$PROFILE" && "$NODE" --input-type=module -e 'await import("dsh-memento")' 2>"$DSH_HOME/port-backup/.port-memento-import.err" ); then
    say "  PASS  import('dsh-memento') 成功（apply 可被宿主装载）"
  else
    say "  FAIL  模块导入失败："; sed 's/^/        /' "$DSH_HOME/port-backup/.port-memento-import.err" 2>/dev/null | head -8; fail=1
  fi
  [ ${#linked[@]} -gt 0 ] && rm -f "${linked[@]}"

  say "== 4. 引擎内 fiber =="
  local cookie=""
  local pref=/data/data/com.dsharnessmobile.shell/shared_prefs/dsh_engine_auth.xml
  [ -f "$pref" ] && cookie=$("$NODE" -e '
    const s=require("node:fs").readFileSync(process.argv[1],"utf8");
    const m=s.match(/name="cookie">([^<]+)</);if(!m)process.exit(1);console.log(m[1]);
  ' "$pref" 2>/dev/null)
  local port=$("$NODE" -e '
    try{const j=require(process.argv[1]);console.log(j.port)}catch(e){}
  ' "$FILES/.engine-endpoint.json" 2>/dev/null)
  [ -n "$port" ] || port=4145
  if [ -n "$cookie" ]; then
    local body
    body=$("$NODE" -e '
      const http=require("node:http");
      const [port,cookie]=process.argv.slice(1);
      const payload=JSON.stringify({type:"client-request",rpcId:"port-verify",method:"pluginManager/listPlugins",payload:{args:{}}});
      const req=http.request({host:"127.0.0.1",port:Number(port),path:"/api/pluginManager/listPlugins",method:"POST",headers:{"content-type":"application/json","cookie":cookie,"content-length":Buffer.byteLength(payload)}},res=>{
        let d="";res.on("data",c=>d+=c);res.on("end",()=>process.stdout.write(d));
      });
      req.on("error",e=>{console.error(e.message);process.exit(1)});
      req.end(payload);
    ' "$port" "$cookie" 2>/dev/null)
    if [ -n "$body" ] && printf '%s' "$body" | "$NODE" -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        let j;try{j=JSON.parse(d)}catch(e){console.log("  FAIL  引擎应答不是 JSON："+d.slice(0,160));process.exit(1);}
        const rows=j && j.result && j.result.value;
        if(!Array.isArray(rows)){
          console.log("  FAIL  引擎拒绝列出插件："+JSON.stringify((j&&j.result&&j.result.error)||j).slice(0,200));
          process.exit(1);
        }
        const hit=rows.filter(r=>(r.entryId||"")==="include:memento"||(r.entryId||"").includes("memento")||r.moduleName==="dsh-memento");
        if(!hit.length){console.log("  FAIL  引擎装配里没有 memento 行（刚装完需重启应用；若重启后仍无，重跑 install）");process.exit(1);}
        const r=hit[0];
        const ok=r.enabled&&r.fiberPhase==="active";
        console.log("  "+(ok?"PASS":"FAIL")+"  "+r.entryId+" → "+r.moduleName+" enabled="+r.enabled+" fiber="+r.fiberPhase);
        process.exit(ok?0:1);
      });
    '; then :; else
      say "  FAIL  引擎里没有活跃的 memento 行（重启应用后再试；若刚装完属正常）"; fail=1
    fi
  else
    say "  SKIP  读不到引擎 cookie（$pref），跳过运行态检查"
  fi

  say ""
  if [ "$fail" = 0 ]; then say "体检结果：全部 PASS"; else say "体检结果：存在 FAIL（见上）"; fi
  return $fail
}

cmd_uninstall() {
  local purge=0
  for a in "$@"; do case "$a" in --purge) purge=1 ;; *) die "未知参数：$a" ;; esac; done
  need_runtime
  mkdir -p "$DSH_HOME/port-backup"
  local backup=$DSH_HOME/port-backup/memento-uninstall-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  cp "$PROFILE/package.json" "$backup/package.json" 2>/dev/null || true
  cp "$PROFILE/cordis.patch.yml" "$backup/cordis.patch.yml" 2>/dev/null || true

  rm -rf "$PROFILE/node_modules/$PKG"
  rm -f "$STATE"
  "$NODE" -e '
    const fs=require("node:fs");
    const [file,name]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    if(j.dependencies) delete j.dependencies[name];
    const p=(j.dsh||{}).profile;
    if(p&&Array.isArray(p.bundles)) p.bundles=p.bundles.filter(x=>x!==name);
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
    console.log("装配已移除：dependencies."+name+" 与 bundles 选择");
  ' "$PROFILE/package.json" "$PKG" || die "写 profile/package.json 失败"

  if [ "$purge" = 1 ]; then
    rm -rf "$MEM_HOME"
    say "已连记忆库一起删除：$MEM_HOME"
  else
    say "记忆库保留在 $MEM_HOME（--purge 可一并删除）"
  fi
  say "卸载完成。重启 dsh web 后生效。"
}

case "${1:-}" in
  status)    shift; cmd_status "$@" ;;
  install)   shift; cmd_install "$@" ;;
  verify)    shift; cmd_verify "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  ""|*)      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
