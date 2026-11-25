#!/usr/bin/env node
/**
 * 校验 package.json 的 exports 与 files 里每个路径都真实存在。
 *
 * 为什么单独成文件：带通配符的条目（如 ./locale/*.json）不能简单地去掉 `*`
 * 再 existsSync —— 那会得到 ./locale/.json 这种不存在的路径，误报"缺失"。
 * 正确做法是拆成「目录存在 + 目录里确有匹配文件」两段判断。
 *
 * 用 .cjs 而非 .js：本包 package.json 是 "type": "module"，.js 会被当 ESM，
 * 而这里要的正是 CommonJS（__dirname / require）语义，扩展名必须显式成 .cjs。
 *
 * 依赖为零，可在 CI 与本地直接 `node .github/scripts/check-exports.cjs`。
 */
const { existsSync, readdirSync, statSync, readFileSync } = require('node:fs')
const { join, resolve } = require('node:path')

const repoRoot = resolve(__dirname, '..', '..')
const pkg = JSON.parse(readFileSync(join(repoRoot, 'package.json'), 'utf8'))

/** 收集需要校验的路径：exports 的全部字符串叶子 + files 列表 */
function collectPaths(p) {
  const out = []
  const walk = (v) => {
    if (typeof v === 'string') out.push(v)
    else if (v && typeof v === 'object') Object.values(v).forEach(walk)
  }
  walk(p.exports)
  for (const f of p.files ?? []) out.push(f)
  return out
}

/** 把单个 glob 段（只含 *）编译成正则 */
function segmentToRegExp(seg) {
  const escaped = seg.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`^${escaped.replace(/\*/g, '.*')}$`)
}

/** 绝对化：相对说明符一律相对仓库根，而不是 cwd */
function toAbs(p) {
  return join(repoRoot, p.replace(/^\.\//, ''))
}

/** 返回 null 表示通过，否则返回错误描述 */
function verify(raw) {
  const norm = raw.replace(/^\.\//, '')
  if (!norm.includes('*')) {
    return existsSync(toAbs(norm)) ? null : `缺失: ${raw}`
  }
  const segs = norm.split('/')
  const idx = segs.findIndex((s) => s.includes('*'))
  const dirAbs = toAbs(segs.slice(0, idx).join('/') || '.')
  if (!existsSync(dirAbs) || !statSync(dirAbs).isDirectory()) return `目录缺失: ${raw}`
  const re = segmentToRegExp(segs[idx])
  const hits = readdirSync(dirAbs).filter((n) => re.test(n))
  return hits.length > 0 ? null : `无匹配文件: ${raw}`
}

const paths = collectPaths(pkg)
if (paths.length === 0) {
  console.error('package.json 既无 exports 也无 files，无法校验发布形态')
  process.exit(1)
}

let bad = 0
for (const p of paths) {
  const err = verify(p)
  if (err) {
    console.error(`  FAIL ${err}`)
    bad++
  } else {
    console.log(`   OK  ${p}`)
  }
}

if (bad > 0) {
  console.error(`\n${bad} 个路径不可达`)
  process.exit(1)
}
console.log(`\nexports/files 全部可达（${paths.length} 条）`)
