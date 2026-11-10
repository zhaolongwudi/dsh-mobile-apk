#!/usr/bin/env node
// 把 port-kit/payload/node_modules 打包成确定性的 payload.tar.gz（ustar + gzip）。
// 不用系统 tar/gzip：Android 快照里的 tar 依赖 exec 到 gzip，本机实测 "Cannot exec: No such file or directory"。
// 用法：node tools/pack-payload.mjs [--out payload.tar.gz] [--root payload]
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const SELF = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = path.resolve(SELF, opt("--root", "payload"));
const out = path.resolve(SELF, opt("--out", "payload.tar.gz"));
const MTIME = 1731110400; // 2026-11-09T00:00:00Z，固定值保证可复现

function walk(dir, base = "") {
  const rows = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const full = path.join(dir, entry.name);
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      rows.push({ kind: "dir", rel, data: Buffer.alloc(0), mode: 0o755 });
      rows.push(...walk(full, rel));
    } else if (entry.isFile()) {
      rows.push({ kind: "file", rel, data: fs.readFileSync(full), mode: 0o644 });
    } else {
      throw new Error(`载荷里不允许链接/特殊文件：${rel}`);
    }
  }
  return rows;
}

function header(rel, size, mode, kind) {
  const buf = Buffer.alloc(512);
  const put = (str, off, len) => buf.write(str, off, Math.min(len - 1, Buffer.byteLength(str)));
  put(rel, 0, 100);
  buf.write(mode.toString(8).padStart(7, "0") + "\0", 100, 8, "ascii");
  buf.write("0000000\0", 108, 8, "ascii");
  buf.write("0000000\0", 116, 8, "ascii");
  buf.write(size.toString(8).padStart(11, "0") + "\0", 124, 12, "ascii");
  buf.write(MTIME.toString(8).padStart(11, "0") + "\0", 136, 12, "ascii");
  buf.write("        ", 148, 8, "ascii");
  buf.write(kind === "dir" ? "5" : "0", 156, 1, "ascii");
  buf.write("ustar\0", 257, 6, "ascii");
  buf.write("00", 263, 2, "ascii");
  let sum = 0;
  for (const byte of buf) sum += byte;
  buf.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");
  return buf;
}

const rows = walk(root);
const chunks = [];
for (const row of rows) {
  if (Buffer.byteLength(row.rel) > 100) throw new Error(`路径过长（ustar 上限 100）：${row.rel}`);
  chunks.push(header(row.rel, row.data.length, row.mode, row.kind));
  if (row.kind === "file") {
    chunks.push(row.data);
    const pad = (512 - (row.data.length % 512)) % 512;
    if (pad) chunks.push(Buffer.alloc(pad));
  }
}
chunks.push(Buffer.alloc(1024));
const tar = Buffer.concat(chunks);
const gz = zlib.gzipSync(tar, { level: 9 });
fs.writeFileSync(out, gz);
const sha = createHash("sha256").update(gz).digest("hex");
console.log(JSON.stringify({ out, entries: rows.filter((r) => r.kind === "file").length, bytes: gz.length, sha256: sha }, null, 1));
