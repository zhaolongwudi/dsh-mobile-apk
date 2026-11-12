#!/usr/bin/env node
// 从「上游基线 + overlay（规范补丁后态）」重新生成可移植补丁。
//
// 为什么要有这个脚本：上一版补丁的 ---/+++ 头是**设备绝对路径**
// （/data/data/.../node_modules/dsh-memento/index.mjs），甚至指向生成时的临时文件
// （index.mjs.orig2）——只有 cwd=/ 时才可能 apply，换设备/换 DSH_HOME 立刻失效，
// 属「文档」而非「可执行补丁」。本脚本生成标准 a/<相对路径> · b/<相对路径> 形式，
// 任何目录下 `git apply -p1` / `patch -p1` 都能应用。
//
// 用法：node tools/make-patches.mjs        # 重新生成 patches/*.patch
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const KIT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const P = (p) => path.join(KIT, p)

/** 生成一份标准统一 diff（带 git 头，无时间戳 ⇒ 输出确定）。 */
function unified(beforeAbs, afterAbs, rel) {
  let raw
  try {
    raw = execFileSync('diff', ['-u', '--label', `a/${rel}`, '--label', `b/${rel}`, beforeAbs, afterAbs], { encoding: 'utf8' })
  } catch (error) {
    if (error.status !== 1) throw error
    raw = String(error.stdout ?? '')
  }
  if (raw.length === 0) throw new Error(`${rel}: 两侧内容相同，无需补丁`)
  return `diff --git a/${rel} b/${rel}\n${raw}`
}

const jobs = [
  {
    out: '01-client-configforms-softwait.patch',
    before: 'patches/client.js.upstream',
    after: 'patches/client.js.softwait',
    rel: 'client/client.js',
  },
  {
    out: '02-client-panel-decide-buttons.patch',
    before: 'patches/client.js.softwait',
    after: 'patches/client.js.decide',
    rel: 'client/client.js',
  },
  {
    out: '03-panel-proposal-decide.patch',
    before: 'patches/index.mjs.upstream',
    after: 'patches/index.mjs.decide',
    rel: 'index.mjs',
  },
  {
    out: '04-panel-entry-controls.patch',
    before: 'patches/client.js.decide',
    after: 'overlay/client/client.js',
    rel: 'client/client.js',
  },
  {
    out: '05-panel-entry-write.patch',
    before: 'patches/index.mjs.decide',
    after: 'overlay/index.mjs',
    rel: 'index.mjs',
  },
]

const rows = []
for (const job of jobs) {
  const text = unified(P(job.before), P(job.after), job.rel)
  fs.writeFileSync(P(`patches/${job.out}`), text)
  rows.push({ patch: job.out, target: job.rel, bytes: Buffer.byteLength(text), lines: text.split('\n').length - 1 })
}
console.log(JSON.stringify(rows, null, 1))
