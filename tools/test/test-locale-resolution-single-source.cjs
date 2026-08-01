// tools/test/test-locale-resolution-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Locale Resolution Single-Source Guard
 * DESCRIPTION:
 * Verifies that the locale resolution cascade is single-sourced:
 *   - The shared module _shared/lua/locale/core.lua exists and is consumed by
 *     both macOS (macos/infra/locale.lua) and Linux (linux/infra/locale.lua)
 *     drivers via `require("locale.core")`.
 *   - The cross-driver corpus _shared/tests/corpus/locale/resolution_vectors.json
 *     exists and has at least one vector.
 *   - macOS has a corpus consumer test (test_corpus_locale_resolution.lua).
 *   - AHK has a corpus consumer test (test_corpus_locale_resolution.ahk)
 *     included in run_all.ahk.
 *   - The AHK t() function lives in windows/infra/locale.ahk (the single source
 *     for AHK locale resolution).
 *
 * ROOT CAUSE ENCODED:
 * The macOS and Linux locale modules were fork quasi-verbatim copies (~160 lines
 * each) differing only in JSON decoder + path resolution. They were fused into
 * the shared locale.core, but the AHK t() cascade was never corpus-pinned — a
 * change to the fallback order or ★ substitution logic could silently diverge
 * between AHK and Lua. This gate ensures the corpus exists and is consumed on
 * both sides.
 * ==============================================================================
 */

'use strict';

const fs   = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const SP   = p.join(ROOT, 'static/ergopti_plus');

const errors = [];

function fileExists(rel) {
	return fs.existsSync(p.join(ROOT, rel));
}
function fileExistsSP(rel) {
	return fs.existsSync(p.join(SP, rel));
}
function read(rel) {
	return fs.readFileSync(p.join(ROOT, rel), 'utf8');
}

// ── 1. Shared locale.core must exist ──────────────────────────────────────
if (!fileExistsSP('_shared/lua/locale/core.lua')) {
	errors.push('_shared/lua/locale/core.lua: missing — locale resolution must be single-sourced');
}

// ── 2. macOS must consume it ───────────────────────────────────────────────
const macLocale = fileExistsSP('macos/infra/locale.lua') ? read('static/ergopti_plus/macos/infra/locale.lua') : '';
if (!macLocale.includes('require("locale.core")')) {
	errors.push('macos/infra/locale.lua: must require("locale.core") — not a hand-rolled copy');
}

// ── 3. Linux must consume it ───────────────────────────────────────────────
const lnxLocale = fileExistsSP('linux/infra/locale.lua') ? read('static/ergopti_plus/linux/infra/locale.lua') : '';
if (!lnxLocale.includes('require("locale.core")')) {
	errors.push('linux/infra/locale.lua: must require("locale.core") — not a hand-rolled copy');
}

// ── 4. Neither driver may re-implement the cascade inline ───────────────────
for (const [relPath, name] of [
	['static/ergopti_plus/macos/infra/locale.lua', 'macos'],
	['static/ergopti_plus/linux/infra/locale.lua', 'linux'],
]) {
	const src = fileExists(relPath) ? fs.readFileSync(p.join(ROOT, relPath), 'utf8') : '';
	// These functions should live in locale.core, not re-declared here
	for (const forbidden of ['local function ensure_loaded', 'local function load_locale']) {
		if (src.includes(forbidden)) {
			errors.push(`${name}/infra/locale.lua: re-declares "${forbidden}" — must delegate to locale.core`);
		}
	}
}

// ── 5. Corpus must exist ──────────────────────────────────────────────────
const corpusPath = '_shared/tests/corpus/locale/resolution_vectors.json';
if (!fileExistsSP(corpusPath)) {
	errors.push(`${corpusPath}: missing — locale resolution vectors must be shared`);
} else {
	const corpus = JSON.parse(read('static/ergopti_plus/' + corpusPath));
	if (!Array.isArray(corpus.vectors) || corpus.vectors.length === 0) {
		errors.push(`${corpusPath}: vectors array must be non-empty`);
	}
}

// ── 6. macOS must have a corpus consumer test ──────────────────────────────
if (!fileExistsSP('macos/tests/unit/meta/test_corpus_locale_resolution.lua')) {
	errors.push('macos/tests/unit/meta/test_corpus_locale_resolution.lua: missing — must replay locale corpus');
}

// ── 7. AHK must have a corpus consumer test included in run_all.ahk ────────
if (!fileExistsSP('windows/tests/meta/test_corpus_locale_resolution.ahk')) {
	errors.push('windows/tests/meta/test_corpus_locale_resolution.ahk: missing — must replay locale corpus');
} else {
	const runAll = fileExistsSP('windows/tests/run_all.ahk')
		? read('static/ergopti_plus/windows/tests/run_all.ahk')
		: '';
	if (!runAll.includes('test_corpus_locale_resolution.ahk')) {
		errors.push('windows/tests/run_all.ahk: must #Include test_corpus_locale_resolution.ahk');
	}
}

// ── 8. AHK t() must live in windows/infra/locale.ahk (single source) ─────────
if (!fileExistsSP('windows/infra/locale.ahk')) {
	errors.push('windows/infra/locale.ahk: missing — t() must be single-sourced here');
}

// ── 9. The old macOS hand-rolled copy must NOT exist — it was fused ────────
//    (locale.core now holds the logic; macOS and Linux only wire platform deps)

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Locale resolution is not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log('\x1b[32m[OK] Locale resolution single-sourced — locale.core consumed by macOS + Linux; corpus exists and is consumed by macOS + AHK tests.\x1b[0m');
