// tools/test/test-no-fallback-literals.cjs

/**
 * ==============================================================================
 * MODULE: No-Fallback-Literal Invariant Test
 * DESCRIPTION:
 * Cross-driver regression guard locking in the fail-fast refactor: the hardcoded
 * default/fallback mirrors that used to silently mask a missing or renamed shared
 * value have been removed, and they must never come back. This text-scans the
 * driver sources (no runtime needed, runs in CI on any OS) and fails if a
 * forbidden pattern reappears.
 *
 * Each entry encodes the ROOT CAUSE of a specific fix so the regression can never
 * silently return (project rule 5.9): a future edit that re-adds a divergent
 * in-code default fails here instead of shipping.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '../../static/ergopti_plus');

const PASS = '✓';
const FAIL = '✗';
let pass = 0;
let fail = 0;

// Each check: a file, a forbidden regex, and why it must stay gone.
const CHECKS = [
	{
		file: 'windows/infra/llm_defaults.ahk',
		forbid: /_LLM_DEFAULTS_FALLBACK/,
		why: 'the 20-key AHK defaults mirror is gone — read every shared key from defaults.json (fail fast)'
	},
	{
		file: 'windows/ui/menu/menu_llm/menu_settings.ahk',
		forbid: /_LLM_DEFAULTS_FALLBACK/,
		why: '_LLM_DefaultFor must read LLM_Defaults, never the deleted fallback mirror'
	},
	{
		file: 'windows/modules/llm/api_common.ahk',
		forbid: /LLM_COMMON_FALLBACK/,
		why: 'the inference-tunables mirror is gone — read every tunable from inference.json (fail fast)'
	},
	{
		file: 'macos/modules/llm/profiles.lua',
		forbid: /llm_(min|max)_words\s+or\s+\d/,
		why: 'word bounds come from the single source (DEFAULT_STATE), never a divergent `or 4` / `or 20`'
	},
	{
		file: 'macos/modules/llm/init.lua',
		forbid: /get_port\(\)\)?\s*or\s*8080/,
		why: 'the MLX boot sweep must resolve the canonical port, never fall back to the forbidden 8080'
	},
	{
		file: 'macos/modules/llm/api_ollama.lua',
		forbid: /"http:\/\/127\.0\.0\.1:11434/,
		why: 'Ollama URLs must derive from get_base_url() (configurable port), not a hardcoded host:port'
	}
];




// ==================================================
// ==================================================
// ======= 1/ Scan =================================
// ==================================================
// ==================================================

console.log('\nNo-fallback-literal invariants (fail-fast lock)');
console.log('='.repeat(50));

for (const check of CHECKS) {
	const abs = path.join(ROOT, check.file);
	if (!fs.existsSync(abs)) {
		console.log(`  ${FAIL}  ${check.file}: file not found`);
		fail++;
		continue;
	}
	const src = fs.readFileSync(abs, 'utf8');
	if (check.forbid.test(src)) {
		console.log(`  ${FAIL}  ${check.file}: forbidden pattern ${check.forbid}`);
		console.log(`       - ${check.why}`);
		fail++;
	} else {
		console.log(`  ${PASS}  ${check.file} (${check.forbid})`);
		pass++;
	}
}

console.log('');
console.log(`Total: ${pass + fail} check(s) — ${pass} passed, ${fail} failed`);
console.log('');

process.exit(fail > 0 ? 1 : 0);
