#!/usr/bin/env node
/**
 * test-settings-ui.mjs —— meow-memory 设置页三项移植修复的静态结构测试
 *
 * 背景（用户实机反馈 2026-11-12）：
 *   ① 「反思/梦境换模型」的标签被挤成竖排（布局塌陷）
 *   ② 模型只能手填字符串，没得选、易填错
 *   ③ 记忆保存目录也只能手填，无法选择
 *
 * 本测试对「补丁后的 client.js」做结构与语法断言（离线、只读、可重跑）。
 * 它不能替代肉眼看一眼 UI，但能保证：语法不坏、三项修复的代码路径都在、
 * 且旧的塌陷写法确实被移除。
 *
 * 用法：node tools/test-settings-ui.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const SELF_DIR = path.dirname(fileURLToPath(import.meta.url));
const KIT_DIR = path.dirname(SELF_DIR);
const CANDIDATES = [
  path.join(KIT_DIR, 'overlay', 'lib', 'client.js'),
  process.env.MEOW_CLIENT || '',
].filter(Boolean);

const target = CANDIDATES.find((p) => fs.existsSync(p));
if (!target) {
  console.error('找不到 client.js：先跑 `bash port.sh overlay` 或在 kit 内保留 overlay/');
  process.exit(1);
}

const src = fs.readFileSync(target, 'utf8');
const results = [];
const t = (name, ok, detail = '') => results.push({ name, ok, detail });
const has = (re) => (re instanceof RegExp ? re.test(src) : src.includes(re));

/* ── A. 语法：vm.Script 编译（不执行） ───────────────────────── */
try {
  new vm.Script(src, { filename: 'client.js' });
  t('A 语法：client.js 可编译', true, `${src.length} 字符`);
} catch (e) {
  t('A 语法：client.js 可编译', false, e.message);
}

/* ── B. 修复①：窄屏不再塌陷 ─────────────────────────────────── */
t('B① 存在窄屏断点 @media (max-width:600px)', has('@media (max-width:600px)'));
t('B① 断点内行改纵向堆叠', has(/@media \(max-width:600px\)\{[\s\S]{0,600}?\.meowmm_set_row\{flex-direction:column/));
t('B① 标签列拿到 flex 基准（不再被压到 1 字宽）', has('.meowmm_set_rowtext{display:flex;flex-direction:column;gap:2px;min-width:0;flex:1 1 200px}'));
t('B① 旧的塌陷写法已移除（rowtext 无 flex 基准）',
  !has('.meowmm_set_rowtext{display:flex;flex-direction:column;gap:2px;min-width:0}'));
t('B① 控件列改可换行（原本 flex:none 撑爆窄屏）', has('.meowmm_set_ctrl{flex:0 0 auto;padding-top:2px;display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:flex-end}'));
t('B① 断点内输入框占满整行', has(/@media \(max-width:600px\)\{[\s\S]{0,900}?\.meowmm_set_input,\.meowmm_set_input_time,\.meowmm_set_model\{width:100%/));

/* ── C. 修复②：模型改为下拉选择 ─────────────────────────────── */
t('C② delegate.model 字段类型改为 model', has('{ key: "model", sub: "delegate", label: "settings.field.delegateModel.label", type: "model"'));
t('C② renderField 有 model 分支', has('if (spec.type === "model") {'));
t('C② 渲染为 <select>', has(/if \(spec\.type === "model"\)[\s\S]{0,900}?el\(\s*"select"/));
t('C② 目录来自宿主 modelCatalog', has('remote.session.modelCatalog'));
t('C② 按 provider 分组（optgroup）', has('el("optgroup", { key: g.id, label: g.name }'));
t('C② 保留未知旧值（不被静默清空）', has('（未知，保留原值）'));
t('C② 选项值用 provider/model 形式（parseModelSpec 契约，不能是裸 model id）', has(/\$\{g\.id\}\/\$\{m\.id\}/));
t('C② 裸模型 id 也认作已知（不重复显示未知项）', has('current.indexOf("/") < 0 && m.id === current'));
t('C② 模型目录模块级缓存（不重复请求）', has('MODEL_CACHE'));
t('C② 加载失败安全回落空列表', has(/loadModelCatalog[\s\S]{0,600}?catch \{\s*return \[\];/));

/* ── D. 修复③：目录可从系统选择器挑 ───────────────────────── */
t('D③ 有 hostPickDirectory 辅助函数', has('async function hostPickDirectory()'));
t('D③ 主路径走 uiWorkspace.pickDirectory', has('uw?.pickDirectory'));
t('D③ 兜底走 directoryPicker.pick', has('dp?.pick'));
t('D③ 选择按钮只挂 homeDir（projectDir 必须相对工作区，不给一键选目录）',
  has('const needsPick = spec.key === "homeDir"') && !has('spec.key === "projectDir" || spec.key === "homeDir"'));
t('D③ projectDir 行的收窄带注释（防回退）', has('[port fix 2026-11-12] 目录选择器只给 homeDir'));
t('D③ 通用行里渲染了 pickBtn', has(/"meowmm_set_ctrl", style: \{ display: "flex", gap: "8px", alignItems: "center" \} \},\s*control,\s*pickBtn,/));
t('D③ homeDir 自定义输入框旁也有 pickBtn', has(/void apply2\(spec, next\);\s*\}\s*\}\)\,?\s*pickBtn/));
t('D③ 选择器不可用时有提示而非静默', has('目录选择器不可用'));
t('D③ 按钮文案「选择目录…」', has('选择目录…'));

/* ── E. 修复④：projectDir 绝对路径兜底（服务端半边，2026-11-12 记忆库漂移事故后加） ── */
const idxPath = path.join(KIT_DIR, 'overlay', 'lib', 'index.js');
if (!fs.existsSync(idxPath)) {
  t('E④ overlay/lib/index.js 在位', false, '缺文件 —— 兜底铺不上（port.sh overlay 遍历 overlay/ 才有意义）');
} else {
  const idx = fs.readFileSync(idxPath, 'utf8');
  const ih = (s) => idx.includes(s);
  t('E④ overlay/lib/index.js 在位', true, `${idx.length} 字符`);
  t('E④ 有 normalizeProjectDir 兜底函数', ih('function normalizeProjectDir('));
  t('E④ resolveConfig 用兜底替换裸默认值', ih('projectDir: normalizeProjectDir(c.projectDir)'));
  t('E④ 绝对路径/盘符/UNC 三种形态都拦', ih('isAbsolute(raw) || /^[A-Za-z]:[\\\\/]/.test(raw) || raw.startsWith("\\\\\\\\")'));
  t('E④ 回退值是相对名 .dsh-meow', ih('return ".dsh-meow";'));
  t('E④ 回退时响亮报错而非静默', ih('[meow-memory][port-fix] projectDir 不接受绝对路径'));
  t('E④ 上游旧的裸默认值写法已移除', !ih('projectDir: c.projectDir ?? ".dsh-meow"'));
}

/* ── 输出 ───────────────────────────────────────────────────── */
const fail = results.filter((r) => !r.ok);
for (const r of results) {
  console.log(`  ${r.ok ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m'} ${r.name}${r.detail ? `  \x1b[2m${r.detail}\x1b[0m` : ''}`);
}
console.log(`\n结论  PASS ${results.length - fail.length}/${results.length}${fail.length ? `  FAIL ${fail.length}` : '  全通过'}`);
console.log(`被测文件：${target}`);
process.exit(fail.length ? 1 : 0);
