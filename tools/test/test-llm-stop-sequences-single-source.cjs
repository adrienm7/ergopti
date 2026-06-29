// tools/test/test-llm-stop-sequences-single-source.cjs

/**
 * ==============================================================================
 * MODULE: LLM Stop-Sequences Single-Source Gate (P10.2 D-3)
 * DESCRIPTION:
 * Ensures that the three backend files that previously hard-coded stop-token
 * arrays (windows api_ollama.ahk, macos api_ollama.lua, macos api_mlx_inference.lua)
 * no longer contain literal inline arrays, and that inference.json carries the
 * authoritative stop_sequences section that both drivers read at runtime.
 *
 * FEATURES & RATIONALE:
 * 1. Detects regression: a re-inlined literal is caught before it silently drifts
 *    from the JSON source (the exact failure mode D-3 was created to prevent).
 * 2. Positive check: verifies inference.json actually has the stop_sequences key
 *    so the fallback cannot be triggered silently at runtime.
 * ==============================================================================
 */

'use strict';

const fs   = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const EP   = path.join(ROOT, 'static', 'ergopti_plus');

const failures = [];

function check(label, filePath, pattern, mustMatch) {
	const rel = path.relative(ROOT, filePath).replace(/\\/g, '/');
	if (!fs.existsSync(filePath)) {
		failures.push(`[MISSING] ${rel} — file not found`);
		return;
	}
	const src  = fs.readFileSync(filePath, 'utf8');
	const hit  = pattern.test(src);
	if (mustMatch && !hit) {
		failures.push(`[MISSING] ${rel} — expected pattern not found: ${pattern}`);
	} else if (!mustMatch && hit) {
		failures.push(`[VIOLATION] ${rel} — literal stop array found (should read from inference.json): ${pattern}`);
	}
}

// inference.json must contain the stop_sequences section
check(
	'inference.json has stop_sequences',
	path.join(EP, '_shared', 'modules', 'llm', 'inference.json'),
	/"stop_sequences"\s*:/,
	true
);

// AHK api_ollama.ahk must NOT define inline stop globals (detect re-inlining by
// the distinctive first token "<|eot_id|>" appearing as a literal in this file)
check(
	'AHK api_ollama.ahk: no inline stop-token literal',
	path.join(EP, 'windows', 'modules', 'llm', 'api_ollama.ahk'),
	/"<\|eot_id\|>"/,
	false
);

// macOS api_ollama.lua must NOT contain inline stop-token literals
check(
	'macOS api_ollama.lua: no inline stop-token literal',
	path.join(EP, 'macos', 'modules', 'llm', 'api_ollama.lua'),
	/"<\|eot_id\|>"/,
	false
);

// macOS api_mlx_inference.lua must NOT contain inline stop-token literals
check(
	'macOS api_mlx_inference.lua: no inline stop-token literal',
	path.join(EP, 'macos', 'modules', 'llm', 'api_mlx_inference.lua'),
	/"<\|eot_id\|>"/,
	false
);

if (failures.length > 0) {
	console.error('\x1b[31m[ERROR] LLM stop-sequences single-source violations:\x1b[0m');
	for (const f of failures) console.error('  ' + f);
	console.error('\n  Stop sequences must be read from _shared/modules/llm/inference.json.');
	console.error('  Do NOT re-inline literal arrays in backend adapter files.');
	process.exit(1);
}

console.log('\x1b[32m[OK] LLM stop sequences: single source in inference.json, no inline literals in backends.\x1b[0m');
