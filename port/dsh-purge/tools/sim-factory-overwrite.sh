#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# sim-factory-overwrite.sh —— 「上游/快照覆盖后插件不丢」的隔离验收演练
#
# 证明：APK 快照刷新（= dsh 运行时树被整体换新、68 个宿主补丁全丢）之后，
#       dsh-purge 的启动自愈能把整棵树重新清洗回与真身逐条一致的状态。
#
# 覆盖范围要按真实来：补丁落点有三处（不是只有 @deepseek-ai）——
#   node_modules/@deepseek-ai/*     62 个 .bak
#   node_modules/@earendil-works/pi-ai  3 个（#47/#49/#57，Anthropic/DeepSeek role）
#   config/agent-presets            3 个
# 所以演练场复制的是**整个 dsh 包**，不是子集（子集会假报 na，见 2026-11-10 实测）。
#
# 隔离手段（四路重定向，真实宿主与真实引擎零写盘）：
#   DSH_BASE → 副本插件根   instance.js:230/310 显式选择器；enumeratePatchAiBases
#                          见到它立即收敛为单一宿主，不再扫描其它安装
#   DSH_HOME → 副本 home    戳、审计、prompt-inject 全落副本
#   HOME     → 副本 home    guessedPrefixDirs 走 os.homedir()
#   PATH     → 副本 bin     findShimDir 取 PATH 里第一个带 dsh 启动器的目录
#
# 坑（实测）：不能用 `env -i`。净化环境后本域 app 的 exec 被 SELinux 判成跨域
# 拒绝（连 /system/bin/ls / 都 EACCES）；只做定向覆盖则正常。
#
# 用法：bash tools/sim-factory-overwrite.sh [--keep]
# ============================================================================
set -u

HOST_D=/data/data/com.dsharnessmobile.shell/files/usr/lib/node_modules/@deepseek-ai/dsh
HOST_REAL="$HOST_D/node_modules/@deepseek-ai"
REAL_HOME=/data/user/0/com.dsharnessmobile.shell/files/home/.dsh
NODE=$(command -v node)
PKG="$REAL_HOME/profiles/web/node_modules/dsh-purge-community"
SIM="$REAL_HOME/port-backup/sim-factory"
SIM_D="$SIM/dsh"
SIM_HOME="$SIM/home"
SIM_BASE="$SIM_D/node_modules/@deepseek-ai"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

say() { printf '%s\n' "$*"; }
hr() { say "------------------------------------------------------------"; }

# 只做定向覆盖，绝不用 env -i（见头注）
run_sim() { # run_sim <js> [args...]
  env -u DSH_WORKSPACE -u DSH_SESSION_ID -u DSH_WRITE_MODE -u DSH_PROFILE_DIR -u DSH_WEB_URL \
    PATH="$SIM/bin:/system/bin" HOME="$SIM_HOME" DSH_HOME="$SIM_HOME" \
    DSH_BASE="$SIM_BASE" DSH_PROFILE=web TMPDIR="$SIM_HOME" \
    "$NODE" "$@"
}
run_real() { # 真身只读侧
  env -u DSH_WORKSPACE -u DSH_SESSION_ID -u DSH_WRITE_MODE -u DSH_PROFILE_DIR -u DSH_WEB_URL \
    PATH="$SIM/bin:/system/bin" HOME="$REAL_HOME" DSH_HOME="$REAL_HOME" \
    DSH_BASE="$HOST_REAL" DSH_PROFILE=web TMPDIR="$REAL_HOME" \
    "$NODE" "$@"
}
sim_selfcheck() { run_sim "$PKG/bin/community.js" selfcheck --json 2>>"$SIM/err.log"; }

hr; say "dsh-purge 工厂覆盖 / 自愈 隔离演练"
say "宿主真身 : $HOST_REAL"
say "演练场   : $SIM_D"
hr

say "[1/6] 重建演练场（整装复制 dsh 包）…"
rm -rf "$SIM"; mkdir -p "$SIM_HOME" "$SIM/bin"
cp -a "$HOST_D" "$SIM_D" || { say "复制失败"; exit 1; }
printf '#!/bin/sh\nexit 0\n' > "$SIM/bin/dsh"; chmod 755 "$SIM/bin/dsh"
mkdir -p "$SIM_HOME/profiles/web" "$SIM_HOME/.agent-presets"
cp -a "$REAL_HOME/profiles/web/package.json"      "$SIM_HOME/profiles/web/" 2>/dev/null
cp -a "$REAL_HOME/profiles/web/cordis.patch.yml"  "$SIM_HOME/profiles/web/" 2>/dev/null
cp -a "$REAL_HOME/.agent-presets/."               "$SIM_HOME/.agent-presets/" 2>/dev/null
# prompt-inject.md 是 selfcheck「运行时提示词注入」层的判据（selfcheck.js:221-234）：
# 缺了它，即使补丁 71/72 全对齐，state 也会是 broken。属演练场缺件，不是自愈缺陷。
cp -a "$REAL_HOME/prompt-inject.md"               "$SIM_HOME/" 2>/dev/null
say "      ok：$(du -sh "$SIM_D" 2>/dev/null | cut -f1)；home 面已镜像"

say "[2/6] 模拟工厂覆盖：还原 .bak 原文 + 删除 .bak（三处落点全算）"
n=0
while IFS= read -r b; do cp -f "$b" "${b%.dshpurge.bak}"; rm -f "$b"; n=$((n + 1)); done \
  < <(find "$SIM_D" -name '*.dshpurge.bak' 2>/dev/null)
mk=$(grep -rl '\[dsh-purge\]' "$SIM_D" --include=*.js --include=*.yml 2>/dev/null | wc -l)
say "      还原 $n 个文件（真身共 68）；残留标记文件 $mk 个（应为 0）"

say "[3/6] 覆盖后自检"
SC1=$(sim_selfcheck); printf '%s' "$SC1" > "$SIM/selfcheck-before.json"
printf '%s' "$SC1" | "$NODE" -e '
  let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
    let j;try{j=JSON.parse(d)}catch(e){console.log("  解析失败");process.exit(0)}
    const p=j.patch||{};
    console.log("  state="+j.state+"  ok="+j.ok+"  applied="+p.applied+"/"+p.total+"  na="+p.na);
  });'

say "[4/6] 走启动自愈（reapply-cli = 引擎启动时 settle 调的同一入口）"
RA=$(run_sim "$PKG/lib/reapply-cli.js" 2>&1); say "      $RA"

say "[4b/6] 补一次完整 Apply（preserveClientBundles=false）"
say "        启动自愈对 watched client bundle 一律跳过（reapply.js:319/335 + core.js:2697-2705，"
say "        理由是不动前端 client.js 的 mtime，#63）→ #56/#77 会停在 pending，必须补这一刀。"
say "        另注：不能走 community.js 的 LEGACY 转发——execPath=linker64 会让它变成"
say "        linker64 dsh-purge.js → bad ELF magic:23212f75；直接调目标脚本。"
FA=$(run_sim "$PKG/bin/dsh-purge.js" --apply 2>&1 | tail -3); say "      $FA"

say "[5/6] 自愈后自检 + 与真身逐条比对"
SC2=$(sim_selfcheck); printf '%s' "$SC2" > "$SIM/selfcheck-after.json"
printf '%s' "$SC2" | "$NODE" -e '
  let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
    let j;try{j=JSON.parse(d)}catch(e){console.log("  解析失败");process.exit(0)}
    const p=j.patch||{};
    console.log("  state="+j.state+"  ok="+j.ok+"  level="+j.level+"  applied="+p.applied+"/"+p.total+
                "  missing_file="+p.missing_file+" partial="+p.partial+" off="+p.off);
    console.log("  层: 宿主 "+(j.summary&&j.summary.host?j.summary.host.passed+"/"+j.summary.host.total:"?"));
  });'
PROBE=/storage/emulated/0/Download/DSH/破甲移植/port-kit/tools/probe-states.mjs
if [ -f "$PROBE" ]; then
  run_sim  "$PROBE" > "$SIM/states-sim.json"  2>>"$SIM/err.log"
  run_real "$PROBE" > "$SIM/states-real.json" 2>>"$SIM/err.log"
  "$NODE" -e '
    const fs=require("fs");
    const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8")).states;
    const b=JSON.parse(fs.readFileSync(process.argv[2],"utf8")).states;
    const cnt=o=>Object.values(o).reduce((m,v)=>(m[v]=(m[v]||0)+1,m),{});
    console.log("  演练场: "+JSON.stringify(cnt(a)));
    console.log("  真身  : "+JSON.stringify(cnt(b)));
    const ids=[...new Set([...Object.keys(a),...Object.keys(b)])].map(Number).sort((x,y)=>x-y);
    const diff=ids.filter(i=>a[i]!==b[i]);
    if(!diff.length) console.log("  [OK] 逐条状态与真身完全一致，差异 0");
    else { console.log("  [NG] 差异 "+diff.length+" 条:"); diff.forEach(i=>console.log("     #"+i+"  演练场="+a[i]+"  真身="+b[i])); }
  ' "$SIM/states-sim.json" "$SIM/states-real.json"
  mk2=$(grep -rl '\[dsh-purge\]' "$SIM_D" --include=*.js --include=*.yml 2>/dev/null | wc -l)
  say "      自愈后标记文件 $mk2 个（真身基线 46）"
fi

say "[6/6] 真身未被触碰校验（基线按**整个 dsh 包**算：46 标记 / 68 bak）"
say "      标记文件 $(grep -rl '\[dsh-purge\]' "$HOST_D" --include=*.js --include=*.yml 2>/dev/null | wc -l) 个（基线 46）；.bak $(find "$HOST_D" -name '*.dshpurge.bak' 2>/dev/null | wc -l) 个（基线 68）"

if [ "$KEEP" -eq 0 ]; then say "清理演练场（--keep 保留）…"; rm -rf "$SIM_D"; fi
hr; say "演练结束：结论看第 5 段是否「差异 0」。"
