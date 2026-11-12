#!/data/data/com.dsharnessmobile.shell/files/usr/bin/bash
# 从 npm registry 按 manifest.json 钉住的版本重新下载离线载荷（不依赖 pnpm / npm / git）。
#
# 用途：把 kit 提交在仓库里时不必背二进制；换机/重装后一条命令就能把
#       port/dsh-memento/payload/ 重建出来，随后 port.sh install 直接可用。
#
# 与 port/jet-hub 版本的差异（刻意的）：
#   ① dsh-memento 的 dependencies 为空、bundledDependencies 也为空 —— 无随包依赖，
#      只取插件本身（其 peerDependencies 全部由宿主运行时解析）。
#   ② 【本轮修】载荷 = 上游 + overlay 覆盖层：
#      · 先按 manifest.upstream.files 核对**上游基线**（说得清「下载到的是哪一份上游」）；
#      · 再把 overlay/ 的补丁后态覆盖上去（两个移植修复不会在重建时丢失）；
#      · 最后按 manifest.overlay.files 复核补丁后态。
#      旧版只从 npm 拉上游就完事 —— 重建结果是**未打补丁**的包，两个修复全部消失，
#      而随后的 sha 校验必然失败（等于「离线兜底路径整体不可用」）。
#      覆盖层用 copyFileSync 而不是打补丁：不依赖 git/patch，结果确定。
#   ③ --pack 不走系统 tar（本机快照里的 tar 会 exec 到 gzip，实测 "Cannot exec"），
#      改用本 kit 自带的 tools/pack-payload.mjs（确定性 ustar，固定 mtime）。
#   ④ 打包后按 manifest.payload.sha256 核对，不一致就报错退出（可复现性检查）。
#
# 用法：bash fetch-payload.sh            # 下载到 ./payload（存在则跳过，--force 覆盖）
#       bash fetch-payload.sh --pack     # 额外打成 payload.tar.gz 并核对哈希
set -u

SELF=$(cd -- "$(dirname -- "$0")" && pwd)
FILES=${DSH_FILES_DIR:-/data/data/com.dsharnessmobile.shell/files}
[ -x "$FILES/usr/bin/node" ] || FILES=/data/user/0/com.dsharnessmobile.shell/files
NODE=${NODE:-$FILES/usr/bin/node}

die() { printf 'fetch: %s\n' "$*" >&2; exit 1; }
[ -x "$NODE" ] || die "找不到 node：$NODE"
[ -f "$SELF/manifest.json" ] || die "缺少 manifest.json"

PACK=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --pack) PACK=1 ;;
    --force) FORCE=1 ;;
  esac
done

"$NODE" --input-type=module -e '
import { readFileSync, mkdirSync, existsSync, writeFileSync, rmSync, copyFileSync } from "node:fs"
import { gunzipSync } from "node:zlib"
import { createHash } from "node:crypto"
import { join, dirname } from "node:path"

const [kit, packArg, forceArg] = process.argv.slice(1)
const packFlag = packArg === "1"
const force = forceArg === "1"
const manifest = JSON.parse(readFileSync(join(kit, "manifest.json"), "utf8"))
const registry = manifest.registry ?? "https://registry.npmjs.org"

const targets = [
  { name: manifest.package.name, version: manifest.package.version },
  ...Object.entries(manifest.bundledDependencies ?? {}).map(([name, version]) => ({ name, version })),
]

const out = join(kit, "payload", "node_modules")

const sha256 = (file) => createHash("sha256").update(readFileSync(file)).digest("hex")

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
  console.log(`${(tgz.length / 1048576).toFixed(2)} MB, ${files} files`)
}

// ── ② 基线核对 + overlay 覆盖层（重建载荷的关键一步）──
if (manifest.upstream?.files !== undefined || manifest.overlay?.files !== undefined) {
  const pkgDir = join(out, manifest.package.name)
  for (const [rel, want] of Object.entries(manifest.upstream?.files ?? {})) {
    const file = join(pkgDir, rel)
    const have = existsSync(file) ? sha256(file) : "(缺文件)"
    if (have !== want) throw new Error(`上游基线不符：${rel} want ${want} have ${have}（npm 可能重新发布过 tarball，需重新核对 manifest.upstream）`)
    console.log(`base  ${rel} ✓`)
  }
  for (const [rel, want] of Object.entries(manifest.overlay?.files ?? {})) {
    copyFileSync(join(kit, "overlay", rel), join(pkgDir, rel))
    const have = sha256(join(pkgDir, rel))
    if (have !== want) throw new Error(`overlay 覆盖后不符：${rel} want ${want} have ${have}`)
    console.log(`overlay ${rel} ✓`)
  }
}
' "$SELF" "$PACK" "$FORCE" || die "下载/解包/覆盖失败"

echo "载荷就绪：$SELF/payload/node_modules"

if [ "$PACK" = 1 ]; then
  [ -f "$SELF/tools/pack-payload.mjs" ] || die "缺少 tools/pack-payload.mjs，无法打包"
  "$NODE" "$SELF/tools/pack-payload.mjs" --root payload --out payload.tar.gz || die "打包失败"
  want=$("$NODE" -e 'const m=require(process.argv[1]);console.log(m.payload?.sha256||"")' "$SELF/manifest.json" 2>/dev/null || echo "")
  have=$("$NODE" -e '
    const {createHash}=require("node:crypto"),fs=require("node:fs");
    console.log(createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
  ' "$SELF/payload.tar.gz" 2>/dev/null || echo "")
  if [ -n "$want" ] && [ "$want" = "$have" ]; then
    echo "载荷 sha256 与 manifest 一致：$have"
  elif [ -n "$want" ]; then
    echo "载荷 sha256 不一致（可复现性告警）：" >&2
    echo "  manifest: $want" >&2
    echo "  实际    : $have" >&2
    echo "  若上游包内容已变或 npm 重新发布过 tarball，请更新 manifest.payload 与 manifest.upstream。" >&2
    exit 1
  fi
fi
