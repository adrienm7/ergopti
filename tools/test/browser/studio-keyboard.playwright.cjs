// tools/test/browser/studio-keyboard.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Studio Keyboard Walk
 * DESCRIPTION:
 * Walks every Ergopti Studio page (editor, Comparer, Optimiser) with the Tab
 * key alone, then back with Shift+Tab, in headless Chromium from a loopback
 * server that serves static/ as the site does: the focus must leave the page
 * at both ends (no keyboard trap, WCAG 2.1.2), follow the page from top to
 * bottom with no positive tabindex (focus order, 2.4.3), land only on
 * elements shown on screen (2.4.7), and come back the same way. The
 * Comparer is walked again with its details and settings unfolded, where
 * most of its controls live. Each page's outline is read too
 * (heading-landmarks.cjs): one h1, no skipped heading level, one main
 * landmark, every other landmark named. The maintainer asked for a keyboard walk of the
 * Studio on 2026-11-16 (TODO « Full accessibility », « Keyboard and motor »).
 * Page errors and requests outside the loopback origin fail the gate.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
const { collectOutline, outlineProblems } = require('../lib/heading-landmarks.cjs');
const { walkProblems } = require('../lib/keyboard-walk.cjs');

const STATIC_ROOT = path.resolve(__dirname, '..', '..', '..', 'static');
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.mjs': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json',
	'.svg': 'image/svg+xml',
	'.woff2': 'font/woff2',
	'.toml': 'text/plain'
};
const UI = '/ergopti_plus/_shared/ui/';
// The pages the site frames under /studio, /studio/comparer and /studio/optimiser.
const PAGES = Object.freeze([
	{ name: 'editor', path: UI + 'layout_editor/index.html', ready: '#le-board [data-code="KeyA"]' },
	{
		name: 'Comparer',
		path: UI + 'layout_analysis/index.html',
		// A fresh visit opens « Home », the corpus, the layouts and the settings.
		ready: '#la-panel-home #la-corpus'
	},
	{ name: 'Optimiser', path: UI + 'layout_optimizer/index.html', ready: '.layout-optimizer h1' }
]);
const VIEWPORT = { width: 1280, height: 900 };

/** Serves static/ read-only on loopback, as the site serves its pages. */
function serve() {
	const server = http.createServer((request, response) => {
		const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
		const file = path.resolve(STATIC_ROOT, pathname.slice(1));
		if (
			!file.startsWith(STATIC_ROOT + path.sep) ||
			!fs.existsSync(file) ||
			!fs.statSync(file).isFile()
		) {
			response.writeHead(404);
			response.end();
			return;
		}
		response.setHeader('Content-Type', TYPES[path.extname(file)] || 'application/octet-stream');
		fs.createReadStream(file).pipe(response);
	});
	return new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => resolve(server));
	});
}

/**
 * Describes the focused element, or null when the focus is outside the
 * page's content (on the body or out of the document).
 */
function focusedStop() {
	const element = document.activeElement;
	if (!element || element === document.body || element === document.documentElement) return null;
	const all = Array.from(document.querySelectorAll('*'));
	const order = all.indexOf(element);
	const label = (
		element.getAttribute('aria-label') ||
		element.getAttribute('title') ||
		element.textContent ||
		element.getAttribute('placeholder') ||
		''
	)
		.replace(/\s+/g, ' ')
		.trim()
		.slice(0, 40);
	const rect = element.getBoundingClientRect();
	const style = getComputedStyle(element);
	const visible =
		rect.width > 0 &&
		rect.height > 0 &&
		style.visibility !== 'hidden' &&
		rect.right > 0 &&
		rect.bottom > 0 &&
		rect.left < innerWidth &&
		rect.top < innerHeight;
	const name = `${element.tagName.toLowerCase()}${element.id ? '#' + element.id : ''}`;
	return {
		id: `${name}@${order} «${label}»`,
		key: `${name} «${label}»`,
		order,
		visible,
		tabindex: element.tabIndex
	};
}

/**
 * Presses one key until the focus leaves the page's content.
 * @returns {Promise<{stops: object[], left: boolean}>}
 */
async function walk(page, key) {
	await page.evaluate(() => {
		if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
	});
	const stops = [];
	const seen = new Set();
	// Every stop is an element: a walk that neither leaves nor meets a stop
	// twice ends within the document's elements, so their count bounds it.
	const elements = () => page.evaluate(() => document.getElementsByTagName('*').length);
	for (let step = 0; step <= (await elements()); step++) {
		await page.keyboard.press(key);
		const stop = await page.evaluate(focusedStop);
		if (stop === null) {
			if (stops.length > 0) return { stops, left: true };
			continue;
		}
		stops.push(stop);
		// A stop met twice before the focus left: the focus is held.
		if (seen.has(stop.id)) break;
		seen.add(stop.id);
	}
	return { stops, left: false };
}

/** Opens one Studio page in French, as the site frames it, and waits for it to settle. */
async function open(browser, origin, target) {
	const context = await browser.newContext({ viewport: VIEWPORT });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/') && !request.url().startsWith('blob:'))
			errors.push('unexpected request: ' + request.url());
	});
	page.on('dialog', (dialog) => errors.push('native dialog: ' + dialog.message()));
	await page.goto(origin + target.path + '?lang=fr');
	await page.locator(target.ready).first().waitFor({ timeout: 60000 });
	await page.waitForFunction(() => !document.querySelector('[aria-busy="true"]'), null, {
		timeout: 60000
	});
	return { context, page, errors };
}

/** Walks a page both ways and fails on any problem the analysis finds. */
async function check(page, label) {
	const forward = await walk(page, 'Tab');
	const backward = await walk(page, 'Shift+Tab');
	const problems = walkProblems({
		forward: forward.stops,
		forwardLeft: forward.left,
		backward: backward.stops,
		backwardLeft: backward.left
	});
	assert.deepEqual(problems, [], label + ': the keyboard walk must pass');
	// The outline a screen reader moves through: one h1, no skipped level, named landmarks.
	const outline = await page.evaluate(collectOutline);
	assert.deepEqual(outlineProblems(outline), [], label + ': headings and landmarks');
	console.log(
		`  ${label}: ${forward.stops.length} stops, out at both ends; ` +
			`${outline.headings.length} headings, ${outline.landmarks.length} landmarks`
	);
	return forward.stops.length;
}

async function main() {
	const server = await serve();
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch();
	try {
		for (const target of PAGES) {
			const { context, page, errors } = await open(browser, origin, target);
			try {
				const stops = await check(page, target.name);
				assert.ok(stops >= 5, target.name + ' must offer its controls to the keyboard');
				if (target.name === 'Comparer') {
					await page.evaluate(() =>
						document.querySelectorAll('#la-details details, #la-settings').forEach((node) => {
							node.open = true;
						})
					);
					const unfolded = await check(page, 'Comparer unfolded');
					assert.ok(unfolded > stops, 'the unfolded settings must add their controls to the walk');
				}
				assert.deepEqual(errors, [], target.name + ': no page error and no outside request');
			} finally {
				await context.close();
			}
		}
	} finally {
		await browser.close();
		await new Promise((resolve) => server.close(resolve));
	}
	console.log('PASS studio-keyboard.playwright');
}

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});

module.exports = { focusedStop, walk };
