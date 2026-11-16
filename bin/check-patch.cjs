// Validate ai-router/cordis.patch.yml and cross-check the route table against
// the subagent whitelist. Run: bin\check-patch.cmd
const fs = require('node:fs')
const path = require('node:path')

// Locate a YAML parser: try a plain require first (works when js-yaml is a
// dependency of the enclosing profile), then fall back to $DSH_PROFILE_DIR or
// one of $DSH_NODE_PATH entries. No machine-specific paths are hardcoded.
function loadYaml () {
  try { return require('js-yaml') } catch { /* fall through */ }
  try { return require('yaml') } catch { /* fall through */ }

  const roots = []
  if (process.env.DSH_PROFILE_DIR) roots.push(process.env.DSH_PROFILE_DIR)
  for (const p of (process.env.DSH_NODE_PATH || '').split(path.delimiter)) {
    if (p) roots.push(p)
  }
  for (const root of roots) {
    for (const name of ['js-yaml', 'yaml']) {
      const c = path.join(root, 'node_modules', name)
      if (fs.existsSync(c)) {
        try { return require(c) } catch { /* try next */ }
      }
    }
  }
  return null
}

const yaml = loadYaml()
if (!yaml) {
  console.error('no yaml parser found; set DSH_PROFILE_DIR or DSH_NODE_PATH, or install js-yaml')
  process.exit(2)
}

const file = path.resolve(__dirname, '..', 'cordis.patch.yml')
const text = fs.readFileSync(file, 'utf8')
let doc
try {
  doc = yaml.load(text)
} catch (e) {
  console.error('YAML PARSE FAILED:', e.message)
  process.exit(1)
}
console.log('YAML OK:', file, '- top-level entries:', doc.length)

const providersEntry = doc.find((e) => e && e.id === 'llm-pi-ai')
if (!providersEntry) { console.error('llm-pi-ai entry missing'); process.exit(1) }
const providers = providersEntry.config.providers
console.log('\nproviders:')
for (const [name, p] of Object.entries(providers)) {
  const models = (p.models || []).map((m) => m.id)
  console.log(` - ${name.padEnd(13)} api=${p.api || '(catalog)'} key=${p.apiKeyEnv || '-'} models=${models.length} [${models.join(', ')}]`)
}

const wl = doc.find((e) => e && e.id === 'subagent-model-selection-settings')
if (!wl) { console.error('\nwhitelist entry missing'); process.exit(1) }
const allowed = wl.config.allowedModels
console.log('\nwhitelist entries:', allowed.length)

const problems = []
for (const a of allowed) {
  if (a.provider === 'deepseek-account') continue
  const p = providers[a.provider]
  if (!p) { problems.push(`provider not declared: ${a.provider}`); continue }
  const ids = (p.models || []).map((m) => m.id)
  if (!ids.includes(a.model)) problems.push(`model not in provider: ${a.provider}/${a.model}`)
}
console.log(problems.length === 0 ? 'cross-check: provider/model all consistent' : 'PROBLEMS:\n' + problems.join('\n'))

const missing = []
for (const [name, p] of Object.entries(providers)) {
  for (const m of p.models || []) {
    if (!allowed.some((a) => a.provider === name && a.model === m.id)) missing.push(`${name}/${m.id}`)
  }
}
console.log(missing.length === 0
  ? 'whitelist covers every declared model'
  : 'declared but not whitelisted (selectable as main model, not by subagents):\n  ' + missing.join('\n  '))
process.exit(problems.length === 0 ? 0 : 1)
