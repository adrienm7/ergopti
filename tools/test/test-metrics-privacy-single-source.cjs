// tools/test/test-metrics-privacy-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Privacy Defaults — Single Source
 * DESCRIPTION:
 * The three keylogger privacy filters and the at-rest encryption opt-in are
 * declared once, in `_shared/modules/features/manifest.toml` under
 * `[[features.metrics]]`, and every driver resolves its default from there.
 *
 * THE ROOT CAUSE THIS FREEZES:
 * They used to exist THREE times. The manifest declared each twice — once
 * canonically (`private_filter_enabled`) and once again AHK-only under a
 * different id (`filter_private_browsing`) — and the AHK driver read neither,
 * hardcoding `static private_browsing := true` in the class body. So the shared
 * manifest could be edited, both copies of it, and the Windows driver would keep
 * whatever the class said.
 *
 * The third spelling made it worse than a duplicate: the driver PERSISTED
 * `metrics_filter_private_browsing`, which matched neither manifest id, so the
 * key it wrote at shutdown was not the key the config template offered and not
 * the key macOS reads.
 *
 * WHY THIS SETTING AND NOT A GENERIC DUPLICATE-ID GATE:
 * A duplicate feature id is caught by the generator (one address, one block).
 * What that cannot catch is the same CONCEPT under two ids, and this is the one
 * concept where getting it wrong means recording keystrokes the user asked not
 * to record. The list below is therefore written by hand, on purpose: it is a
 * second, independent statement of which ids are the real ones.
 *
 * FAIL-CLOSED, DELIBERATELY:
 * The three filters default ON and encryption defaults OFF. The gate asserts the
 * direction, not just the agreement — two drivers agreeing on "filtering off"
 * would satisfy a pure parity check and be exactly the wrong answer.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const P = (...parts) => path.join(ROOT, ...parts);

const MANIFEST = P('static', 'ergopti_plus', '_shared', 'modules', 'features', 'manifest.toml');
const AHK_FILTERS = P('static', 'ergopti_plus', 'windows', 'infra', 'metrics', 'metrics_filters.ahk');
const AHK_LOADER = P('static', 'ergopti_plus', 'windows', 'infra', 'config_shortcuts.ahk');
const AHK_WRITER = P('static', 'ergopti_plus', 'windows', 'infra', 'config_io.ahk');
const HS_KEYLOGGER = P('static', 'ergopti_plus', 'macos', 'modules', 'keylogger', 'init.lua');

// The canonical id of each setting, and the default it must resolve to.
const CANONICAL = [
	['private_filter_enabled', true],
	['secure_filter_enabled', true],
	['system_auth_filter_enabled', true],
	['encrypt', false]
];

// Ids that named the same four settings before they were merged. Any of these
// reappearing anywhere is the duplication coming back.
const RETIRED_IDS = [
	'filter_private_browsing',
	'metrics_filter_private_browsing',
	'metrics_filter_secure_field',
	'metrics_filter_system_auth',
	'metrics_encrypt'
];

const errors = [];

/** @returns {string} the file's contents, or '' when it does not exist. */
function read(file) {
	if (!fs.existsSync(file)) {
		errors.push(`missing file: ${path.relative(ROOT, file)}`);
		return '';
	}
	return fs.readFileSync(file, 'utf8');
}

const manifest = read(MANIFEST);
const ahkFilters = read(AHK_FILTERS);
const ahkLoader = read(AHK_LOADER);
const ahkWriter = read(AHK_WRITER);
const hsKeylogger = read(HS_KEYLOGGER);

// ==================================================
// ==================================================
// ======= 1/ The manifest declares each once =======
// ==================================================
// ==================================================

/**
 * Collect the `[[features.metrics]]` blocks as {id, default} pairs.
 * @param {string} src - manifest.toml contents.
 * @returns {Array<{id: string, default: string}>}
 */
function metricsFeatures(src) {
	const out = [];
	const blocks = src.split(/^\[\[features\.metrics\]\]\s*$/m).slice(1);
	for (const b of blocks) {
		// Stop at the next table header so a block never absorbs its successor.
		const body = b.split(/^\[/m)[0];
		const id = body.match(/^id\s*=\s*"([^"]+)"/m);
		const def = body.match(/^default\s*=\s*(.+)$/m);
		if (id) out.push({ id: id[1], default: def ? def[1].trim() : '' });
	}
	return out;
}

const features = metricsFeatures(manifest);

// Floor: a parse that stopped matching would find zero features and every
// "declared exactly once" assertion below would hold vacuously.
if (features.length < 10) {
	errors.push(
		`parsed only ${features.length} [[features.metrics]] block(s) — the manifest scan is broken, ` +
			'and every uniqueness assertion below would then pass having read nothing'
	);
}

for (const [id, expected] of CANONICAL) {
	const hits = features.filter((f) => f.id === id);
	if (hits.length === 0) {
		errors.push(`manifest declares no [[features.metrics]] with id "${id}"`);
		continue;
	}
	if (hits.length > 1) {
		errors.push(`manifest declares "${id}" ${hits.length} times — it must be declared once`);
	}
	const actual = hits[0].default;
	if (actual !== String(expected)) {
		errors.push(
			`metrics.${id} defaults to ${actual}, expected ${expected}. The three filters fail CLOSED ` +
				'(on) and encryption is an opt-in (off) — flipping either direction is a privacy change, ' +
				'not a config tweak'
		);
	}
}

for (const retired of RETIRED_IDS) {
	if (features.some((f) => f.id === retired)) {
		errors.push(
			`manifest re-declares the retired id "${retired}". These four settings had a second, ` +
				'driver-scoped declaration of the same concept; the drivers read neither and kept their ' +
				'own hardcoded copy. One concept, one id.'
		);
	}
}

// ==========================================================
// ==========================================================
// ======= 2/ The AHK driver resolves, not hardcodes =======
// ==========================================================
// ==========================================================

if (ahkFilters && !/MetricsFiltersApplyManifestDefaults\(\)\s*\{/.test(ahkFilters)) {
	errors.push(
		'metrics_filters.ahk no longer defines MetricsFiltersApplyManifestDefaults() — without it the ' +
			'class body literals become the effective defaults again, silently'
	);
}

if (ahkLoader && !/MetricsFiltersApplyManifestDefaults\(\)/.test(ahkLoader)) {
	errors.push(
		'CS_Load() does not call MetricsFiltersApplyManifestDefaults(). Defining it is not enough — ' +
			'the manifest defaults have to be applied BEFORE the user config, or the order that decides ' +
			'a privacy setting is whichever include ran first'
	);
}

for (const [id] of CANONICAL) {
	if (ahkLoader && !ahkLoader.includes(`"${id}"`)) {
		errors.push(`config_shortcuts.ahk does not read the canonical config key "${id}"`);
	}
	if (ahkWriter && !ahkWriter.includes(`"${id}"`)) {
		errors.push(
			`config_io.ahk does not persist "${id}". A driver that reads one key and writes another ` +
				'loses the setting on the next boot without failing anything'
		);
	}
}

for (const retired of RETIRED_IDS) {
	for (const [name, src] of [
		['config_shortcuts.ahk', ahkLoader],
		['config_io.ahk', ahkWriter]
	]) {
		if (src && src.includes(`"${retired}"`)) {
			errors.push(`${name} still addresses the retired config key "${retired}"`);
		}
	}
}

// ==================================================
// ==================================================
// ======= 3/ macOS reads the same four =============
// ==================================================
// ==================================================

// macOS names the encryption toggle differently in its own state, so only the
// three filters are asserted here — they are the ones that decide whether a
// keystroke is recorded at all.
for (const id of ['private_filter_enabled', 'secure_filter_enabled', 'system_auth_filter_enabled']) {
	if (hsKeylogger && !hsKeylogger.includes(`Manifest.default_for("metrics.${id}")`)) {
		errors.push(
			`macos/modules/keylogger/init.lua does not resolve metrics.${id} from the manifest — ` +
				'the two drivers are back to two independent privacy defaults'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] metrics privacy defaults are not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${CANONICAL.length} metrics privacy setting(s) declared once and resolved by both drivers ` +
		`(${features.length} [[features.metrics]] block(s) scanned).\x1b[0m`
);
