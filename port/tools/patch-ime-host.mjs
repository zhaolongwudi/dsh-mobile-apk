#!/usr/bin/env node
/**
 * patch-ime-host.mjs —— 把 IME 变量的**读取端**从 `<html>` 改到就近宿主。
 *
 * ## 为什么要有这一步（2026-11-21 真机实测，不是推演）
 *
 * 壳侧把 `--dsh-android-ime-bottom` 持续推给页面。原实现写 `document.documentElement`，
 * 本页 12765 个节点 / 7128 条规则，实测「在 `:root` 上写内联自定义属性」的强制重算
 * 代价 **110~157ms/次** —— 写一个页面里完全没用到的变量同样是 180ms，说明代价来自
 * 根元素内联样式变更本身、而非某个变量被消费。
 *
 *   宿主对比（同一变量，只换落点）：
 *     :root                  110~157ms
 *     [data-dsh-frame]       127~141ms   （frame 一万多节点，一样全树失效）
 *     [data-composer-seat]     4.4~5.2ms  （126 节点）
 *
 * 键盘动画期间这条通道逐帧变化，于是每帧一次全树重排：真机 1151 帧里 93 帧 >100ms、
 * p99=283ms、最坏帧 399ms。壳侧已改用 seat 作为写入点（见 MainActivity.pushWebInsets），
 * 本脚本负责让**页面读取端**跟着搬，否则页面仍去 `<html>` 上读、读到 0。
 *
 * ## 改哪几处
 *
 * `@dsh-android/dsh-client-ui-responsive` 是手工铺进 profile 的已编译产物
 * （不在 pnpm 账本里），profile 重建后会被覆盖回原版 —— 所以做成可重跑的补丁，
 * 而不是一次性手工编辑。
 *
 * 四处读取点，全部改成「composerStack -> seat -> frame -> documentElement」逐级回落：
 *   - imeHostEl()            （MutationObserver 监听 styles 的宿主 + isRelevantMutation 判据）
 *   - imeInsetPx()           （sidebar-gestures 的键盘展开判据）
 *   - sidebar-bubbles 的 nativeBottom（弹层避让）
 *   - composer-insets 的 CSS 不动（`html[data-dsh-ime]` 前缀的那条规则本机没有写入者，
 *     即它是死规则；动它没有收益，还会掩盖将来补上 data-dsh-ime 时的语义）
 *
 * 逐级回落是刻意的：旧壳只写 root 时，四处仍能读到；新壳写 seat 时，逐级第一跳命中。
 *
 * ## 用法
 *
 *   node port/tools/patch-ime-host.mjs <profile-dir>            # 打上（幂等）
 *   node port/tools/patch-ime-host.mjs <profile-dir> --check    # 只判定，退出码 0=已打/无需
 */
import { readFileSync, writeFileSync, existsSync, copyFileSync } from 'node:fs'
import { join } from 'node:path'

const PKG = '@dsh-android/dsh-client-ui-responsive'
const CLIENT = join('node_modules', PKG, 'lib', 'client.js')

const [profileArg] = process.argv.slice(2)
const checkOnly = process.argv.includes('--check')
if (!profileArg) {
  console.error('usage: node patch-ime-host.mjs <profile-dir> [--check]')
  process.exit(2)
}

const clientPath = join(profileArg, CLIENT)
if (!existsSync(clientPath)) {
  console.error(`patch-ime-host: 找不到 ${clientPath}（该 profile 没装 ${PKG}？）`)
  process.exit(2)
}

const HELPER_MARK = 'function imeHostEl() {'
const HELPER = `function imeHostEl() {
	const hosts = [
		document.querySelector("[data-composer-seat] [class*='composerStack']"),
		document.querySelector("[data-composer-seat]"),
		document.querySelector("[data-dsh-frame]"),
		document.documentElement
	].filter((el) => el !== null);
	for (const host of hosts) {
		const raw = Number.parseFloat(getComputedStyle(host).getPropertyValue("--dsh-android-ime-bottom"));
		if (Number.isFinite(raw) && raw !== 0) return host;
	}
	return document.documentElement;
}`

/** 每条：[说明, 旧文本, 新文本]。旧文本为 null 表示只要求「已存在」。 */
const EDITS = [
  {
    label: 'MutationObserver 监听 styles 的宿主',
    from: `this.lastImeInset = document.documentElement.style.getPropertyValue("--dsh-android-ime-bottom");
				this.mutationObserver.observe(document.documentElement, {
					attributes: true,
					attributeFilter: ["style"]
				});`,
    to: `this.lastImeInset = imeHostEl().style.getPropertyValue("--dsh-android-ime-bottom");
				this.mutationObserver.observe(imeHostEl(), {
					attributes: true,
					attributeFilter: ["style"]
				});`,
    done: 'this.lastImeInset = imeHostEl().style.getPropertyValue',
  },
  {
    label: 'isRelevantMutation 的宿主判据',
    from: `if (record.type === "attributes" && record.target === document.documentElement) {
					const inset = document.documentElement.style.getPropertyValue("--dsh-android-ime-bottom");`,
    to: `if (record.type === "attributes" && record.target === imeHostEl()) {
					const inset = imeHostEl().style.getPropertyValue("--dsh-android-ime-bottom");`,
    done: 'record.target === imeHostEl()',
  },
  {
    label: 'imeInsetPx（键盘展开判据）',
    from: `function imeInsetPx() {
			const raw = getComputedStyle(document.documentElement).getPropertyValue(IME_INSET_VAR);`,
    to: `function imeInsetPx() {
			const raw = getComputedStyle(imeHostEl()).getPropertyValue(IME_INSET_VAR);`,
    done: 'getComputedStyle(imeHostEl()).getPropertyValue(IME_INSET_VAR)',
  },
  {
    label: 'sidebar-bubbles 的 nativeBottom',
    from: `const root = getComputedStyle(document.documentElement);
				const nativeBottom = document.documentElement.hasAttribute("data-dsh-ime") ? 0 : Math.max(0, parseFloat(root.getPropertyValue("--dsh-android-ime-bottom")) || 0, parseFloat(root.getPropertyValue("--dsh-android-system-bottom")) || 0);`,
    to: `const root = getComputedStyle(document.documentElement);
				const imeComputed = getComputedStyle(imeHostEl());
				const nativeBottom = document.documentElement.hasAttribute("data-dsh-ime") ? 0 : Math.max(0, parseFloat(imeComputed.getPropertyValue("--dsh-android-ime-bottom")) || 0, parseFloat(root.getPropertyValue("--dsh-android-system-bottom")) || 0);`,
    done: 'const imeComputed = getComputedStyle(imeHostEl());',
  },
]

let text = readFileSync(clientPath, 'utf8')
const results = []
let need = 0

for (const edit of EDITS) {
  if (text.includes(edit.done)) {
    results.push(`OK    ${edit.label}（已在位）`)
    continue
  }
  const hits = text.split(edit.from).length - 1
  if (hits !== 1) {
    // 锚点漂移：上游产物换形状，拒绝猜测
    console.error(`patch-ime-host: ${edit.label} 锚点命中 ${hits} 处（期望 1）—— 产物形状变了，核对 ${clientPath}`)
    process.exit(1)
  }
  if (checkOnly) {
    results.push(`MISS  ${edit.label}`)
    need += 1
    continue
  }
  text = text.replace(edit.from, edit.to)
  results.push(`OK    ${edit.label}（已改）`)
}

// helper 必须存在，否则上面四处全部引用未定义函数
if (!text.includes(HELPER_MARK)) {
  if (checkOnly) {
    results.push('MISS  imeHostEl helper')
    need += 1
  } else {
    const marker = 'const IME_INSET_VAR = '
    const idx = text.indexOf(marker)
    const alt = text.indexOf('function imeInsetPx()')
    const at = idx > 0 ? idx : alt
    if (at < 0) {
      console.error('patch-ime-host: 找不到注入点（IME_INSET_VAR / imeInsetPx 都不存在）')
      process.exit(1)
    }
    const doc = `/**
 * IME 变量的宿主元素。
 *
 * 壳侧写在 [data-composer-seat] 上，不是 <html>：给根元素写内联 style 会让 Chrome 做
 * 全文档样式重算（2026-11-21 真机实测 110~157ms/次；同变量写 seat 是 4.4~5.2ms）。
 * 键盘动画逐帧推送时写 root 就是每帧一次全树重排。
 * 逐级回落让旧壳（只写 root）与新壳（写 seat）都能读到。
 */
`
    text = text.slice(0, at) + doc + HELPER + '\n\n' + text.slice(at)
    results.push('OK    imeHostEl helper（已插入）')
  }
} else {
  results.push('OK    imeHostEl helper（已在位）')
}

if (!checkOnly) {
  copyFileSync(clientPath, clientPath + '.pre-ime-host.bak')
  writeFileSync(clientPath, text)
}

for (const line of results) console.log(line)
if (checkOnly && need > 0) {
  console.log(`\n共 ${need} 处待打：跑 node port/tools/patch-ime-host.mjs ${profileArg}`)
  process.exit(1)
}
console.log(checkOnly ? '\n全部在位。' : '\nIME 读取端已改到就近宿主（备份：client.js.pre-ime-host.bak）')
process.exit(0)
