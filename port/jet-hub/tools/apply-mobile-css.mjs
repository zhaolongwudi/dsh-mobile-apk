#!/data/data/com.dsharnessmobile.shell/files/usr/bin/node
// ============================================================================
// apply-mobile-css.mjs —— 把移动端适配层注入 jet-hub 客户端产物的 STYLES 末尾
//
// 为什么不在上游源码里改：jet-hub 是 npm 上的第三方包（dsh-providers-hub），
// 上游升级会整份覆盖 lib/client/jet-hub.js。改源码 = 每次升级都要重制补丁且
// 容易冲突；追加式注入 = 升级后原样重跑本脚本即可，补丁内容与被改文件解耦。
//
// 判据（幂等）：
//   已注入 → STYLES 末尾含 MOBILE_CSS_MARK，直接跳过（不重复写、不改 mtime）
//   未注入 → 备份 .mobcss.bak → 追加 → 校验语法 → 校验 marker 落地
//
// 用法：
//   node apply-mobile-css.mjs                  # 打到已装包（$DSH_HOME/profiles/web/...）
//   node apply-mobile-css.mjs --file <path>    # 打到指定文件（payload 预处理用）
//   node apply-mobile-css.mjs --check          # 只检查，不写
// ============================================================================
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";

// ⚠️ 必须用 fileURLToPath 而不是 new URL(...).pathname —— 本机工作区路径含中文
// （破甲移植），pathname 会保留百分号编码，后续 readFileSync 直接 ENOENT。
const SELF = path.dirname(fileURLToPath(import.meta.url));
const CSS_FILE = path.join(SELF, "..", "overlay", "mobile.css");

// marker 必须独一无二且在 CSS 里真的存在，用来判断「已注入」。
const MOBILE_CSS_MARK = "Jet Hub 移动端适配层（port overlay";
// ⚠️ 幂等判据用**内容哈希**而不是只看 marker：marker 是固定文本，overlay 改了
// 内容但 marker 不变时，只看 marker 会误判「已是最新」而跳过更新 —— 本轮就踩了
// 这个坑（追加了胶囊/rail 修复后 SKIP，界面毫无变化）。
const OVERLAY_BEGIN = "/* __JET_HUB_MOBILE_OVERLAY_BEGIN__ */";
const OVERLAY_END = "/* __JET_HUB_MOBILE_OVERLAY_END__ */";
function sha(s) { return crypto.createHash("sha256").update(s).digest("hex").slice(0, 16); }
// 唯一的拼接口径：wantHash / payloadCss / 写后复核三处**必须**共用它，
// 否则任何一处多一个换行都会让哈希恒不相等（本轮就是这么卡的）。
function buildSection(source) { return OVERLAY_BEGIN + "\n" + source.replace(/\s+$/, "") + "\n" + OVERLAY_END; }
const STYLES_OPEN = "var STYLES = `";

const args = process.argv.slice(2);
const optFile = args.includes("--file") ? args[args.indexOf("--file") + 1] : null;
const checkOnly = args.includes("--check");

function dshHome() {
  const env = String(process.env.DSH_HOME || "").trim();
  if (env) return env;
  return path.join(process.env.HOME || "/data/user/0/com.dsharnessmobile.shell/files/home", ".dsh");
}

function targetFile() {
  if (optFile) return optFile;
  return path.join(dshHome(), "profiles", "web", "node_modules", "dsh-providers-hub", "lib", "client", "jet-hub.js");
}

function fail(msg) {
  console.error("FAIL: " + msg);
  process.exit(1);
}

const css = fs.readFileSync(CSS_FILE, "utf8");
if (css.includes("`")) fail("mobile.css 含反引号，内联会提前闭合 STYLES 模板");
if (/\$\{/.test(css)) fail("mobile.css 含美元花括号插值写法，内联会提前触发插值");
if (!css.includes(MOBILE_CSS_MARK)) fail("mobile.css 缺少 marker 文本：" + MOBILE_CSS_MARK);

const target = targetFile();
if (!fs.existsSync(target)) fail("目标不存在：" + target);

const original = fs.readFileSync(target, "utf8");

// 定位 STYLES 模板的收尾反引号（模板从 STYLES_OPEN 起，到第一个 "`;" 止）。
const start = original.indexOf(STYLES_OPEN);
if (start < 0) fail("没找到 STYLES 模板起点（上游结构变了？）：" + STYLES_OPEN);
const cssStart = start + STYLES_OPEN.length;
const end = original.indexOf("`;", cssStart);
if (end < 0) fail("没找到 STYLES 模板终点");

const cssBlock = original.slice(cssStart, end);

// 已注入的段落 = BEGIN..END 之间（新版注入必带这对标记；旧版没有 END 标记）
const curHash = cssBlock.includes(OVERLAY_BEGIN) && cssBlock.includes(OVERLAY_END)
  ? sha(cssBlock.slice(cssBlock.indexOf(OVERLAY_BEGIN), cssBlock.indexOf(OVERLAY_END) + OVERLAY_END.length))
  : null;
const wantHash = sha(buildSection(css));

if (curHash === wantHash) {
  console.log("SKIP: 适配层已是最新（内容哈希一致 " + wantHash + "），mtime 未改动");
  console.log("  file : " + target);
  console.log("  STYLES 长度 : " + cssBlock.length);
  process.exit(0);
}

if (checkOnly) {
  console.log(curHash === null
    ? "CHECK: 未注入（无标记对）"
    : "CHECK: 已注入但内容过期（现 " + curHash + " ≠ 应 " + wantHash + "）");
  console.log("  file : " + target);
  console.log("  STYLES 长度 : " + cssBlock.length);
  process.exit(3);
}

// 备份（只保留一份，重复跑不堆备份）。
const bak = target + ".mobcss.bak";
if (!fs.existsSync(bak)) fs.writeFileSync(bak, original, { mode: 0o600 });

// 先剥离已经注入过的旧段（含没有 END 标记的第一版），再写新段 —— 否则重跑会叠加。
const stripped = (() => {
  let block = cssBlock;
  if (block.includes(OVERLAY_BEGIN)) {
    const a = block.indexOf(OVERLAY_BEGIN);
    const b = block.includes(OVERLAY_END) ? block.indexOf(OVERLAY_END) + OVERLAY_END.length : block.length;
    block = block.slice(0, a) + block.slice(b);
  } else if (block.includes(MOBILE_CSS_MARK)) {
    // 第一版没有 BEGIN/END 标记：整段砍到 STYLES 末尾（它就是最后追加的）
    block = block.slice(0, block.indexOf("Jet Hub 移动端适配层"));
  }
  return block.replace(/\s+$/, "");
})();

const payloadCss = buildSection(css);
const next = original.slice(0, cssStart) + stripped + "\n" + payloadCss + original.slice(end);

// 写前自证：注入后必须仍然能被当作合法的 JS 模板字符串解析。
// 用 node --check 直接校验整个文件，不靠正则猜。
// ⚠️ Android 执行器坑（与 port-kit 的 android-node-exec-patch 同源）：
// 本机 process.execPath = /apex/com.android.runtime/bin/linker64（termux-exec 的
// LD_PRELOAD 把 exec 重路由到 linker），直接 spawn(process.execPath, ['--check', f])
// 会报 error: expected absolute path: "--check"。走真正的 node 二进制。
function nodeBin() {
  const env = String(process.env.PURGE_NODE_EXEC || "").trim();
  if (env && fs.existsSync(env)) return env;
  const baked = "/data/data/com.dsharnessmobile.shell/files/usr/bin/node";
  if (fs.existsSync(baked)) return baked;
  return process.execPath;
}

// ⚠️ 后缀必须是 .mjs：node --check 会按扩展名判模块格式，.tmp 直接抛
// ERR_UNKNOWN_FILE_EXTENSION（不是语法错，但会让校验恒失败）。
const tmp = target + ".mobcss.tmp.mjs";
fs.writeFileSync(tmp, next, { mode: 0o600 });
try {
  execFileSync(nodeBin(), ["--check", tmp], { stdio: "pipe" });
} catch (e) {
  fs.unlinkSync(tmp);
  fail("注入后语法校验失败，已放弃写入：" + String(e.stderr || e.message).slice(0, 400));
}

fs.renameSync(tmp, target);

// 写后复核：marker 必须在，且 STYLES 长度确实增长。
const after = fs.readFileSync(target, "utf8");
const afterStart = after.indexOf(STYLES_OPEN) + STYLES_OPEN.length;
const afterEnd = after.indexOf("`;", afterStart);
const afterBlock = after.slice(afterStart, afterEnd);
if (!afterBlock.includes(MOBILE_CSS_MARK)) fail("写入后 marker 仍不在位");
if (!afterBlock.includes(OVERLAY_BEGIN) || !afterBlock.includes(OVERLAY_END)) fail("写入后缺少 BEGIN/END 标记对");
// ⚠️ 不要断言「一定变长」：内容相同时长度可以不变（比如只改了剥离后的等价内容），
// 断言变长会让幂等重跑在「已是最新」的等价路径上报错。改为断言**哈希正确**。
const finalHash = sha(afterBlock.slice(afterBlock.indexOf(OVERLAY_BEGIN), afterBlock.indexOf(OVERLAY_END) + OVERLAY_END.length));
if (finalHash !== wantHash) fail("写入后内容哈希不符：" + finalHash + " ≠ " + wantHash);

console.log("OK: 已注入移动端适配层");
console.log("  file     : " + target);
console.log("  STYLES   : " + cssBlock.length + " → " + afterBlock.length + " (+" + (afterBlock.length - cssBlock.length) + ")");
console.log("  backup   : " + bak);
console.log("  ⚠ 引擎只在启动时缓存 client bundle —— 必须重启应用才生效（刷新页面不够）");
