// tools/test/test-ollama-port-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Ollama Port Single-Source Guard
 * DESCRIPTION:
 * The default Ollama port lives in exactly ONE place —
 * _shared/modules/llm/defaults.json (llm_ollama_port). The AHK driver loads it
 * into LLM_Defaults (infra/llm_defaults.ahk) and sources every default from there:
 * api_ollama.ahk seeds LLM_OLLAMA_PORT at boot (LLM_Ollama_LoadDefaults), the
 * tray menu seeds _LLM_Menu["ollama_port"] (LLM_Menu_ApplySharedDefaults) and
 * reads the default via _LLM_DefaultFor("llm_ollama_port"). macOS reads the same
 * key from DEFAULT_STATE, so the cross-driver default cannot diverge.
 *
 * ROOT CAUSE ENCODED:
 * The port default 11434 was previously hardcoded in four AHK sites in parallel
 * with the JSON (a §5.2 violation with no gate). Unifying the value is not
 * enough — the moment a literal lives in one of these files it can drift again.
 * This guard fails if the literal port value appears (outside comments) in any
 * of the deferring files, or if one of them stops referencing llm_ollama_port
 * (which would mean the default resolution was silently deleted).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SSOT_FILE = path.join(ROOT, 'static/ergopti_plus/_shared/modules/llm/defaults.json');

// AHK files that must source the Ollama port default from LLM_Defaults, never
// from a local literal. api_ollama.ahk is a redirect shim; constants live in
// the init sub-file which is the authoritative gate for this invariant.
const FILES = [
	'static/ergopti_plus/windows/modules/llm/api_ollama/init.ahk',
	'static/ergopti_plus/windows/ui/menu/menu_llm/_index.ahk',
	'static/ergopti_plus/windows/ui/menu/menu_llm/menu_models.ahk',
	'static/ergopti_plus/windows/ui/menu/menu_llm/menu_settings.ahk'
];

const SHARED_KEY = 'llm_ollama_port';

// Strip AHK line comments (a ";" at line start or preceded by whitespace) so a
// documentation mention of the port in a comment is not flagged as a literal.
function stripComments(src) {
	return src
		.split(/\r?\n/)
		.map((line) => line.replace(/(^|\s);.*$/, '$1'))
		.join('\n');
}

function readSsotPort() {
	const json = JSON.parse(fs.readFileSync(SSOT_FILE, 'utf8'));
	return typeof json.llm_ollama_port === 'number' ? json.llm_ollama_port : null;
}

const ssot = readSsotPort();
if (ssot === null) {
	console.error('\x1b[31m[ERROR] Could not read llm_ollama_port from defaults.json.\x1b[0m');
	process.exit(1);
}
if (!Number.isInteger(ssot) || ssot < 1024 || ssot > 65535) {
	console.error(
		`\x1b[31m[ERROR] llm_ollama_port must be an integer in the documented 1024..65535 range; got ${String(ssot)}.\x1b[0m`
	);
	process.exit(1);
}

const literalRe = new RegExp(`\\b${ssot}\\b`);
const violations = [];
const missingRef = [];

for (const rel of FILES) {
	const abs = path.join(ROOT, rel);
	const src = fs.readFileSync(abs, 'utf8');
	if (!src.includes(SHARED_KEY)) missingRef.push(rel);
	const lines = stripComments(src).split('\n');
	for (let i = 0; i < lines.length; i++) {
		if (literalRe.test(lines[i])) {
			violations.push(`${rel}:${i + 1}  ${lines[i].trim()}`);
		}
	}
}

if (violations.length > 0 || missingRef.length > 0) {
	console.error(
		`\x1b[31m[ERROR] The Ollama port default must come from the single shared source (defaults.json llm_ollama_port = ${ssot}).\x1b[0m`
	);
	if (violations.length > 0) {
		console.error(`  Hardcoded ${ssot} literal found (route it through LLM_Defaults / _LLM_DefaultFor("${SHARED_KEY}")):`);
		for (const v of violations) console.error('    ' + v);
	}
	if (missingRef.length > 0) {
		console.error('  File no longer references llm_ollama_port (default resolution deleted?):');
		for (const f of missingRef) console.error('    ' + f);
	}
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No hardcoded Ollama port — all ${FILES.length} AHK files defer to defaults.json llm_ollama_port (${ssot}).\x1b[0m`
);
