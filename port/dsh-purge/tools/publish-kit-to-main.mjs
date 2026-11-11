#!/data/data/com.dsharnessmobile.shell/files/usr/bin/node
// ============================================================================
// publish-kit-to-main.mjs —— 用 GitHub Git Data API 把一个 port kit 直接追加到 main
//
// 为什么不用本地 plumbing 再 push：
//   工作区那份 clone 是**浅 + blobless**（git fetch --depth=1 --filter=blob:none）。
//   在它上面 git read-tree/write-tree 会隐式去 promisor 远端取 blob（实测要取
//   port/jet-hub/README.md），而本机直连 github.com 超时 → 卡满 134s 后 fatal。
//   服务端做同样的事就没有这个问题：GitHub 手里有全部对象，我们只上传这十几个小文件，
//   先用 base_tree 继承当前 main 的整棵树（jet-hub 等原样保留），再挂上我们的子目录。
//
// 语义：fast-forward 追加一个提交到 main（不是本地 merge，也不是 PR）。
//
// 用法：
//   node publish-kit-to-main.mjs --repo owner/name --dir <本地 kit 目录> \
//        --prefix <仓库内路径> --message "..." [--dry]
// 令牌：从环境 GITHUB_TOKEN 取；未设置则从 git remote URL 里解析（不打印）。
// 输出：只打印 sha 与结果，绝不打印令牌。
// ============================================================================
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
const REPO = opt("--repo");
const KIT = opt("--dir");
const PREFIX = (opt("--prefix") || "").replace(/^\/+|\/+$/g, "");
const MESSAGE = opt("--message");
const DRY = args.includes("--dry");
const BRANCH = opt("--branch", "main");
const EXCLUDE = (opt("--exclude", "") || "").split(",").map((s) => s.trim()).filter(Boolean);

if (!REPO || !KIT || !PREFIX || !MESSAGE) {
  console.error("用法: node publish-kit-to-main.mjs --repo owner/name --dir <kit> --prefix <path> --message <msg> [--dry]");
  process.exit(2);
}

function token() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN.trim();
  try {
    const url = execFileSync("git", ["remote", "get-url", "origin"], { encoding: "utf8", cwd: process.cwd() }).trim();
    const m = url.match(/^https:\/\/(?:x-access-token:)?([^@]+)@/);
    if (m) return decodeURIComponent(m[1]);
  } catch { /* 不在仓库里或没有 remote */ }
  console.error("找不到令牌：设 GITHUB_TOKEN，或在带 origin remote 的仓库里运行");
  process.exit(2);
}
const TOKEN = token();
const API = "https://api.github.com";

async function api(method, url, body) {
  const res = await fetch(`${API}${url}`, {
    method,
    headers: {
      authorization: `Bearer ${TOKEN}`,
      accept: "application/vnd.github+json",
      "user-agent": "dsh-port-publisher",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(45000),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 非 JSON */ }
  if (!res.ok) {
    const detail = json?.message || text.slice(0, 300);
    throw new Error(`${method} ${url} -> HTTP ${res.status}: ${detail}`);
  }
  return json;
}

// 1) 当前 main 与其树
const ref = await api("GET", `/repos/${REPO}/git/ref/heads/${BRANCH}`);
const headSha = ref.object.sha;
const headCommit = await api("GET", `/repos/${REPO}/git/commits/${headSha}`);
console.log(`main tip    : ${headSha.slice(0, 8)}`)
console.log(`base tree   : ${headCommit.tree.sha.slice(0, 8)}`);

// 2) 收集本地文件（排除载荷等）
function walk(dir, base = "") {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (e.name === ".unpacked" || e.name === "payload" || e.name === "node_modules" || e.name.startsWith(".git")) continue;
    const full = path.join(dir, e.name);
    const rel = base ? `${base}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...walk(full, rel));
    else if (e.isFile()) {
      if (EXCLUDE.includes(e.name) || EXCLUDE.includes(rel)) continue;
      out.push({ rel, full });
    }
  }
  return out;
}
const files = walk(KIT);
if (!files.length) { console.error("kit 目录为空"); process.exit(2); }

// 3) 逐个建 blob（小文件，走 base64）
const tree = [];
for (const f of files) {
  const content = fs.readFileSync(f.full);
  const isShell = /\.sh$/.test(f.rel) || /(^|\/)post-(merge|checkout)$/.test(f.rel);
  const mode = isShell ? "100755" : "100644";
  if (DRY) { console.log(`  [dry] ${mode} ${PREFIX}/${f.rel} (${content.length}B)`); continue; }
  const blob = await api("POST", `/repos/${REPO}/git/blobs`, {
    content: content.toString("base64"), encoding: "base64",
  });
  tree.push({ path: `${PREFIX}/${f.rel}`, mode, type: "blob", sha: blob.sha });
  console.log(`  blob ${mode} ${PREFIX}/${f.rel} (${content.length}B) -> ${blob.sha.slice(0, 8)}`);
}
if (DRY) { console.log("dry run：未写入"); process.exit(0); }

// 4) 基于当前 main 的树建新树（继承 jet-hub 等既有内容）
const newTree = await api("POST", `/repos/${REPO}/git/trees`, { base_tree: headCommit.tree.sha, tree });
console.log(`new tree    : ${newTree.sha.slice(0, 8)}`);

// 5) 提交（父 = 当前 main tip，即 fast-forward 追加）
const commit = await api("POST", `/repos/${REPO}/git/commits`, {
  message: MESSAGE, tree: newTree.sha, parents: [headSha],
});
console.log(`new commit  : ${commit.sha}`);

// 6) 推进 main（force:false，非快进会被拒）
const updated = await api("PATCH", `/repos/${REPO}/git/refs/heads/${BRANCH}`, { sha: commit.sha, force: false });
console.log(`ref updated : ${updated.object.sha}`);
console.log("完成。");
