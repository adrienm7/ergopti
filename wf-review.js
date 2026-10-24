export const meta = {
  name: 'review-and-land-branch',
  description: 'Adversarially review one agent branch against origin/dev, verify each finding, then fix confirmed ones in its worktree',
  whenToUse: 'Before pushing an agent branch onto Ergopti dev',
  phases: [
    { title: 'Review', detail: 'three independent lenses over the branch diff' },
    { title: 'Verify', detail: 'two skeptics per finding; one refutation kills it' },
    { title: 'Fix', detail: 'one fixer applies confirmed findings in the worktree' },
  ],
}

const A = args
const CTX = `Repository worktree: ${A.worktree} (git branch ${A.ref}). The change under review is \`git -C ${A.worktree} log --reverse -p origin/dev..HEAD\` (${A.commits} commits on top of origin/dev). Work READ-ONLY in that worktree (no edits, no commits, no fetch). The author's own report:\n---\n${A.report}\n---\nRepository rules that matter: AGENTS.md (one source of truth per constant, no magic values, no silent fallbacks, fail fast, explicit init ownership, cross-OS parity or a stated reason, regression test that can fail for the original bug, generated files only through generators, English Conventional Commits without Co-Authored-By or tool attribution). Every finding must cite file:line in the CURRENT worktree and concrete evidence (a command you ran, code you read). Do not report style nits the strict lint already enforces, and do not report pre-existing issues the branch does not touch.`

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'number' },
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          claim: { type: 'string' },
          evidence: { type: 'string' },
          suggested_fix: { type: 'string' },
        },
        required: ['file', 'line', 'severity', 'claim', 'evidence', 'suggested_fix'],
      },
    },
  },
  required: ['findings'],
}

const LENSES = [
  { key: 'correctness', prompt: `${CTX}\n\nLENS: correctness. Find real bugs the branch introduces: wrong logic, broken edge cases, behaviour regressions for existing users, error paths that hide failures, races, resource leaks, tests that cannot fail (false green: assertions on tautologies, scans that return empty, vectors not actually replayed). Run the branch's new/changed tests yourself where cheap (Linux: cd static/ergopti_plus/linux && luajit tests/run.lua --only <module>; macOS: cd static/ergopti_plus/macos && LUA=lua5.4 lua5.4 tests/run.lua --only <module>; node tools/test/<gate>.cjs). Then try to make one fail by mentally mutating the production code it guards.` },
  { key: 'contracts', prompt: `${CTX}\n\nLENS: repository contracts and parity. Check the diff against AGENTS.md and the relevant .agents/skills (cross-driver-parity, logger, i18n, verify-change, linux-driver, hammerspoon-driver, ahk-driver as applicable) and docs/memory topics: duplicated constants, hard-coded values that have a registry, new gates not registered where the suite and verify-change run them (tools/test/features/*/suite.json ordinals must be unique across all suites; package.json aliases; CI wiring self-checks such as tools/test/test-ci-pipeline-wiring.cjs), generated files edited by hand, locale keys missing in some of the 21 locales, platform behaviour that diverges without a reason, logger lifecycle pairing.` },
  { key: 'integration', prompt: `${CTX}\n\nLENS: integration risk. This branch will be rebased onto a dev that other agents are concurrently changing (shared Lua helpers, ownership shims, menu frames, timing registry gates, UI-string gates, fix/linux fix/macos fix/windows rebases with ~340 commits). Find: claims in the commit messages that the diff does not deliver; CI workflow edits that could break a hosted lane (YAML syntax, step names pinned by tests, shard counts); files pinned by hash (tools/ci/*cohort*inputs*.json, updater seals) that the branch changes without resealing; things that would only work on the author's container. Run node tools/test/verify-change.cjs --range=origin/dev..HEAD --plan in the worktree and say which selected gates matter.` },
]

phase('Review')
const reviews = await parallel(LENSES.map(l => () =>
  agent(l.prompt, { label: `review:${l.key}`, phase: 'Review', schema: FINDINGS })
    .then(r => (r ? r.findings.map(f => ({ ...f, lens: l.key })) : []))))
const all = reviews.filter(Boolean).flat()
log(`${all.length} raw findings`)

const VERDICT = {
  type: 'object',
  properties: { refuted: { type: 'boolean' }, reasoning: { type: 'string' } },
  required: ['refuted', 'reasoning'],
}

phase('Verify')
const verified = await parallel(all.map((f, i) => () =>
  parallel(['code', 'convention'].map(v => () =>
    agent(`${CTX}\n\nA reviewer claims (${f.severity}, lens ${f.lens}) at ${f.file}:${f.line}: ${f.claim}\nEvidence given: ${f.evidence}\n\nYour job (${v} lens): try to REFUTE it. ${v === 'code' ? 'Read the cited code and its callers; run what is cheap to run. Is the claimed failure actually reachable from a real caller or input? Is it pre-existing rather than introduced by this branch?' : 'Does the claim misread a repository rule, re-raise a decision recorded in docs/memory/rejected_proposals.md or the todo "Decided, do not re-raise" section, or ask for something out of proportion to what it prevents?'} Answer refuted=true if the claim is wrong, not introduced by this branch, unreachable, or not worth its fix; refuted=false only if it is a real, introduced defect worth fixing.`,
      { label: `verify:${v}:${i}`, phase: 'Verify', schema: VERDICT })))
    .then(vs => ({ f, vs: vs.filter(Boolean) }))))
const confirmed = verified.filter(Boolean).filter(x => x.vs.length === 2 && x.vs.every(v => !v.refuted)).map(x => x.f)
log(`${confirmed.length} confirmed of ${all.length}`)

let fix = null
if (confirmed.length) {
  phase('Fix')
  fix = await agent(`You are the fixer for Ergopti worktree ${A.worktree} (branch ${A.ref}; commit there, never push, never fetch/rebase/reset/stash). Confirmed review findings on the branch's commits (origin/dev..HEAD):\n${JSON.stringify(confirmed, null, 2)}\n\nFix each one properly at its root, as new atomic commits on top of the branch (English Conventional Commits, lowercase subject <= 72 chars, body explains why; NO Co-Authored-By or tool attribution; never --no-verify — the husky hook formats and lints). Add or strengthen a test that fails without each fix. node_modules is a symlink to the coordinator checkout. Run the targeted gates (the driver suites' affected modules, node tools/test/verify-change.cjs --range=origin/dev..HEAD for the JS gates; npm run lint:conventions:strict; npm run format:check limited to files you touched). Final answer: per finding, fixed (commit sha) or not fixed (why), and gate results.`,
    { label: 'fix', phase: 'Fix' })
}
return { raw: all.length, confirmed, fix }
