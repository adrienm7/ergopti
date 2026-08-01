// tools/test/test-prompt-builder-constants-parity.cjs

/**
 * ==============================================================================
 * MODULE: Prompt-Builder Constant Parity (Lua ↔ JS ↔ generated AHK)
 * DESCRIPTION:
 * The ten prompt-builder constants must hold the same value in every language
 * that declares them.
 *
 * WHAT THIS PINS, AND WHAT THE BACKLOG SAID:
 * Lot 8 recorded "5 hand-maintained copies today, already diverged". Measured on
 * 2026-08-01, that is **no longer true**, and the reason is worth keeping: the
 * AutoHotkey copy became a generator output, which removed the copy that had
 * drifted. What survives is three declarations of the same ten numbers — shared
 * Lua, shared JS, generated AHK — agreeing today with nothing checking that they
 * still will. `test-max-tokens-single-source.cjs` covers exactly one of the ten,
 * and only for backend adapters.
 *
 * WHY DIVERGENCE HERE IS PARTICULARLY QUIET:
 * These constants shape a PROMPT. A context window 40 characters per word on one
 * driver and 30 on another does not error, does not fail a test, and does not
 * look wrong in the output — it produces slightly worse predictions on one
 * platform, indefinitely. There is no user-visible symptom to trace back, which
 * is why the value has to be compared rather than trusted.
 *
 * The AutoHotkey side is generated: if it disagrees, the fix is to re-run the
 * generator, never to edit the emitted file.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

// Each source, with the shape its language declares constants in.
const SOURCES = [
	{
		label: 'shared Lua',
		file: path.join(SP, '_shared', 'lua', 'llm', 'prompt_builder.lua'),
		pattern: /^M\.([A-Z_]+)\s*=\s*([-\d.]+)\s*$/gm,
		fix: 'edit _shared/lua/llm/prompt_builder.lua'
	},
	{
		label: 'shared JS',
		file: path.join(SP, '_shared', 'core', 'domain', 'PromptBuilder.js'),
		pattern: /^const ([A-Z_]+)\s*=\s*([-\d.]+)\s*;/gm,
		fix: 'edit _shared/core/domain/PromptBuilder.js'
	},
	{
		label: 'generated AHK',
		file: path.join(SP, 'windows', '_generated', 'prompt_builder.ahk'),
		pattern: /^global PB_([A-Z_]+)\s*:=\s*([-\d.]+)\s*$/gm,
		fix: 're-run the generator (npm run gen) — never edit the emitted file'
	}
];

// Floor: ten today. A parse that stops matching would compare empty sets and
// report perfect agreement.
const MIN_CONSTANTS = 8;

const errors = [];
const parsed = new Map();

for (const src of SOURCES) {
	if (!fs.existsSync(src.file)) {
		errors.push(`${src.label}: ${path.relative(ROOT, src.file)} is missing`);
		continue;
	}
	const text = fs.readFileSync(src.file, 'utf8');
	const found = new Map();
	for (const m of text.matchAll(src.pattern)) {
		found.set(m[1], Number(m[2]));
	}
	if (found.size < MIN_CONSTANTS) {
		errors.push(
			`${src.label}: parsed only ${found.size} constant(s) (floor ${MIN_CONSTANTS}) — the ` +
				'declaration shape changed, and this guard would then compare almost nothing and pass'
		);
		continue;
	}
	parsed.set(src.label, found);
}

if (parsed.size === SOURCES.length) {
	// Every name declared anywhere, so a constant present in one language and
	// absent from another is reported rather than skipped.
	const names = new Set();
	for (const found of parsed.values()) for (const k of found.keys()) names.add(k);

	for (const name of [...names].sort()) {
		const readings = [...parsed].map(([label, found]) => [label, found.get(name)]);
		const missing = readings.filter(([, v]) => v === undefined).map(([l]) => l);
		if (missing.length > 0) {
			errors.push(
				`${name}: declared in ${readings.length - missing.length} of ${readings.length} language(s) ` +
					`— absent from ${missing.join(', ')}. A constant one driver lacks silently falls back to ` +
					'whatever that code does instead.'
			);
			continue;
		}
		const values = new Set(readings.map(([, v]) => v));
		if (values.size > 1) {
			errors.push(
				`${name} disagrees: ${readings.map(([l, v]) => `${l} = ${v}`).join(', ')}. These shape a ` +
					'prompt, so a mismatch does not error and does not look wrong — it just produces worse ' +
					'predictions on one platform, indefinitely. ' +
					SOURCES.map((s) => s.fix).join(' / ')
			);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] prompt-builder constant parity:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

const n = parsed.size > 0 ? [...parsed.values()][0].size : 0;
console.log(
	`\x1b[32m[OK] all ${n} prompt-builder constant(s) agree across ${parsed.size} language(s).\x1b[0m`
);
