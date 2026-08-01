// tools/test/test-toml-coercion-parity.cjs
//
// Drift gate: TOML scalar coercion cross-driver parity.
// Asserts that:
//   1. The shared corpus coercion_vectors.json exists and has >= 12 vectors.
//   2. macOS test_corpus_toml_coercion.lua exists and opens the shared corpus.
//   3. AHK test_corpus_toml_coercion.ahk exists and opens the shared corpus.
//   4. macOS config_overrides.lua still exports M.coerce (not deleted/renamed).
//   5. AHK toml_config_loader.ahk still defines TomlCoerceValueExt (not deleted).
//   6. All 4 coercion sites still exist (no site removed without updating corpus).
//
// This gate does NOT run the coercion functions — it only prevents drift by
// asserting that the shared corpus and the test consumers still reference each
// other, and that the coercion functions still exist at their known locations.

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const MACOS = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const LINUX = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

let passed = 0;
let failed = 0;

function assert(condition, label) {
	if (condition) { passed++; }
	else { failed++; console.error(`  FAIL: ${label}`); }
}

// ─── 1. Corpus exists and is well-formed ──────────────────────────────
const corpusPath = path.join(SHARED, 'tests', 'corpus', 'toml', 'coercion_vectors.json');
const corpusExists = fs.existsSync(corpusPath);
assert(corpusExists, 'coercion_vectors.json exists');

let corpus;
if (corpusExists) {
	try { corpus = JSON.parse(fs.readFileSync(corpusPath, 'utf8')); }
	catch (e) { console.error(`  FAIL: corpus parse error: ${e.message}`); failed++; }
}

assert(corpus && Array.isArray(corpus.vectors), 'corpus has .vectors array');
assert(corpus && corpus.vectors && corpus.vectors.length >= 12, `corpus has >= 12 vectors (got ${corpus?.vectors?.length ?? 0})`);

// ─── 2. macOS corpus consumer test exists ────────────────────────────
const macosTestPath = path.join(MACOS, 'tests', 'unit', 'meta', 'test_corpus_toml_coercion.lua');
assert(fs.existsSync(macosTestPath), 'macOS corpus test exists');
if (fs.existsSync(macosTestPath)) {
	const src = fs.readFileSync(macosTestPath, 'utf8');
	assert(src.includes('coercion_vectors.json'), 'macOS test opens coercion_vectors.json');
	assert(src.includes('config_overrides'), 'macOS test references config_overrides module');
}

// ─── 3. AHK corpus consumer test exists ──────────────────────────────
const ahkTestPath = path.join(WINDOWS, 'tests', 'meta', 'test_corpus_toml_coercion.ahk');
assert(fs.existsSync(ahkTestPath), 'AHK corpus test exists');
if (fs.existsSync(ahkTestPath)) {
	const src = fs.readFileSync(ahkTestPath, 'utf8');
	assert(src.includes('coercion_vectors.json'), 'AHK test opens coercion_vectors.json');
	assert(src.includes('TomlCoerceValue'), 'AHK test references TomlCoerceValue function');
}

// ─── 4. All 4 coercion sites still exist ─────────────────────────────

// macOS: infra/config_overrides.lua exports M.coerce
const macosOverridePath = path.join(MACOS, 'infra', 'config_overrides.lua');
assert(fs.existsSync(macosOverridePath), 'macOS config_overrides.lua exists');
if (fs.existsSync(macosOverridePath)) {
	const src = fs.readFileSync(macosOverridePath, 'utf8');
	assert(src.includes('function M.coerce'), "macOS config_overrides.lua exports M.coerce");
	assert(src.includes('match_quoted_prefix'), "macOS config_overrides.lua has match_quoted_prefix helper");
}

// AHK: config_shortcuts.ahk defines CS_CoerceValue
const csPath = path.join(WINDOWS, 'infra', 'config_shortcuts.ahk');
assert(fs.existsSync(csPath), 'AHK config_shortcuts.ahk exists');
if (fs.existsSync(csPath)) {
	const src = fs.readFileSync(csPath, 'utf8');
	assert(src.includes('CS_CoerceValue('), "AHK config_shortcuts.ahk defines CS_CoerceValue");
}

// AHK: toml_loader.ahk defines TomlCoerceValue
const tlPath = path.join(WINDOWS, 'infra', 'toml', 'toml_loader.ahk');
assert(fs.existsSync(tlPath), 'AHK toml_loader.ahk exists');
if (fs.existsSync(tlPath)) {
	const src = fs.readFileSync(tlPath, 'utf8');
	assert(src.includes('TomlCoerceValue('), "AHK toml_loader.ahk defines TomlCoerceValue");
}

// AHK: toml_config_loader.ahk defines TomlCoerceValueExt
const tclPath = path.join(WINDOWS, 'infra', 'toml', 'toml_config_loader.ahk');
assert(fs.existsSync(tclPath), 'AHK toml_config_loader.ahk exists');
if (fs.existsSync(tclPath)) {
	const src = fs.readFileSync(tclPath, 'utf8');
	assert(src.includes('TomlCoerceValueExt('), "AHK toml_config_loader.ahk defines TomlCoerceValueExt");
	assert(src.includes('same algorithm as CS_CoerceValue'), "AHK comment admits same algorithm");
}

// ─── 5. Linux driver has no equivalent coercion bypass ───────────────
// The Linux driver uses toml_codec for all TOML parsing — there should
// be no hand-rolled coercion site in the Linux driver.
const linuxOverridePath = path.join(LINUX, 'infra', 'config_overrides.lua');
assert(!fs.existsSync(linuxOverridePath), 'Linux has no config_overrides.lua (uses toml_codec)');

// ─── Summary ─────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
