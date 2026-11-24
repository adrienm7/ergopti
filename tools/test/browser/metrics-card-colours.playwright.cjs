// tools/test/browser/metrics-card-colours.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Typing Metrics Card Colours
 * DESCRIPTION:
 * Opens the shared « Métriques de frappe » window in Chromium with the fake
 * host and its filled fixture, in the light and the dark theme, with the
 * colour-blind and the high-contrast reading settings, and reads the painted
 * colour of each card's information marks and headline values.
 *
 * ROOT CAUSE ENCODED:
 * 1. Every information mark (.stat-inline-tooltip) was painted with the speed
 *    card's orange, so the AI and hotstring cards' marks, and those of the
 *    detail cards, did not wear their card's colour. Each mark and each
 *    headline value must now be its card's own colour token.
 * 2. The dark hotstring red (#ff453a) was 4.4:1 on its card, below the 4.5:1
 *    AAA floor of large text (WCAG 1.4.6), and its value read as orange; the
 *    dark AI purple was 4.3:1. Each main card's title and value must hold
 *    4.5:1 on the card in both themes.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require('playwright');
const { serveStatic, installFakeHost } = require('../lib/app-window-host.cjs');
const { WINDOWS } = require('./app-windows-fixtures.cjs');

const STATIC_ROOT = path.resolve(__dirname, '../../../static');
const PAGE = '/ergopti_plus/_shared/ui/metrics_typing/index.html';
const SCHEMES = ['light', 'dark'];
// The reading settings that recolour the page (theme.css « Reading preferences »).
const VARIANTS = [
	{ name: 'default', attributes: {} },
	{ name: 'colour-blind', attributes: { 'data-a11y-colors': 'cvd' } },
	{ name: 'high-contrast', attributes: { 'data-a11y-contrast': 'high' } }
];
// WCAG 1.4.6: the AAA floor of large text (the cards' titles and values).
const LARGE_TEXT_ENHANCED = 4.5;

// Each card, the colour token it is drawn in, and whether its title and value
// are measured against it (the three main cards).
const CARDS = [
	{ card: '#llm_card', token: '--kpi-llm-color', measured: true },
	{ card: '#hs_card', token: '--kpi-hs-color', measured: true },
	{ card: '#global_card', token: '--kpi-wpm-color', measured: true },
	{ card: '.chart-row-block.is-precision', token: '--kpi-precision-color', measured: false },
	{ card: '#dist_card', token: '--kpi-dist-color', measured: false },
	{ card: '#rep_card', token: '--kpi-rep-color', measured: false },
	{ card: '#sfb_card', token: '--kpi-sfb-color', measured: false },
	{ card: '#ergo_bigram_card', token: '--ekpi-ergo-bigram-ink', measured: false },
	{ card: '#ergo_trigram_card', token: '--ekpi-ergo-trigram-ink', measured: false },
	{ card: '#errors_card', token: '--ekpi-errors-ink', measured: false },
	{ card: '#roi_card', token: '--ekpi-roi-ink', measured: false },
	{ card: '#lexical_card', token: '--ekpi-lexical-ink', measured: false },
	{ card: '#rhythm_card', token: '--ekpi-rhythm-ink', measured: false },
	{ card: '#sessions_card', token: '--ekpi-sessions-ink', measured: false },
	{ card: '#records_card', token: '--ekpi-records-ink', measured: false },
	{ card: '#charmix_card', token: '--ekpi-charmix-ink', measured: false },
	{ card: '#apps_card', token: '--ekpi-apps-ink', measured: false },
	{ card: '#wellness_card', token: '--ekpi-wellness-ink', measured: false }
];

/**
 * Reads, in the page, each card's token colour, the colours of its marks and
 * headline values, and the contrast of its title and value on the card.
 */
function readCards(cards) {
	const canvas = document.createElement('canvas');
	canvas.width = canvas.height = 1;
	const context = canvas.getContext('2d', { willReadFrequently: true });
	/** The opaque pixel the given fills paint, one over the other. */
	const pixel = (...fills) => {
		context.clearRect(0, 0, 1, 1);
		for (const fill of fills) {
			context.fillStyle = fill;
			context.fillRect(0, 0, 1, 1);
		}
		return Array.from(context.getImageData(0, 0, 1, 1).data.slice(0, 3));
	};
	const linear = (channel) => {
		const value = channel / 255;
		return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
	};
	const luminance = ([r, g, b]) => 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
	const ratio = (a, b) => {
		const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
		return (high + 0.05) / (low + 0.05);
	};
	/** A token's colour as the page paints it, through a probe in the card. */
	const tokenColour = (card, token) => {
		const probe = document.createElement('span');
		probe.style.color = 'var(' + token + ')';
		card.appendChild(probe);
		const colour = getComputedStyle(probe).color;
		probe.remove();
		return colour;
	};
	const page = getComputedStyle(document.body).backgroundColor;
	return cards.map(({ card: selector, token, measured }) => {
		const card = document.querySelector(selector);
		if (!card) return { selector, missing: true };
		const expected = tokenColour(card, token);
		const painted = (element) => ({
			id: element.id || element.className,
			colour: getComputedStyle(element).color
		});
		const marks = Array.from(card.querySelectorAll('.stat-inline-tooltip')).map(painted);
		const values = Array.from(card.querySelectorAll('.stat-value')).map(painted);
		const contrasts = [];
		if (measured) {
			const ground = pixel(page, getComputedStyle(card).backgroundColor);
			for (const element of [card.querySelector('h2'), ...card.querySelectorAll('.stat-value')])
				contrasts.push({
					id: element.id || element.tagName,
					ratio: ratio(pixel(getComputedStyle(element).color), ground)
				});
		}
		return { selector, expected, marks, values, contrasts };
	});
}

async function main() {
	const target = WINDOWS.find((window) => window.id === 'metrics_typing');
	assert.ok(target, 'The metrics_typing fixture is missing');
	const server = await serveStatic(STATIC_ROOT, 0);
	const origin = 'http://127.0.0.1:' + server.address().port;
	const browser = await chromium.launch({
		...(process.env.CHROMIUM_EXECUTABLE ? { executablePath: process.env.CHROMIUM_EXECUTABLE } : {})
	});
	const failures = [];
	let checked = 0;
	try {
		for (const scheme of SCHEMES)
			for (const variant of VARIANTS) {
				const context = await browser.newContext({
					colorScheme: scheme,
					reducedMotion: 'reduce',
					viewport: { width: 1300, height: 900 }
				});
				context.setDefaultTimeout(30000);
				await context.route(
					(url) => !url.href.startsWith(origin + '/'),
					(route) => route.abort()
				);
				const page = await context.newPage();
				const errors = [];
				page.on('pageerror', (error) => errors.push(error.message));
				await page.addInitScript(installFakeHost, {
					bridge: target.bridge,
					family: 'windows',
					locale: 'fr',
					host: target.host ? target.host.toString() : null
				});
				await page.goto(origin + PAGE);
				await target.fill(page);
				await page.locator(target.ready).first().waitFor({ state: 'visible' });
				await page.evaluate((attributes) => {
					for (const [name, value] of Object.entries(attributes))
						document.documentElement.setAttribute(name, value);
				}, variant.attributes);
				const where = scheme + ' / ' + variant.name;
				assert.deepEqual(errors, [], where + ': the page threw');
				for (const card of await page.evaluate(readCards, CARDS)) {
					if (card.missing) {
						failures.push(where + ': ' + card.selector + ' is missing');
						continue;
					}
					if (!card.marks.length && !card.values.length)
						failures.push(where + ': ' + card.selector + ' shows no mark and no value');
					for (const element of [...card.marks, ...card.values]) {
						checked++;
						if (element.colour !== card.expected)
							failures.push(
								`${where}: ${card.selector} ${element.id} is ${element.colour}, ` +
									`its card's colour is ${card.expected}`
							);
					}
					if (variant.name !== 'default') continue;
					for (const { id, ratio } of card.contrasts)
						if (ratio < LARGE_TEXT_ENHANCED)
							failures.push(
								`${where}: ${card.selector} ${id} is ${ratio.toFixed(2)}:1 on its card, ` +
									`below ${LARGE_TEXT_ENHANCED}:1`
							);
				}
				await context.close();
			}
	} finally {
		await browser.close();
		server.close();
	}
	assert.deepEqual(failures, [], 'Each card mark and value wears its card colour');
	assert.ok(checked > 100, 'Too few marks and values were read: ' + checked);
	console.log(
		`Typing metrics card colours: ${checked} marks and values in their card's colour, ` +
			'PASS in Chromium (light and dark, colour-blind and high contrast).'
	);
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
