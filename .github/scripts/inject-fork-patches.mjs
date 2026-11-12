#!/usr/bin/env node
// fork 补丁刷新器（幂等）：由 .github/workflows/daily-sync.yml 每次同步上游后调用。
//   1) README.md：维护顶部「每日自动构建下载」区块（标记内整体替换）
//   2) .github/workflows/build-apk.yml：补 schedule 触发器（每日北京 04:30 自动构建）
//      + 修 inputs.version_code 判定（schedule 事件下 inputs 为空，原写法会误跑预览号步骤）
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const OWNER_REPO = 'zhaolongwudi/dsh-mobile-apk'
const NIGHTLY = `https://github.com/${OWNER_REPO}/releases/download/nightly`
const BEGIN = '<!-- dsh-nightly:begin -->'
const END = '<!-- dsh-nightly:end -->'

const ASSETS = [
  { abi: 'arm64', file: 'dsh-mobile-apk-arm64.apk', note: '真机' },
  { abi: 'x86_64', file: 'dsh-mobile-apk-x86_64.apk', note: '模拟器' },
]

function readmeBlock() {
  const rows = ASSETS.map((a) => {
    const direct = `${NIGHTLY}/${a.file}`
    return `| ${a.abi}（${a.note}） | [直连](${direct}) | [加速](${`https://gh-proxy.com/${direct}`}) | [加速](${`https://ghfast.top/${direct}`}) |`
  }).join('\n')
  return [
    BEGIN,
    '## ⬇️ 每日自动构建下载（本 fork）',
    '',
    `本仓库跟随上游 [\`kelai141/dsh-mobile-apk\`](https://github.com/kelai141/dsh-mobile-apk)：每天北京时间 **04:00** 拉取新提交，**04:30** 自动重构建，产物覆盖发布在 [\`nightly\`](https://github.com/${OWNER_REPO}/releases/tag/nightly)。`,
    '',
    '| 架构 | 直连 | 加速（gh-proxy.com） | 加速（ghfast.top） |',
    '|---|---|---|---|',
    rows,
    '',
    '> 三个链接指向同一个文件，直连不通时改用加速前缀。某天构建失败时不会覆盖已有产物。',
    END,
  ].join('\n')
}

function patchReadme() {
  const p = join(ROOT, 'README.md')
  if (!existsSync(p)) return 'README.md 不存在，跳过'
  const src = readFileSync(p, 'utf8')
  const block = readmeBlock()
  const i = src.indexOf(BEGIN)
  const j = src.indexOf(END)
  if (i !== -1 && j > i) {
    const next = src.slice(0, i) + block + src.slice(j + END.length)
    if (next === src) return 'README.md 无变化'
    writeFileSync(p, next)
    return 'README.md 区块已更新'
  }
  const lines = src.split('\n')
  const h = lines.findIndex((l) => l.startsWith('# '))
  lines.splice(h === -1 ? 0 : h + 1, 0, '', block)
  writeFileSync(p, lines.join('\n'))
  return 'README.md 区块已插入'
}

function patchBuildApk() {
  const p = join(ROOT, '.github/workflows/build-apk.yml')
  if (!existsSync(p)) return 'build-apk.yml 不存在，跳过'
  const before = readFileSync(p, 'utf8')
  let src = before
  const notes = []

  if (!/^ {2}schedule:/m.test(src)) {
    const anchor = /^ {2}workflow_dispatch:\s*$/m
    if (!anchor.test(src)) {
      throw new Error('build-apk.yml 结构变化：找不到 on.workflow_dispatch，请人工确认后再跑同步')
    }
    src = src.replace(
      anchor,
      [
        '  schedule:',
        '    # 北京时间 04:30（UTC 20:30）；daily-sync 04:00 同步，留 30 分钟余量',
        "    - cron: '30 20 * * *'",
        '  workflow_dispatch:',
      ].join('\n'),
    )
    notes.push('已补 schedule 触发器')
  }

  const oldIf = "if: ${{ inputs.version_code != '' }}"
  const newIf = "if: ${{ github.event_name == 'workflow_dispatch' && inputs.version_code != '' }}"
  if (src.includes(oldIf)) {
    src = src.split(oldIf).join(newIf)
    notes.push('已修 version_code 判定')
  } else if (!src.includes(newIf) && /inputs\.version_code/.test(src)) {
    notes.push('警告：version_code 判定写法已变化，未自动修补，请人工确认 schedule 下不会误跑')
  }

  // ③ schedule 下 matrix.abi 兜底。与 ② 同因：schedule 事件拿不到 workflow_dispatch 的
  //    default，inputs.abi 是空串，fromJSON 会展开成 [""] —— 于是底座路径被拼成
  //    base-usr-.tar.xz（根本不存在），构建在「断言底座确实已落地」那一步判红。
  //    2026-11-12：11-11 与 11-12 两次 schedule 构建都死在这里，手动 dispatch 却正常。
  // 用双引号字符串而不是模板字面量：YAML 里的 ${{ ... }} 在模板字面量里会被当成插值。
  const oldMatrix = "abi: ${{ fromJSON(inputs.abi == 'both' && '[\"arm64\",\"x86_64\"]' || format('[\"{0}\"]', inputs.abi)) }}"
  const newMatrix = "abi: ${{ fromJSON((github.event_name == 'workflow_dispatch' && inputs.abi || 'both') == 'both' && '[\"arm64\",\"x86_64\"]' || format('[\"{0}\"]', inputs.abi)) }}"
  if (src.includes(oldMatrix)) {
    src = src.split(oldMatrix).join(newMatrix)
    notes.push('已修 schedule 下 matrix.abi 为空')
  } else if (!src.includes(newMatrix) && /inputs\.abi == 'both'/.test(src)) {
    notes.push('警告：matrix.abi 写法已变化，未自动修补，请人工确认 schedule 下 ABI 不会变成空串')
  }

  if (src === before) return `build-apk.yml 无变化${notes.length ? `（${notes.join('；')}）` : ''}`
  writeFileSync(p, src)
  return `build-apk.yml：${notes.join('；') || '已更新'}`
}

console.log(patchReadme())
console.log(patchBuildApk())
