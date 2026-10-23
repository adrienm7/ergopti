// tools/test/test-visible-text-is-localized.cjs

/**
 * ==============================================================================
 * MODULE: Visible Text Localization Guard
 * DESCRIPTION:
 * User-visible text reaches the screen through the i18n catalogue on every
 * driver. This guard pins three places where a literal used to slip through:
 *
 * 1. Windows notifications: no `TrayTip(` whose message (first argument) is a
 *    quoted literal. Six sites showed English sentences to every language.
 * 2. macOS personal-information editor: every field label goes through
 *    `i18n.get`, except the two acronyms that are the same in every language.
 * 3. Linux shortcut labels: the key names "Espace" and "Entrée" were French
 *    literals shown to every language; they now come from the catalogue.
 *
 * WHY A TARGETED GUARD AND NOT A WORD FILTER:
 * A scan for accented literals was measured and rejected: 154 hits in 37 files,
 * nearly all of them data (hotstring tables, Unicode case tables, parser
 * vocabularies). A guard that fires on correct work gets deleted, so this one
 * names the exact shapes that were wrong.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');

/**
 * Lists AutoHotkey sources that ship in the driver, tests excluded.
 * @param {string} dir Directory to walk.
 * @param {string[]} out Accumulator.
 * @returns {string[]} Absolute paths.
 */
function walkAhk(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.name === 'tests' || entry.name === '_generated') continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) walkAhk(full, out);
		else if (entry.name.endsWith('.ahk')) out.push(full);
	}
	return out;
}

// 1. Windows notifications.
const literalNotices = [];
for (const file of walkAhk(path.join(DRIVERS, 'windows'))) {
	const lines = fs.readFileSync(file, 'utf8').split('\n');
	lines.forEach((line, index) => {
		const code = line.replace(/;.*$/, '');
		if (/\bTrayTip\(\s*"/.test(code)) {
			literalNotices.push(`${path.relative(ROOT, file)}:${index + 1}`);
		}
	});
}
assert.deepEqual(
	literalNotices,
	[],
	`TrayTip needs a translated message, not a literal: ${literalNotices.join(', ')}`
);

// 2. macOS personal-information editor labels.
const editor = fs.readFileSync(
	path.join(DRIVERS, 'macos', 'ui', 'personal_info_editor', 'init.lua'),
	'utf8'
);
const ACRONYMS = new Set(['IBAN', 'BIC']);
const literalLabels = [...editor.matchAll(/label\s*=\s*"([^"]*)"/g)]
	.map((match) => match[1])
	.filter((label) => !ACRONYMS.has(label));
assert.deepEqual(literalLabels, [], `field labels must use i18n.get: ${literalLabels.join(', ')}`);

// 3. Linux shortcut labels.
const shortcuts = fs.readFileSync(
	path.join(DRIVERS, 'linux', 'modules', 'shortcuts', 'keyboard_shortcuts.lua'),
	'utf8'
);
for (const french of ['"Espace"', '"Entrée"']) {
	assert(!shortcuts.includes(french), `${french} is a French literal in a shared menu label`);
}

console.log('visible text is localized: ok');
