#!/usr/bin/env node
/**
 * The colour palette the hotstrings settings window offers must be identical on
 * macOS and Linux — same colours, same order, same labels.
 *
 * WHY THIS IS A GATE AND NOT A SHARED FILE.
 * Every other cross-driver default in this subsystem lives in
 * _shared/modules/hotstrings/defaults.toml, and this one cannot: the shared
 * hotstrings TOML reader (_shared/lua/toml_codec/reader.lua) parses scalar keys
 * inside sections and has no array support, so an ORDERED palette has no
 * spelling there. The three single colours (global_default, personal, neutral)
 * fit because each is one scalar.
 *
 * So the list is written twice, which is exactly what rule 5.2 forbids — unless
 * something holds the two copies equal. This is that something. A palette that
 * drifts is not a crash: the two drivers simply offer different colours for the
 * same categories, and a user who set "cyan" on one machine sees a hex the other
 * does not list.
 *
 * If the reader ever gains array support, delete this file and move the palette
 * into the shared TOML — that is strictly better than a gate.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const SP = path.join(__dirname, '..', '..', 'static', 'ergopti_plus');
const MACOS = path.join(SP, 'macos', 'ui', 'hotstrings_config_window', 'init.lua');
const LINUX = path.join(SP, 'linux', 'ui', 'hotstrings_config_window', 'bridge.lua');

// A palette that shrank to nothing would make both sides "equal" and this check
// vacuous, so the count is pinned too.
const EXPECTED_COUNT = 8;

const errors = [];

/**
 * Extracts the ordered (i18nKey, hex) pairs from a COLOR_PRESETS table.
 * @param {string} file Absolute path to the Lua file.
 * @returns {Array<{key: string, hex: string}>}
 */
function readPresets(file) {
	const source = fs.readFileSync(file, 'utf8');
	const block = source.match(/local COLOR_PRESETS = \{([\s\S]*?)\n\}/);
	if (!block) {
		errors.push(`${path.relative(process.cwd(), file)}: no "local COLOR_PRESETS = {" table found — this check cannot compare what it cannot read.`);
		return [];
	}
	// macOS spells the label as i18n.get("key"); Linux stores the key itself, so
	// both forms are accepted and only the KEY and the HEX are compared. The
	// resolved strings would differ by locale and prove nothing.
	const out = [];
	const row = /(?:i18n\.get\(\s*)?"(hs_config\.color_[a-z]+)"\s*\)?[^"]*?"(#[0-9a-fA-F]{6})"/g;
	let match;
	while ((match = row.exec(block[1])) !== null) {
		out.push({ key: match[1], hex: match[2].toLowerCase() });
	}
	return out;
}

const macos = readPresets(MACOS);
const linux = readPresets(LINUX);

for (const [name, list] of [['macOS', macos], ['Linux', linux]]) {
	if (list.length !== EXPECTED_COUNT) {
		errors.push(
			`${name} declares ${list.length} colour preset(s), expected ${EXPECTED_COUNT}. Either the ` +
				`palette changed on purpose — update EXPECTED_COUNT and the other driver — or the pattern ` +
				`stopped matching, which would make this check pass while comparing nothing.`
		);
	}
}

if (macos.length === linux.length) {
	for (let i = 0; i < macos.length; i += 1) {
		if (macos[i].key !== linux[i].key || macos[i].hex !== linux[i].hex) {
			errors.push(
				`preset ${i + 1} differs: macOS has ${macos[i].key} = ${macos[i].hex}, Linux has ` +
					`${linux[i].key} = ${linux[i].hex}. The settings window would offer different colours ` +
					`on the two drivers for the same categories.`
			);
		}
	}
} else if (macos.length > 0 && linux.length > 0) {
	errors.push(
		`macOS offers ${macos.length} preset(s) and Linux ${linux.length}; the palettes must match exactly.`
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] hotstring colour presets differ across drivers:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] hotstring colour presets — ${macos.length} preset(s), identical on macOS and Linux.\x1b[0m`
);
