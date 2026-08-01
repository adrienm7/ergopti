// tools/test/test-llm-model-single-source.cjs

/**
 * ==============================================================================
 * MODULE: AHK Default-Literal Single-Source Guard (LLM model + GPT link)
 * DESCRIPTION:
 * Two AHK-local default literals must each live in exactly ONE production place:
 *   1. The local LLM model name lives only in infra/llm_defaults.ahk
 *      (_LLM_LOCAL_DEFAULTS["llm_model"]). models.ahk and menu_llm/actions.ahk
 *      previously re-typed the same "Qwen3.5-0.8B" string as a fallback (a §5.2
 *      violation); they now read the canonical map.
 *   2. The GPT shortcut link is sourced from the manifest-backed Features map
 *      (shortcuts.gpt.link); gestures/init.ahk previously re-typed the URL as a
 *      hardcoded fallback (a §5.4 violation). That literal is now gone.
 *
 * ROOT CAUSE ENCODED:
 * Unifying the value is not enough — the moment a literal reappears in a second
 * production file it can drift again silently (no runtime gate catches it). This
 * guard fails if the model literal appears outside infra/llm_defaults.ahk, or if
 * the GPT URL literal reappears in gestures/init.ahk. Mirrors the proven
 * test-ollama-port-single-source.cjs pattern. Comments are stripped so a
 * documentation mention is not flagged.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

// The model literal must live ONLY here (its single canonical AHK source).
const MODEL_SSOT = 'infra/llm_defaults.ahk';
const MODEL_LITERAL = 'Qwen3.5-0.8B';
// The GPT link literal must not be re-typed in the gesture action (it reads the
// manifest-backed Features map instead).
const GPT_FILE = 'modules/gestures/init.ahk';
const GPT_LITERAL = 'chatgpt.com';

// Strip AHK line comments (";" at line start or after whitespace) so a mention
// of the literal in a comment is not counted as a re-typed value.
function stripComments(src) {
	return src
		.split(/\r?\n/)
		.map((line) => line.replace(/(^|\s);.*$/, '$1'))
		.join('\n');
}

// Recursively collect production .ahk files (exclude tests/_generated/vendor).
function collectAhk(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (/^(tests|_generated|vendor)$/.test(entry.name)) continue;
			collectAhk(full, acc);
		} else if (entry.isFile() && entry.name.endsWith('.ahk')) {
			acc.push(full);
		}
	}
	return acc;
}

const errors = [];

// 1. Model literal appears in exactly one production file (the SSoT).
const modelHits = [];
for (const abs of collectAhk(WIN, [])) {
	if (stripComments(fs.readFileSync(abs, 'utf8')).includes(MODEL_LITERAL)) {
		modelHits.push(path.relative(WIN, abs).replace(/\\/g, '/'));
	}
}
if (!(modelHits.length === 1 && modelHits[0] === MODEL_SSOT)) {
	errors.push(
		`The LLM model literal "${MODEL_LITERAL}" must appear in exactly one production file ` +
		`(${MODEL_SSOT}); found in: ${modelHits.join(', ') || '(none — SSoT deleted?)'}. ` +
		`Route fallbacks through _LLM_LOCAL_DEFAULTS["llm_model"].`
	);
}

// 2. GPT link literal must not be re-typed in the gesture action.
const gptSrc = stripComments(fs.readFileSync(path.join(WIN, GPT_FILE), 'utf8'));
if (gptSrc.includes(GPT_LITERAL)) {
	errors.push(
		`The GPT link literal "${GPT_LITERAL}" must not be hardcoded in ${GPT_FILE}; ` +
		`read it from the manifest-backed Features["shortcuts"]["gpt"]["link"].`
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] AHK default-literal single-source violated:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] LLM model literal single-sourced in ${MODEL_SSOT}; no GPT link literal in ${GPT_FILE}.\x1b[0m`
);
