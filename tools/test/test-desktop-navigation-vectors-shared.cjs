// tools/test/test-desktop-navigation-vectors-shared.cjs

/**
 * ==============================================================================
 * MODULE: Shared Desktop-Navigation Corpus Gate
 * DESCRIPTION:
 * Checks the corpus of the previous/next desktop actions,
 * _shared/tests/corpus/desktop_navigation/vectors.json, against the documented
 * rule, and that each driver suite replays it.
 *
 * WHY:
 * The three drivers decided where a step lands three ways. macOS left it to
 * Ctrl+Arrow and hid a "circular" checkbox that never wrapped; Windows left it
 * to Ctrl+Win+Arrow, which stops at the edge; Linux computed a modulo in shell,
 * so its "previous desktop" wrapped while the other two stopped. The plain and
 * wrapping actions now share one rule (_shared/lua/desktop_navigation, ported
 * to windows/modules/gestures/virtual_desktops.ahk), and this corpus pins it.
 * A corpus nobody replays pins nothing, so this gate also fails when a suite
 * stops reading it or stops being run.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'desktop_navigation', 'vectors.json');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

/**
 * The documented rule, as a reference.
 * @param {number} index 0-based current desktop.
 * @param {number} count Number of desktops.
 * @param {string} direction "prev" or "next".
 * @param {boolean} wrap Whether the step wraps at the edges.
 * @returns {number} The 0-based target.
 */
function referenceTarget(index, count, direction, wrap) {
	const target = index + (direction === 'next' ? 1 : -1);
	if (target >= 0 && target < count) return target;
	return wrap ? (target + count) % count : index;
}

/**
 * Whether the rule can place an input at all.
 * @param {object} v A corpus entry.
 * @returns {boolean}
 */
function placeable(v) {
	return (
		Number.isInteger(v.count) &&
		v.count >= 1 &&
		Number.isInteger(v.index) &&
		v.index >= 0 &&
		v.index < v.count &&
		(v.direction === 'prev' || v.direction === 'next') &&
		typeof v.wrap === 'boolean'
	);
}

// ==================================================
// ==================================================
// ======= 1/ The corpus follows the rule ===========
// ==================================================
// ==================================================

const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
const vectors = corpus.vectors || [];
const invalid = corpus.invalid || [];
check(vectors.length >= 20, `only ${vectors.length} vector(s) in the corpus`);
check(invalid.length >= 7, `only ${invalid.length} invalid input(s) in the corpus`);
const ids = new Set();
for (const v of [...vectors, ...invalid]) {
	check(typeof v.id === 'string' && !ids.has(v.id), `duplicate or missing id: ${v.id}`);
	ids.add(v.id);
}
for (const v of vectors) {
	check(placeable(v), `${v.id}: the rule cannot place this vector`);
	check(
		v.target === referenceTarget(v.index, v.count, v.direction, v.wrap),
		`${v.id}: target ${v.target} breaks the documented rule`
	);
}
for (const v of invalid) check(!placeable(v), `${v.id}: an "invalid" input the rule can place`);

// The cases the three drivers disagreed on must be there, both ways.
const edge = (direction, wrap) =>
	vectors.some(
		(v) =>
			v.count > 2 &&
			v.direction === direction &&
			v.wrap === wrap &&
			v.index === (direction === 'next' ? v.count - 1 : 0)
	);
for (const direction of ['prev', 'next']) {
	check(edge(direction, true), `no vector wraps ${direction} across the edge`);
	check(edge(direction, false), `no vector stops ${direction} at the edge`);
}
check(
	vectors.some((v) => v.count === 1),
	'no vector covers the single desktop every session starts with'
);

// ==================================================
// ==================================================
// ======= 2/ Every suite replays it ================
// ==================================================
// ==================================================

const CONTRACT = path.join(SP, '_shared', 'lua', 'test', 'desktop_navigation_contract.lua');
const contract = fs.existsSync(CONTRACT) ? fs.readFileSync(CONTRACT, 'utf8') : '';
check(
	contract.includes('tests/corpus/desktop_navigation/vectors.json'),
	'the shared Lua contract must read the desktop-navigation corpus'
);
const CONSUMERS = [
	{
		file: 'macos/tests/unit/modules/gestures/test_desktop_navigation_vectors.lua',
		needle: 'require("test.desktop_navigation_contract")'
	},
	{
		file: 'linux/tests/unit/modules/test_desktop_navigation_vectors.lua',
		needle: 'require("test.desktop_navigation_contract")'
	},
	{
		file: 'windows/tests/unit/test_virtual_desktops.ahk',
		needle: '\\tests\\corpus\\desktop_navigation\\vectors.json'
	}
];
for (const consumer of CONSUMERS) {
	const abs = path.join(SP, consumer.file);
	const source = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : '';
	check(source.includes(consumer.needle), `${consumer.file} must replay the shared corpus`);
}
const linuxManifest = fs.readFileSync(path.join(SP, 'linux', 'tests', 'test_manifest.lua'), 'utf8');
check(
	linuxManifest.includes('"tests.unit.modules.test_desktop_navigation_vectors"'),
	'the Linux test manifest must list test_desktop_navigation_vectors'
);
const ahkRunner = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
check(
	/^#Include unit\/test_virtual_desktops\.ahk$/m.test(ahkRunner),
	'windows/tests/run_all.ahk must #Include unit/test_virtual_desktops.ahk'
);

// ==================================================
// ==================================================
// ======= 3/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] shared desktop-navigation corpus: ${checks} check(s) passed ` +
		`(${vectors.length} vectors, ${invalid.length} invalid inputs, 3 driver suites).\x1b[0m`
);
