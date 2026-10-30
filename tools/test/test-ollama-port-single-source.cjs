// tools/test/test-ollama-port-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Ollama Port Single-Source Guard
 * DESCRIPTION:
 * The default Ollama port lives in exactly ONE place —
 * _shared/modules/llm/defaults.json. Ergopti's own Ollama reads
 * llm_ollama_owned_port on Windows, macOS and Linux, and the stock llm_ollama_port
 * names only the port a user's own Ollama keeps. Linux mirrors both in
 * infra/llm_bridge.lua, pinned by test-linux-llm-defaults-single-source.cjs. The AHK driver loads it
 * into LLM_Defaults (infra/llm_defaults.ahk) and sources every default from there:
 * api_ollama.ahk seeds LLM_OLLAMA_PORT at boot (LLM_Ollama_LoadDefaults), the
 * tray menu seeds _LLM_Menu["ollama_port"] (LLM_Menu_ApplySharedDefaults) and
 * reads the default via _LLM_DefaultFor("llm_ollama_owned_port"). macOS reads the same
 * key from DEFAULT_STATE, so the cross-driver default cannot diverge.
 *
 * ROOT CAUSE ENCODED:
 * The port default 11434 was previously hardcoded in four AHK sites in parallel
 * with the JSON (a §5.2 violation with no gate). Unifying the value is not
 * enough — the moment a literal lives in one of these files it can drift again.
 * This guard fails if the literal port value appears (outside comments) in any
 * of the deferring files, or if one of them stops referencing llm_ollama_port
 * (which would mean the default resolution was silently deleted).
 *
 * The Ollama install script (install/ollama_install.sh) probed and announced a
 * typed 11434 too; it now reads the port from the same defaults.json and is held
 * to the same rule. It stays on the stock key: it is the legacy system installer,
 * which no driver calls. Its PowerShell
 * twin installed a system Ollama and is gone: its absence is checked here.
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
const OWNED_KEY = 'llm_ollama_owned_port';
const STOCK_KEY = 'llm_ollama_port';
const FILES = [
	['static/ergopti_plus/windows/modules/llm/api_ollama/init.ahk', OWNED_KEY],
	['static/ergopti_plus/windows/ui/menu/menu_llm/_index.ahk', OWNED_KEY],
	// The Ollama port tool moved from the tray's model list to the selector page.
	['static/ergopti_plus/windows/ui/model_browser/init.ahk', OWNED_KEY],
	['static/ergopti_plus/windows/ui/menu/menu_llm/menu_settings.ahk', OWNED_KEY],
	['static/ergopti_plus/_shared/modules/llm/install/ollama_install.sh', STOCK_KEY]
];

const RETIRED_SYSTEM_INSTALLER =
	'static/ergopti_plus/_shared/modules/llm/install/ollama_install.ps1';

// Line-comment marker per language: AHK uses ";", shell and PowerShell "#".
const COMMENT_MARKERS = { '.ahk': ';', '.sh': '#', '.ps1': '#' };

// Strip line comments (the marker at line start or preceded by whitespace) so a
// documentation mention of the port in a comment is not flagged as a literal.
function stripComments(src, rel) {
	const marker = COMMENT_MARKERS[path.extname(rel)];
	if (!marker) throw new Error(`${rel}: no comment marker known for this file type`);
	const comment = new RegExp(`(^|\\s)${marker}.*$`);
	return src
		.split(/\r?\n/)
		.map((line) => line.replace(comment, '$1'))
		.join('\n');
}

const SSOT = JSON.parse(fs.readFileSync(SSOT_FILE, 'utf8'));
const ssot = typeof SSOT.llm_ollama_port === 'number' ? SSOT.llm_ollama_port : null;
const ownedSsot = SSOT.llm_ollama_owned_port;
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

if (!Number.isInteger(ownedSsot) || ownedSsot < 1024 || ownedSsot > 65535 || ownedSsot === ssot) {
	console.error(
		`\x1b[31m[ERROR] llm_ollama_owned_port must be a valid port other than the stock ${ssot}; got ${String(ownedSsot)}.\x1b[0m`
	);
	process.exit(1);
}
if (fs.existsSync(path.join(ROOT, RETIRED_SYSTEM_INSTALLER))) {
	console.error(
		`\x1b[31m[ERROR] ${RETIRED_SYSTEM_INSTALLER} would install a system Ollama; Ergopti owns its own.\x1b[0m`
	);
	process.exit(1);
}

const literalRe = new RegExp(`\\b(?:${ssot}|${ownedSsot})\\b`);
const violations = [];
const missingRef = [];

for (const [rel, sharedKey] of FILES) {
	const abs = path.join(ROOT, rel);
	const src = fs.readFileSync(abs, 'utf8');
	if (!src.includes(sharedKey)) missingRef.push(`${rel} (${sharedKey})`);
	const lines = stripComments(src, rel).split('\n');
	for (let i = 0; i < lines.length; i++) {
		if (literalRe.test(lines[i])) {
			violations.push(`${rel}:${i + 1}  ${lines[i].trim()}`);
		}
	}
}

if (violations.length > 0 || missingRef.length > 0) {
	console.error(
		`\x1b[31m[ERROR] The Ollama port default must come from the single shared source (defaults.json llm_ollama_port = ${ssot}, llm_ollama_owned_port = ${ownedSsot}).\x1b[0m`
	);
	if (violations.length > 0) {
		console.error(
			'  Hardcoded port literal found (route it through LLM_Defaults / _LLM_DefaultFor):'
		);
		for (const v of violations) console.error('    ' + v);
	}
	if (missingRef.length > 0) {
		console.error('  File no longer references its shared port key (default resolution deleted?):');
		for (const f of missingRef) console.error('    ' + f);
	}
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No hardcoded Ollama port — all ${FILES.length} AHK and install-script files defer to defaults.json (stock ${ssot}, owned ${ownedSsot}).\x1b[0m`
);
