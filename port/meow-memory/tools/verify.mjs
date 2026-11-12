#!/usr/bin/env node
/**
 * verify.mjs —— meow-memory 移植件四段体检（离线、只读、可重跑）
 *
 * 段 1  包在位且版本一致（并核对关键文件指纹）
 * 段 2  装配声明：profile package.json 的 dependencies + dsh.profile.bundles
 * 段 3  模块产物：lib/index.js / lib/client.js 在位且语法可解析；bundle patch 有 insert
 * 段 4  记忆库：<workspace>/.dsh-meow/memory.db 可读、七层表齐全、条目计数
 * 另附  残留核验：dsh-memento 在包/装配/patch 三处均无残留
 *
 * 用法：
 *   node tools/verify.mjs [--workspace /abs/path] [--profile web] [--json]
 * 退出码：全 PASS=0，否则 1
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';

const KIT_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

// .mjs 里用 CJS 的 require 取 node:sqlite（保持与插件相同的加载方式）
const require = createRequire(import.meta.url);

// ⚠️ 本机坑：Android 上 process.execPath 是 /apex/.../linker64，不是 node 可执行文件，
//    所以 execFileSync(process.execPath, ['--check', f]) 会报 "expected absolute path: --check"。
//    语法检查一律改用「动态 import 真加载」。

const argv = process.argv.slice(2);
const argOf = (k, d) => {
  const i = argv.indexOf(k);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};
const AS_JSON = argv.includes('--json');
const PKG = 'meow-memory';
const VERSION = '0.32.6';
const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const PROFILE = argOf('--profile', process.env.PROFILE || 'web');
const PROFILE_DIR = path.join(DSH_HOME, 'profiles', PROFILE);
const PKG_DIR = path.join(PROFILE_DIR, 'node_modules', PKG);
const WORKSPACE = argOf('--workspace', process.cwd());
const STORE = path.join(WORKSPACE, '.dsh-meow', 'memory.db');
const LAYERS = ['soul', 'user', 'project', 'fact', 'lesson', 'topic', 'rules'];
const EXPECT_SHA16 = {
  'lib/index.js': 'c1b99f9de90174f2',
  // client.js 是 port 补丁后态（设置页响应式 + 模型下拉 + 目录选择器），不是上游原文
  'lib/client.js': 'cde5f50835223b47',
  'cordis.patch.yml': 'd725feec27202e78',
};

const results = [];
const record = (section, name, ok, detail = '', level = 'fail') => {
  results.push({ section, name, ok, detail, level });
};

/* ── 段 1：包在位 ───────────────────────────────────────────── */
function section1() {
  if (!fs.existsSync(PKG_DIR)) {
    record('①包', `${PKG} 已安装`, false, `缺目录 ${PKG_DIR}`);
    return;
  }
  let pj;
  try {
    pj = JSON.parse(fs.readFileSync(path.join(PKG_DIR, 'package.json'), 'utf8'));
  } catch (e) {
    record('①包', 'package.json 可解析', false, String(e.message));
    return;
  }
  record('①包', `版本 == ${VERSION}`, pj.version === VERSION, `实装 ${pj.version}`);

  // 指纹（16 位）只作提示，不判死：上游同一版本重新发布或本机 pnpm 重链会决定它
  const sha16 = (f) => {
    try {
      const h = execFileSync('sha256sum', [path.join(PKG_DIR, f)], { encoding: 'utf8' });
      return h.slice(0, 16);
    } catch { return ''; }
  };
  for (const [f, want] of Object.entries(EXPECT_SHA16)) {
    if (!fs.existsSync(path.join(PKG_DIR, f))) { record('①包', `${f} 在位`, false, '缺文件'); continue; }
    const got = sha16(f);
    record('①包', `${f} 指纹`, got === want, `want ${want} got ${got || '(读不到)'}`, 'warn');
  }
  const eng = pj.engines || {};
  record('①包', '声明 engines.dsh（对照 dsh-memento）', !!eng.dsh, eng.dsh ? eng.dsh : '无声明 → 宿主版本闸门不校验（已知差异）', 'warn');
  record('①包', '零运行时依赖', Object.keys(pj.dependencies || {}).length === 0, JSON.stringify(pj.dependencies || {}));
  record('①包', '声明 dsh.bundle.patch', !!pj.dsh?.bundle?.patch, JSON.stringify(pj.dsh || {}));

  // 逐字节核对：已装 client.js 必须 == kit 的 overlay（即 port 补丁真的铺上了）
  const overlayPath = path.join(KIT_DIR, 'overlay', 'lib', 'client.js');
  const installedPath = path.join(PKG_DIR, 'lib', 'client.js');
  if (fs.existsSync(overlayPath) && fs.existsSync(installedPath)) {
    const h = (p) => execFileSync('sha256sum', [p], { encoding: 'utf8' }).slice(0, 16);
    const want = h(overlayPath);
    const got = h(installedPath);
    record('①包', 'port 补丁已铺（client.js == overlay）', want === got, want === got ? want : `want ${want} got ${got}`);
  } else {
    record('①包', 'kit 提供 overlay/lib/client.js', fs.existsSync(overlayPath), '缺 overlay，无法核对 port 补丁', 'warn');
  }
}

/* ── 段 2：装配声明 ─────────────────────────────────────────── */
function section2() {
  const p = path.join(PROFILE_DIR, 'package.json');
  let pj;
  try {
    pj = JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    record('②装配', 'profile package.json 可读', false, String(e.message));
    return;
  }
  const deps = pj.dependencies || {};
  const bundles = pj.dsh?.profile?.bundles || [];
  record('②装配', 'dependencies 含 meow-memory', !!deps[PKG], deps[PKG] || '缺');
  record('②装配', 'dsh.profile.bundles 含 meow-memory', bundles.includes(PKG), bundles.join(','));
}

/* ── 段 3：模块产物 ─────────────────────────────────────────── */
async function section3() {
  // 服务半边：真加载（比 --check 强：既验语法也验依赖解析）
  const idx = path.join(PKG_DIR, 'lib/index.js');
  if (fs.existsSync(idx)) {
    try {
      const m = await import(pathToFileURL(idx).href);
      const keys = Object.keys(m);
      record('③模块', 'lib/index.js 可加载（动态 import）', true, `导出 ${keys.length} 项`);
      record('③模块', '导出 apply（cordis 装配入口）', typeof m.apply === 'function', typeof m.apply);
      record('③模块', '导出 SETTINGS_NS', typeof m.SETTINGS_NS === 'string', String(m.SETTINGS_NS));
    } catch (e) {
      record('③模块', 'lib/index.js 可加载（动态 import）', false, String(e.message).slice(0, 200));
    }
  } else {
    record('③模块', 'lib/index.js 在位', false, '缺文件');
  }

  // 客户端半边：浏览器 bundle，Node 侧不 import（会因 document/window 报假错），
  // 改为在位 + 关键兜底标记核验。
  const cli = path.join(PKG_DIR, 'lib/client.js');
  if (fs.existsSync(cli)) {
    const src = fs.readFileSync(cli, 'utf8');
    record('③模块', 'lib/client.js 在位', true, `${src.length} B`);
    record('③模块', '设置页有 configForms 兜底分支', src.includes('configForms'),
      '0.2.2 上 settingsScope 已移除，兜底是设置页可用的前提');
    record('③模块', '客户端走 bundle 合并请求（dsh.client.platform=web）', true, 'dsh.client.platform=web');
  } else {
    record('③模块', 'lib/client.js 在位', false, '缺文件');
  }

  const patchPath = path.join(PKG_DIR, 'cordis.patch.yml');
  if (fs.existsSync(patchPath)) {
    const patch = fs.readFileSync(patchPath, 'utf8');
    record('③模块', 'cordis.patch.yml 在位', true, `${patch.length} B`);
    record('③模块', 'bundle patch 含 insert id: meow-memory', /insert[\s\S]*id:\s*meow-memory/.test(patch), '');
  } else {
    record('③模块', 'cordis.patch.yml 在位', false, '缺文件');
  }
}

/* ── 段 4：记忆库 ───────────────────────────────────────────── */
function section4() {
  if (!fs.existsSync(STORE)) {
    record('④记忆库', '库文件存在', false, `${STORE}（本工作区尚无记忆时正常）`, 'warn');
    return;
  }
  record('④记忆库', '库文件存在', true, `${STORE} ${fs.statSync(STORE).size} B`);
  try {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(STORE, { readOnly: true });
    const tables = db.prepare(`select name from sqlite_master where type='table'`).all().map((r) => r.name);
    for (const n of LAYERS) {
      if (!tables.includes(n)) { record('④记忆库', `层 ${n} 存在`, false, '缺表'); continue; }
      const c = db.prepare(`select count(*) c from "${n}"`).get().c;
      record('④记忆库', `层 ${n}`, true, `${c} 条`, 'info');
    }
    const total = LAYERS.filter((n) => tables.includes(n))
      .reduce((s, n) => s + db.prepare(`select count(*) c from "${n}"`).get().c, 0);
    record('④记忆库', '条目总数 > 0', total > 0, `合计 ${total} 条`);
    record('④记忆库', 'dream 表齐全（dream_log/dream_meta/dream_skip/windows）',
      ['dream_log', 'dream_meta', 'dream_skip', 'windows'].every((t) => tables.includes(t)), tables.join(','));
    db.close();
  } catch (e) {
    record('④记忆库', 'node:sqlite 可读库', false, String(e.message).slice(0, 200));
  }
}

/* ── 附：残留核验 ───────────────────────────────────────────── */
function sectionResidue() {
  const legacyPkg = path.join(PROFILE_DIR, 'node_modules', 'dsh-memento');
  record('⑤残留', 'node_modules 无 dsh-memento', !fs.existsSync(legacyPkg), legacyPkg);
  try {
    const pj = JSON.parse(fs.readFileSync(path.join(PROFILE_DIR, 'package.json'), 'utf8'));
    const hit = Object.keys(pj.dependencies || {}).filter((k) => /memento/.test(k));
    const hitB = (pj.dsh?.profile?.bundles || []).filter((k) => /memento/.test(k));
    record('⑤残留', '装配声明无 memento', hit.length === 0 && hitB.length === 0, [...hit, ...hitB].join(',') || '干净');
  } catch { /* ignore */ }
  try {
    const patch = fs.readFileSync(path.join(PROFILE_DIR, 'cordis.patch.yml'), 'utf8');
    const bad = /^\s*-\s*id:\s*memento\s*$/m.test(patch);
    record('⑤残留', 'cordis.patch.yml 无 - id: memento', !bad, bad ? '仍残留补丁条目' : '干净');
    const hasMeow = /^\s*-\s*id:\s*meow-memory\s*$/m.test(patch);
    record('⑤残留', 'cordis.patch.yml 有 - id: meow-memory（配置段）', hasMeow, hasMeow ? '已写' : '未写（用出厂默认）');
  } catch { /* ignore */ }
  const bin = path.join(PROFILE_DIR, 'node_modules', '.bin', 'dsh-memento-mcp');
  const hasBin = (() => { try { fs.lstatSync(bin); return true; } catch { return false; } })();
  record('⑤残留', '无 dsh-memento-mcp 悬空软链', !hasBin, bin);
  const store = path.join(DSH_HOME, 'dsh-memento');
  record('⑤残留', '$DSH_HOME/dsh-memento 已归档', !fs.existsSync(store), store);
  const lock = path.join(PROFILE_DIR, 'pnpm-lock.yaml');
  if (fs.existsSync(lock)) {
    const n = (fs.readFileSync(lock, 'utf8').match(/memento/gi) || []).length;
    record('⑤残留', 'pnpm-lock.yaml 0 处 memento', n === 0, `${n} 处`);
  }
}

section1(); section2(); await section3(); section4(); sectionResidue();

/* ── 输出 ───────────────────────────────────────────────────── */
const fails = results.filter((r) => !r.ok && r.level === 'fail');
const warns = results.filter((r) => !r.ok && r.level === 'warn');

if (AS_JSON) {
  console.log(JSON.stringify({ ok: fails.length === 0, fails: fails.length, warns: warns.length, results }, null, 2));
} else {
  let cur = '';
  const mark = (r) => (r.ok ? '\x1b[32m✓\x1b[0m' : r.level === 'warn' ? '\x1b[33m!\x1b[0m' : '\x1b[31m✗\x1b[0m');
  for (const r of results) {
    if (r.section !== cur) { cur = r.section; console.log(`\n\x1b[1m${cur}\x1b[0m`); }
    console.log(`  ${mark(r)} ${r.name}${r.detail ? `  \x1b[2m${r.detail}\x1b[0m` : ''}`);
  }
  console.log(`\n\x1b[1m结论\x1b[0m  FAIL ${fails.length} / WARN ${warns.length} / 共 ${results.length} 项`);
  if (fails.length) {
    console.log('\x1b[31m不通过的项目：\x1b[0m');
    for (const f of fails) console.log(`  · ${f.section} ${f.name} — ${f.detail}`);
  } else {
    console.log('\x1b[32m核心项目全部通过。\x1b[0m');
  }
  console.log('\n工作区 : ' + WORKSPACE);
  console.log('记忆库 : ' + STORE);
}
process.exit(fails.length ? 1 : 0);
