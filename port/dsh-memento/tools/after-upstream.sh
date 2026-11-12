#!/bin/bash
# ============================================================================
# after-upstream.sh —— 拉上游提交之后的移植件守卫（**只读，不写盘**）
#
# 由 githooks/post-merge、githooks/post-checkout 调用。检查三件事：
#   ① 移植件完整性：payload.tar.gz 的 sha256 是否仍与 manifest.json 一致
#      （仓库里的 kit 不背载荷，载荷缺席时本段打印 SKIP —— 见 §载荷约定）
#   ② profile 装配是否还在（插件包 / dependencies 键 / bundles 选择 / bundle patch）
#   ③ 引擎内 fiber 是否活跃（能读到引擎 cookie 时）
#
# 只报不修是刻意的：拉代码 ≠ 装 APK。真正需要修复的时机是「新 APK 装完」，
# 那时跑 tools/guard.sh（或 bash port.sh install --force）。本脚本绝不改工作区。
#
# 退出码恒为 0（不阻断 git 操作）。用 DSH_PORT_GUARD_STRICT=1 可改成失败即非零。
# ============================================================================
set -u

STRICT=${DSH_PORT_GUARD_STRICT:-0}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)      # .../port/dsh-memento/tools
KIT=$(cd -- "$HERE/.." && pwd)                 # .../port/dsh-memento

FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -d "$FILES/home" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
DSH_HOME=${DSH_HOME:-$FILES/home/.dsh}
PROFILE=$DSH_HOME/profiles/web
PKG=dsh-memento
NODE=$(command -v node 2>/dev/null || true)
[ -n "$NODE" ] || NODE=$FILES/usr/bin/node

ok=0
say() { printf '  %s\n' "$*"; }
bad() { printf '  [!] %s\n' "$*"; ok=1; }

printf '\n[dsh-memento 移植件守卫] 拉取后自检\n'

# ── ① 移植件完整性 ──
if [ -f "$KIT/manifest.json" ] && [ -f "$KIT/payload.tar.gz" ]; then
  want=$("$NODE" -e 'const m=require(process.argv[1]);console.log(m.payload?.sha256||"")' "$KIT/manifest.json" 2>/dev/null)
  have=$(sha256sum "$KIT/payload.tar.gz" 2>/dev/null | cut -d' ' -f1)
  if [ -n "$want" ] && [ "$want" = "$have" ]; then
    say "① 载荷 sha256 与 manifest 对齐"
  else
    bad "① 载荷 sha256 不一致（manifest: ${want:-空} / 实际: ${have:-空}）"
  fi
elif [ -f "$KIT/manifest.json" ]; then
  say "① SKIP 载荷缺席（仓库约定不背载荷；需要时跑 fetch-payload.sh --pack 重建）"
  if [ ! -f "$KIT/fetch-payload.sh" ]; then
    bad "① 既无载荷也无 fetch-payload.sh —— 换机后无法重建"
  fi
else
  bad "① 缺 manifest.json"
fi

# ── ①b 移植链（上游基线 → 补丁 → overlay → payload → 已装副本）──
# 只核 payload.tar.gz 的 sha 是不够的：它只能证明「这份载荷没被改坏」，
# 证明不了「这份载荷确实是上游 + 本 kit 的补丁」（旧版重建路径就是在这一步悄悄丢补丁的）。
if [ -f "$KIT/tools/verify-overlay.mjs" ]; then
  if out=$("$NODE" "$KIT/tools/verify-overlay.mjs" 2>&1); then
    say "①b 移植链四段对齐（上游基线/补丁/overlay/payload/已装副本）"
  else
    bad "①b 移植链核对失败："
    printf '%s\n' "$out" | sed 's/^/        /' | grep -E 'FAIL|错误|Error' | head -6
  fi
else
  say "①b SKIP 无 tools/verify-overlay.mjs（旧版 kit：无法证明载荷含本地补丁）"
fi

# ── ② profile 装配 ──
if [ -f "$PROFILE/node_modules/$PKG/package.json" ]; then
  v=$("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json" 2>/dev/null || echo unreadable)
  say "② 插件包在位：$PKG@$v"
else
  bad "② 插件包缺失：$PROFILE/node_modules/$PKG（跑 port.sh install）"
fi
[ -f "$PROFILE/node_modules/$PKG/cordis.patch.yml" ] || bad "② 缺 bundle patch（cordis.patch.yml）"
if [ -f "$PROFILE/package.json" ]; then
  if "$NODE" -e '
    const fs=require("node:fs");
    const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const n=process.argv[2];
    process.exit((j.dependencies||{})[n] && (((j.dsh||{}).profile||{}).bundles||[]).includes(n) ? 0 : 1);
  ' "$PROFILE/package.json" "$PKG" 2>/dev/null; then
    say "② 装配在位：dependencies.$PKG + dsh.profile.bundles 选择"
  else
    bad "② 装配漂移（依赖键或 bundles 选择丢失）→ 跑 port.sh install"
  fi
else
  bad "② 找不到 $PROFILE/package.json"
fi

# ── ③ 引擎内 fiber（只读探测，读不到就 SKIP）──
pref=/data/data/com.dsharnessmobile.shell/shared_prefs/dsh_engine_auth.xml
cookie=""
[ -f "$pref" ] && cookie=$("$NODE" -e '
  const s=require("node:fs").readFileSync(process.argv[1],"utf8");
  const m=s.match(/name="cookie">([^<]+)</);if(!m)process.exit(1);console.log(m[1]);
' "$pref" 2>/dev/null)
port=$("$NODE" -e 'try{console.log(require(process.argv[1]).port)}catch(e){}' "$FILES/.engine-endpoint.json" 2>/dev/null)
[ -n "$port" ] || port=4145
if [ -n "$cookie" ]; then
  body=$("$NODE" -e '
    const http=require("node:http");
    const [port,cookie]=process.argv.slice(1);
    const payload=JSON.stringify({type:"client-request",rpcId:"after-upstream",method:"pluginManager/listPlugins",payload:{args:{}}});
    const req=http.request({host:"127.0.0.1",port:Number(port),path:"/api/pluginManager/listPlugins",method:"POST",headers:{"content-type":"application/json",cookie:cookie,"content-length":Buffer.byteLength(payload)}},res=>{
      let d="";res.on("data",c=>d+=c).on("end",()=>process.stdout.write(d));
    });
    req.on("error",()=>process.exit(1));
    req.end(payload);
  ' "$port" "$cookie" 2>/dev/null)
  if printf '%s' "$body" | grep -q '"dsh-memento"'; then
    phase=$(printf '%s' "$body" | "$NODE" -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        const j=JSON.parse(d);const rows=(j.result&&j.result.value)||[];
        const r=rows.find(x=>x.moduleName==="dsh-memento");
        console.log(r?(r.entryId+" enabled="+r.enabled+" fiber="+r.fiberPhase):"未找到");
      });
    ' 2>/dev/null)
    if printf '%s' "$phase" | grep -q "fiber=active"; then
      say "③ 引擎内 fiber 活跃：$phase"
    else
      bad "③ 引擎内 fiber 不活跃：$phase（重启应用后再看）"
    fi
  else
    say "③ SKIP 引擎未应答 memento 行（应用没起或刚装完未重启）"
  fi
else
  say "③ SKIP 读不到引擎 cookie"
fi

printf '\n'
if [ "$ok" = 0 ]; then
  printf '自检通过：移植件与设备装配一致。\n'
else
  printf '自检发现问题（上面标 [!] 的项）。修复：bash %s/port.sh install --force\n' "$KIT"
fi

[ "$STRICT" = 1 ] && exit "$ok"
exit 0
