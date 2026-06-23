// tools/test/test-max-tokens-single-source.cjs

/**
 * ==============================================================================
 * MODULE: max_tokens Single-Source Guard (LLM backend adapters)
 * DESCRIPTION:
 * Forbids any backend adapter from re-declaring the output-token cap default as
 * a bare numeric literal. The cap has exactly ONE source — the domain constant
 * DEFAULT_MAX_TOKENS in _shared/core/domain/PromptBuilder.js, propagated by
 * codegen to PB_DEFAULT_MAX_TOKENS (AHK) and read as SharedPromptBuilder
 * .DEFAULT_MAX_TOKENS (Lua). The engine threads that value into every backend;
 * an unset/out-of-range value must resolve to the shared constant, never to a
 * per-file literal.
 *
 * ROOT CAUSE ENCODED:
 * The bug was three divergent hardcoded fallbacks (ollama 150, remote 256, mlx
 * 50). Unifying the VALUE is not enough — the moment a literal lives in an
 * adapter it can drift again. This guard fails if ANY of the backend adapters
 * contains a numeric-literal max_tokens default/fallback (AHK `max_tokens := N`,
 * AHK `Integer(max_tokens) : N`, or Lua `tonumber(...max_tokens...) or N`),
 * forcing every default to come from the single shared constant. It is the
 * cross-platform twin of the OS-purity and pinned-source ratchets: no new
 * instances of a divergence-prone pattern. Deliberate non-default literals
 * (e.g. the 1-token MLX/Ollama health probes, `max_tokens = 1`) are NOT matched
 * because they are direct assignments, not `:=` defaults or `or` fallbacks.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

// The single source of truth for the default output-token budget.
const SSOT_FILE = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'core', 'domain', 'PromptBuilder.js');

// Backend adapters that must defer to the shared constant for their default.
const ADAPTERS = [
	'static/ergopti_plus/windows/modules/llm/api_remote.ahk',
	'static/ergopti_plus/windows/modules/llm/api_ollama.ahk',
	'static/ergopti_plus/macos/modules/llm/api_remote.lua',
	// The MLX request builder (where max_tokens resolves) moved out of api_mlx.lua
	// into the api_mlx_inference sibling during the P6 god-file split.
	'static/ergopti_plus/macos/modules/llm/api_mlx_inference.lua'
];

// Each builder file must positively reference the shared constant so the default
// resolution is never simply deleted (which would push a raw nil/"" downstream).
const SHARED_REF_RE = /PB_DEFAULT_MAX_TOKENS|SharedPromptBuilder\.DEFAULT_MAX_TOKENS/;

// Forbidden literal-default patterns, per language:
//   AHK param default:    max_tokens := 150
//   AHK body fallback:    ... ? Integer(max_tokens) : 150
//   Lua fallback:         tonumber(opts.max_tokens) or 50
const FORBIDDEN = [
	{ re: /max_tokens\s*:=\s*\d+/g, why: 'AHK param default literal (use the "" sentinel + PB_DEFAULT_MAX_TOKENS)' },
	{ re: /Integer\(\s*max_tokens\s*\)\s*:\s*\d+/g, why: 'AHK body fallback literal (use : PB_DEFAULT_MAX_TOKENS)' },
	{ re: /tonumber\([^)\n]*max_tokens[^)\n]*\)\s*or\s*\d+/g, why: 'Lua fallback literal (use or SharedPromptBuilder.DEFAULT_MAX_TOKENS)' }
];

/**
 * Reads DEFAULT_MAX_TOKENS from the domain SSoT so the message can name the
 * canonical value a drifting literal should have deferred to.
 * @returns {number|null} The parsed default, or null if the constant is absent.
 */
function readSsotDefault() {
	const src = fs.readFileSync(SSOT_FILE, 'utf8');
	const m = src.match(/const\s+DEFAULT_MAX_TOKENS\s*=\s*(\d+)\s*;/);
	return m ? Number(m[1]) : null;
}

const ssot = readSsotDefault();
if (ssot === null) {
	console.error('\x1b[31m[ERROR] Could not read DEFAULT_MAX_TOKENS from the domain SSoT (PromptBuilder.js).\x1b[0m');
	process.exit(1);
}

const violations = [];
const missingRef = [];

for (const rel of ADAPTERS) {
	const abs = path.join(ROOT, rel);
	const src = fs.readFileSync(abs, 'utf8');
	const lines = src.split('\n');

	if (!SHARED_REF_RE.test(src)) missingRef.push(rel);

	for (const { re, why } of FORBIDDEN) {
		re.lastIndex = 0;
		for (let i = 0; i < lines.length; i++) {
			if (re.test(lines[i])) {
				violations.push(`${rel}:${i + 1}  ${lines[i].trim()}   — ${why}`);
			}
			re.lastIndex = 0;
		}
	}
}

if (violations.length > 0 || missingRef.length > 0) {
	console.error(`\x1b[31m[ERROR] max_tokens default must come from the single shared source (DEFAULT_MAX_TOKENS = ${ssot}).\x1b[0m`);
	if (violations.length > 0) {
		console.error('  Literal max_tokens default/fallback found in a backend adapter:');
		for (const v of violations) console.error('    ' + v);
	}
	if (missingRef.length > 0) {
		console.error('  Adapter no longer references the shared constant (default resolution deleted?):');
		for (const f of missingRef) console.error('    ' + f);
	}
	process.exit(1);
}

console.log(`\x1b[32m[OK] No literal max_tokens defaults — all ${ADAPTERS.length} backend adapters defer to the shared DEFAULT_MAX_TOKENS (${ssot}).\x1b[0m`);
