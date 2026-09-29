// tools/test/test-ahk-format-placeholders.cjs

/**
 * ==============================================================================
 * MODULE: AutoHotkey Format Placeholder Guard
 * DESCRIPTION:
 * AutoHotkey's Format() fills numbered placeholders ({1}, {2:d}) only. A named
 * one such as {tag} is not an error: Format returns it verbatim, so the user
 * reads the raw placeholder and nothing is logged.
 *
 * ROOT CAUSE ENCODED:
 * The Windows update row was built as Format(t("menu.about.update_now"), Tag)
 * while every locale spells that string "Update to {tag}" (the Linux driver
 * substitutes {tag} itself), so the tray offered "Update to {tag}" instead of
 * the release it was about to install. This guard reads every
 * Format(t("key"), ...) call in the Windows driver and requires the string in
 * all 21 locales to carry numbered placeholders only; a named placeholder
 * belongs to a StrReplace call instead.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const windowsDir = path.join(root, 'static', 'ergopti_plus', 'windows');
const localesDir = path.join(root, 'static', 'ergopti_plus', '_shared', 'data', 'locales');
const errors = [];

const FORMAT_OF_TRANSLATION = /\bFormat\(\s*t\(\s*["']([^"']+)["']\s*\)/g;
const PLACEHOLDER = /\{[^{}]*\}/g;
const NUMBERED = /^\{\d+(?::[^{}]*)?\}$/;

/**
 * Collects the driver's AutoHotkey sources outside its tests.
 * @param {string} dir Directory to scan.
 * @param {string[]} out Accumulated file paths.
 * @returns {string[]} AutoHotkey source paths.
 */
function ahkSources(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name !== 'tests') ahkSources(full, out);
		} else if (entry.name.endsWith('.ahk')) {
			out.push(full);
		}
	}
	return out;
}

const calls = [];
for (const file of ahkSources(windowsDir)) {
	const source = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
	for (const match of source.matchAll(FORMAT_OF_TRANSLATION)) {
		calls.push({ key: match[1], file: path.relative(root, file).replaceAll('\\', '/') });
	}
}
// Floor: a regex that stopped matching would pass over nothing.
if (calls.length < 10) {
	errors.push(
		`expected the Windows driver's Format(t("key"), ...) calls, found only ${calls.length}`
	);
}

const locales = fs
	.readdirSync(localesDir)
	.filter((name) => name.endsWith('.json'))
	.sort();
if (locales.length !== 21) errors.push(`expected 21 locale catalogues, found ${locales.length}`);
for (const name of locales) {
	const catalog = JSON.parse(fs.readFileSync(path.join(localesDir, name), 'utf8'));
	for (const { key, file } of calls) {
		const text = catalog[key];
		if (typeof text !== 'string') continue; // key parity belongs to the catalogue gates
		const named = (text.match(PLACEHOLDER) ?? []).filter((token) => !NUMBERED.test(token));
		if (named.length > 0) {
			errors.push(
				`${file}: Format(t("${key}")) leaves ${named.join(', ')} verbatim in ${name}: ${text}`
			);
		}
	}
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log(
	`[OK] ${calls.length} Windows Format(t(...)) calls read numbered placeholders only, in ${locales.length} locales.`
);
