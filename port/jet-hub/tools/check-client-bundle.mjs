// 第 5 段的探针：比对「引擎下发内容」与「磁盘产物」。
//
// 为什么单独成文件（而不是像原来那样内联在 port.sh 里）：
//   内联脚本靠 sh 的单引号包裹，脚本里**一个单引号都不能有**；
//   上一版给剥离逻辑加注释时写了带引号的字面量，sh 的引号配对被打断，
//   整段 JS 被腰斩 —— 表现为「追加行 0 字节」的静默失效
//   （脚本不报语法错，只是判据永远走不到剥离那一支）。单独成文件后
//   单引号/撇号/中文注释都自由，且这个探针可被单测直接调用。
//
// 用法：node check-client-bundle.mjs <port> <cookie> <pkgName> <diskFile>
// 退出码：0 = 内容一致（PASS）／1 = 内容真不同（FAIL）／2 = 跳过（WARN）
//
// ── 判据的三轮修正（全部实测，不是推演）────────────────────────────────
// ① 只比 rev：rev 由 mtime/ctime/size 派生（artifactRevision），重铺一次文件就换 rev，
//    内容逐字节相同也报 FAIL ⇒ 误报。
// ② 比 sha256(引擎下发字节) vs sha256(磁盘字节) ⇒ **恒 FAIL**。
//    真因：引擎在下发时自己追加尾部（服务端行为，磁盘上没有）：
//        ";\n//# sourceMappingURL=??<pkg>/client.js.map&rev=<rev>\n"
//    实测 served=999503 / disk=999429，差 74 字节 =
//      **1（分号）+ 1（换行）+ 72（标记行）**。
//    ⚠️ 这里有个只剩逐字节比对才能发现的坑：只看「差 74 字节」会以为那 74 字节**全是**
//       sourcemap 行，于是「剥掉标记行」后仍差 1 字节（999430 vs 999429），
//       会被判成「内容不同」—— 判据又退化回误报。那个多出来的 1 字节是**分号**。
// ③ 现行判据（本文件）：
//    剥掉「分号 + sourceMappingURL 行」这 74 字节再比；为兼容只追加标记行的实现，
//    另留一条「只剥标记行」的候选。任一候选命中即 PASS。
//    并回显 appended 字节数与是否命中，让「差的到底是什么」一眼可见。
import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';

const [port, cookie, name, diskPath] = process.argv.slice(2);

const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const get = (p) => new Promise((resolve, reject) => {
  const req = http.request({ host: '127.0.0.1', port: Number(port), path: p, method: 'GET', headers: { cookie } }, (res) => {
    const chunks = [];
    res.on('data', (c) => chunks.push(c));
    res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
  });
  req.on('error', reject);
  req.end();
});

const MARK = '//# sourceMappingURL=';

/**
 * 把「引擎下发字节」还原成「产物内容」。
 * @returns {{candidates: Buffer[], appended: number, mark: string|null, semicolon: boolean}}
 */
function stripEngineTail(servedBuf) {
  const text = servedBuf.toString('utf8');
  const lines = text.split('\n');
  // 末尾可能是空行（引擎追加尾部自带换行）
  let last = lines.length - 1;
  while (last >= 0 && lines[last].trim() === '') last--;

  const mark = last >= 0 ? lines[last].trim() : '';
  if (last < 0 || !mark.startsWith(MARK)) {
    return { candidates: [servedBuf], appended: 0, mark: null, semicolon: false };
  }

  const lastLineBytes = Buffer.byteLength(lines[last], 'utf8');
  const tailNlBytes = servedBuf.length - Buffer.byteLength(lines.slice(0, last + 1).join('\n'), 'utf8');
  const semicolon = last >= 1 && lines[last - 1].trim() === ';';

  const candidates = [];
  if (semicolon) {
    // 连分号与其前置换行一起剥。
    // ⚠️ `lines.slice(0,last-1).join("\n")` 会**多出一个尾换行**（join 在最后一段后面也放分隔符），
    //    实测多 1 字节（999430 vs 999429）—— 这正是「剥完还差 1 字节」的第二个来源。
    //    产物自身的尾换行要保留，所以只在「分号之前那一行」之后截断：slice(0,last-1).join + "\n" 再退掉 join 的尾巴。
    const body = lines.slice(0, last - 1).join('\n') + '\n';
    candidates.push(Buffer.from(body, 'utf8'));
  }
  // 只剥标记行（保留它前面的内容，含结尾换行）
  const bodyNoMark = lines.slice(0, last).join('\n') + '\n';
  candidates.push(Buffer.from(bodyNoMark, 'utf8'));

  const appended = servedBuf.length - candidates[candidates.length - 1].length;
  void lastLineBytes; void tailNlBytes;
  return { candidates, appended, mark, semicolon };
}

try {
  const root = await get('/');
  if (root.status !== 200) { console.log(`  WARN  取不到引擎首页（HTTP ${root.status}），跳过`); process.exit(2); }
  const html = root.body.toString('utf8');

  // boot manifest 形如：window["__DSH_BOOT__"] = {…}
  const anchor = html.indexOf('__DSH_BOOT__');
  let entry = null;
  if (anchor >= 0) {
    const start = html.indexOf('{', anchor);
    let depth = 0, end = -1;
    for (let k = start; k < html.length; k++) {
      const c = html[k];
      if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) { end = k + 1; break; } }
    }
    try { entry = (JSON.parse(html.slice(start, end)).entries || []).find((x) => x.id === name); } catch { /* 解析失败按缺条目处理 */ }
  }
  if (!entry) { console.log('  WARN  读不到引擎 boot manifest 里本条，跳过'); process.exit(2); }

  const served = await get('/' + entry.url);
  if (served.status !== 200) { console.log(`  WARN  取不到下发的 bundle（HTTP ${served.status}），跳过`); process.exit(2); }

  const disk = fs.readFileSync(diskPath);
  const diskSha = sha(disk);
  const st = stripEngineTail(served.body);
  const hitIdx = st.candidates.findIndex((c) => sha(c) === diskSha);
  const same = hitIdx >= 0;
  const shown = same ? st.candidates[hitIdx] : st.candidates[st.candidates.length - 1];

  const how = st.mark === null
    ? '（未发现引擎追加尾部）'
    : `（已剥：${st.semicolon ? '“;” 1 字节 + ' : ''}sourceMappingURL 行，共 ${st.appended} 字节）`;
  const tail = `content ${shown.length} / disk ${disk.length}，engine-tail ${st.appended} 字节 ${how}，served rev=${entry.rev}`;

  if (same) {
    console.log(`  PASS  引擎下发内容与磁盘一致（${tail}）`);
    process.exit(0);
  }
  console.log(`  FAIL  引擎下发内容与磁盘不同（${tail}）`);
  process.exit(1);
} catch (e) {
  console.log('  WARN  探测失败：' + e.message);
  process.exit(2);
}
