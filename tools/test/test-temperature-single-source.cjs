// tools/test/test-temperature-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Temperature Single-Source Guard (macOS LLM backend adapters)
 * DESCRIPTION:
 * Forbids any macOS LLM backend adapter from hardcoding the default generation
 * temperature (the ``tonumber(x) or 0.1`` idiom) at a call site. The default
 * has one source — ``llm_temperature`` in _shared/modules/llm/defaults.json,
 * surfaced once as ApiCommon.DEFAULT_TEMPERATURE — and every defensive fallback
 * must resolve to it, never to a per-site literal.
 *
 * ROOT CAUSE ENCODED:
 * The bug was the literal 0.1 duplicated across 13 fallback sites in four
 * adapters (api_common, api_remote, api_ollama, api_mlx). Sourcing them from
 * ApiCommon.DEFAULT_TEMPERATURE removes the duplication; this guard fails if any
 * adapter reintroduces a ``or 0.1`` temperature literal, so the divergence can
 * never return. The single intentional JSON-mirror fallback inside
 * load_default_temperature() is a bare ``return 0.1`` (not ``or 0.1``) and is
 * therefore not matched — it is the one place allowed to name the value, exactly
 * like api_common's existing FALLBACK mirror of inference.json.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

// The single source of truth for the default generation temperature.
const SSOT_FILE = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'llm', 'defaults.json');

const ADAPTERS = [
	'static/ergopti_plus/macos/modules/llm/api_common.lua',
	'static/ergopti_plus/macos/modules/llm/api_remote.lua',
	'static/ergopti_plus/macos/modules/llm/api_ollama.lua',
	// The MLX request builder (where temperature resolves) moved out of api_mlx.lua
	// into the api_mlx_inference sibling during the P6 god-file split.
	'static/ergopti_plus/macos/modules/llm/api_mlx_inference.lua'
];

// Every adapter must reference the single shared default so the resolution is
// never simply deleted (which would push a raw nil into the request payload).
const SHARED_REF_RE = /DEFAULT_TEMPERATURE/;

// Forbidden: a temperature fallback literal at a call site. Matches " or 0.1"
// only when NOT followed by another digit, so the legitimate retry step
// " or 0.18" is left alone, and the bare "return 0.1" JSON mirror is not an
// "or" fallback and is not matched.
const FORBIDDEN_RE = / or 0\.1(?![0-9])/;

const ssotTemp = (() => {
	const m = fs.readFileSync(SSOT_FILE, 'utf8').match(/"llm_temperature"\s*:\s*([0-9.]+)/);
	return m ? Number(m[1]) : null;
})();
if (ssotTemp === null) {
	console.error('\x1b[31m[ERROR] Could not read llm_temperature from the shared defaults.json.\x1b[0m');
	process.exit(1);
}

const violations = [];
const missingRef = [];

for (const rel of ADAPTERS) {
	const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
	const lines = src.split('\n');
	if (!SHARED_REF_RE.test(src)) missingRef.push(rel);
	for (let i = 0; i < lines.length; i++) {
		if (FORBIDDEN_RE.test(lines[i])) {
			violations.push(`${rel}:${i + 1}  ${lines[i].trim()}`);
		}
	}
}

if (violations.length > 0 || missingRef.length > 0) {
	console.error(`\x1b[31m[ERROR] Default temperature must come from the single shared source (llm_temperature = ${ssotTemp}).\x1b[0m`);
	if (violations.length > 0) {
		console.error('  Literal "or 0.1" temperature fallback found in a backend adapter:');
		for (const v of violations) console.error('    ' + v);
		console.error('  Use ApiCommon.DEFAULT_TEMPERATURE instead.');
	}
	if (missingRef.length > 0) {
		console.error('  Adapter no longer references DEFAULT_TEMPERATURE (resolution deleted?):');
		for (const f of missingRef) console.error('    ' + f);
	}
	process.exit(1);
}

console.log(`\x1b[32m[OK] No literal temperature fallbacks — all ${ADAPTERS.length} macOS adapters defer to the shared DEFAULT_TEMPERATURE (${ssotTemp}).\x1b[0m`);
