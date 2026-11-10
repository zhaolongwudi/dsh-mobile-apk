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
  local cache=$SELF/.unpacked
  if [ -d "$cache/node_modules/$PKG" ]; then printf '%s' "$cache"; return 0; fi
  local archive=$SELF/payload.tar.gz
  [ -f "$archive" ] || die "缺少离线载荷：$archive"
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
    const fs=require("node:fs");const [f,n]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(f,"utf8"));
    const dep=(j.dependencies||{})[n]||"(缺少)";
    const b=((j.dsh||{}).profile||{}).bundles||[];
    console.log("dep key      : "+dep);
    console.log("bundles      : "+(b.includes(n)?"已登记 ("+b.length+" 项)":"未登记 ("+b.length+" 项)"));
  ' "$PROFILE/package.json" "$PKG" 2>/dev/null || say "package.json : 无法解析"
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

  if [ "$force" = 0 ] && [ -f "$STATE" ] && grep -q "\"version\":\"$version\"" "$STATE" 2>/dev/null; then
    say "文件已是 $version，跳过重铺（--force 可强制）"
  else
    say "铺设插件文件到 profile/node_modules ..."
    mkdir -p "$PROFILE/node_modules"
    cp -R "$payload/node_modules/." "$PROFILE/node_modules/" || die "复制插件文件失败"
    printf '%s\n' "$stamp" > "$STATE"
    say "文件落位完成：$version"
  fi

  "$NODE" -e '
    const fs=require("node:fs");
    const [file,name,version]=process.argv.slice(1);
    const j=JSON.parse(fs.readFileSync(file,"utf8"));
    j.dependencies=j.dependencies||{};
    j.dependencies[name]=j.dependencies[name]||version;
    j.dsh=j.dsh||{}; j.dsh.profile=j.dsh.profile||{};
    const b=Array.isArray(j.dsh.profile.bundles)?j.dsh.profile.bundles:[];
    if(!b.includes(name)) b.push(name);
    j.dsh.profile.bundles=b;
    fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n");
    console.log("装配已登记：dependencies."+name+"；dsh.profile.bundles 共 "+b.length+" 项");
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
  DSH_BASE="$host" DSH_HOME="$DSH_HOME" HOME="$HOME_DIR" PATH="$FILES/usr/bin:$PATH" \
    "$NODE" "$PROFILE/node_modules/$PKG/bin/community.js" apply || die "apply 失败"
  say "== permission 预设固定 =="
  ensure_pin
  say ""
  say "补丁已写入磁盘；重启 dsh（或点面板「应用」后的提示）后完全生效。"
}

cmd_revert() {
  need_runtime
  local host; host=$(host_base) || die "未定位宿主 @deepseek-ai 目录"
  DSH_BASE="$host" DSH_HOME="$DSH_HOME" HOME="$HOME_DIR" PATH="$FILES/usr/bin:$PATH" \
    "$NODE" "$PROFILE/node_modules/$PKG/bin/community.js" revert || die "revert 失败"
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
  if jq_node '
    const j=require(process.argv[1]);const n=process.argv[2];
    const dep=(j.dependencies||{})[n];const b=((j.dsh||{}).profile||{}).bundles||[];
    if(!dep||!b.includes(n))process.exit(1);
  ' "$PROFILE/package.json" "$PKG" 2>/dev/null; then say "  PASS  依赖键与 dsh.profile.bundles 都在"
  else say "  FAIL  装配缺项（重跑 install）"; fail=1; fi

  say "== 3. 模块可加载 =="
  if ( cd "$PROFILE" && "$NODE" --input-type=module -e "await import('$PKG')" 2>"$DSH_HOME/port-backup/.purge-import.err" ); then
    say "  PASS  import('$PKG') 成功"
  else say "  FAIL  模块导入失败："; sed 's/^/        /' "$DSH_HOME/port-backup/.purge-import.err" | head -8; fail=1; fi

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
  if [ "$tag" = "v$(kit_version)" ]; then say "已是最新，无需同步。"; return 0; fi
  [ "$check" = 1 ] && { say "（--check：只查不下载）"; return 0; }
  [ -n "$url" ] || die "该 release 没有 dsh-purge-community tgz 资产"
  local tmp=$SELF/.sync; rm -rf "$tmp"; mkdir -p "$tmp"
  say "下载 $url"
  curl -sSL --max-time 300 -o "$tmp/plugin.tgz" "$url" || die "下载失败"
  if [ -n "$sha" ]; then
    local got; got=$(sha256sum "$tmp/plugin.tgz" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || die "SHA-256 校验失败（期望 $sha，实得 $got）"
    say "SHA-256 校验通过"
  fi
  rm -rf "$SELF/payload/node_modules/$PKG"
  tar xzf "$tmp/plugin.tgz" -C "$tmp" || die "解包失败"
  mv "$tmp/package" "$SELF/payload/node_modules/$PKG" || die "无法替换载荷目录"
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
