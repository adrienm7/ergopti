// tools/test/test-windows-hotstring-preview-shows.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Preview Bubble Gate (hotstring-preview-shows)
 * DESCRIPTION:
 * Maintainer report: « Sur driver AHK les tooltips hotstrings ne s'affichent
 * pas. Seul le tooltip LLM fonctionne. » Only the AHK suite can run the
 * Windows preview, on Windows CI. This gate checks from the sources, anywhere,
 * what the bubble depends on:
 *
 * 1. The Windows time gate (_HSE_PrepareDispatchDecision) fails closed without
 *    a timestamp for the trigger's previous key, so every character the engine
 *    is fed must be stamped: the prefix watcher stamps it through the single
 *    timestamp owner, after verifying its control and before feeding the
 *    engine, and that owner loads with the engine rather than with the layout
 *    emulation.
 * 2. The preview switches exist on all three drivers and ship on (PAR-24); the
 *    bubble shows on a fresh configuration, and « Restaurer les valeurs
 *    conseillées » restores them, the AI bubble excepted (consent).
 * 3. The AHK regression test is registered in run_all.ahk.
 *
 * ROOT CAUSE ENCODED:
 * Only the layout emulation wrote LastSentCharacterKeyTime. With the emulation
 * off, the neutral layout setting since W1, a key typed through the OS layout
 * had no timestamp, so every delayed hotstring (all bundled ones) was refused
 * by the preview and by dispatch. The ungated repeat doubling was the only row
 * left, and the bubble never offers it, so no bubble showed at all.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static', 'ergopti_plus');
const WIN = path.join(PLUS, 'windows');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (file) => fs.readFileSync(file, 'utf8').replace(/^﻿/, '');

/**
 * Removes full-line and trailing AHK comments, keeping line positions.
 * @param {string} source AHK source text.
 * @returns {string} Source without comments.
 */
const stripComments = (source) =>
	source
		.split('\n')
		.map((line) => (/^\s*;/.test(line) ? '' : line.replace(/\s+;.*$/, '')))
		.join('\n');

/**
 * Returns the body of an AHK function declared at column 0.
 * @param {string} source AHK source text.
 * @param {string} name Function name.
 * @returns {{start: number, text: string}} Body start offset and text, text "" when absent.
 */
const bodyOf = (source, name) => {
	const start = source.search(new RegExp(`^${name}\\(`, 'm'));
	if (start < 0) return { start: -1, text: '' };
	const open = source.slice(start).search(/\)\s*\{[ \t]*$/m);
	if (open < 0) return { start: -1, text: '' };
	const end = source.indexOf('\n}', start + open);
	return end < 0 ? { start: -1, text: '' } : { start, text: source.slice(start, end) };
};

/**
 * Lists the shipped Windows driver sources, tests, vendor and generated code excluded.
 * @param {string} dir Directory to walk.
 * @returns {string[]} Absolute .ahk paths.
 */
const driverSources = (dir) => {
	const out = [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (!['tests', 'vendor', '_generated'].includes(entry.name)) out.push(...driverSources(full));
		} else if (entry.name.endsWith('.ahk')) {
			out.push(full);
		}
	}
	return out;
};

// 1. Every character the engine is fed carries a timestamp for the time gate.
const OWNER = 'AppState_TouchLastSentKey';
const OWNER_FILE = path.join(WIN, 'infra', 'hotstrings', 'hotstring_send.ahk');

const dispatch = stripComments(
	read(path.join(WIN, 'infra', 'hotstrings', 'hotstring_dispatch.ahk'))
);
const gate = bodyOf(dispatch, '_HSE_PrepareDispatchDecision').text;
check(
	gate.includes('LastSentCharacterKeyTime.Has(PrevKey)'),
	'_HSE_PrepareDispatchDecision must still time a trigger from LastSentCharacterKeyTime; if the gate moved, move this check with it'
);

const ownerSource = stripComments(read(OWNER_FILE));
const owner = bodyOf(ownerSource, OWNER);
check(
	owner.text !== '',
	`${OWNER} must be defined in infra/hotstrings/hotstring_send.ahk, which loads with the engine: in modules/keymap/ it belongs to the layout emulation, the only writer the neutral layout setting leaves out`
);

const writes = [];
for (const file of driverSources(WIN)) {
	const source = stripComments(read(file));
	for (const match of source.matchAll(/LastSentCharacterKeyTime\[[^\]\n]*\]\s*:=/g)) {
		writes.push({ file, index: match.index });
	}
}
check(
	writes.length === 1 &&
		writes[0].file === OWNER_FILE &&
		writes[0].index > owner.start &&
		writes[0].index < owner.start + owner.text.length,
	`${OWNER} must be the only writer of LastSentCharacterKeyTime, found: ${writes
		.map((write) => path.relative(WIN, write.file))
		.join(', ')}`
);

const watcher = stripComments(
	read(path.join(WIN, 'infra', 'hotstrings', 'hotstring_inputhook.ahk'))
);
const onChar = bodyOf(watcher, '_OnPrefixChar').text;
const STAMP = '_PrefixStampCompletedInput';
const stamp = bodyOf(watcher, STAMP).text;
const completeAt = stamp.indexOf('_TextCompleteTailScalar(DeliveredChar) != ""');
const touchAt = stamp.indexOf(`${OWNER}(DeliveredChar, ObservedTick)`);
const ensureAt = onChar.indexOf('_PrefixEnsureInputContext()');
const stampAt = onChar.indexOf(`${STAMP}(Char)`);
const feedAt = onChar.indexOf('HSEMatch := HSE_FeedChar(Char, true)');
check(
	onChar !== '' &&
		stamp !== '' &&
		stamp.includes('for DeliveredChar in _TextCodepoints(Observed)') &&
		completeAt > 0 &&
		touchAt > completeAt &&
		stampAt > 0,
	`_OnPrefixChar must call the actual ${STAMP} helper, which stamps completed scalars through ${OWNER} and refuses orphan units`
);
check(
	onChar !== '' && ensureAt > 0 && feedAt > 0 && ensureAt < stampAt && stampAt < feedAt,
	'_OnPrefixChar must stamp the character after verifying its control and before feeding the engine'
);

const layout = stripComments(read(path.join(WIN, 'modules', 'keymap', 'layout.ahk')));
check(
	bodyOf(layout, 'UpdateLastSentCharacter').text.includes(`${OWNER}(Character)`),
	`the layout emulation's UpdateLastSentCharacter must stamp through the same owner, ${OWNER}`
);

// 2. The preview switches exist on all three drivers (PAR-24) and ship on, so the
// bubble shows on a fresh configuration without any import.
const manifest = TOML.parse(
	read(path.join(PLUS, '_shared', 'modules', 'features', 'manifest.toml'))
);
const previews = manifest.features.hotstrings.filter((entry) => /^preview_/.test(entry.id));
check(previews.length === 4, 'the manifest must declare the four hotstring preview switches');
const wizard = manifest.onboarding.pages.hotstrings.settings || {};
const scope = manifest.scopes.hotstrings;
for (const entry of previews) {
	const key = `hotstrings.${entry.id}`;
	const consent = entry.id === 'preview_ai_enabled';
	check(entry.default === true, `${key} must ship on, on every driver`);
	check(entry.recommended === true, `${key} must be recommended on`);
	check(
		entry.platforms === undefined ||
			['ahk', 'hs', 'linux'].every((platform) => entry.platforms.includes(platform)),
		`${key} must be offered by all three drivers: Windows has the switches since PAR-24`
	);
	check(
		scope.restore_exclude.includes(key) === consent,
		consent
			? `${key} must stay out of the restore of recommended values: AI consent is never restored`
			: `the restore of recommended values must turn ${key} on`
	);
	check(
		!Object.prototype.hasOwnProperty.call(wizard, key),
		`the first-run wizard must not offer ${key}: it ships on, and the generator refuses a setting that recommends its neutral default`
	);
}

// 3. The AHK regression test runs.
const runAll = read(path.join(WIN, 'tests', 'run_all.ahk'));
check(
	/^#Include unit\/modules\/hotstrings\/preview\/test_hotstring_preview_shows\.ahk$/m.test(runAll),
	'run_all.ahk must include unit/modules/hotstrings/preview/test_hotstring_preview_shows.ahk'
);

if (errors.length) {
	for (const message of errors) console.error(`FAIL ${message}`);
	console.error(`hotstring-preview-shows: ${errors.length} of ${checks} checks failed.`);
	process.exit(1);
}
console.log(`hotstring-preview-shows: ${checks} checks passed.`);
