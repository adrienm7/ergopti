// tools/test/test-driver-scoped-features-stay-scoped.cjs

/**
 * ==============================================================================
 * MODULE: Driver-Scoped Features Stay Scoped
 * DESCRIPTION:
 * A handful of features are implemented by exactly one driver. This pins which,
 * by name, and asserts each one reaches that driver's generated config template
 * and no other's.
 *
 * THE ROOT CAUSE THIS FREEZES:
 * A feature that omits `platforms` inherits it from its nearest ancestor
 * section. While the manifest had driver silos, five expansion-preview keys sat
 * under [sections.hs.hotstrings] and inherited ["hs"] without ever saying so.
 * Lot 4 moved them to [sections.hotstrings] — platforms ["ahk", "hs", "linux"] —
 * and four were pinned on the way while `preview_star_enabled` was not. It
 * silently became a Windows and Linux feature: their config templates started
 * offering a setting neither driver implements.
 *
 * WHY A HARD-CODED LIST AND NOT A MANIFEST QUERY:
 * Reading the expected scope out of the manifest and then checking the templates
 * against it only proves the generator filters correctly, which it did. The
 * defect was in the manifest, so the assertion has to come from somewhere else.
 * This list is that somewhere else — a second, independent statement of which
 * driver owns each feature, which disagrees loudly when one of them drifts.
 *
 * If a driver genuinely gains one of these, move it here in the same commit that
 * changes the manifest. That is the point: the change becomes deliberate.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

const TEMPLATES = {
	ahk: 'static/ergopti_plus/windows/_generated/config_template.toml',
	hs: 'static/ergopti_plus/macos/_generated/config_template.toml',
	linux: 'static/ergopti_plus/linux/_generated/config_template.toml'
};

// Each entry: the config key, and the ONLY driver that implements it.
const SINGLE_DRIVER_KEYS = [
	// The expansion preview is a Hammerspoon tooltip; no other driver draws one.
	['hotstrings.expansion_delay', 'hs'],
	['hotstrings.preview_ai_enabled', 'hs'],
	['hotstrings.preview_autocorrect_enabled', 'hs'],
	['hotstrings.preview_colored_tooltips', 'hs'],
	['hotstrings.preview_star_enabled', 'hs'],
	// The Windows layout is installed by the AHK driver's own remapper.
	['layout.ergopti_base', 'ahk'],
	['layout.direct_access_digits', 'ahk'],
	['layout.ergopti_alt_gr', 'ahk'],
	['layout.ergopti_plus', 'ahk'],
	// Per-category master switches exist only in the AHK tray menu.
	['category_enabled.hotstrings', 'ahk'],
	['category_enabled.layout', 'ahk'],
	['category_enabled.shortcuts', 'ahk'],
	['category_enabled.tap_holds', 'ahk']
];

const errors = [];
const templates = {};

for (const [driver, rel] of Object.entries(TEMPLATES)) {
	const abs = path.join(ROOT, rel);
	if (!fs.existsSync(abs)) {
		console.error(`\x1b[31m[ERROR] missing generated template: ${rel}\x1b[0m`);
		process.exit(1);
	}
	templates[driver] = fs.readFileSync(abs, 'utf8');
}

/**
 * Reports whether a dotted config key is present in a rendered TOML template.
 * @param {string} src - The template's contents.
 * @param {string} dotted - Config key such as "hotstrings.preview_star_enabled".
 * @returns {boolean}
 */
function templateHasKey(src, dotted) {
	const parts = dotted.split('.');
	const leaf = parts.pop();
	const section = parts.join('.');
	const lines = src.split(/\r?\n/);
	let current = null;
	for (const raw of lines) {
		const line = raw.trim();
		const header = line.match(/^\[([A-Za-z0-9_.]+)\]$/);
		if (header) {
			current = header[1];
			continue;
		}
		if (current !== section) continue;
		if (new RegExp(`^${leaf}\\s*=`).test(line)) return true;
	}
	return false;
}

// A template that stopped rendering keys entirely would make every "absent"
// assertion below pass while proving nothing.
for (const [driver, src] of Object.entries(templates)) {
	const keyCount = (src.match(/^[a-z_]+\s*=/gm) || []).length;
	if (keyCount < 20) {
		errors.push(
			`${driver} template renders only ${keyCount} key(s) — too few to trust the absence checks below`
		);
	}
}

for (const [key, owner] of SINGLE_DRIVER_KEYS) {
	if (!Object.prototype.hasOwnProperty.call(TEMPLATES, owner)) {
		errors.push(`${key}: unknown owning driver "${owner}"`);
		continue;
	}
	if (!templateHasKey(templates[owner], key)) {
		errors.push(
			`${key} is declared ${owner}-only but is ABSENT from the ${owner} template — ` +
				'either the feature was removed, or its platforms list no longer includes its own driver'
		);
	}
	for (const driver of Object.keys(TEMPLATES)) {
		if (driver === owner) continue;
		if (templateHasKey(templates[driver], key)) {
			errors.push(
				`${key} is ${owner}-only but the ${driver} template offers it. A feature that omits ` +
					'"platforms" inherits it from its section, so moving it between sections silently ' +
					'changes which drivers get it. Pin platforms on the feature, or update this list if ' +
					`${driver} genuinely implements it now.`
			);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] driver-scoped features leaked across drivers:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${SINGLE_DRIVER_KEYS.length} single-driver feature(s) reach only their own driver.\x1b[0m`
);
