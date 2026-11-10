#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# ============================================================================
# fetch-payload.sh —— 按 manifest.json 钉住的版本重建离线载荷
#
# 为什么有它：仓库里的 kit **不背 2.2 MB 二进制**（与 port/jet-hub 同一约定）。
# 换机 / 重装 / 只 clone 了仓库之后，一条命令就能把 port/dsh-purge/payload/ 重建出来，
# 随后 port.sh install 直接可用；port.sh 在缺载荷时也会自己调它。
#
# 两个来源（都钉在 manifest.json 里，不猜版本）：
#   1) package.source  —— dsh-purge-community 的 GitHub release tgz
#   2) bundledDependencies —— npm registry 上的依赖（当前只有 yaml）
#
# 镜像：本机实测直连 github.com 的 release 下载会超时，镜像 gh-proxy.com 正常
#   （2026-11-10：直连 12s 无响应；https://gh-proxy.com/<原 URL> 200 / 2,098,818 B / 1.5s）。
# 所以 github 域名的 URL 会按「直连 → DSH_PAYLOAD_MIRRORS → 内置镜像」逐个试。
# npm registry 直连可达，不走镜像。
#
# 用法：
#   bash fetch-payload.sh            # 取到 ./payload/node_modules（已存在则跳过，--force 覆盖）
#   bash fetch-payload.sh --pack     # 额外用 tools/pack-payload.mjs 打成 payload.tar.gz 并核对 sha256
# ============================================================================
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -x "$FILES/usr/bin/node" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
NODE=${NODE:-$FILES/usr/bin/node}

die() { printf 'fetch: %s\n' "$*" >&2; exit 1; }
[ -x "$NODE" ] || die "找不到 node：$NODE"
[ -f "$SELF/manifest.json" ] || die "缺少 manifest.json"

FORCE=0; PACK=0
for a in "$@"; do
  [ "$a" = "--force" ] && FORCE=1
  [ "$a" = "--pack" ] && PACK=1
done

NODE_BIN="$NODE" "$NODE" --input-type=module -e '
import { readFileSync, mkdirSync, existsSync, writeFileSync, rmSync } from "node:fs"
import { gunzipSync, gzipSync } from "node:zlib"
import { join, dirname } from "node:path"
import { createHash } from "node:crypto"

const [kit, forceArg, packArg] = process.argv.slice(1)
const force = forceArg === "1"
const pack = packArg === "1"
const manifest = JSON.parse(readFileSync(join(kit, "manifest.json"), "utf8"))
const out = join(kit, "payload", "node_modules")

// 内置镜像（前缀式）。可用 DSH_PAYLOAD_MIRRORS 覆盖，空格分隔。
const mirrors = (process.env.DSH_PAYLOAD_MIRRORS ?? "https://gh-proxy.com/ https://ghproxy.net/")
  .split(/\s+/).filter(Boolean)

/** 极简 tar 解析：只处理 ustar 常规文件与目录。npm / release tgz 的根是 package/。 */
function untar(buffer, dst) {
  let off = 0, files = 0
  while (off + 512 <= buffer.length) {
    const head = buffer.subarray(off, off + 512)
    if (head.every((b) => b === 0)) break
    const name = head.subarray(0, 100).toString("utf8").replace(/\0.*$/s, "")
    const prefix = head.subarray(345, 500).toString("utf8").replace(/\0.*$/s, "")
    const size = parseInt(head.subarray(124, 136).toString("ascii").replace(/\0.*$/s, "").trim() || "0", 8)
    const type = String.fromCharCode(head[156] || 48)
    const mode = parseInt(head.subarray(100, 108).toString("ascii").replace(/\0.*$/s, "").trim() || "644", 8)
    let full = prefix ? `${prefix}/${name}` : name
    const data = buffer.subarray(off + 512, off + 512 + size)
    off += 512 + Math.ceil(size / 512) * 512
    if (full.startsWith("package/")) full = full.slice(8)
    if (!full || full === "." || full === "./") continue
    const target = join(dst, full)
    if (!target.startsWith(dst)) throw new Error(`unsafe path ${full}`)
    if (type === "5") mkdirSync(target, { recursive: true })
    else if (type === "0" || type === "\0" || type === "") {
      mkdirSync(dirname(target), { recursive: true })
      writeFileSync(target, data, { mode: mode & 0o777 })
      files++
    }
  }
  return files
}

const isGithub = (u) => /^https:\/\/(github\.com|objects\.githubusercontent\.com|codeload\.github\.com)\//.test(u)

async function get(url, ms = 20000) {
  const res = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(ms) })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return Buffer.from(await res.arrayBuffer())
}

/** 逐个试候选地址（github 域名才走镜像）。 */
async function download(url, label) {
  const candidates = isGithub(url) ? [url, ...mirrors.map((m) => m + url)] : [url]
  const errs = []
  for (const cand of candidates) {
    const host = (() => { try { return new URL(cand).host } catch { return cand } })()
    process.stdout.write(`  try ${label} via ${host} … `)
    try {
      const buf = await get(cand)
      console.log(`${(buf.length / 1048576).toFixed(2)} MB`)
      return buf
    } catch (e) {
      console.log(`失败（${e.name === "TimeoutError" ? "超时" : e.message}）`)
      errs.push(`${cand}: ${e.message}`)
    }
  }
  throw new Error(`${label} 全部候选地址失败\n    ${errs.join("\n    ")}`)
}

const targets = [
  { name: manifest.package.name, version: manifest.package.version, url: manifest.package.source, kind: "release" },
  ...Object.entries(manifest.bundledDependencies ?? {}).map(([name, version]) => {
    const base = name.includes("/") ? name.split("/")[1] : name
    const registry = manifest.registry ?? "https://registry.npmjs.org"
    return { name, version, url: `${registry}/${name}/-/${base}-${version}.tgz`, kind: "npm" }
  }),
]

for (const t of targets) {
  const dir = join(out, t.name)
  if (!force && existsSync(join(dir, "package.json"))) { console.log(`skip  ${t.name}@${t.version}（已存在）`); continue }
  const tgz = await download(t.url, `${t.name}@${t.version}（${t.kind}）`)
  rmSync(dir, { recursive: true, force: true }); mkdirSync(dir, { recursive: true })
  const n = untar(gunzipSync(tgz), dir)
  console.log(`ok    ${t.name}@${t.version} -> ${n} files`)
}

console.log(`载荷就绪：${join(kit, "payload", "node_modules")}`)

if (pack) {
  const { execFileSync } = await import("node:child_process")
  // 坑（本机实锤）：不能用 process.execPath —— 它是 /apex/com.android.runtime/bin/linker64
  // （termux-exec 的 LD_PRELOAD 把 exec 重路由到 linker），于是 `linker64 pack-payload.mjs`
  // 会报 has bad ELF magic: 23212f75。node 路径必须由 shell 显式传入。
  const nodeBin = process.env.NODE_BIN || "node"
  const res = execFileSync(nodeBin, [join(kit, "tools", "pack-payload.mjs"), "--root", "payload"],
    { cwd: kit, encoding: "utf8" })
  const info = JSON.parse(res)
  const want = manifest.payload?.sha256 ?? ""
  console.log(`打包：${info.bytes} B / ${info.entries} files`)
  console.log(`sha256：${info.sha256}`)
  if (want) {
    if (info.sha256 === want) console.log("与 manifest 记录一致：是（载荷可逐字节复现）")
    else {
      console.log(`与 manifest 记录不一致！manifest=${want}`)
      console.log("  可能原因：上游 release 被重传、或依赖版本在 registry 上被重新发布。")
      console.log("  处理：核对后更新 manifest.payload，或改用带 payload.tar.gz 的分支副本。")
      process.exitCode = 2
    }
  }
}
' "$SELF" "$FORCE" "$PACK"
