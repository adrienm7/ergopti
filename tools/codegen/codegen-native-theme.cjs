// tools/codegen/codegen-native-theme.cjs

/**
 * ==============================================================================
 * MODULE: Native Theme Codegen
 * DESCRIPTION:
 * Projects _shared/data/native_theme.toml (the hotstring colour palette and the
 * download-window accents) into _shared/lua/native_theme_data.lua, the module
 * the macOS and Linux drivers require, and the palette into
 * windows/_generated/native_theme.ahk, instead of typing the colours again.
 *
 * WHY THIS EXISTS:
 * The palette was written in the macOS window, the Linux bridge and the Windows
 * helper, and a gate had to keep the copies equal. The shared hotstrings TOML
 * reader has no array support, so no driver can read an ordered palette at
 * runtime; a generated table has no such limit and costs no file read at
 * startup.
 *
 * USAGE:  node tools/codegen/codegen-native-theme.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const toml = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const SOURCE = shared('data', 'native_theme.toml');
const TARGET = shared('lua', 'native_theme_data.lua');
const AHK_TARGET = shared('..', 'windows', '_generated', 'native_theme.ahk');
const LOCALE_SOURCE = shared('data', 'locales', 'en.json');
const TOOLTIP_SOURCE = shared('modules', 'tooltip', 'constants.toml');
const HEX = /^#[0-9a-f]{6}$/i;
const THEME_CSS = shared('ui', 'theme.css');

// ==========================================
// ==========================================
// ======= 1/ Validation ===================
// ==========================================
// ==========================================

/**
 * The hex of one palette row: typed in the row, or read from the tooltip
 * constants' [accent_colors] when the row names its source with `hex_from`.
 * @param {object} row One [[hotstring_palette]] row.
 * @param {object} accents The tooltip constants' [accent_colors] table.
 * @returns {string} The lowercase #rrggbb colour.
 */
function resolveHex(row, accents) {
	if ((row.hex === undefined) === (row.hex_from === undefined)) {
		throw new Error(`native_theme.toml: "${row.name}" needs exactly one of hex and hex_from`);
	}
	const hex = row.hex !== undefined ? row.hex : accents[row.hex_from];
	if (typeof hex !== 'string' || !HEX.test(hex)) {
		throw new Error(`native_theme.toml: "${row.name}" has hex "${hex}"`);
	}
	return hex.toLowerCase();
}

/**
 * Validates the theme source; a malformed colour must not reach a driver.
 * @param {object} theme The parsed TOML.
 * @param {object} locale The English locale table.
 * @param {object} tooltipAccents The tooltip constants' [accent_colors] table.
 */
function validate(theme, locale, tooltipAccents) {
	const palette = theme.hotstring_palette;
	if (!Array.isArray(palette) || palette.length === 0) {
		throw new Error('native_theme.toml: [[hotstring_palette]] must list at least one colour');
	}
	const names = new Set();
	for (const row of palette) {
		resolveHex(row, tooltipAccents);
		if (names.has(row.name)) throw new Error(`native_theme.toml: duplicate colour "${row.name}"`);
		names.add(row.name);
		if (!Object.hasOwn(locale, row.i18n)) {
			throw new Error(
				`native_theme.toml: "${row.name}" names the unknown locale key "${row.i18n}"`
			);
		}
	}
	const accents = Object.entries(theme.download_accent || {});
	if (accents.length === 0) throw new Error('native_theme.toml: [download_accent] is empty');
	for (const [kind, hex] of accents) {
		if (!HEX.test(hex))
			throw new Error(`native_theme.toml: download accent "${kind}" has hex "${hex}"`);
	}
}

// ==========================================
// ==========================================
// ======= 2/ Emitter ======================
// ==========================================
// ==========================================

/**
 * The static palette of the web theme: every token of the first :root block of
 * theme.css whose value is a bare hex. A native webview that inlines its own
 * page builds its custom properties from this table instead of retyping them.
 * @returns {Array<[string, string]>} [name without the --theme- prefix, #rrggbb] in file order.
 */
function webPalette() {
	const css = fs.readFileSync(THEME_CSS, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
	const root = /:root\s*\{([^}]*)\}/.exec(css);
	if (!root) throw new Error('theme.css: no :root palette block');
	const rows = [];
	for (const match of root[1].matchAll(/--theme-([\w-]+)\s*:\s*(#[0-9a-fA-F]{6})\s*;/g)) {
		rows.push([match[1], match[2].toLowerCase()]);
	}
	if (rows.length === 0) throw new Error('theme.css: the palette block holds no 6-digit colour');
	return rows;
}

/**
 * Renders the Lua module.
 * @param {object} theme The validated theme.
 * @param {object} accentColors The tooltip constants' [accent_colors] table.
 * @returns {string} The module text.
 */
function emit(theme, accentColors) {
	const rows = theme.hotstring_palette.map(
		(row) =>
			`\t\t{ name = "${row.name}", i18n = "${row.i18n}", hex = "${resolveHex(row, accentColors)}" },`
	);
	const accents = Object.entries(theme.download_accent).map(
		([kind, hex]) => `\t\t${kind} = "${hex}",`
	);
	return [
		'--- _shared/lua/native_theme_data.lua',
		'',
		'--- Generated by tools/codegen/codegen-native-theme.cjs; do not edit.',
		'--- Source: _shared/data/native_theme.toml and the palette of _shared/ui/theme.css.',
		'return {',
		'\thotstring_palette = {',
		...rows,
		'\t},',
		'\tdownload_accent = {',
		...accents,
		'\t},',
		'\t-- The static palette of ui/theme.css (name without --theme-), for native webviews.',
		'\tweb_palette = {',
		...webPalette().map(([name, hex]) => `\t\t["${name}"] = "${hex}",`),
		'\t},',
		'}',
		''
	].join('\n');
}

/**
 * Renders the AHK palette: one function returning a fresh Array of Maps, because
 * the window translates the labels when it opens.
 * @param {object} theme The validated theme.
 * @param {object} accentColors The tooltip constants' [accent_colors] table.
 * @returns {string} The module text, with the UTF-8 BOM every AHK source carries.
 */
function emitAhk(theme, accentColors) {
	const rows = theme.hotstring_palette.map(
		(row) =>
			`\t\tMap("Name", "${row.name}", "I18n", "${row.i18n}", "Hex", "${resolveHex(row, accentColors)}"),`
	);
	return [
		'﻿; _generated/native_theme.ahk',
		'; AUTO-GENERATED from _shared/data/native_theme.toml.',
		'; DO NOT EDIT BY HAND: run `npm run gen` to refresh.',
		'#Requires AutoHotkey v2.0',
		'',
		'; The ordered palette of the hotstrings settings window, the 14 colours the three drivers offer.',
		'; @returns {Array} Maps { Name, I18n, Hex }, in the order of the source.',
		'NativeThemeHotstringPalette() {',
		'\treturn [',
		...rows,
		'\t]',
		'}',
		''
	].join('\n');
}

const theme = toml.parse(fs.readFileSync(SOURCE, 'utf8'));
const accentColors = toml.parse(fs.readFileSync(TOOLTIP_SOURCE, 'utf8')).accent_colors;
validate(theme, JSON.parse(fs.readFileSync(LOCALE_SOURCE, 'utf8')), accentColors);
fs.writeFileSync(TARGET, emit(theme, accentColors), 'utf8');
fs.writeFileSync(AHK_TARGET, emitAhk(theme, accentColors), 'utf8');
console.log('[OK] Generated the shared native theme data.');
