// 逐条补丁状态探针（只读）。用于比对「真身」与「演练场」的 patchStatus 差集。
// 用法：DSH_BASE=<插件根> DSH_HOME=<home> node tools/probe-states.mjs
import * as core from "/data/user/0/com.dsharnessmobile.shell/files/home/.dsh/profiles/web/node_modules/dsh-purge-community/lib/core.js";

core.applyRuntimeEnv();
const base = core.findAiBase();
if (!base) { console.log(JSON.stringify({ base: null, error: "未定位插件根" })); process.exit(1); }
const st = await core.patchStatus(base);
console.log(JSON.stringify({ base, states: st }));
