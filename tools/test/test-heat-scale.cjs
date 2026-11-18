// tools/test/test-heat-scale.cjs

/**
 * ==============================================================================
 * MODULE: Studio Heat Scale Gate
 * DESCRIPTION:
 * Holds Ergopti Studio's one heat scale (theme.css « Chart look »,
 * --theme-chart-heat-*) to what it was chosen for: blue for the least used
 * key, through green, yellow and orange, to red for the most (maintainer,
 * 2026-11-18, replacing the one-hue blue ramp), readable in the light and the
 * dark theme, and read by every count figure from that one definition.
 *
 * ROOT CAUSE ENCODED:
 * 1. The heat maps, their tables and the bigram matrix mixed one blue hue from
 *    light to dark, and the editor's key colours had their own green-to-red
 *    hsl() formula: two scales, and neither the warm-to-cool one asked for.
 * 2. A multi-hue scale is light in its middle and darker at its ends, so the
 *    heat ink must stay at 4.5:1 on every point of it, not only at its stops.
 * 3. Colour is never the only cue: the keys keep their edge against the
 *    surface, and each heat figure keeps its legend from 0 to its largest value.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { shared } = require('../lib/paths.cjs');

const THEME = fs.readFileSync(shared('ui', 'theme.css'), 'utf8');
const STUDIO_CSS = fs.readFileSync(shared('ui', 'layout_analysis', 'style.css'), 'utf8');
const EDITOR_CSS = fs.readFileSync(shared('ui', 'layout_editor', 'style.css'), 'utf8');
const COMPARER = fs.readFileSync(shared('ui', 'layout_analysis', 'comparer_page.js'), 'utf8');
const TEXT_CONTRAST = 4.5;
const NON_TEXT_CONTRAST = 3;
// Adjacent stops of a continuous scale: told apart at a glance (the categorical
// hues of the chart look need 15, being read without their order).
const STOP_DELTA_E = 10;
const STOPS = 5;

/** A custom property's value in a stylesheet (its first definition). */
function token(css, name) {
	const match = css.match(new RegExp('--' + name + ':\\s*([^;]+);'));
	assert.ok(match, 'No --' + name);
	return match[1].trim();
}

/** The declarations of the first CSS block whose selector is exactly the given text. */
function block(css, selector) {
	const start = css.indexOf('\n' + selector + ' {');
	assert.ok(start >= 0, 'No block ' + selector);
	return css.slice(start, css.indexOf('}', start));
}

function channels(hex) {
	assert.match(hex, /^#[0-9a-f]{6}$/, 'A six-digit colour: ' + hex);
	return [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
}

const linear = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);

function luminance(rgb) {
	const [r, g, b] = rgb.map(linear);
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a, b) {
	const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
	return (x + 0.05) / (y + 0.05);
}

function oklab(rgb) {
	const [r, g, b] = rgb.map(linear);
	const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
	const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
	const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
	return [
		0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
	];
}

const deltaE = (a, b) => Math.hypot(...oklab(a).map((v, i) => v - oklab(b)[i])) * 100;

// 1/ One definition: the stops, the ink and the gradient through them in order.
const stops = Array.from({ length: STOPS }, (_, i) =>
	channels(token(THEME, `theme-chart-heat-${i + 1}`))
);
const ink = channels(token(THEME, 'theme-chart-heat-ink'));
const scale = token(THEME, 'theme-chart-heat-scale');
assert.deepEqual(
	[...scale.matchAll(/var\(--theme-chart-heat-(\d)\)/g)].map((m) => Number(m[1])),
	[1, 2, 3, 4, 5],
	'the scale runs through its five stops in order'
);
for (const name of ['heat-1', 'heat-5', 'heat-ink', 'heat-scale'])
	assert.equal(
		(THEME.match(new RegExp('--theme-chart-' + name + ':', 'g')) || []).length,
		1,
		`--theme-chart-${name} is defined once, for both themes`
	);

// 2/ Warm to cool: blue the least, then green, yellow, orange, red the most.
const [r1, g1, b1] = stops[0];
assert.ok(b1 > r1 && b1 > g1, 'the least is blue');
assert.ok(stops[1][1] > stops[1][0] && stops[1][1] > stops[1][2], 'then green');
assert.ok(stops[2][0] > 0.9 && stops[2][1] > 0.8 && stops[2][2] < 0.5, 'then yellow');
assert.ok(
	stops[3][0] > stops[3][1] && stops[3][1] > stops[3][2] && stops[3][1] > 0.5,
	'then orange'
);
assert.ok(stops[4][0] > 0.9 && stops[4][1] < 0.5 && stops[4][2] < 0.5, 'the most is red');
for (let i = 1; i < STOPS; i++)
	assert.ok(
		deltaE(stops[i - 1], stops[i]) >= STOP_DELTA_E,
		`stops ${i} and ${i + 1} are told apart (ΔE ${deltaE(stops[i - 1], stops[i]).toFixed(1)})`
	);

// 3/ The ink reads on every point of the gradient (CSS interpolates in sRGB).
for (let step = 0; step <= 100; step++) {
	const at = (step / 100) * (STOPS - 1);
	const i = Math.min(STOPS - 2, Math.floor(at));
	const f = at - i;
	const colour = stops[i].map((v, c) => v * (1 - f) + stops[i + 1][c] * f);
	assert.ok(
		contrast(ink, colour) >= TEXT_CONTRAST,
		`the heat ink at ${step} % of the scale: ${contrast(ink, colour).toFixed(2)}:1`
	);
}

// 4/ Every key keeps its edge against the light and the dark surface.
const chart = THEME.slice(THEME.indexOf('5/ Chart look'));
const edges = [
	[token(block(chart, ':root'), 'theme-chart-ramp-edge'), '#ffffff'],
	[
		token(block(chart, ":root[data-theme='dark']"), 'theme-chart-ramp-edge'),
		token(THEME, 'theme-gray5-dark')
	]
];
for (const [edge, surface] of edges)
	assert.ok(
		contrast(channels(edge), channels(surface)) >= NON_TEXT_CONTRAST,
		`the key edge ${edge} stands out on ${surface}`
	);

// 5/ Every count figure reads the one scale, with the heat ink.
assert.equal(token(STUDIO_CSS, 'la-heat-scale'), 'var(--theme-chart-heat-scale)');
assert.equal(token(STUDIO_CSS, 'la-heat-fill-ink'), 'var(--theme-chart-heat-ink)');
for (const selector of [
	'.la-heatmap .la-key',
	'.la-matrix .la-cell-count',
	'.la-heat-table .la-cell-count'
]) {
	const rule = block(STUDIO_CSS, selector);
	assert.match(
		rule,
		/background: var\(--la-heat-scale\) var\(--la-share\) 0 \/ 10000% 100% no-repeat;/,
		selector
	);
	assert.match(rule, /color: var\(--la-heat-fill-ink\);/, selector + ' prints in the heat ink');
}
assert.match(
	block(STUDIO_CSS, '.la-heat-ramp'),
	/background: var\(--la-heat-scale\);/,
	'the legend draws the scale'
);
assert.ok(!/la-heat-(low|high)/.test(STUDIO_CSS), 'no second heat ramp in the Comparer');
const editorHeat = block(EDITOR_CSS, '.le-key.le-heat');
assert.match(
	editorHeat,
	/var\(--theme-chart-heat-scale\) calc\(var\(--le-heat\) \* 100%\)/,
	'the editor keys read the scale'
);
assert.match(editorHeat, /color: var\(--theme-chart-heat-ink\);/);
assert.ok(!/hsl\(calc\(/.test(EDITOR_CSS), 'no second heat formula in the editor');
// The legend from 0 to the largest value, beside each heat figure.
assert.ok(
	(COMPARER.match(/el\('span', 'la-heat-ramp'\)/g) || []).length >= 4,
	'each heat figure has its legend'
);

console.log(
	'ok - heat scale: one blue-to-red scale, readable in both themes, read by every count figure'
);
