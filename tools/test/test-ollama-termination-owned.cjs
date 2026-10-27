// tools/test/test-ollama-termination-owned.cjs

/**
 * ==============================================================================
 * MODULE: Ollama Termination Ownership Gate
 * DESCRIPTION:
 * No driver may stop Ollama by process name or by its port. Each driver stops
 * only the daemon it launched, through the exact handle it holds (macOS
 * api_ollama.stop_owned_server, Linux and Windows by the owned PID), so a stock
 * Ollama the user runs on their own is never killed.
 *
 * ROOT CAUSE ENCODED:
 * The macOS launch path ran `pkill -f '[o]llama serve'` before every start
 * (item 120, formerly 46/47/48). That killed any `ollama serve` on the Mac,
 * including one the user started outside Ergopti. a8d2b45196 replaced it with
 * the owned foreground daemon but added no guard, so the broad kill could come
 * back in any driver without a failing test.
 *
 * FEATURES & RATIONALE:
 * 1. Scope: every production source of the three drivers and the shared tree
 *    (Lua, shell, Python, AutoHotkey, PowerShell, Swift), tests excluded.
 * 2. Forms caught: pkill, killall and pgrep with an Ollama pattern (including
 *    the `[o]llama` self-match trick), taskkill /IM, Stop-Process -Name,
 *    ProcessClose on a name, and an lsof listener sweep on the default Ollama
 *    port read from _shared/modules/llm/defaults.json.
 * 3. Mutation control: the detector flags the historical macOS line and each
 *    other form, and accepts a PID kill, the MLX sweep and a comment.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const PRODUCT = path.join(ROOT, 'static', 'ergopti_plus');
const SCOPES = ['macos', 'linux', 'windows', '_shared'];
const EXTENSIONS = new Set(['.lua', '.sh', '.py', '.ahk', '.ps1', '.swift']);
const SKIPPED_DIRECTORIES = new Set(['tests', 'node_modules', '.git']);
const OLLAMA_PORT = JSON.parse(
	fs.readFileSync(path.join(PRODUCT, '_shared', 'modules', 'llm', 'defaults.json'), 'utf8')
).llm_ollama_port;
// `[o]llama` keeps pgrep/pkill from matching their own command line.
const NAME = String.raw`\[?o\]?llama`;
const FORMS = [
	new RegExp(String.raw`\b(?:pkill|killall|pgrep)\b.*${NAME}`, 'i'),
	new RegExp(String.raw`\btaskkill\b.*/IM\s+["']?${NAME}`, 'i'),
	new RegExp(String.raw`\bStop-Process\b.*-Name\s+["']?${NAME}`, 'i'),
	new RegExp(String.raw`\bProcessClose\(\s*["']${NAME}`, 'i'),
	new RegExp(String.raw`\blsof\b.*\b${OLLAMA_PORT}\b.*\bkill\b`, 'i')
];
const COMMENT = /^\s*(?:--|#|;|\/\/|\*)/;

/**
 * Lists the lines of a source that stop Ollama by name or by its port.
 * @param {string} text Source text.
 * @returns {number[]} One-based line numbers.
 */
function broadTerminations(text) {
	const hits = [];
	text.split('\n').forEach((line, index) => {
		if (COMMENT.test(line)) return;
		if (FORMS.some((form) => form.test(line))) hits.push(index + 1);
	});
	return hits;
}

/**
 * Collects the production sources under one directory.
 * @param {string} directory Absolute directory.
 * @param {string[]} files Accumulator.
 * @returns {string[]}
 */
function sources(directory, files = []) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		if (entry.isDirectory()) {
			if (!SKIPPED_DIRECTORIES.has(entry.name)) sources(path.join(directory, entry.name), files);
		} else if (EXTENSIONS.has(path.extname(entry.name))) {
			files.push(path.join(directory, entry.name));
		}
	}
	return files;
}

// ===== 1) Mutation control =====

assert.ok(Number.isInteger(OLLAMA_PORT), 'defaults.json must define llm_ollama_port');
for (const line of [
	// The macOS launch path before a8d2b45196.
	`\t\t\t"-c", "pkill -f '[o]llama serve' 2>/dev/null || true"`,
	'killall ollama',
	'pgrep -f "ollama serve" | xargs kill',
	'Run("taskkill.exe /IM ollama.exe /F", , "Hide")',
	'Stop-Process -Name ollama -Force',
	'ProcessClose("ollama.exe")',
	`/usr/sbin/lsof -nP -tiTCP:${OLLAMA_PORT} -sTCP:LISTEN | /usr/bin/xargs /bin/kill -9`
]) {
	assert.deepEqual(broadTerminations(line), [1], `the detector must flag: ${line}`);
}
for (const line of [
	'Run("taskkill.exe /PID " . Pid . " /T /F", , "Hide")',
	'start_detached_sweep("mlx-server-processes", PKILL_BIN, { "-9", "-f", "mlx_lm.*server" })',
	"-- The old path ran pkill -f '[o]llama serve' before each start.",
	'local ok, settled = pcall_log("owned Ollama retirement", ApiOllama.stop_owned_server)'
]) {
	assert.deepEqual(broadTerminations(line), [], `the detector must accept: ${line}`);
}

// ===== 2) Every production source =====

const files = SCOPES.flatMap((scope) => sources(path.join(PRODUCT, scope)));
const macosOwner = path.join(PRODUCT, 'macos', 'modules', 'llm', 'api_ollama.lua');
assert.ok(files.includes(macosOwner), 'the scan must cover the macOS Ollama owner');
const offenders = files.flatMap((file) =>
	broadTerminations(fs.readFileSync(file, 'utf8')).map(
		(line) => `${path.relative(ROOT, file).split(path.sep).join('/')}:${line}`
	)
);
assert.deepEqual(
	offenders,
	[],
	'Ollama is stopped only through the owned daemon handle or PID, never by name or port'
);
console.log(`ollama-termination-owned: OK (${files.length} sources, no broad termination)`);
