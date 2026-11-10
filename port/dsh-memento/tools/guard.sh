#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# guard.sh —— dsh-memento 移植件守卫（体检 → 漂移就重铺 → 复核 → 记日志）
#
# 与 port/dsh-purge 的 guard.sh 分工完全相同（「在覆盖发生的那一瞬间就发现」），
# 但**守的东西不同**：dsh-memento 是纯 JS 插件，不改宿主运行时树，
# 所以没有「86 条宿主补丁需要重打」这回事。本脚本守的是落在
# app 私有数据里的**三处落点**：
#   ① $PROFILE/node_modules/dsh-memento/          插件包本体
#   ② $PROFILE/package.json                       dependencies 键 + dsh.profile.bundles 选择
#   ③ 模块可加载性 + 引擎内 fiber 活性
#
# 依据（dsh-mobile-apk 源码实测）：
#   · SnapshotTransaction.mergeTree()：只遍历**工厂侧**子项递归，live 独有项（我们的
#     插件目录）永不被删 ⇒ ① 天然存活。
#   · ProfilePackageManifest.merge()：`return user.toString(2)` —— 以用户清单为基座，
#     工厂件只补「用户没有的键」⇒ ② 天然存活。
#   · SnapshotFs/SnapshotUserData：未知 `.dsh` 冲突项默认保留 ⇒ memory.db 存活。
# 既然三处都是**合并保留**，本守卫正常情况下应当**恒为干净**；一旦报漂移，
# 说明合并语义变了或有人手工动了 profile —— 那时脚本用**与 port.sh install 完全相同的
# 入口**补回去。
#
# 退出码：0 = 干净或已修复；1 = 需要人工介入。
# 用法：
#   bash guard.sh            # 体检，漂移则自动修复
#   bash guard.sh --dry      # 只体检，不写盘
#   bash guard.sh --quiet    # 只输出结论
# ============================================================================
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
KIT=$(cd -- "$SELF/.." 2>/dev/null && pwd || echo "$SELF")
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -d "$FILES/home" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
DSH_HOME=${DSH_HOME:-$FILES/home/.dsh}
PROFILE=$DSH_HOME/profiles/web
PKG=dsh-memento
NODE=${NODE:-$FILES/usr/bin/node}
LOG="$DSH_HOME/port-backup/memento-guard.log"

DRY=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --dry) DRY=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

mkdir -p "$(dirname "$LOG")"
stamp=$(date '+%F %T %z')
log() { printf '%s  %s\n' "$stamp" "$*" >> "$LOG"; }
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

[ -x "$NODE" ] || { echo "找不到 node：$NODE"; exit 1; }
[ -d "$PROFILE" ] || { echo "找不到 web profile：$PROFILE"; exit 1; }

drift=0
say "[dsh-memento 移植件守卫] $(date '+%F %T')"

# ── ① 插件包本体 ──
if [ -f "$PROFILE/node_modules/$PKG/package.json" ]; then
  v=$("$NODE" -e 'console.log(require(process.argv[1]).version)' "$PROFILE/node_modules/$PKG/package.json" 2>/dev/null || echo unreadable)
  say "  ① 插件包在位：$PKG@$v"
else
  say "  ① [!] 插件包缺失：$PROFILE/node_modules/$PKG"; drift=1; log "DRIFT 插件包缺失"
fi
[ -f "$PROFILE/node_modules/$PKG/cordis.patch.yml" ] || { say "  ① [!] 缺 bundle patch"; drift=1; }

# ── ② profile 装配（dependencies 键 + bundles 选择）──
if "$NODE" -e '
  const fs=require("node:fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const n=process.argv[2];
  const dep=(j.dependencies||{})[n];
  const b=((j.dsh||{}).profile||{}).bundles||[];
  process.exit(dep && b.includes(n) ? 0 : 1);
' "$PROFILE/package.json" "$PKG" 2>/dev/null; then
  say "  ② 装配在位：dependencies.$PKG + dsh.profile.bundles 选择"
else
  say "  ② [!] 装配漂移（依赖键或 bundles 选择丢了）"; drift=1; log "DRIFT 装配漂移"
fi

# ── ③ 模块可加载 ──
if ( cd "$PROFILE" && "$NODE" --input-type=module -e 'await import("dsh-memento")' 2>/dev/null ); then
  say "  ③ 模块可加载：import('dsh-memento') 成功"
else
  say "  ③ [!] 模块导入失败"; drift=1; log "DRIFT 模块导入失败"
fi

# ── ④ 引擎内 fiber ──
cookie=""
pref=/data/data/com.dsharnessmobile.shell/shared_prefs/dsh_engine_auth.xml
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
    const payload=JSON.stringify({type:"client-request",rpcId:"guard",method:"pluginManager/listPlugins",payload:{args:{}}});
    const req=http.request({host:"127.0.0.1",port:Number(port),path:"/api/pluginManager/listPlugins",method:"POST",headers:{"content-type":"application/json",cookie:cookie,"content-length":Buffer.byteLength(payload)}},res=>{
      let d="";res.on("data",c=>d+=c);res.on("end",()=>process.stdout.write(d));
    });
    req.on("error",()=>process.exit(1));
    req.end(payload);
  ' "$port" "$cookie" 2>/dev/null)
  if printf '%s' "$body" | grep -q '"dsh-memento"'; then
    phase=$(printf '%s' "$body" | "$NODE" -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        const j=JSON.parse(d);const rows=(j.result&&j.result.value)||[];
        const r=rows.find(x=>x.moduleName==="dsh-memento"||(x.entryId||"").includes("memento"));
        console.log(r?(r.entryId+" enabled="+r.enabled+" fiber="+r.fiberPhase):"未找到");
      });
    ' 2>/dev/null)
    if printf '%s' "$phase" | grep -q "fiber=active"; then
      say "  ④ 引擎内 fiber 活跃：$phase"
    else
      say "  ④ [!] 引擎内 fiber 不活跃：$phase"; drift=1; log "DRIFT fiber 不活跃: $phase"
    fi
  else
    say "  ④ [!] 引擎装配里没有 memento 行"; drift=1; log "DRIFT 引擎无 memento 行"
  fi
else
  say "  ④ SKIP 读不到引擎 cookie，跳过运行态检查"
fi

# ── 漂移则修复（用与 port.sh install 相同的入口，不另写一套逻辑）──
if [ "$drift" = 1 ]; then
  if [ "$DRY" = 1 ]; then
    say ""
    say "结论：检测到漂移（--dry 未修复）。修复方式：bash $KIT/port.sh install --force"
    log "DRIFT 检出（--dry），未写盘"
    exit 1
  fi
  say ""
  say "检测到漂移，调用 port.sh install --force 补回去 ..."
  if [ -f "$KIT/port.sh" ]; then
    if bash "$KIT/port.sh" install --force >/dev/null 2>&1; then
      log "REPAIR 已执行 port.sh install --force"
      # 复核
      if [ -f "$PROFILE/node_modules/$PKG/package.json" ] && "$NODE" -e '
        const fs=require("node:fs");
        const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        const n=process.argv[2];
        process.exit((j.dependencies||{})[n] && (((j.dsh||{}).profile||{}).bundles||[]).includes(n) ? 0 : 1);
      ' "$PROFILE/package.json" "$PKG" 2>/dev/null; then
        say "  修复完成（文件与装配已恢复）。若 ④ 仍不活跃，重启应用后重跑本脚本。"
        log "REPAIR OK"
        exit 0
      else
        say "  修复后复核仍不过 —— 需要人工介入。"
        log "REPAIR FAILED 复核不过"
        exit 1
      fi
    else
      say "  port.sh install --force 执行失败 —— 需要人工介入。"
      log "REPAIR FAILED port.sh 退出非零"
      exit 1
    fi
  else
    say "  找不到 $KIT/port.sh —— 需要人工介入。"
    log "REPAIR FAILED 缺 port.sh"
    exit 1
  fi
fi

say "结论：干净（三处落点全在位）"
exit 0
