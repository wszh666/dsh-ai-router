/**
 * Diagnostic probe for the ai-router bundle.
 *
 * The session-level model allowlist is snapshotted when a Session is created,
 * so a session that predates the configuration cannot report which routes the
 * provider registry actually holds. This plugin answers that question from the
 * Host side instead: on mount it resolves every declared route through the same
 * `llm.resolveCallConfig` preflight the subagent tool uses, then writes the
 * outcome to a JSON file that any session can read.
 *
 * It performs no inference and makes no network call; it only asks the runtime
 * whether a route resolves.
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

// Report location defaults to ./diagnostics/report.json next to this module.
// Override with AI_ROUTER_REPORT when the bundle lives somewhere read-only.
const REPORT_PATH = process.env.AI_ROUTER_REPORT
  ?? fileURLToPath(new URL('./diagnostics/report.json', import.meta.url))

const ROUTES = [
  { provider: 'ollama', model: 'qwen2.5vl:7b' },
  { provider: 'ollama', model: 'qwen2.5vl:3b' },
  // 免费档：智谱（Key 已在 credentials）与 pollinations（完全免 Key）。
  { provider: 'zhipu', model: 'glm-4-flash' },
  { provider: 'zhipu', model: 'glm-4v-flash' },
  { provider: 'pollinations', model: 'openai-fast' },
  // 待填 Key 的路由：解析成功只证明路由注册了，不代表 Key 有效。
  { provider: 'modelscope', model: 'deepseek-ai/DeepSeek-V4.1-Flash' },
  { provider: 'openrouter', model: 'baidu/ernie-5.5-flash-preview:free' },
  { provider: 'doubao', model: 'doubao-seed-2-1-pro-260915' },
  // hunyuan (直连混元) 于 2026-11-14 因 401 停用，元宝改走 tokenhub/hy3。
  { provider: 'tokenhub', model: 'deepseek-v4-pro' },
  { provider: 'tokenhub', model: 'hy3' },
  { provider: 'tokenhub', model: 'glm-5.3' },
  { provider: 'tokenhub', model: 'kimi-k3.1-pro' },
  // DeepSeek 官方 API（付费，需要 DEEPSEEK_API_KEY）
  { provider: 'deepseek', model: 'deepseek-v4-flash' },
  { provider: 'deepseek-account', model: 'deepseek-flash' },
]

export const name = 'ai-router-diagnostics'

export const inject = ['llm']

export function apply(ctx) {
  const report = {
    at: new Date().toISOString(),
    plugin: name,
    serviceAvailable: false,
    probes: [],
  }

  const flush = () => {
    try {
      mkdirSync(dirname(REPORT_PATH), { recursive: true })
      writeFileSync(REPORT_PATH, JSON.stringify(report, null, 2), 'utf8')
    } catch {
      // A failed diagnostic write must never take the plugin down.
    }
  }

  const llm = ctx.get('llm')
  if (llm === undefined) {
    report.error = 'llm service unavailable'
    flush()
    return
  }
  report.serviceAvailable = true
  try {
    report.methods = Object.getOwnPropertyNames(Object.getPrototypeOf(llm))
      .filter(key => typeof llm[key] === 'function')
  } catch {
    report.methods = []
  }
  flush()

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

  // Mount order is not a guarantee: this plugin can mount before the pi-ai
  // adapter has registered its routes, which used to poison the report with
  // "no adapter registered for provider X" while the route actually worked a
  // few hundred milliseconds later. Retry before recording a failure.
  const resolveWithRetry = async (route) => {
    let lastError
    for (let attempt = 1; attempt <= 4; attempt++) {
      try {
        return { resolved: await llm.resolveCallConfig(route), attempts: attempt }
      } catch (error) {
        lastError = error
        if (attempt < 4) await sleep(500 * attempt)
      }
    }
    throw lastError
  }

  void (async () => {
    for (const route of ROUTES) {
      const entry = { ...route }
      try {
        const { resolved, attempts } = await resolveWithRetry(route)
        entry.ok = true
        entry.attempts = attempts
        entry.resolvedKeys = resolved === null || typeof resolved !== 'object'
          ? String(resolved)
          : Object.keys(resolved)
      } catch (error) {
        entry.ok = false
        entry.error = String(error?.message ?? error)
      }
      report.probes.push(entry)
      flush()
    }
  })()
}
