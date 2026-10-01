// tools/test/test-report-button-contrast.cjs

/**
 * ==============================================================================
 * MODULE: Report Button Contrast Tests
 * DESCRIPTION:
 * The « Signaler sur GitHub » button of the system diagnostics window and of
 * the error window is the pages' one primary button. It reads as white text on
 * a blue background in the light and in the dark appearance.
 *
 * FEATURES & RATIONALE:
 * 1. The dark appearance once swapped it for near-black text on a pale blue,
 *    which the maintainer found ugly and hard to read (report-button-contrast).
 *    Both appearances now resolve the same pair.
 * 2. The pair is checked as a reader sees it: the text is white, the
 *    background is a blue, and their WCAG contrast ratio is at least 4.5.
 * 3. The colours are read from the stylesheet's own variables, through the
 *    rule that paints `button.primary`, so a renamed variable fails here.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ui = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const PAGES = ['healthcheck', 'error_dialog'];
const MINIMUM_RATIO = 4.5;

/** Expands #abc to [r, g, b] and reads #aabbcc. */
function rgb(hex) {
	const value = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex.trim());
	assert.ok(value, `${hex} is not a hexadecimal colour`);
	const digits = value[1].length === 3 ? [...value[1]].map((c) => c + c).join('') : value[1];
	return [0, 2, 4].map((at) => parseInt(digits.slice(at, at + 2), 16));
}

/** WCAG relative luminance of one colour. */
function luminance(hex) {
	const [r, g, b] = rgb(hex).map((channel) => {
		const c = channel / 255;
		return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
	});
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio of two colours. */
function ratio(a, b) {
	const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
	return (high + 0.05) / (low + 0.05);
}

/** The custom properties one block declares. */
function variables(block) {
	const found = {};
	for (const match of block.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g))
		found[match[1]] = match[2].trim();
	return found;
}

for (const page of PAGES) {
	const css = fs
		.readFileSync(path.join(ui, page, 'style.css'), 'utf8')
		.replace(/\/\*[\s\S]*?\*\//g, '');
	const html = fs.readFileSync(path.join(ui, page, 'index.html'), 'utf8');
	assert.match(
		html,
		/id="btn-report"[^>]*class="primary"|class="primary"[^>]*id="btn-report"/,
		`${page}: the report button is the page's primary button`
	);

	const rule = /button\.primary\s*\{([^}]*)\}/.exec(css);
	assert.ok(rule, `${page}: the primary button has a rule`);
	const background = /background:\s*var\((--[\w-]+)\)/.exec(rule[1]);
	const text = /(?:^|[;\s])color:\s*var\((--[\w-]+)\)/.exec(rule[1]);
	assert.ok(background && text, `${page}: the primary button takes its colours from variables`);

	const light = variables(/:root\s*\{([^}]*)\}/.exec(css)[1]);
	const darkBlock = /@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{([^}]*)\}/.exec(
		css
	);
	assert.ok(darkBlock, `${page}: the page follows the dark appearance`);
	const dark = { ...light, ...variables(darkBlock[1]) };

	for (const [appearance, vars] of [
		['light', light],
		['dark', dark]
	]) {
		const where = `${page}, ${appearance} appearance`;
		const fill = vars[background[1]];
		const ink = vars[text[1]];
		assert.ok(fill && ink, `${where}: the button's colours are declared`);
		assert.deepEqual(rgb(ink), [255, 255, 255], `${where}: the button's text is white, got ${ink}`);
		const [r, g, b] = rgb(fill);
		assert.ok(b > r && b > g, `${where}: the button's background is a blue, got ${fill}`);
		const contrast = ratio(ink, fill);
		assert.ok(
			contrast >= MINIMUM_RATIO,
			`${where}: white on ${fill} has a contrast of ${contrast.toFixed(2)}, below ${MINIMUM_RATIO}`
		);
	}
}

console.log(
	'[OK] report button: white on blue with a contrast of at least 4.5 in both appearances, on both pages.'
);
