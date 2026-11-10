#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# 从 npm registry 按 manifest.json 钉住的版本重新下载离线载荷（不依赖 pnpm / npm / git）。
#
# 用途：把 kit 提交在仓库里时不必背 10 MB 二进制；换机/重装后一条命令就能把
#       port/jet-hub/payload/ 重建出来，随后 port.sh install 直接可用。
#
# 用法：bash fetch-payload.sh            # 下载到 ./payload（存在则跳过同名包，--force 覆盖）
#       bash fetch-payload.sh --pack     # 额外打成 payload.tar.gz
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -x "$FILES/usr/bin/node" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
NODE=${NODE:-$FILES/usr/bin/node}

die() { printf 'fetch: %s\n' "$*" >&2; exit 1; }
[ -x "$NODE" ] || die "找不到 node：$NODE"
[ -f "$SELF/manifest.json" ] || die "缺少 manifest.json"

PACK=0
for a in "$@"; do [ "$a" = "--pack" ] && PACK=1; done

FORCE=0
for a in "$@"; do [ "$a" = "--force" ] && FORCE=1; done

"$NODE" --input-type=module -e '
import { readFileSync, mkdirSync, existsSync, writeFileSync, rmSync } from "node:fs"
import { gunzipSync } from "node:zlib"
import { join, dirname } from "node:path"

const [kit, packArg, forceArg] = process.argv.slice(1)
const packFlag = packArg === "1"
const force = forceArg === "1"
const manifest = JSON.parse(readFileSync(join(kit, "manifest.json"), "utf8"))
const registry = manifest.registry ?? "https://registry.npmjs.org"

const targets = [
  { name: manifest.package.name, version: manifest.package.version },
  ...Object.entries(manifest.bundledDependencies).map(([name, version]) => ({ name, version })),
]

const out = join(kit, "payload", "node_modules")

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
    else if (type === "0" || type === "\0") {
      mkdirSync(dirname(target), { recursive: true })
      writeFileSync(target, data, { mode: mode & 0o777 })
      files++
    }
  }
  return files
}

for (const { name, version } of targets) {
  const dir = join(out, name)
  if (!force && existsSync(join(dir, "package.json"))) {
    console.log(`skip  ${name}@${version}（已存在）`)
    continue
  }
  const base = name.includes("/") ? name.split("/")[1] : name
  const url = `${registry}/${name}/-/${base}-${version}.tgz`
  process.stdout.write(`fetch ${name}@${version} … `)
  const res = await fetch(url, { redirect: "follow" })
  if (!res.ok) throw new Error(`${name}@${version}: HTTP ${res.status} ${url}`)
  const tgz = Buffer.from(await res.arrayBuffer())
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(dir, { recursive: true })
  const files = untar(gunzipSync(tgz), dir)
  console.log(`${(tgz.length / 1048576).toFixed(1)} MB, ${files} files`)
}

if (packFlag) {
  // 打包成 tar.gz：与仓库里原先的载荷同布局（node_modules/... 为顶层）
  const { execFileSync } = await import("node:child_process")
  execFileSync("tar", ["-cf", join(kit, "payload.raw.tar"), "-C", join(kit, "payload"), "."])
  const raw = readFileSync(join(kit, "payload.raw.tar"))
  const gz = (await import("node:zlib")).gzipSync(raw, { level: 9 })
  writeFileSync(join(kit, "payload.tar.gz"), gz)
  rmSync(join(kit, "payload.raw.tar"), { force: true })
  console.log(`packed payload.tar.gz ${(gz.length / 1048576).toFixed(1)} MB`)
}
' "$SELF" "$PACK" "$FORCE"


echo "载荷就绪：$SELF/payload/node_modules"
