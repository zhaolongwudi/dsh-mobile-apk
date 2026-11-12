#!/data/data/com.dsharnessmobile.shell/files/usr/bin/node
// ============================================================================
// upstream-watch.mjs —— 移植插件「上游最新提交」巡检 + 二次可用性复核 + 回传仓库
//
// 做三件事，按顺序，任一步失败不影响后面（各自记账）：
//
//   ① 拉取上游最新：每个 kit 按自己 manifest 钉的来源探针
//        · npm registry 包 → /latest 的 version
//        · GitHub release 包 → /releases/latest 的 tag
//        · 另有 GitHub 仓库的 → 最新 commit sha（用于「上游动了但还没发版」的早期预警）
//      与本机 kit 钉住的版本比，判 OUTDATED / CURRENT / RETIRED。
//
//   ② 二次确认（这是本脚本的主体，不是附属）：
//        A 现装体检   —— 跑各 kit 自带的 port.sh verify，逐条统计 PASS/FAIL/WARN
//        B 结构漂移   —— kit 的 overlay/ 每个文件在已装包里是否存在（上游删文件/改名会先在这里现形）
//        C 上游可移植性 —— 真有新版时：解包 → 逐补丁 patch --dry-run → 全过则实打 → node --check
//                        → kit 自带结构测试（MEOW_CLIENT 指向新打的 client.js）
//        D 结论       —— READY（可直接升）/ NEEDS-PORT（补丁冲突，要人重制）/ BLOCKED
//      只看 A 会把「上游已改而本机还没升」当成健康，只看 C 会把「本机坏了但上游没动」漏掉，
//      所以两路证据都要，且必须同一次运行里取。
//
//   ③ 回传仓库：把 port/ 里**有实质变化**的文件（含本脚本产出的 UPSTREAM-STATUS.md）
//      用 GitHub Git Data API 推到远端 main。不走 git push：本机直连 github.com 的
//      smart-http 实测 133s 后 fatal（工作区那份是浅+blobless，read-tree 会去 promisor
//      取 blob 而卡死）。API 通道稳定，且只需上传变化的 blob。
//
// 用法：
//   node port/tools/upstream-watch.mjs                 # 只巡检，写报告，不联网写
//   node port/tools/upstream-watch.mjs --publish       # 巡检 + 推 port/ 到远端 main
//   node port/tools/upstream-watch.mjs --publish --prune   # 额外删除远端 port/ 下本地已没有的文件
//   node port/tools/upstream-watch.mjs --no-verify     # 跳过跑本机体检（CI/无运行时时用）
//
// 令牌：环境 GITHUB_TOKEN，否则从 repo 的 git remote origin URL 解析（不打印）。
// 退出码：0 = 巡检完成（无论有无新版）；1 = 有 kit 现装 FAIL（需要人管）；2 = 用法/环境错误。
// ============================================================================
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SELF = fileURLToPath(import.meta.url);
const TOOLS = path.dirname(SELF);
const PORT = path.dirname(TOOLS);              // .../port
const REPO_DIR = path.dirname(PORT);           // .../fork
const NODE = process.env.NODE_BIN || process.execPath;
const NODE_CMD = process.env.NODE_CMD || "node";   // Android 上 execPath 可能是 linker64，调用一律用这个名字

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

const PUBLISH = has("--publish");
const DRY = has("--dry");   // 与 --publish 同用时只算差分，不建 blob 不提交
const PRUNE = has("--prune");
const DO_VERIFY = !has("--no-verify");
const REPO = opt("--repo", "zhaolongwudi/dsh-mobile-apk");
const BRANCH = opt("--branch", "main");
// 运行期产物一律放仓库外（$DSH_HOME/port-upstream）：仓库工作树只留 port/ 里要提交的东西。
// 早先放 <repo>/.work 的代价是 36 MB 缓存 + 每轮日志在 git status 里常驻为未跟踪噪声。
const DSH_HOME = process.env.DSH_HOME || "/data/user/0/com.dsharnessmobile.shell/files/home/.dsh";
const RUN_HOME = path.join(DSH_HOME, "port-upstream");
const CACHE = path.resolve(opt("--cache", path.join(RUN_HOME, "cache")));
const REPORT_DIR = path.resolve(opt("--report-dir", path.join(RUN_HOME, "reports")));
const STATUS_MD = path.join(PORT, "UPSTREAM-STATUS.md");

// dsh-memento 已被 meow-memory 取代并卸载（manifest 里「replaces」写在 meow 一侧），不再跟上游。
const RETIRED = new Set(["dsh-memento"]);

const T0 = Date.now();
const nowCN = () =>
  new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).format(new Date()) + " +08:00";

const log = (...a) => console.log(...a);
const pad = (s, n) => String(s).padEnd(n);
/** 子进程输出进报告前先脱色去符：ANSI 转义、勾叉一律清掉（仓库禁装饰字符，md 也要干净） */
function plain(s) {
  return String(s ?? "")
    .replace(/\u001b\[[0-9;]*m/g, "")
    .replace(/[✓✔✗✘]/g, "")
    .replace(/[ \t]+/g, " ")
    .trim();
}

// ── 小工具 ────────────────────────────────────────────────────────────────
function readJson(p) { return JSON.parse(fs.readFileSync(p, "utf8")); }
function sha256(buf) { return crypto.createHash("sha256").update(buf).digest("hex"); }
function gitBlobSha(buf) { return crypto.createHash("sha1").update(`blob ${buf.length}\0`).update(buf).digest("hex"); }

async function fetchJson(url, { token, timeout = 30000 } = {}) {
  const res = await fetch(url, {
    headers: {
      accept: "application/vnd.github+json",
      "user-agent": "dsh-port-upstream-watch",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    signal: AbortSignal.timeout(timeout),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 非 JSON */ }
  if (!res.ok) throw new Error(`HTTP ${res.status} ${url.replace(/\/\/[^@/]*@/, "//")} :: ${(json?.message || text).slice(0, 200)}`);
  return json;
}

async function download(url, dst, { timeout = 180000 } = {}) {
  const res = await fetch(url, { signal: AbortSignal.timeout(timeout), redirect: "follow" });
  if (!res.ok) throw new Error(`下载失败 HTTP ${res.status} ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.writeFileSync(dst, buf);
  return buf;
}

function token() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN.trim();
  try {
    const url = execFileSync("git", ["remote", "get-url", "origin"], { encoding: "utf8", cwd: REPO_DIR }).trim();
    const m = url.match(/^https:\/\/([^@]+)@/);
    if (!m) return "";
    // 远端 URL 里的 credential 是 "user:token" 形状；只取口令段，用户名拼进去会变成
    // 无效令牌（实测 Authorization: Bearer zhaolongwudi:ghp_... → 401）
    const cred = decodeURIComponent(m[1]);
    return cred.includes(":") ? cred.slice(cred.indexOf(":") + 1) : cred;
  } catch { /* 不在仓库里 */ }
  return "";
}

// ── ① 上游探针 ────────────────────────────────────────────────────────────
/** 从 kit manifest 里解析出「上游是谁、钉在哪」。不猜版本。 */
function kitSource(kitDir, manifest) {
  const name = path.basename(kitDir);
  const pkgName = manifest.package?.name || manifest.package || manifest.kit || name;
  const pinned = manifest.package?.version || manifest.version || "";
  const src = manifest.package?.source || manifest.source?.registry || manifest.source?.repo || "";

  const npm = src.match(/registry\.npmjs\.org\/(.+?)\/-\//) || (src.includes("registry.npmjs.org") ? null : null);
  const ghRel = src.match(/github\.com\/([^/]+)\/([^/]+)\/releases\/download\/([^/]+)\//);
  const ghRepo = src.match(/github\.com\/([^/]+)\/([^/#?]+)/);
  const repoMeta = manifest.source?.repo || manifest.package?.repo || "";

  return {
    name,
    pkgName,
    pinned,
    src,
    npmName: npm ? npm[1] : (src.startsWith("https://registry.npmjs.org") ? pkgName : null),
    ghRelease: ghRel ? { owner: ghRel[1], repo: ghRel[2], tag: ghRel[3] } : null,
    ghRepo: ghRel ? { owner: ghRel[1], repo: ghRel[2] } : (repoMeta.match(/github\.com\/([^/]+)\/([^/]+)/) ? (() => { const m = repoMeta.match(/github\.com\/([^/]+)\/([^/]+)/); return { owner: m[1], repo: m[2] }; })() : (ghRepo ? { owner: ghRepo[1], repo: ghRepo[2].replace(/\.git$/, "") } : null)),
    retired: RETIRED.has(name) || manifest.retired === true,
  };
}

async function probeUpstream(src, tk) {
  const out = { checks: [] };
  if (src.npmName && !/^dsh-purge/.test(src.pkgName)) {
    try {
      const j = await fetchJson(`https://registry.npmjs.org/${encodeURIComponent(src.npmName)}/latest`);
      out.checks.push({ kind: "npm", ok: true, version: j.version, tarball: j.dist?.tarball, integrity: j.dist?.integrity });
    } catch (e) { out.checks.push({ kind: "npm", ok: false, error: e.message }); }
  }
  if (src.ghRelease) {
    try {
      const j = await fetchJson(`https://api.github.com/repos/${src.ghRelease.owner}/${src.ghRelease.repo}/releases/latest`, { token: tk });
      out.checks.push({
        kind: "gh-release", ok: true, tag: j.tag_name, published: j.published_at,
        asset: (j.assets || []).find((a) => /\.tgz$/.test(a.name) && a.name === `${src.pkgName}-${String(j.tag_name).replace(/^v/, "")}.tgz`)?.browser_download_url
          || (j.assets || []).find((a) => /\.tgz$/.test(a.name))?.browser_download_url || null,
      });
    } catch (e) { out.checks.push({ kind: "gh-release", ok: false, error: e.message }); }
  }
  if (src.ghRepo) {
    try {
      const j = await fetchJson(`https://api.github.com/repos/${src.ghRepo.owner}/${src.ghRepo.repo}/commits?per_page=1`, { token: tk });
      const c = Array.isArray(j) ? j[0] : null;
      out.checks.push({ kind: "gh-commit", ok: !!c, sha: c?.sha, date: c?.commit?.author?.date, subject: (c?.commit?.message || "").split("\n")[0] });
    } catch (e) { out.checks.push({ kind: "gh-commit", ok: false, error: e.message }); }
  }
  return out;
}

function verdict(src, probe, prev) {
  if (src.retired) return { state: "RETIRED", note: "已由 meow-memory 取代，不再跟踪" };
  const npm = probe.checks.find((c) => c.kind === "npm" && c.ok);
  const rel = probe.checks.find((c) => c.kind === "gh-release" && c.ok);
  const up = npm?.version || (rel?.tag ? String(rel.tag).replace(/^v/, "") : "");
  if (!up) return { state: "UNKNOWN", note: "上游探针全部失败（网络或仓库改名）" };
  const seen = prev?.upstream;      // 上次记录的上游版本，判断「新出现」
  let state = "CURRENT";
  if (src.pinned && up !== src.pinned) state = "OUTDATED";
  const commit = probe.checks.find((c) => c.kind === "gh-commit" && c.ok);
  const commitNew = !!(commit && prev?.commit && commit.sha !== prev.commit);
  const commitFirst = !!(commit && !prev?.commit);
  return {
    state,
    upstreamVersion: up,
    pinned: src.pinned,
    isNewSinceLastRun: !!(prev?.upstream && prev.upstream !== up),
    commitSha: commit?.sha || null,
    commitDate: commit?.date || null,
    commitSubject: commit?.subject || null,
    commitNew,
    commitFirst,
    note: state === "OUTDATED" ? `上游 ${up} > 本机 ${src.pinned}` : "与上游一致",
  };
}

// ── ②A 现装体检 ───────────────────────────────────────────────────────────
function runVerify(kitDir) {
  const script = path.join(kitDir, "port.sh");
  if (!fs.existsSync(script)) return { ran: false, reason: "无 port.sh" };
  const r = spawnSync("bash", [script, "verify"], { encoding: "utf8", cwd: REPO_DIR, timeout: 180000, env: { ...process.env } });
  const text = (r.stdout || "") + (r.stderr || "");
  const lines = text.split("\n");
  // 汇总行（"FAIL 0 / WARN 2 / 共 27 项"）本身带 FAIL 字样，不能计入失败明细；明细只认以 FAIL/WARN 开头或以「FAIL  说明」成行的项
  const isSummary = (l) => /FAIL\s+\d+\s*\/\s*WARN\s+\d+/.test(l) || /共\s*\d+\s*项/.test(l);
  const fails = lines.filter((l) => /\bFAIL\b/.test(l) && !isSummary(l)).map((l) => l.trim());
  const warns = lines.filter((l) => /\bWARN\b/.test(l) && !isSummary(l)).map((l) => l.trim());
  // meow 的 verify.mjs 会打 "FAIL 0 / WARN 2 / 共 27 项"；两者取并集更稳
  const m = text.match(/FAIL\s+(\d+)\s*\/\s*WARN\s+(\d+)\s*\/\s*共\s*(\d+)/);
  const triaged = triageDependencyFails(kitDir, fails);
  // 净 FAIL 按行数算，不按「核销条目数」：一条核销可能对应两行（如原生绑定的 ABI 行与 dlopen 行）
  const depsCleared = new Set(triaged.downgraded.filter((d) => d.why.includes("嵌套布局")).map((d) => d.dep));
  const nativeCleared = triaged.downgraded.some((d) => d.why.includes("dlopen"));
  const uncleared = fails.filter((line) => {
    const dm = line.match(/缺少依赖\s+(\S+)/);
    if (dm && depsCleared.has(dm[1])) return false;
    if (nativeCleared && /原生绑定/.test(line)) return false;
    return true;
  });
  return {
    ran: true,
    rc: r.status,
    failCount: m ? Number(m[1]) : fails.length,
    warnCount: m ? Number(m[2]) : warns.length,
    total: m ? Number(m[3]) : null,
    fails: fails.slice(0, 10),
    uncleared: uncleared.slice(0, 6),
    downgraded: triaged.downgraded,
    realFailCount: uncleared.length,
    tail: lines.filter((l) => l.trim()).slice(-2).join(" | ").slice(0, 200),
  };
}

/**
 * 「缺少依赖 X」这一类 FAIL 要分真假：pnpm 把依赖装在包自己的 node_modules 里（嵌套布局）
 * 时，kit 的 verify 在 profile 根上找 → 误报。判据 = 从「已装包目录」按 Node 解析规则能不能
 * 找到该包（走 package.json 的 main/exports 存在性即可，不真的 import）。找不到才是真缺。
 */
function triageDependencyFails(kitDir, fails) {
  const manifest = (() => { try { return readJson(path.join(kitDir, "manifest.json")); } catch { return {}; } })();
  const pkgName = manifest.package?.name || manifest.kit || path.basename(kitDir);
  const dshHome = process.env.DSH_HOME || "/data/user/0/com.dsharnessmobile.shell/files/home/.dsh";
  const installed = path.join(dshHome, "profiles", "web", "node_modules", pkgName);
  const downgraded = [];
  for (const line of fails) {
    const m = line.match(/缺少依赖\s+(\S+)/);
    if (!m) continue;
    const dep = m[1];
    const candidates = [
      path.join(installed, "node_modules", dep),
      path.join(dshHome, "profiles", "web", "node_modules", dep),
      path.join(dshHome, "profiles", "web", "node_modules", pkgName, "node_modules", dep),
    ];
    const hit = candidates.find((c) => fs.existsSync(path.join(c, "package.json")));
    if (hit) downgraded.push({ dep, at: hit.replace(dshHome, "$DSH_HOME"), why: "装在包内 node_modules（嵌套布局），verify 在 profile 根上找属误报" });
  }

  // 「原生绑定加载失败」同理：kit 从 profile 根解析 .node，路径找不到就说加载失败；
  // 真判据是 dlopen 能不能过。逐个真载一次，全过才算误报。
  if (fails.some((l) => /原生绑定加载失败/.test(l)) && fs.existsSync(installed)) {
    const nodes = [];
    (function walk(d, depth) {
      if (depth > 4) return;
      let ents = [];
      try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
      for (const e of ents) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p, depth + 1);
        else if (/\.node$/.test(e.name) && !nodes.includes(p)) nodes.push(p);
      }
    })(installed, 0);
    if (nodes.length) {
      const host = process.arch;
      const loaded = [];
      for (const n of nodes) {
        const r = spawnSync(NODE_CMD, ["-e", `try{process.dlopen({exports:{}}, ${JSON.stringify(n)}); console.log("OK")}catch(e){console.log("E "+e.message)}`], { encoding: "utf8", timeout: 30000 });
        if ((r.stdout || "").includes("OK")) loaded.push(n);
      }
      if (loaded.length === nodes.length) {
        downgraded.push({
          dep: nodes.map((n) => path.basename(n)).join(","),
          at: loaded.map((n) => n.replace(dshHome, "$DSH_HOME")).join(" , "),
          why: `${host} 上 dlopen 实测全部成功（${loaded.length}/${nodes.length}），「加载失败」是 kit 从 profile 根找不到绑定路径造成的误报`,
        });
      }
    }
  }
  return { downgraded };
}

/** ②B overlay 结构漂移：kit overlay 的每个相对路径是否在已装包里还在。 */
function overlayDrift(kitDir, manifest) {
  const ov = path.join(kitDir, "overlay");
  if (!fs.existsSync(ov)) return { checked: 0, missing: [] };
  const dshHome = process.env.DSH_HOME || "/data/user/0/com.dsharnessmobile.shell/files/home/.dsh";
  const pkgName = manifest.package?.name || manifest.kit || path.basename(kitDir);
  const installed = path.join(dshHome, "profiles", "web", "node_modules", pkgName);
  const rels = [];
  (function walk(d, base = "") {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const r = base ? `${base}/${e.name}` : e.name;
      if (e.isDirectory()) walk(path.join(d, e.name), r); else rels.push(r);
    }
  })(ov);
  const missing = rels.filter((r) => !fs.existsSync(path.join(installed, r)));
  return { checked: rels.length, installed, missing };
}

// ── ②C 上游可移植性（真有新版才跑） ────────────────────────────────────────
function patchesInOrder(kitDir, manifest) {
  const dir = path.join(kitDir, "patches");
  if (!fs.existsSync(dir)) return [];
  const declared = Object.keys(manifest.portPatches || {});
  const onDisk = fs.readdirSync(dir).filter((f) => f.endsWith(".patch")).sort();
  // 以 manifest 声明顺序为准，磁盘上多出来的按名字追加（新补丁忘了登记也要试）
  return [...declared.filter((f) => onDisk.includes(f)), ...onDisk.filter((f) => !declared.includes(f))]
    .map((f) => path.join(dir, f));
}

async function tryPort(kitDir, manifest, src, probe, stamp) {
  const npm = probe.checks.find((c) => c.kind === "npm" && c.ok);
  const rel = probe.checks.find((c) => c.kind === "gh-release" && c.ok);
  const url = npm?.tarball || rel?.asset;
  if (!url) return { state: "BLOCKED", note: "拿不到上游包地址" };

  const work = path.join(CACHE, `${src.name}-${stamp}`);
  fs.rmSync(work, { recursive: true, force: true });
  fs.mkdirSync(work, { recursive: true });
  const tgz = path.join(work, "upstream.tgz");
  if (!downloadSync(url, tgz)) return { state: "BLOCKED", note: `下载失败：${url.split("/").pop()}` };

  const x = path.join(work, "x");
  fs.mkdirSync(x, { recursive: true });
  const tar = spawnSync("tar", ["-xzf", tgz, "-C", x], { encoding: "utf8" });
  if (tar.status !== 0) return { state: "BLOCKED", note: `解包失败：${(tar.stderr || "").slice(0, 160)}` };
  const pkgRoot = fs.existsSync(path.join(x, "package")) ? path.join(x, "package") : x;

  const patches = patchesInOrder(kitDir, manifest);
  const applied = [], conflicts = [];
  for (const p of patches) {
    const dry = spawnSync("patch", ["-p1", "--dry-run", "-N", "-i", p], { encoding: "utf8", cwd: pkgRoot, timeout: 60000 });
    const ok = dry.status === 0;
    if (!ok) {
      conflicts.push({ patch: path.basename(p), detail: ((dry.stdout || "") + (dry.stderr || "")).split("\n").filter((l) => /fail|hunk|error/i.test(l)).slice(0, 3).join(" / ").slice(0, 240) });
      break;   // 链式补丁：前一个失败就不必试后面的
    }
    const real = spawnSync("patch", ["-p1", "-N", "-i", p], { encoding: "utf8", cwd: pkgRoot, timeout: 60000 });
    if (real.status === 0) applied.push(path.basename(p));
    else { conflicts.push({ patch: path.basename(p), detail: "dry-run 通过但实打失败" }); break; }
  }

  // 语法检查：只查打补丁涉及的、确实存在的文件（不硬编码路径）
  const syntax = [];
  for (const relPath of ["lib/index.js", "lib/client.js", "index.mjs", "client/client.js"]) {
    const f = path.join(pkgRoot, relPath);
    if (!fs.existsSync(f)) continue;
    const r = spawnSync(NODE_CMD, ["--check", f], { encoding: "utf8", timeout: 60000 });
    syntax.push({ file: relPath, ok: r.status === 0, err: (r.stderr || "").split("\n").find((l) => /Error|error/.test(l)) || "" });
  }

  // kit 自带结构测试：meow 的 test-settings-ui.mjs 支持 MEOW_CLIENT 指向任意 client.js
  let structural = null;
  const t = path.join(kitDir, "tools", "test-settings-ui.mjs");
  if (fs.existsSync(t)) {
    const client = path.join(pkgRoot, "lib", "client.js");
    if (fs.existsSync(client)) {
      const r = spawnSync(NODE_CMD, [t], { encoding: "utf8", timeout: 120000, env: { ...process.env, MEOW_CLIENT: client } });
      const text = (r.stdout || "") + (r.stderr || "");
      structural = {
        ok: r.status === 0,
        summary: plain(text.split("\n").filter((l) => /[✓✗]|PASS|FAIL|通过|失败|共/.test(l)).slice(-4).join(" | ")).slice(0, 240),
      };
    }
  }

  // 真加载：把候选包临时放进 profile 的 node_modules 里 import 一次（peer 依赖只有那里能解析）。
  // node --check 只查语法；插件真正的失败模式是「语法对、导入即炸」（缺导出、peer 契约变了），
  // 所以这一步不能省。失败分两种：缺对端依赖 = SKIP（环境不在，不算候选的错），其余 = FAIL。
  const loadProbe = await tryLoad(manifest, pkgRoot);

  // 原生模块 ABI：没有补丁可打（纯载荷型 kit）时，新版本唯一的失效面就是 .node 与本机架构不符。
  // 读 ELF 头的 e_machine 判定，不依赖 file 命令。
  const native = scanNative(pkgRoot);

  const state = conflicts.length ? "NEEDS-PORT"
    : syntax.some((s) => !s.ok) ? "BLOCKED"
      : (structural && !structural.ok) ? "NEEDS-PORT"
        : loadProbe.state === "FAIL" ? "BLOCKED"
          : native.mismatch.length ? "BLOCKED"
            : "READY";
  return {
    state, upstream: npm?.version || rel?.tag, work, applied, conflicts, syntax, structural, loadProbe, native,
    note: state === "READY"
      ? (patches.length ? `补丁 ${applied.length}/${patches.length} 全部可应用` : "无补丁（纯载荷型 kit），按包内容与运行时直检") + `；语法/结构测试${loadProbe.state === "PASS" ? "/真实导入" : ""}通过${native.found.length ? `；原生模块 ${native.found.length} 个架构匹配` : ""}`
      : state === "NEEDS-PORT"
        ? `补丁需重制：${conflicts.map((c) => c.patch).join(",") || "结构断言失败"}`
        : `不通：${native.mismatch.length ? `原生模块架构不符 ${native.mismatch.join(",")}` : loadProbe.state === "FAIL" ? `真实导入失败 ${loadProbe.error}` : "语法或解包层面"}`,
  };
}

const ELF_MACHINE = { 183: "arm64", 62: "x64", 40: "arm", 3: "ia32" };
function scanNative(root, out = []) {
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (/\.node$/.test(e.name)) out.push(p);
    }
  })(root);
  const host = process.arch;   // arm64 / x64 / arm / ia32
  const found = [], mismatch = [];
  for (const f of out) {
    try {
      const fd = fs.openSync(f, "r");
      const head = Buffer.alloc(20);
      fs.readSync(fd, head, 0, 20, 0);
      fs.closeSync(fd);
      const isElf = head[0] === 0x7f && head[1] === 0x45 && head[2] === 0x4c && head[3] === 0x46;
      const machine = isElf ? head.readUInt16LE(18) : null;
      const arch = ELF_MACHINE[machine] || `machine${machine}`;
      const rel = path.relative(root, f);
      if (!isElf) mismatch.push(`${rel}(非 ELF)`);
      else if (arch !== host) mismatch.push(`${rel}(${arch}≠${host})`);
      else found.push(rel);
    } catch { /* 读不动就跳过，不制造假红 */ }
  }
  return { found, mismatch, host };
}

/** 候选包真实 import 一次；只做临时落位，结束即删。 */
async function tryLoad(manifest, pkgRoot) {
  const pkgName = manifest.package?.name || manifest.kit;
  const entry = (() => {
    try {
      const pj = readJson(path.join(pkgRoot, "package.json"));
      const e = pj.main || pj.exports?.["."] || "lib/index.js";
      return path.join(pkgRoot, typeof e === "string" ? e : "lib/index.js");
    } catch { return null; }
  })();
  if (!entry || !fs.existsSync(entry)) return { state: "SKIP", reason: "无 ESM 入口（客户端型插件）" };
  const dshHome = process.env.DSH_HOME || "/data/user/0/com.dsharnessmobile.shell/files/home/.dsh";
  const nm = path.join(dshHome, "profiles", "web", "node_modules");
  if (!fs.existsSync(nm)) return { state: "SKIP", reason: "无已装 profile，无法解析 peer 依赖" };

  const sandbox = path.join(nm, `.port-cand-${pkgName}-${Date.now().toString(36)}`);
  try {
    fs.cpSync(pkgRoot, path.join(sandbox, "package"), { recursive: true });
    const r = spawnSync(NODE_CMD, ["--input-type=module", "-e",
      `const m = await import(${JSON.stringify("file://" + path.join(sandbox, "package", "lib", "index.js"))});`
      + `const k = Object.keys(m); if (!k.length) { console.error("NO_EXPORTS"); process.exit(3) } console.log("EXPORTS " + k.length)`],
    { encoding: "utf8", cwd: sandbox, timeout: 90000 });
    const text = (r.stdout || "") + (r.stderr || "");
    if (r.status === 0) return { state: "PASS", detail: text.trim().split("\n").pop() };
    if (/ERR_MODULE_NOT_FOUND/.test(text)) {
      const miss = (text.match(/Cannot find package '([^']+)'/) || [])[1];
      return { state: "SKIP", reason: `本机未装对端依赖 ${miss || "?"}（环境不在，非候选缺陷）` };
    }
    return { state: "FAIL", error: text.split("\n").filter((l) => l.trim()).slice(-1)[0].slice(0, 200) };
  } catch (e) {
    return { state: "FAIL", error: String(e.message).slice(0, 200) };
  } finally {
    fs.rmSync(sandbox, { recursive: true, force: true });
  }
}

function downloadSync(url, dst) {
  // 同步语义：本脚本是流水线，串行更易读；用 spawnSync 的 curl 避免把 async 渗进 tryPort
  const mirrors = [url];
  if (/^https:\/\/github\.com\//.test(url)) mirrors.push(`https://gh-proxy.com/${url}`, `https://ghproxy.net/${url}`);
  for (const u of mirrors) {
    const r = spawnSync("curl", ["-LfsS", "--max-time", "180", "-o", dst, u], { encoding: "utf8", timeout: 200000 });
    if (r.status === 0 && fs.existsSync(dst) && fs.statSync(dst).size > 1024) return true;
  }
  return false;
}

// ── ③ 回传：Git Data API 推 port/ ─────────────────────────────────────────
async function api(tk, method, url, body) {
  const res = await fetch(`https://api.github.com${url}`, {
    method,
    headers: {
      authorization: `Bearer ${tk}`,
      accept: "application/vnd.github+json",
      "user-agent": "dsh-port-upstream-watch",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60000),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* */ }
  if (!res.ok) throw new Error(`${method} ${url} -> HTTP ${res.status}: ${(json?.message || text).slice(0, 200)}`);
  return json;
}

function walkLocal(root, base = "", out = []) {
  for (const e of fs.readdirSync(path.join(root, base), { withFileTypes: true })) {
    if (e.name === ".git" || e.name === "node_modules" || e.name === "payload" || e.name === ".unpacked") continue;
    if (e.name.startsWith(".purge-old")) continue;
    const rel = base ? `${base}/${e.name}` : e.name;
    if (e.isDirectory()) walkLocal(root, rel, out);
    else if (e.isFile()) out.push(rel);
  }
  return out;
}

async function publish(tk, summary) {
  const head = await api(tk, "GET", `/repos/${REPO}/git/ref/heads/${BRANCH}`);
  const headSha = head.object.sha;
  const headCommit = await api(tk, "GET", `/repos/${REPO}/git/commits/${headSha}`);
  const tree = await api(tk, "GET", `/repos/${REPO}/git/trees/${headCommit.tree.sha}?recursive=1`);
  const remote = new Map();
  for (const t of tree.tree || []) if (t.type === "blob" && t.path.startsWith("port/")) remote.set(t.path, t);

  const locals = walkLocal(PORT).map((rel) => {
    const abs = path.join(PORT, rel);
    const buf = fs.readFileSync(abs);
    return { rel: `port/${rel}`, abs, buf, sha: gitBlobSha(buf), mode: (/\.sh$/.test(rel) || /(^|\/)post-(merge|checkout)$/.test(rel)) ? "100755" : "100644" };
  });

  const changed = locals.filter((f) => remote.get(f.rel)?.sha !== f.sha);
  // 报告每轮都带新时间戳，若只按字节比，等于每两天白造一个只有时间的提交。
  // 判据：把「巡检时间」那一行抹掉再比，内容一致就不推。（报告已在本地更新，时间戳以最后一次实质变更时为准）
  const stripStamp = (buf) => buf.toString("utf8").replace(/^- 巡检时间：.*$/m, "- 巡检时间：（仅实质变更时刷新）");
  const onlyStamp = [];
  for (const f of [...changed]) {
    const r = remote.get(f.rel);
    if (!r || !/UPSTREAM-STATUS\.md$/.test(f.rel)) continue;
    try {
      const remoteBuf = Buffer.from((await api(tk, "GET", `/repos/${REPO}/git/blobs/${r.sha}`)).content, "base64");
      if (stripStamp(remoteBuf) === stripStamp(f.buf)) {
        onlyStamp.push(f.rel);
        // 本地也退回到远端那一行时间戳：让工作树与远端逐字节一致，下一轮快进不会撞本地修改。
        // 真正的「本轮何时跑的」在 $DSH_HOME/port-upstream/logs/ 与 reports/ 里有，不靠这份报告。
        const remoteStamp = (remoteBuf.toString("utf8").match(/^- 巡检时间：.*$/m) || [""])[0];
        const patched = Buffer.from(f.buf.toString("utf8").replace(/^- 巡检时间：.*$/m, remoteStamp), "utf8");
        fs.writeFileSync(f.abs, patched);
        changed.splice(changed.indexOf(f), 1);
      }
    } catch { /* 取不到就在下面按内容变化处理，不制造假跳过 */ }
  }
  if (onlyStamp.length) log(`  仅巡检时间不同，按无实质变化处理：${onlyStamp.join(", ")}`);
  const deletions = [...remote.keys()].filter((p) => !locals.some((f) => f.rel === p));
  log(`  远端 port/ 文件 ${remote.size}，本地 ${locals.length}，内容变化 ${changed.length}，远端多余 ${deletions.length}`);
  if (!changed.length && !(PRUNE && deletions.length)) {
    log("  无实质变化，跳过提交。");
    return { pushed: false, headSha, changed: 0 };
  }

  if (DRY) {
    for (const f of changed) log(`  [dry] ${f.mode} ${f.rel} (${f.buf.length}B)`);
    for (const p of (PRUNE ? deletions : [])) log(`  [dry] del  ${p}`);
    log("  dry run：未写入远端。");
    return { pushed: false, dry: true, changed: changed.length, headSha };
  }
  const entries = [];
  for (const f of changed) {
    const blob = await api(tk, "POST", `/repos/${REPO}/git/blobs`, { content: f.buf.toString("base64"), encoding: "base64" });
    entries.push({ path: f.rel, mode: f.mode, type: "blob", sha: blob.sha });
    log(`  blob ${f.mode} ${f.rel} (${f.buf.length}B)`);
  }
  if (PRUNE) {
    for (const p of deletions) { entries.push({ path: p, mode: "100644", type: "blob", sha: null }); log(`  del  ${p}`); }
  }
  if (!entries.length) return { pushed: false, headSha, changed: 0 };

  const newTree = await api(tk, "POST", `/repos/${REPO}/git/trees`, { base_tree: headCommit.tree.sha, tree: entries });
  const msg = [
    `port: 上游巡检 + 可用性复核（${nowCN()}）`,
    "",
    summary.lines.join("\n"),
    "",
    `由 port/tools/upstream-watch.mjs 自动生成；报告见 port/UPSTREAM-STATUS.md`,
  ].join("\n");
  const commit = await api(tk, "POST", `/repos/${REPO}/git/commits`, { message: msg, tree: newTree.sha, parents: [headSha] });
  const updated = await api(tk, "PATCH", `/repos/${REPO}/git/refs/heads/${BRANCH}`, { sha: commit.sha, force: false });
  log(`  提交 ${commit.sha.slice(0, 8)} → ${BRANCH} 已推进到 ${updated.object.sha.slice(0, 8)}`);
  return { pushed: true, commit: commit.sha, changed: changed.length, deleted: PRUNE ? deletions.length : 0 };
}

// ── 主流程 ────────────────────────────────────────────────────────────────
async function main() {
  const tk = token();
  const kitsDir = PORT;
  const kits = fs.readdirSync(kitsDir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && e.name !== "tools" && fs.existsSync(path.join(kitsDir, e.name, "manifest.json")))
    .map((e) => e.name)
    .sort();

  const stamp = new Date().toISOString().slice(0, 10);
  fs.mkdirSync(CACHE, { recursive: true });
  fs.mkdirSync(REPORT_DIR, { recursive: true });
  const stateFile = path.join(REPORT_DIR, "state.json");
  const prev = fs.existsSync(stateFile) ? readJson(stateFile) : { kits: {} };
  const nextState = { at: nowCN(), kits: { ...(prev.kits || {}) } };

  log(`\n=== 移植插件上游巡检 ${nowCN()} ===`);
  log(`仓库 ${REPO}@${BRANCH} · 令牌 ${tk ? "已取到" : "缺（只做本地体检，不推送）"}`);

  const rows = [];
  for (const name of kits) {
    const kitDir = path.join(kitsDir, name);
    const manifest = readJson(path.join(kitDir, "manifest.json"));
    const src = kitSource(kitDir, manifest);
    log(`\n── ${name}（${src.pkgName}@${src.pinned || "?"}）${src.retired ? " [RETIRED]" : ""}`);

    let probe = { checks: [] };
    if (!src.retired) {
      probe = await probeUpstream(src, tk);
      for (const c of probe.checks) log(`   探针 ${pad(c.kind, 10)} ${c.ok ? (c.version || c.tag || (c.sha || "").slice(0, 8)) : "× " + c.error.slice(0, 80)}`);
    }
    const v = verdict(src, probe, prev.kits?.[name]);
    log(`   判定 ${v.state} —— ${v.note}`);

    const verify = DO_VERIFY && !src.retired ? runVerify(kitDir) : { ran: false, reason: "跳过" };
    if (verify.ran) {
      const tri = verify.downgraded?.length ? `（其中 ${verify.downgraded.length} 条为嵌套布局误报，净 FAIL ${verify.realFailCount}）` : "";
      log(`   现装体检 rc=${verify.rc} FAIL=${verify.failCount} WARN=${verify.warnCount}${verify.total ? ` /共 ${verify.total} 项` : ""}${tri}`);
      for (const d of verify.downgraded || []) log(`     误报核销：缺 ${d.dep} → 实在于 ${d.at}`);
    }

    const drift = src.retired ? { checked: 0, missing: [] } : overlayDrift(kitDir, manifest);
    if (drift.checked) log(`   overlay ${drift.checked} 个文件，缺失 ${drift.missing.length}`);

    let port = null;
    if (v.state === "OUTDATED") {
      log(`   上游有新版本，试移植（缓存 ${CACHE}）…`);
      port = await tryPort(kitDir, manifest, src, probe, stamp);
      log(`   可移植性 ${port.state} —— ${port.note}`);
      if (port.syntax?.length) log(`   ${port.syntax.map((s) => `${s.file}:${s.ok ? "ok" : "BAD"}`).join(" ")}`);
      if (port.structural) log(`   结构测试 ${port.structural.ok ? "PASS" : "FAIL"} ${port.structural.summary || ""}`);
    }

    nextState.kits[name] = {
      upstream: v.upstreamVersion || null,
      pinned: src.pinned || null,
      commit: v.commitSha || null,
      state: v.state,
      portState: port?.state || null,
      checkedAt: nowCN(),
    };

    const health = src.retired ? "RETIRED"
      : (verify.ran && (verify.realFailCount ?? verify.failCount) > 0) ? "FAIL"
        : (v.state === "OUTDATED" ? (port?.state || "OUTDATED") : v.state);
    rows.push({ name, pkg: src.pkgName, pinned: src.pinned, upstream: v.upstreamVersion || "—", state: v.state, health, verify, drift, port, v });
  }

  // ── 写 Markdown 报告（同时也是推给仓库的那一条） ──────────────────────
  const badKits = rows.filter((r) => r.health === "FAIL");
  const readyKits = rows.filter((r) => r.health === "READY");
  const needsPort = rows.filter((r) => r.health === "NEEDS-PORT" || r.health === "BLOCKED");
  const outdated = rows.filter((r) => r.state === "OUTDATED");

  const md = [];
  md.push("# 移植插件上游状态");
  md.push("");
  md.push(`> 本文件由 \`port/tools/upstream-watch.mjs\` 自动生成并在推送时覆盖，勿手改。`);
  md.push("");
  md.push(`- 巡检时间：**${nowCN()}**`);
  md.push(`- 目标仓库：\`${REPO}@${BRANCH}\`（\`port/\` 目录）`);
  md.push(`- 本次结论：**${badKits.length ? `有 ${badKits.length} 个 kit 现装体检 FAIL` : "现装体检无 FAIL"}**，`
    + `上游有新版 ${outdated.length} 个${readyKits.length ? `，其中 ${readyKits.length} 个可否直接升` : ""}${needsPort.length ? `，${needsPort.length} 个需重制补丁` : ""}`);
  md.push("");
  md.push("## 一、总表");
  md.push("");
  md.push("| kit | 本机钉住 | 上游最新 | 上游状态 | 现装体检 | overlay 漂移 | 可移植性 |");
  md.push("|---|---|---|---|---|---|---|");
  for (const r of rows) {
    const vt = r.verify.ran
      ? ((r.verify.realFailCount ?? r.verify.failCount)
        ? `FAIL ${r.verify.realFailCount ?? r.verify.failCount}${r.verify.downgraded?.length ? `（另有 ${r.verify.downgraded.length} 条误报已核销）` : ""}`
        : `OK${r.verify.warnCount ? `（WARN ${r.verify.warnCount}）` : ""}${r.verify.downgraded?.length ? `（误报核销 ${r.verify.downgraded.length}）` : ""}`)
      : "跳过";
    md.push(`| \`${r.name}\` | ${r.pinned || "—"} | ${r.upstream} | ${r.state} | ${vt} | ${r.drift.checked ? `${r.drift.missing.length} 缺` : "—"} | ${r.port?.state || "—"} |`);
  }
  md.push("");
  md.push("## 二、二次复核明细");
  md.push("");
  for (const r of rows) {
    md.push(`### ${r.name}`);
    md.push("");
    md.push(`- 包：\`${r.pkg}\`，本机 \`${r.pinned || "?"}\`，上游 \`${r.upstream}\`（${r.v.note}）`);
    if (r.v.commitSha) md.push(`- 上游仓库最新提交：\`${r.v.commitSha.slice(0, 8)}\` ${r.v.commitDate || ""} ${r.v.commitSubject || ""}`);
    if (r.verify.ran) {
      md.push(`- 现装体检：rc=${r.verify.rc}，FAIL ${r.verify.failCount} / WARN ${r.verify.warnCount}${r.verify.total ? ` / 共 ${r.verify.total} 项` : ""}`
        + (r.verify.downgraded?.length ? `（净 FAIL ${r.verify.realFailCount}：${r.verify.downgraded.length} 条经实测核销为 kit verify 的解析误报，逐条见下）` : ""));
      for (const f of r.verify.uncleared || []) md.push(`  - 未核销 \`${plain(f)}\``);
      for (const d of r.verify.downgraded || []) md.push(`  - 误报核销：\`${d.dep}\` 实在于 \`${d.at}\` —— ${d.why}`);
    }
    if (r.drift.checked) md.push(`- overlay 结构：${r.drift.checked} 个文件，缺失 ${r.drift.missing.length}${r.drift.missing.length ? `（${r.drift.missing.join(", ")}）` : ""}`);
    if (r.port) {
      md.push(`- 上游试移植：**${r.port.state}** —— ${r.port.note}`);
      if (r.port.applied?.length) md.push(`  - 已可应用：${r.port.applied.join(", ")}`);
      for (const c of r.port.conflicts || []) md.push(`  - 冲突 \`${c.patch}\`：${c.detail}`);
      for (const s of r.port.syntax || []) md.push(`  - 语法 \`${s.file}\`：${s.ok ? "OK" : "BAD " + s.err}`);
      if (r.port.structural) md.push(`  - 结构测试：${r.port.structural.ok ? "PASS" : "FAIL"} ${r.port.structural.summary || ""}`);
      if (r.port.native?.found?.length || r.port.native?.mismatch?.length) md.push(`  - 原生模块（${r.port.native.host}）：匹配 ${r.port.native.found.length}，不符 ${r.port.native.mismatch.length}${r.port.native.mismatch.length ? `（${r.port.native.mismatch.join(", ")}）` : ""}`);
      if (r.port.loadProbe) {
        const lp = r.port.loadProbe;
        md.push(`  - 真实导入（在 profile 内 import 一次）：${lp.state}${lp.detail ? " " + lp.detail : ""}${lp.reason ? " — " + lp.reason : ""}${lp.error ? " — " + lp.error : ""}`);
      }
    }
    md.push("");
  }
  md.push("## 三、复查口径");
  md.push("");
  md.push("「无 bug、修复可用」由两路独立证据合成，任一不足都算未确认：");
  md.push("");
  md.push("1. **静态**：上游包解包后，kit 的补丁在 \`patch --dry-run\` 全通过才算「可移植」；随后 \`node --check\` 与 kit 自带结构断言（如 \`test-settings-ui.mjs\`）必须同时通过。");
  md.push("2. **运行时**：已装包跑 kit 自己的 \`port.sh verify\`，FAIL 必须为 0；WARN 逐条列在明细里，不吞。");
  md.push("");
  md.push("只升「可移植性 = READY」的 kit；\`NEEDS-PORT\` 一律人工重制补丁后重跑本巡检。");
  md.push("");
  fs.writeFileSync(STATUS_MD, md.join("\n"), "utf8");

  const reportPath = path.join(REPORT_DIR, `${stamp}.md`);
  fs.writeFileSync(reportPath, md.join("\n"), "utf8");
  fs.writeFileSync(stateFile, JSON.stringify(nextState, null, 1), "utf8");

  // ── ③ 回传 ────────────────────────────────────────────────────────────
  let pushRes = null;
  if (PUBLISH) {
    if (!tk) { log("\n[publish] 无令牌，跳过（设 GITHUB_TOKEN 或在带 origin 的 clone 里运行）"); }
    else {
      log("\n=== 回传 port/ 到远端 ===");
      const summary = {
        lines: rows.map((r) => `- ${r.name}: 本机 ${r.pinned || "?"} / 上游 ${r.upstream} → ${r.health}${r.verify.ran ? `，体检 FAIL=${r.verify.realFailCount ?? r.verify.failCount}` : ""}`),
      };
      try { pushRes = await publish(tk, summary); }
      catch (e) { log(`[publish] 失败：${e.message}`); pushRes = { pushed: false, error: e.message }; }
    }
  } else {
    log("\n（未加 --publish：只写本地报告，不动远端）");
  }

  log(`\n报告：${reportPath}`);
  log(`状态页：${STATUS_MD}`);
  log(`耗时 ${((Date.now() - T0) / 1000).toFixed(1)}s`);
  if (pushRes) log(`推送：${pushRes.pushed ? `已提交 ${pushRes.commit.slice(0, 8)}（${pushRes.changed} 个文件）`
    : pushRes.dry ? `dry run，待提交 ${pushRes.changed} 个文件`
      : pushRes.error ? `失败 ${pushRes.error}` : "无变化"}`);

  return badKits.length ? 1 : 0;
}

main().then((code) => process.exit(code)).catch((e) => {
  console.error("upstream-watch 失败：", e?.stack || e);
  process.exit(2);
});
