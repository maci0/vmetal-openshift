// Render every ```mermaid block in the docs to a themed SVG with beautiful-mermaid
// (https://agents.craft.do/mermaid). Programmatic + repeatable: `make diagrams`.
//
// Resolves beautiful-mermaid from the local node_modules, $BEAUTIFUL_MERMAID, or a
// global install. Install with: npm i -g beautiful-mermaid
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'

const require = createRequire(import.meta.url)
const THEME = process.env.BM_THEME || 'github-light'
const OUT = 'docs/diagrams'

function resolveBM() {
  const home = process.env.HOME || ''
  const candidates = [
    process.env.BEAUTIFUL_MERMAID,
    'beautiful-mermaid',
    `${home}/.feynman/npm-global/lib/node_modules/beautiful-mermaid`,
  ]
  for (const c of candidates) {
    if (!c) continue
    try { return require.resolve(c) } catch { /* try next */ }
  }
  // global npm root
  try {
    const root = execSync('npm root -g', { encoding: 'utf8' }).trim()
    return require.resolve(`${root}/beautiful-mermaid`)
  } catch { /* fall through */ }
  throw new Error('beautiful-mermaid not found; npm i -g beautiful-mermaid (or set $BEAUTIFUL_MERMAID)')
}

const { renderMermaidSVG, THEMES } = await import(resolveBM())
const theme = THEMES[THEME] || THEMES['github-light']
mkdirSync(OUT, { recursive: true })

const docs = readdirSync('docs').filter(f => f.endsWith('.md')).map(f => `docs/${f}`)
let pass = 0, fail = 0
for (const doc of docs) {
  const blocks = [...readFileSync(doc, 'utf8').matchAll(/```mermaid\n([\s\S]*?)```/g)].map(m => m[1])
  const base = doc.split('/').pop().replace(/\.md$/, '')
  blocks.forEach((b, i) => {
    const name = `${base}-${i + 1}`
    try {
      const svg = renderMermaidSVG(b, theme)
      if (!svg.includes('<svg')) throw new Error('no <svg> in output')
      writeFileSync(`${OUT}/${name}.svg`, svg)
      pass++
    } catch (e) {
      console.error(`FAIL ${name}: ${e.message.split('\n')[0]}`)
      fail++
    }
  })
}
console.log(`rendered ${pass} diagram(s) to ${OUT}/ (theme: ${THEME})${fail ? `, ${fail} failed` : ''}`)
process.exit(fail ? 1 : 0)
