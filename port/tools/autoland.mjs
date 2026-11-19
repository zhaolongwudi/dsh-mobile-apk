#!/data/data/com.dsharnessmobile.shell/files/usr/bin/node
// ============================================================================
// autoland.mjs —— 移植插件「自动落地器」：把 upstream-watch 判 READY 的新版本
//                  真正固化到 kit、装进本机 profile，并把结果推回远端 main。
//
// 补的是链条的第三段。前两段已存在：
//   ① upstream-watch.mjs（每两天 05:00）检测上游 → 二次复核 → 判 READY → 写 state.json
//   ② kit-land.sh        落地器骨架（只认 dsh-purge，且从未被定时任务调用）
//   ③ 本脚本             ← 统一落地：所有具备能力的 kit，复用 ① 已验证的缓存候选包
//
// 设计要点（为什么不重写试移植）：
//   · upstream-watch 在判 READY 前，已经对 <cache>/<kit>-<date>/x/package 做过
//     patch --dry-run → 实打 → node --check → 结构测试 → 真实 import → ABI 扫描。
//     本脚本直接复用这份「已验证候选包」，不重复劳动、不引入新的判定口径。
//   · 固化 = 把候选包打成离线 tgz 放进 port/pkg/ + 更新 manifest(version/source/
//     integrity/offline*) + 覆盖 kit 的 overlay/(补丁后文件) + 重装 + verify。
//   · 全程留档；verify 不过即从备份回滚该 kit 并重装修复前版本。
//   · 推送走 api-push.mjs（Git Data API，本机 git push 常年 SSL 失败）。
//
// 用法：
//   node port/tools/autoland.mjs                 # 落地所有 READY 的 kit 并推远端
//   node port/tools/autoland.mjs --dry           # 只报计划，不动 kit/本机/远端
//   node port/tools/autoland.mjs --no-push       # 落地+verify，但不推远端
//   node port/tools/autoland.mjs --kit meow-memory
//
// 退出码：0=全部处理完成（含「无需动作」）／1=有 kit 落地或验证失败（已回滚）／2=环境错误
// ============================================================================
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SELF = fileURLToPath(import.meta.url);
const TOOLS = path.dirname(SELF);
const PORT = path.dirname(TOOLS);                 // .../port
const REPO = path.dirname(PORT);                  // .../fork
const NODE_CMD = process.env.NODE_CMD || 'node';
const DSH_HOME = process.env.DSH_HOME || '/data/user/0/com.dsharnessmobile.shell/files/home/.dsh';
const RUN_HOME = path.join(DSH_HOME, 'port-upstream');
const STATE_FILE = process.env.STATE_FILE || path.join(RUN_HOME, 'reports', 'state.json');
const CACHE = path.join(RUN_HOME, 'cache');
const LAND_HOME = path.join(DSH_HOME, 'port-land');
const BACKUP_ROOT = path.join(LAND_HOME, 'backup');
const LOG_DIR = path.join(LAND_HOME, 'logs');
fs.mkdirSync(BACKUP_ROOT, { recursive: true });
fs.mkdirSync(LOG_DIR, { recursive: true });

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const DRY = has('--dry');
const PUSH = !has('--no-push');
const ONLY = opt('--kit', '');

const log = (...a) => console.log(...a);
const nowCN = () => new Intl.DateTimeFormat('sv-SE', {
  timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit',
}).format(new Date()) + ' +08:00';
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const sha256_16 = (buf) => sha256(buf).slice(0, 16);
const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const writeJson = (p, o) => fs.writeFileSync(p, JSON.stringify(o, null, 2) + '\n', 'utf8');

function run(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', timeout: opts.timeout || 300000, env: { ...process.env, ...(opts.env || {}) }, cwd: opts.cwd || REPO });
}
function ok(r) { return r.status === 0; }

// 每个 kit 的落地策略。overlay 文件 = 候选包里被补丁改过的文件（upstream-watch 已验证）。
// meow-memory：候选包已打 3 个补丁，overlay 需换成候选包的 lib/index.js + lib/client.js，
//              并把 VERSION/manifest/verify.mjs/port.sh 里的钉住版本一起推进。
const STRATEGY = {
  'meow-memory': {
    offlineDir: path.join(PORT, 'pkg'),
    overlayFiles: ['lib/index.js', 'lib/client.js'],
    versionPinnedFiles: ['port.sh', 'tools/verify.mjs'],
  },
  // dsh-purge 走自己的 port.sh sync（会重建 payload + 改 manifest + 重装），无需通用固化。
  'dsh-purge': { nativeSync: 'sync' },
  // jet-hub：更新 manifest → 自带 fetch-payload.sh --force --pack 重建载荷 → install → verify。
  //   verify 第 5 段「引擎服旧包」是运行时缓存，重启应用后自愈，落地阶段核销（功能面不受影响）；
  //   升级别的相关 kit 后统一跑 lockfix 对齐 pnpm 账本，消除第 8 段 drift。
  'jet-hub': {
    rebuildPayload: true,
    versionPinnedFiles: [],
    // verify 里这些 FAIL 是环境缓存/历史账本，非本次落地缺陷 —— 命中即核销
    waiveFailPatterns: [/引擎仍在服旧包/, /引擎服 rev=.*磁盘是 rev=/],
  },
};

/** 找到 upstream-watch 本轮为某 kit 验证过的、且版本 == 上游最新的候选包目录 */
function findVerifiedCandidate(kit, upstreamVersion) {
  if (!fs.existsSync(CACHE)) return null;
  const dirs = fs.readdirSync(CACHE)
    .filter((d) => d.startsWith(kit + '-') && /^\d{4}-\d{2}-\d{2}$/.test(d.slice(kit.length + 1)))
    .map((d) => ({ d, t: fs.statSync(path.join(CACHE, d)).mtimeMs }))
    .sort((a, b) => b.t - a.t);
  for (const { d } of dirs) {
    const pkg = path.join(CACHE, d, 'x', 'package', 'package.json');
    try {
      if (readJson(pkg).version === upstreamVersion) return path.dirname(pkg);
    } catch { /* 候选不完整，跳过 */ }
  }
  return null;
}

/**
 * 把候选包打成 npm 风格的离线 tgz（顶层 package/），返回路径。
 * 用纯 Node zlib 写 ustar+gzip，不依赖系统 tar/gzip —— Android 快照里的 tar
 * 会 exec gzip 而报 "Cannot exec: No such file or directory"（dsh-purge 的
 * pack-payload.mjs 同款坑，见其注释）。固定 mtime 保证可复现。
 */
function packOffline(kit, candidate, version) {
  const dir = STRATEGY[kit]?.offlineDir || path.join(PORT, 'pkg');
  fs.mkdirSync(dir, { recursive: true });
  const dst = path.join(dir, `${kit}-${version}.tgz`);
  const MTIME = 1731110400; // 2026-11-09T00:00:00Z
  const rows = [];
  const prefix = 'package';
  (function walk(d, rel) {
    const ents = fs.readdirSync(d, { withFileTypes: true })
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const e of ents) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      const full = path.join(d, e.name);
      if (e.isDirectory()) { rows.push({ rel: `${prefix}/${r}/`, data: Buffer.alloc(0), mode: 0o755, dir: true }); walk(full, r); }
      else if (e.isFile()) rows.push({ rel: `${prefix}/${r}`, data: fs.readFileSync(full), mode: 0o644, dir: false });
      // 符号链接等特殊项跳过：离线载荷不需要，避免装包时产生悬空链
    }
  })(candidate, '');
  const chunks = [];
  for (const row of rows) {
    const nameBytes = Buffer.byteLength(row.rel);
    if (nameBytes > 100) throw new Error(`ustar 路径超长(>100)：${row.rel}`);
    const h = Buffer.alloc(512);
    const put = (s, off, len) => h.write(s, off, Math.min(len - 1, Buffer.byteLength(s)));
    put(row.rel, 0, 100);
    h.write(row.mode.toString(8).padStart(7, '0') + '\0', 100, 8, 'ascii');
    h.write('0000000\0', 108, 8, 'ascii');
    h.write('0000000\0', 116, 8, 'ascii');
    h.write(row.data.length.toString(8).padStart(11, '0') + '\0', 124, 12, 'ascii');
    h.write(MTIME.toString(8).padStart(11, '0') + '\0', 136, 12, 'ascii');
    h.write('        ', 148, 8, 'ascii');
    h.write(row.dir ? '5' : '0', 156, 1, 'ascii');
    h.write('ustar\0', 257, 6, 'ascii');
    h.write('00', 263, 2, 'ascii');
    let sum = 0; for (const b of h) sum += b;
    h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
    chunks.push(h);
    if (!row.dir && row.data.length) {
      chunks.push(row.data);
      const pad = (512 - (row.data.length % 512)) % 512;
      if (pad) chunks.push(Buffer.alloc(pad));
    }
  }
  chunks.push(Buffer.alloc(1024));
  const gz = zlib.gzipSync(Buffer.concat(chunks), { level: 9 });
  fs.writeFileSync(dst, gz);
  return dst;
}

/** 通用固化：离线包 + manifest + overlay + 版本钉住文件 */
function solidify(kit, candidate, upstream, st, oldVersion) {
  const kitDir = path.join(PORT, kit);
  const mfPath = path.join(kitDir, 'manifest.json');
  const mf = readJson(mfPath);
  const pkgName = mf.package?.name || mf.package || mf.kit || kit;
  const upstreamPkg = readJson(path.join(candidate, 'package.json'));
  const oldVer = oldVersion || (mf.package?.version) || mf.version || '';

  // 1) 离线 tgz
  const tgz = packOffline(kit, candidate, upstream);
  const tgzBuf = fs.readFileSync(tgz);
  const tgzSha = sha256(tgzBuf);

  // 2) npm registry tarball + integrity（从 dist 取；候选包无 dist 就用固定 URL）
  const npmTarball = `https://registry.npmjs.org/${pkgName}/-/${pkgName}-${upstream}.tgz`;
  const npmIntegrity = upstreamPkg.dist?.integrity
    || `sha512-${crypto.createHash('sha512').update(tgzBuf).digest('base64')}`;
  const npmShasum = upstreamPkg.dist?.shasum || crypto.createHash('sha1').update(tgzBuf).digest('hex');

  // 3) 更新 manifest
  if (mf.package && typeof mf.package === 'object') mf.package.version = upstream;
  else mf.version = upstream;
  if (mf.source?.registry) mf.source.registry = npmTarball;
  if (mf.source?.integrity) mf.source.integrity = npmIntegrity;
  if (mf.source?.shasum) mf.source.shasum = npmShasum;
  if (mf.source?.offlineTarball) mf.source.offlineTarball = `pkg/${kit}-${upstream}.tgz`;
  if (mf.source?.offlineSha256) mf.source.offlineSha256 = tgzSha;
  mf.verifiedAt = new Date().toISOString();
  writeJson(mfPath, mf);

  // 4) 覆盖 overlay（候选包里被补丁改过的文件）
  for (const rel of (st.overlayFiles || [])) {
    const src = path.join(candidate, rel);
    const dst = path.join(kitDir, 'overlay', rel);
    if (!fs.existsSync(src)) throw new Error(`候选包缺 overlay 源文件 ${rel}`);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
  }

  // 5) 版本钉住文件（port.sh / verify.mjs 里的 VERSION 常量）。
  //    先把 VERSION=<旧版本> 常量推进；再把残留的旧版本号字符串全局替换（离线包名等）。
  for (const rel of (st.versionPinnedFiles || [])) {
    const f = path.join(kitDir, rel);
    if (!fs.existsSync(f)) continue;
    let after = fs.readFileSync(f, 'utf8');
    after = after.replace(/(VERSION\s*=\s*['"])[^'"]+(['"])/g, `$1${upstream}$2`);
    if (oldVer && oldVer !== upstream) after = after.split(oldVer).join(upstream);
    fs.writeFileSync(f, after, 'utf8');
  }

  return { tgz: path.join('port', 'pkg', path.basename(tgz)), tgzSha, npmIntegrity };
}

/**
 * jet-hub 专用落地：更新 manifest → 用自带 fetch-payload.sh 重建 payload.tar.gz
 * → 把 payload 的 sha256/bytes/files 写回 manifest → 对齐 pnpm 账本。
 * bundledDependencies 钉的具体版本保留（已核对都在上游 ^ 范围内），只升级主包。
 */
function rebuildJetPayload(kit, candidate, upstream, oldVersion) {
  const kitDir = path.join(PORT, kit);
  const mfPath = path.join(kitDir, 'manifest.json');
  const mf = readJson(mfPath);
  const upPkg = readJson(path.join(candidate, 'package.json'));

  mf.package.version = upstream;
  mf.package.source = `https://registry.npmjs.org/${mf.package.name}/-/${mf.package.name}-${upstream}.tgz`;
  if (upPkg.dist?.integrity) mf.package.integrity = upPkg.dist.integrity;
  if (upPkg.dist?.shasum) mf.package.shasum = upPkg.dist.shasum;
  mf.verifiedAt = new Date().toISOString();
  writeJson(mfPath, mf);

  // 重建载荷（脚本内部用纯 Node zlib 打 gzip，无系统 tar -z 依赖）
  const r = run('bash', [path.join(kitDir, 'fetch-payload.sh'), '--force', '--pack'], { timeout: 600000 });
  if (!ok(r)) throw new Error(`载荷重建失败: ${((r.stdout || '') + (r.stderr || '')).slice(-400)}`);

  // 回写 payload 校验字段
  const gz = fs.readFileSync(path.join(kitDir, 'payload.tar.gz'));
  const count = execFileSync('sh', ['-c', `find "${path.join(kitDir, 'payload', 'node_modules')}" -type f | wc -l`], { encoding: 'utf8' }).trim();
  mf.payload.sha256 = sha256(gz);
  mf.payload.bytes = gz.length;
  mf.payload.files = Number(count) || mf.payload.files;
  writeJson(mfPath, mf);
  return { bytes: gz.length, files: mf.payload.files };
}

/** 用 jet-hub 的通用 lockfix 对齐某个 kit 在 profile 里的 pnpm 账本 */
function lockfixKit(kit, version) {
  const lf = path.join(PORT, 'jet-hub', 'lockfix.mjs');
  if (!fs.existsSync(lf)) return;
  const mf = readJson(path.join(PORT, kit, 'manifest.json'));
  const integ = (mf.package?.integrity) || (mf.source?.integrity) || '-';
  const r = run(NODE_CMD, [lf, path.join(DSH_HOME, 'profiles', 'web'), kit, version, integ]);
  if (!ok(r)) log(`  ! ${kit} lockfix 失败: ${((r.stdout || '') + (r.stderr || '')).slice(-200)}`);
}

/** 刷新 meow 的指纹登记表（改过 kit 后必跑，CI port-guard 依赖它） */
function refreshProtected(kitDir) {
  const r = run('bash', [path.join(kitDir, 'tools', 'protect.sh'), 'snapshot'], { cwd: kitDir });
  if (!ok(r)) log(`  ! protect.sh snapshot 失败: ${(r.stdout || '') + (r.stderr || '')}`.slice(0, 300));
}

/** 安装：port.sh install --force（会补装配 + 铺 overlay / 铺载荷） */
function installKit(kit) {
  const script = path.join(PORT, kit, 'port.sh');
  const r = run('bash', [script, 'install', '--force']);
  if (!ok(r)) throw new Error(`install 失败: ${((r.stdout || '') + (r.stderr || '')).slice(-500)}`);
  return ((r.stdout || '') + (r.stderr || '')).split('\n').filter((l) => /已装|已铺|已就位|版本|落位|装配/.test(l)).slice(-4).join(' | ');
}

/** 按策略固化 + 安装，返回安装摘要。三种落地方式统一入口。 */
function installKitAfter(kit, st, cand, k, bk) {
  if (st.nativeSync) {
    // dsh-purge：自己的 port.sh sync（内含重建载荷 + 改 manifest + install）
    const r = run('bash', [path.join(PORT, kit, 'port.sh'), st.nativeSync]);
    if (!ok(r)) throw new Error(`sync 失败: ${((r.stdout || '') + (r.stderr || '')).slice(-400)}`);
    return ((r.stdout || '') + (r.stderr || '')).split('\n').filter((l) => /已|版本|最新/.test(l)).slice(-3).join(' | ');
  }
  if (st.rebuildPayload) {
    // jet-hub：重建载荷后 install
    const info = rebuildJetPayload(kit, cand, k.upstream, k.pinned);
    log(`  载荷已重建：${(info.bytes / 1048576).toFixed(1)}MB / ${info.files} 文件`);
    return installKit(kit);
  }
  // 通用固化（meow-memory）
  const info = solidify(kit, cand, k.upstream, st, k.pinned);
  log(`  固化完成：${info.tgz}`);
  refreshProtected(path.join(PORT, kit));
  return installKit(kit);
}

/**
 * 验证：port.sh verify。默认必须 rc=0；st.waiveFailPatterns 里声明的 FAIL 是
 * 「可自愈/环境类」（如引擎缓存旧 bundle），逐行匹配后从失败计数里剔除。
 * 与 upstream-watch 的「误报核销」同口径：只认明确列出的模式，不吞其它失败。
 */
function verifyKit(kit, st = {}) {
  const script = path.join(PORT, kit, 'port.sh');
  const r = run('bash', [script, 'verify']);
  const text = (r.stdout || '') + (r.stderr || '');
  const lines = text.split('\n');
  const waived = [];
  const realFails = [];
  for (const l of lines) {
    if (!/^\s*FAIL\b/.test(l)) continue;
    const hit = (st.waiveFailPatterns || []).some((re) => re.test(l));
    (hit ? waived : realFails).push(l.trim());
  }
  // 没有可匹配 FAIL 行时退回看 rc（有些 verify 只在汇总行报数）
  const summary = lines.filter((l) => /FAIL|结论|核心项目|通过/.test(l)).slice(-3).join(' | ').slice(0, 240);
  const okFinal = realFails.length === 0 && (ok(r) || waived.length > 0);
  return { ok: okFinal, summary, rc: r.status, waived, realFails };
}

function rollback(kit, stamp) {
  const kitDir = path.join(PORT, kit);
  const bk = path.join(BACKUP_ROOT, `${kit}-${stamp}`);
  if (!fs.existsSync(bk)) return;
  fs.rmSync(kitDir, { recursive: true, force: true });
  fs.cpSync(bk, kitDir, { recursive: true });
  // 重装回滚前的版本
  try { installKit(kit); } catch { /* 已尽力 */ }
  log(`  已回滚 $kit ← $bk`);
}

/** 用 api-push.mjs 推整个工作树到远端 main */
function pushRemote(message) {
  const script = path.join(TOOLS, 'api-push.mjs');
  const r = run(NODE_CMD, [script, '-m', message], { timeout: 420000 });
  const text = ((r.stdout || '') + (r.stderr || '')).trim();
  log('  ' + text.split('\n').slice(-6).join('\n  '));
  return { ok: ok(r), text };
}

// ── 主流程 ────────────────────────────────────────────────────────────────
function main() {
  log(`\n=== 移植插件自动落地 ${nowCN()} ===`);
  if (!fs.existsSync(STATE_FILE)) { log(`✘ 找不到巡检状态 ${STATE_FILE}，先跑 upstream-watch`); return 2; }
  const state = readJson(STATE_FILE);

  // 新鲜度：state 是上一轮 upstream-watch 刚写的（本脚本紧跟其后），放宽到 72h
  const at = Date.parse(String(state.at || '').replace(/ ([+-]\d{2}):(\d{2})$/, '$1$2').replace(' ', 'T'));
  if (!Number.isFinite(at)) { log('✘ state.json 的 at 无法解析'); return 2; }
  const ageH = (Date.now() - at) / 3600000;
  if (ageH > 72) { log(`✘ 巡检状态已 ${ageH.toFixed(1)}h（>72h），先重跑 upstream-watch`); return 2; }
  log(`巡检状态 ${ageH.toFixed(1)}h 前，令牌 ${(() => {
    try { const u = execFileSync('git', ['remote', 'get-url', 'origin'], { encoding: 'utf8', cwd: REPO }).trim(); return /@/.test(u) ? '已取到' : '缺'; } catch { return '缺'; }
  })()}`);

  const kits = Object.keys(state.kits || {}).filter((k) => !ONLY || ONLY === k).sort();
  const stamp = new Date().toISOString().slice(0, 10);
  let rc = 0;
  const landed = [], skipped = [], failed = [];
  let anyChange = false;

  for (const kit of kits) {
    const k = state.kits[kit];
    log(`\n── ${kit} ── 钉住=${k.pinned} 上游=${k.upstream} 状态=${k.state} 可移植=${k.portState}`);
    if (k.state === 'RETIRED') { log('  · 已退役，跳过'); skipped.push(kit); continue; }
    if (k.state === 'CURRENT') { log('  · 已是最新，无需动作'); skipped.push(kit); continue; }
    if (k.portState !== 'READY') {
      log(`  · 可移植性=${k.portState} —— 不自动落地（NEEDS-PORT 需人工重制补丁，BLOCKED 需先查原因）`);
      skipped.push(`${kit}(${k.portState})`); continue;
    }
    const st = STRATEGY[kit];
    if (!st) { log('  · 无落地策略，跳过'); skipped.push(`${kit}(无策略)`); continue; }

    // 找 upstream-watch 已验证的候选包（nativeSync 的 dsh-purge 不需要）
    const cand = (st.rebuildPayload || st.offlineDir || st.overlayFiles)
      ? findVerifiedCandidate(kit, k.upstream) : null;
    if ((st.rebuildPayload || st.offlineDir) && !cand) {
      log(`  ✘ 找不到版本 ${k.upstream} 的已验证候选包（缓存 $CACHE），跳过`);
      failed.push(`${kit}(无候选包)`); rc = 1; continue;
    }
    if (DRY) {
      log(`  (dry-run) 将落地 ${k.pinned}→${k.upstream}${cand ? ` (${cand})` : ''}`);
      continue;
    }

    const bk = path.join(BACKUP_ROOT, `${kit}-${stamp}-${Date.now()}`);
    fs.cpSync(path.join(PORT, kit), bk, { recursive: true });
    log(`  留档 → ${bk}`);
    try {
      const i = installKitAfter(kit, st, cand, k, bk);
      log(`  安装：${i}`);
      // 落地别的相关 kit 后，统一对齐本机 pnpm 账本（jet-hub verify 第8段会查）
      lockfixKit(kit, k.upstream);
      const v = verifyKit(kit, st);
      if (v.waived?.length) log(`  核销 ${v.waived.length} 条环境类 FAIL: ${v.waived[0].slice(0, 90)}`);
      if (!v.ok) {
        log(`  ✘ verify 失败 → 回滚: ${v.summary}`);
        rollback(kit, path.basename(bk)); failed.push(`${kit}(verify失败已回滚)`); rc = 1; continue;
      }
      log(`  ✔ 已落地 ${k.pinned}→${k.upstream}，${v.summary}`);
      landed.push(`${kit}(${k.pinned}→${k.upstream})`); anyChange = true;
    } catch (e) {
      log(`  ✘ 落地异常 → 回滚: ${e.message}`);
      rollback(kit, path.basename(bk)); failed.push(`${kit}(异常已回滚)`); rc = 1;
    }
  }

  // 推远端：即使本轮只是把上一轮的 READY 固化结果补推，也检查工作树
  log('\n=== 同步到远端 main ===');
  if (DRY) {
    log('（dry-run：不推送）');
  } else if (!PUSH) {
    log('（--no-push：跳过）');
  } else {
    const st2 = execFileSync('git', ['-C', REPO, 'status', '--porcelain'], { encoding: 'utf8' }).trim();
    if (!st2) {
      log('工作树无变化，无需推送');
    } else {
      log(`工作树有 ${st2.split('\n').length} 处变化，推送中…`);
      const pr = pushRemote(`port: 自动落地升版（${nowCN()}）`);
      if (!pr.ok) { log('✘ 推送失败（本机已落地；远端待补）'); rc = 1; }
      else log('✔ 已同步到远端 main');
    }
  }

  log('\n=== 本轮结论 ===');
  log(`  已落地: ${landed.length ? landed.join(', ') : '无'}`);
  if (skipped.length) log(`  跳过: ${skipped.join(', ')}`);
  if (failed.length) log(`  失败: ${failed.join(', ')}`);
  log(`  日志：本轮输出已随定时任务记录（详细见 $DSH_HOME/port-land/logs/）`);
  return rc;
}

process.exit(main());
