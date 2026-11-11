#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# dsh-providers-hub（Jet Hub）在 dsh-mobile-apk 上的移植维护脚本。
#
# 设计前提：本插件**不进入 APK，也不进入仓库**。它只活在 app 私有数据里：
#   $DSH_FILES_DIR/home/.dsh/profiles/web/node_modules/...   插件包与依赖
#   $DSH_FILES_DIR/home/.dsh/profiles/web/package.json         依赖键 + dsh.profile.bundles 选择
#   $DSH_FILES_DIR/home/.dsh/jet-hub/、openai-gateway/         插件自己的账号/网关状态
# 这些路径在 APK 覆盖安装 + 快照刷新时被「合并保留」（见 README 的机制一节），
# 因此每日新构建物不会把它覆盖掉，也不需要改工具的任何提交。
#
# 用法：
#   bash port.sh install            从本地 payload 离线安装/修复（幂等）
#   bash port.sh install --force    忽略版本戳，强制重铺文件
#   bash port.sh install --enable   同时清掉隔离（quarantine）禁用行，恢复启用
#   bash port.sh verify             体检：文件 / 装配 / 模块加载 / 引擎内 fiber / 网关端口
#   bash port.sh status             只打印当前落点与版本，不改任何东西
#   bash port.sh uninstall          卸载（保留账号状态；--purge 连状态一起删）
#   bash port.sh lockfix            把 pnpm 账本（pnpm-lock.yaml + .modules.yaml）对齐到实装版本
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -d "$FILES/home" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
HOME_DIR=$FILES/home
DSH_HOME=$HOME_DIR/.dsh
PROFILE=$DSH_HOME/profiles/web
STATE=$DSH_HOME/port-state.json
NODE=${NODE:-$FILES/usr/bin/node}
PKG=dsh-providers-hub
PKG_DEPS="jose undici wreq-js @wreq-js/binding-android-arm64 @deepseek-ai/cosmokit @deepseek-ai/schemastery"
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

# 载荷里逐版本钉死的依赖清单（manifest.bundledDependencies），用于 install 时的落位校验。
manifest_deps() {
  "$NODE" -e 'const m=require(process.argv[1]);console.log(Object.keys(m.bundledDependencies||{}).join(" "))' "$MANIFEST" 2>/dev/null
}

ensure_payload() {
  local payload=$SELF/payload
  if [ -d "$payload/node_modules/$PKG" ]; then
    echo "$payload"
    return 0
  fi
  local archive=$SELF/payload.tar.gz
  if [ ! -f "$archive" ]; then
    # 仓库里的 kit 不背 10 MB 二进制：缺载荷时按 manifest.json 钉住的版本从 npm 重新拉一份。
    [ -f "$SELF/fetch-payload.sh" ] || die "缺少离线载荷：$SELF/payload.tar.gz（也没有 fetch-payload.sh）"
    say "本地无载荷，按 manifest.json 从 npm 重新获取（首次约 34 MB / 10 秒）..." >&2
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
      // 最小 tar 解析器：只处理 ustar 常规文件/目录（载荷由本脚本自己生成，无长名/无链接）
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
  # 账本一致性：pnpm-lock.yaml 的 importer 版本 vs 实装版本。
  # 这一栏存在的理由（设备实测）：手工铺文件不会改 pnpm 账本，而 App 内「插件」页的
  # 安装/卸载走 `pnpm add`/`pnpm remove` —— 一旦有人点了它，pnpm 按 lockfile 的旧版本
  # 重解析，把手工装的版本**降级**回 lockfile 里那一版，且不会有任何提示。
  local lockv
  lockv=$("$NODE" -e '
    const fs=require("node:fs");
    try{
      const t=fs.readFileSync(process.argv[1],"utf8");
      const re=new RegExp("^\\s{6}"+process.argv[2].replace(/[.*+?^${}()|[\]\\]/g,"\\$&")+":\\s*$[\\s\\S]{0,200}?^\\s{8}version:\\s*(\\S+)\\s*$","m");
      const m=t.match(re);console.log(m?m[1]:"(未登记)");
    }catch(e){console.log("(无 lockfile)")}
  ' "$PROFILE/pnpm-lock.yaml" "$PKG" 2>/dev/null)
  say "lockfile     : $lockv"
  if [ "$lockv" != "$installed" ] && [ "$lockv" != "(无 lockfile)" ]; then
    say "              ^ 与实装不一致 —— 跑 lockfix 对齐，否则 pnpm 重装会按 lockfile 降级"
  fi
  local q=$(grep -c "quarantine-v1" "$DSH_HOME/cordis.patch.yml" 2>/dev/null || echo 0)
  say "quarantine   : $q 条隔离标记（home patch）"
  say "state dir    : $DSH_HOME/jet-hub $([ -d "$DSH_HOME/jet-hub" ] && echo '(存在)' || echo '(尚未生成)')"
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
  local backup=$DSH_HOME/port-backup/profile-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  cp "$PROFILE/package.json" "$backup/package.json" 2>/dev/null || true
  cp "$PROFILE/cordis.patch.yml" "$backup/cordis.patch.yml" 2>/dev/null || true
  cp "$PROFILE/pnpm-lock.yaml" "$backup/pnpm-lock.yaml" 2>/dev/null || true
  cp "$PROFILE/node_modules/.modules.yaml" "$backup/.modules.yaml" 2>/dev/null || true
  # 只留最近 5 份 profile 备份，避免每次修复都堆一份
  ls -1dt "$DSH_HOME/port-backup"/profile-* 2>/dev/null | tail -n +6 | while read -r old; do rm -rf "$old"; done

  if [ "$force" = 0 ] && [ -f "$STATE" ] && grep -q "\"version\":\"$version\"" "$STATE" 2>/dev/null; then
    say "文件已是 $version，跳过重铺（--force 可强制）"
  else
    say "铺设插件文件到 profile/node_modules ..."
    # 包目录整体替换而不是 cp -R 覆盖：`cp -R` 只增不删，上游删掉的文件会永久残留
    # （实测 2.20→2.21 有 32 个新增文件、0 个删除；一旦将来有删除，残留会让 .js 与
    #  .d.ts 的版本面不一致，且旧模块可能仍被 import 到）。
    rm -rf "$PROFILE/node_modules/$PKG"
    mkdir -p "$PROFILE/node_modules/@wreq-js" "$PROFILE/node_modules/@deepseek-ai"
    cp -R "$payload/node_modules/." "$PROFILE/node_modules/" || die "复制插件文件失败"
    # 载荷里没带（但 manifest 声明了）的依赖：从载荷里逐项核对，缺一个就报，不静默放过
    for d in $(manifest_deps); do
      [ -e "$PROFILE/node_modules/$d" ] || say "  警告：载荷缺少声明的依赖 $d"
    done
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
      const nl=text.includes("\r\n")?"\r\n":"\n";
      const lines=text.split(/\r?\n/);
      const out=[];let i=0;let dropped=0;
      while(i<lines.length){
        // 壳侧实际写入的头是 `# dsh-mobile-quarantine-v1 reason=loader-failure`，
        // 旧实现按 `dsh-mobile-quarantine-v1` 子串匹配 —— 那是对的（子串命中），
        // 但块内行数不是固定 3 行：有 name 时是 4 行、无 name 时是 3 行。
        // 用「marker 之后直到 disabled: true」做上界查找，避免把下一块吞掉。
        if(lines[i].includes("dsh-mobile-quarantine-v1")){
          const head=lines[i+1]||"";
          const isTarget=/^-\s+id:/.test(head)&&head.includes(id)&&
            (lines[i+2]||"").includes(name);
          if(isTarget){
            let j=i+1;
            while(j<Math.min(i+8,lines.length)&&!/^\s*disabled:\s*true\s*$/.test(lines[j]))j++;
            if(j<Math.min(i+8,lines.length)){
              i=j+1;while(i<lines.length&&lines[i].trim()==="")i++;
              dropped++;continue;
            }
          }
        }
        out.push(lines[i]);i++;
      }
      if(dropped===0){console.log("没有指向本插件的隔离标记");process.exit(0);}
      const rest=out.join(nl).replace(/(\n)+$/,"\n").trim();
      // 0 字节的 home patch 会让这一层组合失败（实测：删掉禁用行但留下空文件，插件仍不激活），
      // 所以清空到没有内容时直接删文件，回到「没有 home 层」的原状。
      if(rest===""){fs.unlinkSync(file);console.log("已清除 "+dropped+" 条隔离禁用行，并删除空的 home patch");}
      else{fs.writeFileSync(file,rest+nl);console.log("已清除 "+dropped+" 条隔离禁用行");}
    ' "$DSH_HOME/cordis.patch.yml" codearts-auth "$PKG"
  fi

  # 账本对齐：装完立刻把 pnpm 的两个清单写到与实装同版本。
  # 不做这一步的后果是**下一次 pnpm 触碰 profile 就静默降级**（见 README「已知掉线情形」）。
  cmd_lockfix >/dev/null 2>&1 && say "pnpm 账本已对齐到 $version"

  say ""
  say "下一步：在应用里刷新页面（或重启应用）即可看到 Jet Hub 设置入口；"
  say "        随后跑一次  bash \"$SELF/port.sh\" verify  做体检。"
}

# 把 pnpm 的三个账本（profile 锁 + .modules.yaml + 虚拟仓库锁）对齐到实装版本。
# 逻辑放在 lockfix.mjs：正则里全是引号与反斜杠，内联进 bash 会被引用层吃掉一层，
# 实测直接把正则打坏成 “Nothing to repeat”。独立文件还能单独跑、单独测。
# 幂等；只改与本插件相关的行。
cmd_lockfix() {
  need_runtime
  local version
  version=$("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json" 2>/dev/null) || die "插件未安装，先跑 install"
  [ -f "$SELF/lockfix.mjs" ] || die "缺少 lockfix.mjs（kit 不完整）"
  local integ
  integ=$("$NODE" -e 'const m=require(process.argv[1]);console.log((m.package&&m.package.integrity)||"-")' "$MANIFEST" 2>/dev/null)
  [ -n "$integ" ] || integ=-
  "$NODE" "$SELF/lockfix.mjs" "$PROFILE" "$PKG" "$version" "$integ" || die "对齐 pnpm 账本失败"
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
  for d in $PKG_DEPS; do
    if [ -e "$PROFILE/node_modules/$d" ]; then say "  PASS  依赖 $d"; else say "  FAIL  缺少依赖 $d"; fail=1; fi
  done
  # 原生绑定必须与设备 ABI 对得上：Android arm64 包只对本机 arm64 有效
  local abi; abi=$(getprop ro.product.cpu.abi 2>/dev/null)
  if [ -n "$abi" ]; then
    case "$abi" in
      arm64-v8a)
        if [ -f "$PROFILE/node_modules/@wreq-js/binding-android-arm64/wreq-js.android-arm64.node" ]; then
          say "  PASS  原生绑定匹配本机 ABI（$abi）"
        else
          say "  FAIL  ABI=$abi 但缺少 android-arm64 原生绑定"; fail=1
        fi ;;
      *) say "  WARN  本机 ABI=$abi，载荷只含 android-arm64 绑定" ;;
    esac
  fi

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
  # 依赖键版本要与实装版本一致：不一致时引擎按声明版本解析，出错信息会指向错误方向
  local declv instv
  instv=$("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json" 2>/dev/null)
  declv=$("$NODE" -e 'const j=require(process.argv[1]);console.log((j.dependencies||{})[process.argv[2]]||"")' "$PROFILE/package.json" "$PKG" 2>/dev/null)
  if [ "$declv" = "$instv" ]; then
    say "  PASS  声明的版本与实装一致（$instv）"
  else
    say "  FAIL  声明 $declv ≠ 实装 $instv（重跑 install）"; fail=1
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
  if ( cd "$PROFILE" && "$NODE" --input-type=module -e 'await import("dsh-providers-hub")' 2>"$DSH_HOME/port-backup/.port-import.err" ); then
    say "  PASS  import('dsh-providers-hub') 成功（apply/inject 可被宿主装载）"
  else
    say "  FAIL  模块导入失败："; sed 's/^/        /' "$DSH_HOME/port-backup/.port-import.err" 2>/dev/null | head -8; fail=1
  fi
  [ ${#linked[@]} -gt 0 ] && rm -f "${linked[@]}"

  # 原生绑定真的能 dlopen：import 成功不代表 .node 可加载（.node 只在调用到时才 require）
  if ( cd "$PROFILE" && "$NODE" --input-type=module -e 'await import("wreq-js")' >/dev/null 2>&1 ); then
    say "  PASS  原生绑定 wreq-js 可加载（dlopen 成功）"
  else
    say "  FAIL  wreq-js 原生绑定加载失败（ABI/权限/ELF 载入被拒）"; fail=1
  fi

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
        const hit=rows.filter(r=>(r.entryId||"").includes("codearts-auth")||r.moduleName==="dsh-providers-hub");
        if(!hit.length){console.log("  FAIL  引擎装配里没有 codearts-auth 行（bundles 选择丢了？重跑 install）");process.exit(1);}
        const r=hit[0];
        const ok=r.enabled&&r.fiberPhase==="active";
        console.log("  "+(ok?"PASS":"FAIL")+"  "+r.entryId+" → "+r.moduleName+" enabled="+r.enabled+" fiber="+r.fiberPhase);
        if(r.version)console.log("        moduleVersion="+r.version);
        process.exit(ok?0:1);
      });
    '; then :; else
      say "  FAIL  引擎里没有活跃的 codearts-auth/providers-hub 行（刷新页面或重启应用后再试）"; fail=1
    fi
  else
    say "  SKIP  读不到引擎 cookie（$pref），跳过运行态检查"
  fi

  say "== 5. 客户端产物与磁盘一致（引擎服的是不是刚装的那份）=="
  # 这一项为什么必须有（设备实测，不是推演）：
  # 引擎在**启动时**读一次 client bundle，把 mtime/ctime/size 记成 artifactRevision 缓存在内存里
  # （dsh-client-modules 的 rebuilt/artifactRevision）。port.sh 换掉磁盘文件后，**正在运行的引擎
  # 仍旧服旧包**，且 pluginManager/listPlugins 一切正常、import() 也成功 —— 第 1/2/3/4 段全绿，
  # 只有浏览器里看到的是上一版的界面。实测：磁盘 2.21（999429 字节、含 marvis），引擎服 2.20
  # （984665 字节、marvis 零命中）。判据只能取自**引擎自己的应答**：boot manifest 里该条的 rev
  # 必须等于磁盘产物的 artifactRevision。
  local served_rev disk_rev
  disk_rev=$("$NODE" -e '
    const fs=require("node:fs"),c=require("node:crypto");
    const p=process.argv[1];
    const st=fs.statSync(p);
    const h=c.createHash("sha1").update("plugin-artifact").update("\0");
    for(const s of [String(st.mtimeMs),String(st.ctimeMs),String(st.size)]) h.update(`${Buffer.byteLength(s)}:`).update(s);
    console.log(h.digest("hex").slice(0,12));
  ' "$PROFILE/node_modules/$PKG/lib/client/jet-hub.js" 2>/dev/null)
  if [ -n "$cookie" ] && [ -n "$disk_rev" ]; then
    served_rev=$("$NODE" -e '
      const http=require("node:http");
      const [port,cookie,name]=process.argv.slice(1);
      const req=http.request({host:"127.0.0.1",port:Number(port),path:"/",method:"GET",headers:{cookie:cookie}},res=>{
        let d="";res.on("data",c=>d+=c);res.on("end",()=>{
          const m=d.match(new RegExp("\"id\":\""+name.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")+"\"[^}]*?\"rev\":\"([0-9a-f]+)\""));
          process.stdout.write(m?m[1]:"");
        });
      });
      req.on("error",()=>{});
      req.end();
    ' "$port" "$cookie" "$PKG" 2>/dev/null)
    if [ -z "$served_rev" ]; then
      say "  WARN  读不到引擎 boot manifest 里本条的 rev，跳过（不影响文件面结论）"
    elif [ "$served_rev" = "$disk_rev" ]; then
      say "  PASS  引擎服的是磁盘上这份（rev=$disk_rev）"
    else
      say "  FAIL  引擎服 rev=$served_rev，磁盘是 rev=$disk_rev —— 磁盘已换但引擎仍在服旧包。"
      say "        引擎只在启动时缓存 client bundle，**重启应用**后才更新（刷新页面不够）。"
      say "        界面会显示上一版；功能面（fiber/网关）不受影响。"
      fail=1
    fi
  else
    say "  SKIP  缺 cookie 或读不到磁盘产物，跳过"
  fi

  say "== 6. 本地网关（默认 127.0.0.1:8326）=="
  local gw=$("$NODE" -e '
    const http=require("node:http");
    const req=http.request({host:"127.0.0.1",port:8326,path:"/v1/models",method:"GET",timeout:3000},res=>{
      let d="";res.on("data",c=>d+=c);res.on("end",()=>{console.log(res.statusCode+" "+d.slice(0,120));});
    });
    req.on("error",e=>{console.log("ERR "+e.code);});
    req.on("timeout",()=>{req.destroy();console.log("ERR timeout");});
    req.end();
  ' 2>/dev/null)
  case "$gw" in
    401*|200*) say "  PASS  网关在监听（$gw）" ;;
    ERR*) say "  WARN  网关未监听（$gw）——若日志里有 EADDRINUSE，说明 8326 被别的程序占用；"
          say "        可在 Jet Hub 的网关设置里改端口，或先停掉占用者。" ;;
    *) say "  WARN  网关状态未知：$gw" ;;
  esac
  grep -q "openai-gateway.*EADDRINUSE" "$FILES/engine.log" 2>/dev/null && \
    say "  WARN  engine.log 里有网关端口冲突记录（EADDRINUSE 8326）"

  say "== 7. pnpm 账本一致性 =="
  local lv
  lv=$("$NODE" -e '
    const fs=require("node:fs");
    try{
      const t=fs.readFileSync(process.argv[1],"utf8");
      const re=new RegExp("^\\s{6}"+process.argv[2].replace(/[.*+?^${}()|[\]\\]/g,"\\$&")+":\\s*$[\\s\\S]{0,200}?^\\s{8}version:\\s*(\\S+)\\s*$","m");
      const m=t.match(re);console.log(m?m[1]:"(未登记)");
    }catch(e){console.log("(无 lockfile)")}
  ' "$PROFILE/pnpm-lock.yaml" "$PKG" 2>/dev/null)
  if [ "$lv" = "$instv" ]; then
    say "  PASS  pnpm-lock.yaml 与实装同版本（$lv）"
  else
    say "  FAIL  pnpm-lock.yaml 记的是 $lv，实装 $instv —— 跑 lockfix（否则 pnpm 重装会静默降级）"; fail=1
  fi
  local mv
  mv=$("$NODE" -e '
    const fs=require("node:fs");
    try{
      const t=fs.readFileSync(process.argv[1],"utf8");
      const re=new RegExp("^\\s{2}"+process.argv[2].replace(/[.*+?^${}()|[\]\\]/g,"\\$&")+"@([^:\\s]+):","m");
      const m=t.match(re);console.log(m?m[1]:"(未登记)");
    }catch(e){console.log("(无 .modules.yaml)")}
  ' "$PROFILE/node_modules/.modules.yaml" "$PKG" 2>/dev/null)
  if [ "$mv" = "$instv" ]; then
    say "  PASS  node_modules/.modules.yaml 与实装同版本（$mv）"
  else
    say "  FAIL  .modules.yaml 记的是 $mv，实装 $instv —— 跑 lockfix"; fail=1
  fi

  # 同源缺陷的另两个受害者：手工铺的包天生活在 lockfile 之外。
  # 本插件已对齐，但 dsh-purge-community / dsh-memento / @napi-rs/canvas 同样声明在
  # package.json 里、同样不在 lockfile 的 importers 段。任何一次 pnpm install 都会把它们
  # 当成「多余的包」删掉（pnpm 以 lockfile 为目标状态做 prune），且不报错。
  # 本段只**报**不修：补 importer 条目却缺 packages/snapshots（integrity、依赖解析链）
  # 会让 pnpm 解析失败或自行编造，比不补更危险 —— 那种补法必须由各包自己的 port 脚本
  # 按自身 manifest 完成。这里让它可见，别在无知觉的情况下丢掉别的插件。
  say "== 8. 其余手工移植包的账本状态（同源缺陷，只报不修）=="
  if [ -f "$SELF/lockfix.mjs" ]; then
    local scan
    scan=$("$NODE" "$SELF/lockfix.mjs" "$PROFILE" --scan 2>/dev/null)
    if [ -z "$scan" ]; then
      say "  SKIP  扫描失败"
    elif printf '%s' "$scan" | grep -q "absent"; then
      say "  WARN  下列包实装但不在 pnpm 账本里——点一次「插件」页就可能被 prune 掉："
      printf '%s\n' "$scan" | grep "absent" | sed 's/^/      /'
      say "        修法：各自跑自己的 port 脚本（port/dsh-purge、port/dsh-memento 等）。"
      say "        本项不判 FAIL：它不影响 Jet Hub 的可用性，但**会**影响那几个插件。"
    elif printf '%s' "$scan" | grep -q "drift"; then
      say "  FAIL  有声明包与锁版本不符，跑 lockfix"; fail=1
    else
      say "  PASS  全部声明包与锁一致"
    fi
  else
    say "  SKIP  缺 lockfix.mjs"
  fi

  say ""
  if [ "$fail" = 0 ]; then say "结论：移植在位且运行态正常。"; else say "结论：有检查项失败，先跑 install 修复，再复查。"; fi
  return "$fail"
}

cmd_uninstall() {
  local purge=0
  for a in "$@"; do [ "$a" = "--purge" ] && purge=1; done
  need_runtime
  local backup=$DSH_HOME/port-backup/uninstall-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  cp "$PROFILE/package.json" "$backup/package.json" 2>/dev/null || true
  "$NODE" -e '
    const fs=require("node:fs");
    const [file,name]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    if(j.dependencies)delete j.dependencies[name];
    const b=((j.dsh||{}).profile||{}).bundles;
    if(Array.isArray(b))j.dsh.profile.bundles=b.filter(x=>x!==name);
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
  ' "$PROFILE/package.json" "$PKG" || die "改 package.json 失败"
  for d in $PKG $PKG_DEPS; do rm -rf "$PROFILE/node_modules/$d"; done
  rm -rf "$PROFILE/node_modules/@wreq-js"
  rm -f "$STATE"
  if [ "$purge" = 1 ]; then rm -rf "$DSH_HOME/jet-hub" "$DSH_HOME/openai-gateway"; fi
  say "已卸载（profile 清单已回滚，备份在 $backup）；刷新页面或重启应用生效。"
  [ "$purge" = 1 ] && say "账号/网关状态已按 --purge 删除。"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  status) shift; cmd_status "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  lockfix) shift; cmd_lockfix "$@" ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
