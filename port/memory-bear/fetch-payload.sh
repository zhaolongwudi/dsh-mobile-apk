#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# 从 npm registry 按 manifest.json 钉住的版本重新下载离线载荷（不依赖 pnpm / npm / git）。
#
# 用途：把 kit 提交在仓库里时不必背二进制；换机/重装后一条命令就能把
#       port/memory-bear/payload/ 重建出来，随后 port.sh install 直接可用。
#
# 用法：bash fetch-payload.sh            # 下载到 ./payload（已存在同名包则跳过）
#       bash fetch-payload.sh --force    # 覆盖已有包
#       bash fetch-payload.sh --pack     # 额外打成 payload.tar.gz（确定性打包）
#       bash fetch-payload.sh --verify   # 只核验已下载包的 sha256，不下载
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -x "$FILES/usr/bin/node" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
NODE=${NODE:-$FILES/usr/bin/node}

die() { printf 'fetch: %s\n' "$*" >&2; exit 1; }
[ -x "$NODE" ] || die "找不到 node：$NODE"
[ -f "$SELF/manifest.json" ] || die "缺少 manifest.json"

PACK=0; FORCE=0; ONLYVERIFY=0
for a in "$@"; do
  case "$a" in
    --pack) PACK=1 ;;
    --force) FORCE=1 ;;
    --verify) ONLYVERIFY=1 ;;
    *) die "未知参数：$a" ;;
  esac
done

"$NODE" --input-type=module -e '
import { readFileSync, mkdirSync, existsSync, writeFileSync, rmSync, statSync, readdirSync } from "node:fs"
import { gunzipSync, gzipSync } from "node:zlib"
import { createHash } from "node:crypto"
import { join, dirname } from "node:path"
import { execFileSync } from "node:child_process"

const [kit, packArg, forceArg, verifyArg] = process.argv.slice(1)
const packFlag = packArg === "1"
const force = forceArg === "1"
const onlyVerify = verifyArg === "1"
const manifest = JSON.parse(readFileSync(join(kit, "manifest.json"), "utf8"))
const registry = manifest.registry ?? "https://registry.npmjs.org"

// 载荷清单 = 主包 + 备选变体 + 传递依赖（shared 的三个也带上，保证 QEMU 之外换机自足）
const variantNames = Object.entries(manifest.variants)
  .filter(([k, v]) => v && typeof v === "object" && v.name && v.version)
  .map(([k, v]) => [v.name, v.version, k])

const targets = [
  [manifest.package.name, manifest.package.version, "primary"],
  ...variantNames.filter(([n]) => n !== manifest.package.name),
  ...Object.entries(manifest.bundledDependencies).map(([name, version]) => [name, version, "dep"]),
]

// 去重（主包可能与 default 变体同名）
const seen = new Set()
const list = targets.filter(([n]) => !seen.has(n) && seen.add(n))

const out = join(kit, "payload", "node_modules")
const expected = manifest.upstreamTarballs ?? {}
const keyOf = (name, version) => `${name}@${version}`

/** 极简 tar 解析：只处理 ustar 常规文件与目录（npm 包无长名链接，prefix 字段已兼容）。 */
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
    if (!full || full === ".") continue
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

function sha256File(p) {
  return createHash("sha256").update(readFileSync(p)).digest("hex")
}

// 目录级指纹：把所有文件相对路径 + 内容哈希后聚合，用于「与 profile 现有副本是否逐字节相同」
function treeDigest(dir) {
  const h = createHash("sha256")
  const walk = (d, base) => {
    for (const e of readdirSync(d, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const p = join(d, e.name)
      const rel = base ? `${base}/${e.name}` : e.name
      if (e.isDirectory()) walk(p, rel)
      else h.update(rel).update("\0").update(readFileSync(p)).update("\0")
    }
  }
  walk(dir, "")
  return h.digest("hex")
}

if (onlyVerify) {
  let bad = 0
  console.log("核验模式：只比对 sha256，不下载")
  for (const [name, version] of list.map(([n, v]) => [n, v])) {
    const exp = expected[keyOf(name, version)]
    const dir = join(out, name)
    if (!existsSync(join(dir, "package.json"))) { console.log(`  MISS  ${name}@${version}（未下载）`); bad++; continue }
    const actual = JSON.parse(readFileSync(join(dir, "package.json"), "utf8")).version
    if (actual !== version) { console.log(`  FAIL  ${name} 版本 ${actual} ≠ ${version}`); bad++; continue }
    console.log(`  OK    ${name}@${version}${exp ? `  tree-digest=${treeDigest(dir).slice(0, 16)}…` : ""}`)
  }
  process.exit(bad ? 1 : 0)
}

for (const [name, version, role] of list) {
  const dir = join(out, name)
  if (!force && existsSync(join(dir, "package.json"))) {
    const have = JSON.parse(readFileSync(join(dir, "package.json"), "utf8")).version
    if (have === version) { console.log(`skip  ${name}@${version}（已存在，${role}）`); continue }
    console.log(`warn  ${name} 现有版本 ${have} ≠ ${version}，--force 可覆盖`)
    continue
  }
  const base = name.includes("/") ? name.split("/")[1] : name
  const url = `${registry}/${name}/-/${base}-${version}.tgz`
  process.stdout.write(`fetch ${name}@${version} … `)
  const res = await fetch(url, { redirect: "follow" })
  if (!res.ok) throw new Error(`${name}@${version}: HTTP ${res.status} ${url}`)
  const tgz = Buffer.from(await res.arrayBuffer())
  const got = createHash("sha256").update(tgz).digest("hex")
  const exp = expected[keyOf(name, version)]
  if (exp?.sha256 && exp.sha256 !== got) {
    throw new Error(`${name}@${version} sha256 不符：期望 ${exp.sha256}，实得 ${got}`)
  }
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(dir, { recursive: true })
  const files = untar(gunzipSync(tgz), dir)
  console.log(`${(tgz.length / 1048576).toFixed(2)} MB, ${files} files${exp?.sha256 ? ", sha256 ✓" : ", sha256 未比对"}`)
}

if (packFlag) {
  // 与仓库里的载荷同布局（node_modules/ 为顶层）、同确定性参数：
  // GNU tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner + gzip -9
  const parent = join(kit, "payload")
  const tarBin = existsSync("/data/data/com.dsharnessmobile.shell/files/usr/bin/tar")
    ? "/data/data/com.dsharnessmobile.shell/files/usr/bin/tar" : "tar"
  const raw = execFileSync(tarBin, [
    "--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner",
    "-cf", "-", "node_modules",
  ], { cwd: parent, maxBuffer: 1 << 30 })
  const gz = gzipSync(raw, { level: 9 })
  writeFileSync(join(kit, "payload.tar.gz"), gz)
  const sha = createHash("sha256").update(gz).digest("hex")
  const countFiles = (d) => {
    let n = 0
    const walk = (x) => {
      for (const e of readdirSync(x, { withFileTypes: true })) e.isDirectory() ? walk(join(x, e.name)) : n++
    }
    walk(d)
    return n
  }
  const files = countFiles(join(parent, "node_modules"))
  console.log(`packed payload.tar.gz ${gz.length} bytes  ${files} files  sha256=${sha}`)
  const pinned = manifest.payload?.sha256
  if (pinned && pinned !== sha) console.log(`note  manifest 钉的 sha256=${pinned}（若仅目录权限位变化属正常，内容清单一致即可）`)
}
' "$SELF" "$PACK" "$FORCE" "$ONLYVERIFY"

echo "载荷就绪：$SELF/payload/node_modules"
