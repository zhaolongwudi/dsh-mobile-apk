#!/usr/bin/env node
// 从远端 main 的 port/dsh-memento 子树里摘掉 payload.tar.gz，使仓库与 jet-hub/dsh-purge 约定一致
// （仓库不背载荷，只放 fetch-payload.sh）。同时用一条**与实际内容相符**的提交信息。
//
// 为什么要这么做：上一版发布命令漏传 --exclude，把 226 KB 载荷一起提交了，
// 且提交信息写的是「不含载荷」——信息与内容不符。这里修正内容并重写说明。
//
// 用法：node unpublish-payload.mjs [--dry]
import { execFileSync } from "node:child_process";

const DRY = process.argv.includes("--dry");
const REPO = "zhaolongwudi/dsh-mobile-apk";
const BRANCH = "main";
const KEEP_PATH = "port/dsh-memento";
const DROP = "payload.tar.gz";

function token() {
  const url = execFileSync("git", ["remote", "get-url", "origin"], { encoding: "utf8", cwd: "/storage/emulated/0/Download/DSH/破甲移植/fork" }).trim();
  const m = url.match(/^https:\/\/(?:x-access-token:)?([^@]+)@/);
  if (!m) throw new Error("找不到令牌");
  return decodeURIComponent(m[1]);
}
const TOKEN = token();
const API = "https://api.github.com";

async function api(method, url, body) {
  const res = await fetch(`${API}${url}`, {
    method,
    headers: {
      authorization: `Bearer ${TOKEN}`,
      accept: "application/vnd.github+json",
      "user-agent": "memento-port-fix",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${url} -> ${res.status} ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

const ref = await api("GET", `/repos/${REPO}/git/ref/heads/${BRANCH}`);
const headSha = ref.object.sha;
const headCommit = await api("GET", `/repos/${REPO}/git/commits/${headSha}`);
console.log("当前 main tip:", headSha, "\ntree:", headCommit.tree.sha);

// 取 port/dsh-memento 子树
const kit = await api("GET", `/repos/${REPO}/git/trees/${headCommit.tree.sha}?recursive=1`);
const findKit = kit.tree.find((n) => n.path === KEEP_PATH && n.type === "tree");
if (!findKit) throw new Error("找不到 " + KEEP_PATH);

// 重建 port/dsh-memento 子树：原样保留，只去掉 DROP
const kitTree = await api("GET", `/repos/${REPO}/git/trees/${findKit.sha}`);
const kept = kitTree.tree.filter((n) => n.path !== DROP);
const dropped = kitTree.tree.filter((n) => n.path === DROP);
if (!dropped.length) {
  console.log("子树里没有 " + DROP + "，无需处理。");
  process.exit(0);
}
console.log("将移除:", dropped.map((d) => d.path + " (" + d.size + "B)").join(", "));
console.log("将保留:", kept.map((k) => k.path + (k.type === "tree" ? "/" : "")).join(", "));

if (DRY) { console.log("\n[dry] 未写入"); process.exit(0); }

const newKitTree = await api("POST", `/repos/${REPO}/git/trees`, {
  tree: kept.map((n) => ({ path: n.path, mode: n.mode, type: n.type, sha: n.sha })),
});

// 用 base_tree = 旧顶层树，覆盖 port/dsh-memento 一个条目
const newTop = await api("POST", `/repos/${REPO}/git/trees`, {
  base_tree: headCommit.tree.sha,
  tree: [{ path: KEEP_PATH, mode: "040000", type: "tree", sha: newKitTree.sha }],
});

const msg = [
  "port: dsh-memento 记忆插件移植包上 main",
  "",
  "把 dsh-memento（跨会话长期记忆，本地 SQLite）移植进本机 DeepCode 的 web profile。",
  "纯 JS 插件、零运行依赖、零原生模块；不改宿主运行时树",
  "（与 dsh-purge 需要重打的 86 条宿主补丁不同，本 kit 只体检不写宿主）。",
  "",
  "三处落点全部走快照「合并保留」，已读上游 Kotlin 源码逐行确认：",
  "  · SnapshotTransaction.mergeTree() 只遍历工厂侧子项 ⇒ 插件目录永不被删",
  "  · ProfilePackageManifest.merge() 以用户清单为基座、工厂只补缺键 ⇒ 装配逐字节保留",
  "  · 未知 .dsh 项按用户数据保留 ⇒ memory.db 存活",
  "",
  "附 guard.sh（体检 + 装配漂移自愈，已做删键演练反证）与",
  "sim-upstream-merge.sh（上游合并 A/B/C 三场景实证）。",
  "",
  "仓库不背载荷，与 port/jet-hub、port/dsh-purge 同一约定；",
  "需要时 bash fetch-payload.sh --pack 按 manifest 版本重建并核对 sha256。",
].join("\n");

const newCommit = await api("POST", `/repos/${REPO}/git/commits`, {
  message: msg,
  tree: newTop.sha,
  parents: [headSha],
});
await api("PATCH", `/repos/${REPO}/git/refs/heads/${BRANCH}`, { sha: newCommit.sha, force: false });
console.log("\n新 tree:", newTop.sha);
console.log("新提交 :", newCommit.sha);
console.log("main 已更新。");
