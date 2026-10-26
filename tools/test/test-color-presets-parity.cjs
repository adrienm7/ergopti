#!/usr/bin/env node
/**
 * The hotstrings settings window's colour palette has one source,
 * _shared/data/native_theme.toml, and this gate keeps every driver on it.
 *
 * macOS and Linux read the palette from the module generated out of that TOML
 * (_shared/lua/native_theme_data.lua), so they cannot drift and are checked
 * only for not typing a palette again. The Windows driver still types its own
 * list in hcw_helpers.ahk (a superset: pink, indigo, turquoise, lime and brown
 * exist only there), so that copy is the one this gate still compares: every
 * shared colour must appear in it under the same locale key with the same hex.
 *
 * Retire the AHK comparison when the Windows driver consumes a generated
 * palette too (it needs an AHK emitter in codegen-native-theme.cjs).
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const SP = path.join(__dirname, '..', '..', 'static', 'ergopti_plus');
const THEME = path.join(SP, '_shared', 'data', 'native_theme.toml');
const GENERATED = path.join(SP, '_shared', 'lua', 'native_theme_data.lua');
const MACOS = path.join(SP, 'macos', 'ui', 'hotstrings_config_window', 'init.lua');
const LINUX = path.join(SP, 'linux', 'ui', 'hotstrings_config_window', 'bridge.lua');
const WINDOWS = path.join(SP, 'windows', 'ui', 'hotstrings_config_window', 'hcw_helpers.ahk');

const HEX_LITERAL = /#[0-9a-fA-F]{6}\b/;
const errors = [];
const rel = (file) => path.relative(process.cwd(), file);

const palette = toml.parse(fs.readFileSync(THEME, 'utf8')).hotstring_palette;
// A palette that shrank to nothing would make every comparison vacuous.
if (!Array.isArray(palette) || palette.length < 8) {
	errors.push(
		`${rel(THEME)}: the palette lists ${palette && palette.length} colour(s), expected at least 8.`
	);
}

// 1. The Lua drivers consume the generated module and type no colour.
for (const file of [MACOS, LINUX]) {
	const source = fs.readFileSync(file, 'utf8');
	if (!source.includes('require("native_theme_data")')) {
		errors.push(`${rel(file)}: does not read the palette from native_theme_data.`);
	}
	if (/COLOR_PRESETS\s*=\s*\{\s*\n\s*\{/.test(source) || /color_[a-z]+"\s*,\s*hex/.test(source)) {
		errors.push(`${rel(file)}: types a colour palette again instead of using native_theme_data.`);
	}
}
// 2. The generated module carries every colour of the TOML, in order.
const generated = fs.readFileSync(GENERATED, 'utf8');
const generatedRows = [...generated.matchAll(/i18n = "([^"]+)", hex = "(#[0-9a-f]{6})"/g)].map(
	(m) => [m[1], m[2]]
);
const expectedRows = (palette || []).map((row) => [row.i18n, row.hex]);
if (JSON.stringify(generatedRows) !== JSON.stringify(expectedRows)) {
	errors.push(`${rel(GENERATED)}: stale against native_theme.toml; run npm run gen.`);
}

// 3. The Windows copy still contains every shared colour.
const ahk = fs.readFileSync(WINDOWS, 'utf8');
for (const row of palette || []) {
	const line = new RegExp(`t\\("${row.i18n}"\\)\\s*,\\s*"Hex",\\s*"(#[0-9a-fA-F]{6})"`).exec(ahk);
	if (!line) {
		errors.push(`${rel(WINDOWS)}: has no preset for ${row.i18n}.`);
	} else if (line[1].toLowerCase() !== row.hex) {
		errors.push(`${rel(WINDOWS)}: ${row.i18n} is ${line[1]}, the shared palette says ${row.hex}.`);
	} else if (!HEX_LITERAL.test(line[1])) {
		errors.push(`${rel(WINDOWS)}: ${row.i18n} is not a six-digit colour.`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] hotstring colour palette is not single-sourced:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] hotstring colour palette — ${palette.length} colour(s) generated for macOS and Linux, all present in the Windows copy.\x1b[0m`
);
