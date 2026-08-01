// tools/test/test-linux-llm-defaults-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Linux LLM Defaults Single-Source Guard
 * DESCRIPTION:
 * The Linux driver's Ollama defaults must equal the cross-driver canonicals so it
 * predicts with the same settings as macOS/Windows. They live once:
 *   - port / temperature / context-length / keep-alive → _shared/modules/llm/defaults.json
 *   - max_tokens                                        → _shared/lua/llm/prompt_builder.lua
 *
 * ROOT CAUSE ENCODED:
 * Linux had silently diverged — temperature 0.3 (prediction_engine) and 0.7
 * (linux_bridge) vs the canonical 0.1; context 2000 vs 500; max_tokens 200 vs
 * 150; the Ollama port re-typed as 11434 in four places; keep_alive "30m" with no
 * canonical at all. This guard pins the shared bridge's mirrored constants to
 * defaults.json and forbids the old divergent literals from reappearing in the
 * Linux consumers (they must defer to linux_bridge / prompt_builder).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');
const DEFAULTS = JSON.parse(fs.readFileSync(path.join(SP, '_shared/modules/llm/defaults.json'), 'utf8'));

// Strip Lua line comments (`-- …` to EOL) so explanatory comments that mention a
// value (e.g. "was a divergent 0.3") are never mistaken for live code.
function stripLua(src) {
	return src
		.split(/\r?\n/)
		.map((line) => line.replace(/--.*$/, ''))
		.join('\n');
}

function read(rel) {
	return fs.readFileSync(path.join(SP, rel), 'utf8');
}

// Escape a value for embedding in a RegExp (numbers need the dot escaped).
function esc(v) {
	return String(v).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const errors = [];

// ── 1. linux_bridge mirrors must equal the canonical values ───────────────
const bridge = stripLua(read('_shared/lua/llm/linux_bridge.lua'));
const bridgeChecks = [
	['OLLAMA_DEFAULT_PORT', DEFAULTS.llm_ollama_port, 'defaults.json llm_ollama_port'],
	['DEFAULT_TEMPERATURE', DEFAULTS.llm_temperature, 'defaults.json llm_temperature'],
	['DEFAULT_KEEP_ALIVE', `"${DEFAULTS.llm_ollama_keep_alive}"`, 'defaults.json llm_ollama_keep_alive'],
	['DEFAULT_CONTEXT_LENGTH', DEFAULTS.llm_context_length, 'defaults.json llm_context_length'],
	// Privacy posture. Pinned here because the same two keys previously shipped
	// with opposite values on Windows and macOS: macOS hardcoded true while the
	// shared JSON said false and Windows read the JSON.
	[
		'DEFAULT_DISABLE_PASSWORD_FIELDS',
		DEFAULTS.llm_disable_password_fields,
		'defaults.json llm_disable_password_fields'
	],
	[
		'DEFAULT_DISABLE_URL_BARS',
		DEFAULTS.llm_disable_url_bars,
		'defaults.json llm_disable_url_bars'
	]
];
for (const [name, value, source] of bridgeChecks) {
	const re = new RegExp(`M\\.${name}\\s*=\\s*${esc(value)}(?!\\d)`);
	if (!re.test(bridge)) {
		errors.push(`linux_bridge.lua: M.${name} must mirror ${source} (${value})`);
	}
}

// P0-C: the Lua-side canonicals (tail words, max_tokens) live in prompt_builder,
// which linux_bridge already requires — it must read them, never re-type them.
for (const ref of ['PromptBuilder.CONTEXT_TAIL_WORDS', 'PromptBuilder.DEFAULT_MAX_TOKENS']) {
	if (!bridge.includes(ref)) {
		errors.push(`linux_bridge.lua: must read ${ref} from prompt_builder, not a re-typed literal`);
	}
}
if (/M\.CONTEXT_TAIL_WORDS\s*=\s*\d/.test(bridge)) {
	errors.push('linux_bridge.lua: CONTEXT_TAIL_WORDS re-typed as a literal — read PromptBuilder.CONTEXT_TAIL_WORDS');
}

// ── 2. prediction_engine must not re-type the old divergent literals ──────
const pred = stripLua(read('linux/modules/llm/prediction_engine.lua'));
const predForbidden = [
	[/temperature\s*=\s*0\.3\b/, 'temperature 0.3 (use HttpBridge.DEFAULT_TEMPERATURE)'],
	[/max_tokens\s*=\s*200\b/, 'max_tokens 200 (use PromptBuilder.DEFAULT_MAX_TOKENS)'],
	[/_max_context_chars\s*=\s*2000\b/, 'context 2000 (use HttpBridge.DEFAULT_CONTEXT_LENGTH)'],
	[/localhost:11434/, 'localhost:11434 (use HttpBridge.resolve_base_url)'],
	[/port\s*=\s*11434\b/, 'port 11434 (use HttpBridge.OLLAMA_DEFAULT_PORT)']
];
for (const [re, desc] of predForbidden) {
	if (re.test(pred)) errors.push(`prediction_engine.lua: forbidden divergent literal — ${desc}`);
}
for (const ref of ['HttpBridge', 'PromptBuilder']) {
	if (!pred.includes(ref)) errors.push(`prediction_engine.lua: must reference ${ref} (defer to shared canonicals)`);
}

// ── 3. model_browser_bridge must not re-type localhost:11434 ─────────────
const modelBrowser = stripLua(read('linux/ui/model_browser/bridge.lua'));
if (!modelBrowser.includes('HttpBridge.OLLAMA_DEFAULT_HOST') || !modelBrowser.includes('HttpBridge.OLLAMA_DEFAULT_PORT')) {
	errors.push('model_browser_bridge.lua: must resolve Ollama URL via HttpBridge.OLLAMA_DEFAULT_HOST / OLLAMA_DEFAULT_PORT');
}
if (/localhost:11434/.test(modelBrowser)) {
	errors.push('model_browser_bridge.lua: forbidden hardcoded URL — use HttpBridge constants');
}

// ── 4. profiles must resolve port/host from the shared bridge ─────────────
const profiles = stripLua(read('linux/modules/llm/profiles.lua'));
for (const ref of ['HttpBridge.OLLAMA_DEFAULT_PORT', 'HttpBridge.OLLAMA_DEFAULT_HOST']) {
	if (!profiles.includes(ref)) errors.push(`profiles.lua: must resolve endpoint via ${ref}`);
}

// ── 4. macOS Ollama backend must read keep_alive from the shared default ──
const macOllama = stripLua(read('macos/modules/llm/api_ollama.lua'));
if (/keep_alive\s*=\s*"30m"/.test(macOllama)) {
	errors.push('macos/modules/llm/api_ollama.lua: keep_alive "30m" literal — use ApiCommon.OLLAMA_KEEP_ALIVE');
}
if (!macOllama.includes('ApiCommon.OLLAMA_KEEP_ALIVE')) {
	errors.push('macos/modules/llm/api_ollama.lua: must read keep_alive from ApiCommon.OLLAMA_KEEP_ALIVE');
}

// ── 5. Linux Ollama request timeout must come from the timings registry
// Scanned RAW (not comment-stripped): the literal lives in a shell string and
// Lua's "--" comment marker would otherwise clip the max-time token.
const linuxOllamaRaw = read('linux/modules/llm/api_ollama.lua');
if (/--max-time 30\b/.test(linuxOllamaRaw)) {
	errors.push('linux/modules/llm/api_ollama.lua: magic curl timeout literal — use Timings.sec("llm", "request_timeout_ms")');
}
if (!linuxOllamaRaw.includes('Timings.sec("llm", "request_timeout_ms")')) {
	errors.push('linux/modules/llm/api_ollama.lua: must read the LLM request timeout from Timings.sec("llm", "request_timeout_ms")');
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Linux LLM defaults are not single-sourced from the shared canonicals:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Linux LLM defaults single-sourced — linux_bridge mirrors defaults.json (port ${DEFAULTS.llm_ollama_port}, ` +
		`temp ${DEFAULTS.llm_temperature}, ctx ${DEFAULTS.llm_context_length}, keep_alive ${DEFAULTS.llm_ollama_keep_alive}); ` +
		`no divergent literals in prediction_engine/profiles; macOS keep_alive routed.\x1b[0m`
);
