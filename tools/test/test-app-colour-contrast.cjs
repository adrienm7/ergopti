// tools/test/test-app-colour-contrast.cjs

/**
 * ==============================================================================
 * MODULE: App Colour Contrast Gate
 * DESCRIPTION:
 * Holds the colours of Ergopti Studio's figures (theme.css « Chart look ») and
 * of the metrics dashboards (« Metrics look ») to the contrasts they were
 * chosen for, in the light and the dark theme.
 *
 * ROOT CAUSE ENCODED:
 * 1. The heatmap ramp's light end was 1.16:1 (light) and 1.11:1 (dark)
 *    against the surface, and each key's border was the surface itself, so a
 *    key worth zero had no visible shape (WCAG 1.4.11). Every key now wears a
 *    1 px edge of the ramp's hue: at least 3:1 against the surface and against
 *    the light end, and the heatmap's key rule must draw it.
 * 2. The fingering editor's four finger tints (30 % of the system red,
 *    orange, green and blue in the surface) were within 7.7 ΔE of each other
 *    and 1.3:1 against the surface. The fingers now take the categorical hues
 *    of the chart look in their fixed order from the pinky, as their keys'
 *    edges: each adjacent pair at least 15 ΔE apart (OKLab ×100, normal
 *    vision), the printed finger at 4.5:1 on its key's tint.
 * 3. The metrics dashboards' muted text (units, help, table headers) was the
 *    system tertiary grey, 3.3:1 to 3.6:1 in light: it must reach 4.5:1 on
 *    the page, the panels and the table headers in both themes.
 * The dataviz palette validator's run (colour-blind separation included) is
 * recorded in docs/audits/accessibility/README.md.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { shared } = require('../lib/paths.cjs');

const THEME = fs.readFileSync(shared('ui', 'theme.css'), 'utf8');
const STUDIO_CSS = fs.readFileSync(shared('ui', 'layout_analysis', 'style.css'), 'utf8');
const FINGERING_CSS = fs.readFileSync(
	shared('ui', 'layout_analysis', 'fingering_editor.css'),
	'utf8'
);
// WCAG 1.4.11 (non-text) and 1.4.3 (text) floors.
const NON_TEXT_CONTRAST = 3;
const TEXT_CONTRAST = 4.5;
// The dataviz validator's normal-vision floor between neighbouring categories.
const NORMAL_VISION_DELTA_E = 15;
// The share of the finger's hue in its key's tint (fingering_editor.css).
const TINT_SHARE = 0.22;
const FINGER_ORDER = [
	['lp', 'rp'],
	['lr', 'rr'],
	['lm', 'rm'],
	['li', 'ri']
];

/** The declarations of the first CSS block whose selector starts the given text. */
function block(css, selector) {
	const start = css.indexOf(selector + ' {');
	assert.ok(start >= 0, 'No block ' + selector);
	return css.slice(start, css.indexOf('}', start));
}

/** A custom property's value in a block of declarations. */
function token(declarations, name) {
	const match = declarations.match(new RegExp('--' + name + ':\\s*([^;]+);'));
	assert.ok(match, 'No --' + name);
	return match[1].trim();
}

/** The chart look's tokens of one theme, the surface and text resolved. */
function theme(dark) {
	const chart = THEME.slice(THEME.indexOf('5/ Chart look'));
	const tokens = dark ? block(chart, ":root[data-theme='dark']") : block(chart, ':root');
	return {
		surface: dark ? token(THEME, 'theme-gray5-dark') : '#ffffff',
		text: dark ? '#ffffff' : token(THEME, 'theme-label'),
		low: token(tokens, 'theme-chart-ramp-low'),
		edge: token(tokens, 'theme-chart-ramp-edge'),
		cats: [1, 2, 3, 4].map((n) => token(tokens, 'theme-chart-cat-' + n))
	};
}

function channels(hex) {
	assert.match(hex, /^#[0-9a-f]{6}$/, 'A six-digit colour: ' + hex);
	return [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
}

const linear = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const gamma = (v) => (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055);

function luminance(rgb) {
	const [r, g, b] = rgb.map(linear);
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a, b) {
	const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
	return (x + 0.05) / (y + 0.05);
}

/** sRGB (0..1) to OKLab. */
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

/** OKLab back to sRGB (0..1), as color-mix(in oklab) paints it. */
function fromOklab([L, A, B]) {
	const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3;
	const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3;
	const s = (L - 0.0894841775 * A - 1.291485548 * B) ** 3;
	return [
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s
	].map((v) => Math.min(1, Math.max(0, gamma(v))));
}

const deltaE = (a, b) => 100 * Math.hypot(...oklab(a).map((value, i) => value - oklab(b)[i]));

// 1/ The heatmap keys' edge
for (const dark of [false, true]) {
	const mode = dark ? 'dark' : 'light';
	const t = theme(dark);
	const edge = channels(t.edge);
	assert.ok(
		contrast(edge, channels(t.surface)) >= NON_TEXT_CONTRAST,
		mode + ': the key edge must stand out of the surface'
	);
	assert.ok(
		contrast(edge, channels(t.low)) >= NON_TEXT_CONTRAST,
		mode + ': the key edge must stand out of the ramp light end'
	);
}
const key = block(STUDIO_CSS, '.la-heatmap .la-key');
assert.match(
	key,
	/box-shadow:\s*inset 0 0 0 1px var\(--la-heat-edge\)/,
	'The heatmap key draws its edge'
);
assert.equal(token(STUDIO_CSS, 'la-heat-edge'), 'var(--theme-chart-ramp-edge)');

// 2/ The fingering editor's finger hues
FINGER_ORDER.forEach(([left, right], i) => {
	const rule = block(
		FINGERING_CSS,
		`.la-fingering-map .la-fingering-key[data-finger='${left}'],\n` +
			`.la-fingering-map .la-fingering-key[data-finger='${right}']`
	);
	assert.equal(token(rule, 'la-finger'), `var(--theme-chart-cat-${i + 1})`, left + ' hue');
});
const tint = block(FINGERING_CSS, '.la-fingering-map .la-fingering-key[data-finger]');
assert.ok(
	tint.includes(`color-mix(in oklab, var(--la-finger, var(--theme-surface)) ${TINT_SHARE * 100}%`),
	'The key tint mixes the finger hue at the share this gate measures'
);
assert.match(tint, /border: 2px solid var\(--la-finger/, 'The finger hue is the key edge');
for (const dark of [false, true]) {
	const mode = dark ? 'dark' : 'light';
	const t = theme(dark);
	const cats = t.cats.map(channels);
	for (let i = 1; i < cats.length; i++)
		assert.ok(
			deltaE(cats[i - 1], cats[i]) >= NORMAL_VISION_DELTA_E,
			`${mode}: fingers ${i} and ${i + 1} must be told apart`
		);
	const surface = oklab(channels(t.surface));
	for (const cat of cats) {
		const hue = oklab(cat);
		const painted = fromOklab(hue.map((v, j) => v * TINT_SHARE + surface[j] * (1 - TINT_SHARE)));
		assert.ok(
			contrast(channels(t.text), painted) >= TEXT_CONTRAST,
			`${mode}: the printed finger must be readable on its key`
		);
	}
}

// 3/ The metrics dashboards' muted text
const metricsLook = THEME.slice(THEME.indexOf('4/ Metrics look'), THEME.indexOf('5/ Chart look'));
/** A token's colour, following var(--theme-…) references through the theme. */
function resolve(value) {
	const ref = value.match(/^var\(--([a-z0-9-]+)\)$/);
	return ref ? resolve(token(THEME, ref[1])) : value;
}
for (const dark of [false, true]) {
	const tokens = dark
		? block(metricsLook, ":root[data-theme='dark']")
		: block(metricsLook, ':root');
	const muted = channels(resolve(token(tokens, 'theme-metrics-text-muted')));
	for (const ground of ['theme-metrics-bg', 'theme-metrics-panel', 'theme-metrics-th-bg'])
		assert.ok(
			contrast(muted, channels(resolve(token(tokens, ground)))) >= TEXT_CONTRAST,
			(dark ? 'dark' : 'light') + ': muted metrics text must be readable on ' + ground
		);
}

// 4/ The onboarding and the download window (a11y-cvd-2026-11-18)
const ONBOARDING_CSS = fs.readFileSync(shared('ui', 'onboarding', 'style.css'), 'utf8');
const DOWNLOAD_CSS = fs.readFileSync(shared('ui', 'download_window', 'style.css'), 'utf8');
/** A plain property's value in a block of declarations. */
function prop(declarations, name) {
	const match = declarations.match(new RegExp('(?:^|[\\s;{])' + name + ':\\s*([^;]+);'));
	assert.ok(match, 'No ' + name);
	return match[1].trim();
}
/** A colour of a stylesheet, its var() resolved through the theme; rgba() composed on a ground. */
function paint(value, ground) {
	const rgba = value.match(/^rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)$/);
	if (rgba) {
		const alpha = Number(rgba[4]);
		return [1, 2, 3].map((i, j) => (Number(rgba[i]) / 255) * alpha + ground[j] * (1 - alpha));
	}
	return channels(resolve(value));
}
const readable = (fg, bg, what) =>
	assert.ok(contrast(fg, bg) >= TEXT_CONTRAST, what + ': ' + contrast(fg, bg).toFixed(2) + ':1');
/** The page ground: the body block that sets one (an earlier « html, body » sets sizes only). */
function ground(css) {
	for (const match of css.matchAll(/(?:^|\n)body \{([^}]*)\}/g))
		if (/background:/.test(match[1])) return paint(prop(match[1], 'background'));
	assert.fail('No body background');
}
const page = ground(ONBOARDING_CSS);
const white = channels('#ffffff');
// The hints were #888 (3.3:1), the filled button white on the system blue (4.0:1), the
// chosen language, answer and separators that blue (3.5:1 to 4.0:1).
readable(paint(prop(block(ONBOARDING_CSS, '.hint'), 'color')), page, 'onboarding hint');
readable(white, paint(prop(block(ONBOARDING_CSS, '.primary'), 'background')), 'onboarding button');
readable(
	paint(prop(block(ONBOARDING_CSS, '.lang-item.selected .lang-name'), 'color')),
	paint(prop(block(ONBOARDING_CSS, '.lang-item.selected'), 'background')),
	'chosen language'
);
readable(
	paint(
		prop(block(ONBOARDING_CSS, ".radio-card input[type='radio']:checked + .radio-label"), 'color')
	),
	white,
	'chosen answer'
);
readable(paint(prop(block(ONBOARDING_CSS, '.value-separator'), 'color')), white, 'separator');
for (const state of ['register-ok', 'register-err'])
	readable(paint(prop(block(ONBOARDING_CSS, '.register-status.' + state), 'color')), page, state);
// The step dots told done, current and to come by hue alone (1.4:1 and 2.0:1): each
// state has its own shape, and every mark holds 3:1 on the page.
const dot = block(ONBOARDING_CSS, '.step-dot');
const active = block(ONBOARDING_CSS, '.step-dot.active');
const done = block(ONBOARDING_CSS, '.step-dot.done');
assert.equal(prop(dot, 'background'), 'transparent', 'a step to come is a ring');
assert.notEqual(prop(active, 'width'), prop(dot, 'width'), 'the current step is wider');
for (const [what, colour] of [
	['ring', prop(dot, 'border').split(/\s+/).pop()],
	['current', prop(active, 'background')],
	['done', prop(done, 'background')]
])
	assert.ok(
		contrast(paint(colour), page) >= NON_TEXT_CONTRAST,
		'step dot ' + what + ' must stand out of the page'
	);
// The download window's statistics were #888 (4.4:1), its Cancel red 4.1:1 on its wash.
const windowGround = ground(DOWNLOAD_CSS);
for (const selector of ['#model', '#subtitle', '#stats', '#detail-line'])
	readable(paint(prop(block(DOWNLOAD_CSS, selector), 'color')), windowGround, selector);
const cancel = block(DOWNLOAD_CSS, '#btn-cancel');
readable(
	paint(prop(cancel, 'color')),
	paint(prop(cancel, 'background'), windowGround),
	'download Cancel'
);

console.log(
	'test-app-colour-contrast: OK (heatmap edge, finger hues, metrics text, onboarding, download window)'
);
