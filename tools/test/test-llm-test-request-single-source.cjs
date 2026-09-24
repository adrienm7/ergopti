// tools/test/test-llm-test-request-single-source.cjs

/**
 * ==============================================================================
 * MODULE: API Test-Request Single-Source Guard
 * DESCRIPTION:
 * The Test-API probe (minimal end-to-end completion both drivers send
 * verbatim from their Test-active-entry action) lives in exactly ONE place —
 * _shared/modules/llm/api_providers.json (test_request). Both drivers read
 * the prompt, temperature and token budget from there; neither may restate
 * the probe text, or the two buttons stop proving the same thing.
 *
 * ROOT CAUSE ENCODED:
 * A shared probe restated per driver drifts the first time one side is
 * touched (temperature tuned here, prompt reworded there) with no failure
 * anywhere. This guard fails if the probe text appears outside the JSON, or
 * if either driver stops referencing the shared section (which would mean
 * the read was silently deleted and a literal took its place).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SSOT_FILE = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'llm', 'api_providers.json');

// Files that must read the shared probe instead of restating it.
const CONSUMERS = [
	{
		rel: 'static/ergopti_plus/windows/modules/llm/api_remote.ahk',
		refs: ['test_request'],
	},
	{
		rel: 'static/ergopti_plus/windows/ui/menu/menu_llm/menu_api_entries.ahk',
		refs: ['test_request'],
	},
	{
		rel: 'static/ergopti_plus/macos/modules/llm/api_remote.lua',
		refs: ['TEST_REQUEST', 'test_request'],
	},
	{
		rel: 'static/ergopti_plus/macos/ui/menu/menu_llm/api_panel.lua',
		refs: ['test_request'],
	},
	{
		rel: 'static/ergopti_plus/linux/modules/llm/api_remote.lua',
		refs: ['test_request'],
	},
];

let failed = false;
const fail = (msg) => {
	console.error(`\x1b[31m[ERROR] ${msg}\x1b[0m`);
	failed = true;
};

let spec;
try {
	spec = JSON.parse(fs.readFileSync(SSOT_FILE, 'utf8')).test_request;
} catch (err) {
	fail(`could not read test_request from api_providers.json: ${err.message}`);
}

if (!spec || typeof spec !== 'object') {
	fail('api_providers.json has no test_request object.');
} else {
	const problems = [];
	if (typeof spec.system_prompt !== 'string' || spec.system_prompt === '') {
		problems.push('system_prompt must be a non-empty string');
	}
	if (typeof spec.user_text !== 'string' || spec.user_text === '') {
		problems.push('user_text must be a non-empty string');
	}
	if (typeof spec.temperature !== 'number' || spec.temperature < 0 || spec.temperature > 2) {
		problems.push('temperature must be a number in 0..2');
	}
	if (!Number.isInteger(spec.max_tokens) || spec.max_tokens <= 0 || spec.max_tokens > 64) {
		problems.push('max_tokens must be a small positive integer (<= 64)');
	}
	for (const p of problems) fail(`invalid test_request: ${p}.`);
}

// The probe text must live ONLY in the JSON. Strip comments first so a
// documentation mention is not flagged as a restatement.
function stripLineComments(src, isAhk) {
	return src
		.split('\n')
		.map((line) => (isAhk ? line.replace(/(^|\s);.*$/, '$1') : line.split('--')[0]))
		.join('\n');
}

if (spec && typeof spec.system_prompt === 'string' && spec.system_prompt !== '') {
	const probe = spec.system_prompt;
	for (const { rel, refs } of CONSUMERS) {
		const abs = path.join(ROOT, rel);
		if (!fs.existsSync(abs)) {
			fail(`consumer file missing: ${rel}.`);
			continue;
		}
		const src = fs.readFileSync(abs, 'utf8');
		const code = stripLineComments(src, rel.endsWith('.ahk'));
		if (code.includes(probe)) {
			fail(`${rel} restates the shared probe text (keep it in api_providers.json only).`);
		}
		const missing = refs.filter((r) => !src.includes(r));
		if (missing.length > 0) {
			fail(`${rel} no longer references the shared probe (${missing.join(', ')}) — read deleted?`);
		}
	}
}

if (failed) process.exit(1);
console.log('\x1b[32m[OK] API test-request probe is single-sourced (api_providers.json test_request).\x1b[0m');
