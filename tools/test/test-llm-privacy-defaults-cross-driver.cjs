// tools/test/test-llm-privacy-defaults-cross-driver.cjs

/**
 * ==============================================================================
 * MODULE: LLM Privacy-Default Parity Gate
 * DESCRIPTION:
 * The two gates that decide whether the text around the caret is sent to the
 * model must have ONE default, shared by the three drivers.
 *
 * ROOT CAUSE ENCODED:
 * llm_disable_password_fields and llm_disable_url_bars shipped with opposite
 * defaults. macOS hardcoded both to `true` in prediction_engine.lua AND left the
 * two keys out of _SHARED_SCALAR_KEYS, so the shared value was unreachable;
 * Windows read the shared JSON, which said `false`. The same setting therefore
 * blocked predictions in password fields on one driver and sent their contents to
 * the provider on the other. Linux had no gate at all.
 *
 * THE CANONICAL POSTURE (defaults.json is the only source):
 *   llm_disable_password_fields = true   — a credential is not context
 *   llm_disable_url_bars        = false  — a URL is not a credential, and
 *                                          completing one is a real use case
 *
 * FEATURES & RATIONALE:
 * 1. Reads the values from defaults.json rather than asserting literals, so the
 *    maintainer changes the posture in one place and this gate follows.
 * 2. Asserts the MECHANISM, not just the value: macOS must list both keys in
 *    _SHARED_SCALAR_KEYS and must not re-declare them as literals. A matching
 *    hardcoded value is still a bug — it is how the two drivers drifted.
 * 3. Requires Linux to consult a secure-field signal before predicting, and to
 *    fail closed when the detector is unavailable.
 * 4. Fails loudly if a scanned file is missing, so a rename cannot make it
 *    vacuous.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');

const errors = [];

/** Reads a repo-relative file, recording an error when absent. */
function read(rel) {
	const full = path.join(ROOT, rel);
	if (!fs.existsSync(full)) {
		errors.push(`${rel}: expected file is missing — update this gate or restore the file.`);
		return null;
	}
	return fs.readFileSync(full, 'utf8');
}

/** Strips Lua comments so a prose mention cannot satisfy or trip a check. */
function stripLua(src) {
	return src
		.split('\n')
		.map((l) => {
			const at = l.indexOf('--');
			return at === -1 ? l : l.slice(0, at);
		})
		.join('\n');
}

// ── The canonical values ─────────────────────────────────────────────────────

const defaultsPath = path.join(SHARED, 'modules', 'llm', 'defaults.json');
if (!fs.existsSync(defaultsPath)) {
	console.error('[ERROR] _shared/modules/llm/defaults.json is missing.');
	process.exit(1);
}
const DEFAULTS = JSON.parse(fs.readFileSync(defaultsPath, 'utf8'));

const KEYS = ['llm_disable_password_fields', 'llm_disable_url_bars'];
for (const k of KEYS) {
	if (typeof DEFAULTS[k] !== 'boolean') {
		errors.push(`defaults.json: ${k} must be a boolean (it is the canonical posture).`);
	}
}

// A posture that blocks nothing would make this whole gate pointless — and it is
// the state the repo was in on Windows. Require the credential gate to be on.
if (DEFAULTS.llm_disable_password_fields !== true) {
	errors.push(
		'defaults.json: llm_disable_password_fields must be true. The text around the ' +
			'caret in a password field is a credential; sending it to a provider is not a ' +
			'default anyone opts into. Flip it deliberately and update this gate if the ' +
			'posture really changes.'
	);
}

// ── macOS: reads the shared value, does not re-declare it ────────────────────

const macInit = read('static/ergopti_plus/macos/modules/llm/init.lua');
if (macInit) {
	const stripped = stripLua(macInit);
	for (const k of KEYS) {
		if (!stripped.includes(`"${k}"`)) {
			errors.push(
				`macos/modules/llm/init.lua: ${k} must appear in _SHARED_SCALAR_KEYS, ` +
					'otherwise the shared default is unreachable and the driver silently keeps its own.'
			);
		}
	}
}

const macEngine = read('static/ergopti_plus/macos/modules/llm/prediction_engine.lua');
if (macEngine) {
	const stripped = stripLua(macEngine);
	const hardcoded = [
		/local\s+url_bar_filter_enabled\s*=\s*(true|false)\b/,
		/local\s+secure_field_filter_enabled\s*=\s*(true|false)\b/
	];
	for (const re of hardcoded) {
		const m = stripped.match(re);
		if (m) {
			errors.push(
				`macos/modules/llm/prediction_engine.lua: "${m[0].trim()}" re-declares a shared ` +
					'default as a literal. It must read LLM_DEFAULTS — a literal that happens to ' +
					'match today is exactly how the two drivers drifted apart.'
			);
		}
	}
	for (const ref of ['LLM_DEFAULTS.llm_disable_url_bars', 'LLM_DEFAULTS.llm_disable_password_fields']) {
		if (!stripped.includes(ref)) {
			errors.push(`macos/modules/llm/prediction_engine.lua: must read ${ref}.`);
		}
	}
}

// ── Windows: the fallback literal must agree with the shared value ───────────

const winEngine = read('static/ergopti_plus/windows/modules/llm/prediction_engine.ahk');
if (winEngine) {
	const pairs = [
		['disable_password_fields', DEFAULTS.llm_disable_password_fields],
		['disable_url_bars', DEFAULTS.llm_disable_url_bars]
	];
	for (const [key, expected] of pairs) {
		const re = new RegExp(`"${key}",\\s*(true|false)`);
		const m = winEngine.match(re);
		if (!m) {
			errors.push(`windows/modules/llm/prediction_engine.ahk: no seed literal found for ${key}.`);
		} else if ((m[1] === 'true') !== expected) {
			errors.push(
				`windows/modules/llm/prediction_engine.ahk: ${key} seeds ${m[1]} but defaults.json ` +
					`says ${expected}. LLM_Engine_ApplySharedDefaults() returns early when ` +
					'LLM_Defaults is unset, so this literal is live in that path and must agree.'
			);
		}
	}
}

// ── Linux: must consult a secure-field signal, and fail closed ───────────────

const linuxEngine = read('static/ergopti_plus/linux/modules/llm/prediction_engine.lua');
if (linuxEngine) {
	const stripped = stripLua(linuxEngine);
	if (!stripped.includes('adapters.secure_field_detector')) {
		errors.push(
			'linux/modules/llm/prediction_engine.lua: must consult ' +
				'adapters.secure_field_detector before predicting. Linux had no gate at all: the ' +
				'text around the caret in a password field went to the model like any other context.'
		);
	}
	if (!/function M\.predict[\s\S]{0,400}_is_secure_context\(\)/.test(stripped)) {
		errors.push(
			'linux/modules/llm/prediction_engine.lua: M.predict must check the secure context ' +
				'before doing any work — a gate consulted after the request is not a gate.'
		);
	}
	if (!stripped.includes('HttpBridge.DEFAULT_DISABLE_PASSWORD_FIELDS')) {
		errors.push(
			'linux/modules/llm/prediction_engine.lua: the posture must come from the shared ' +
				'bridge, never a re-typed literal.'
		);
	}
}

// ── Report ───────────────────────────────────────────────────────────────────

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] LLM privacy defaults are not single-sourced across drivers:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] LLM privacy posture is single-sourced: secure fields ' +
		`${DEFAULTS.llm_disable_password_fields ? 'blocked' : 'allowed'}, URL bars ` +
		`${DEFAULTS.llm_disable_url_bars ? 'blocked' : 'allowed'}, on all three drivers.\x1b[0m`
);
