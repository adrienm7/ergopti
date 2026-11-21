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
 * Since 2026-11-19 each walk is followed by the operability checks of
 * studio-operability.cjs (the shared lib/keyboard-operability.cjs judgement
 * and widget driver, a focus indicator at every stop, every image hidden or
 * named, tab lists with one stop and Home and End), and every tab of each
 * page's main tab list is opened and checked the same way, the Comparer's on
 * a link naming four layouts. Page errors and requests outside the loopback
 * origin fail the gate. --report prints every problem instead of stopping;
 * --root=<folder> serves another copy of static/ (a revert proof).
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
const operability = require('../lib/keyboard-operability.cjs');
const { operabilityProblems } = require('./studio-operability.cjs');

// --root=<folder> serves another copy of static/ (a revert proof on an older
// commit's pages); --report prints every problem instead of stopping at the first page.
const ROOT_ARG = process.argv.find((arg) => arg.startsWith('--root='));
const STATIC_ROOT = ROOT_ARG
	? path.resolve(ROOT_ARG.slice('--root='.length))
	: path.resolve(__dirname, '..', '..', '..', 'static');
const REPORT = process.argv.includes('--report');
const reported = [];
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
// The pages the site frames under /studio, /studio/comparer, /studio/optimiser
// and /studio/essayer.
const PAGES = Object.freeze([
	{
		name: 'editor',
		path: UI + 'layout_editor/index.html',
		ready: '#le-board [data-code="KeyA"]',
		tabs: '.le-tool-tabs'
	},
	{
		name: 'Comparer',
		path: UI + 'layout_analysis/index.html',
		// A fresh visit opens « Home », the corpus, the layouts and the settings.
		ready: '#la-panel-home #la-corpus',
		tabs: '#la-tabs',
		// The result tabs are swept on a link naming a few layouts: a fresh visit
		// ranks the whole library, some 650 rows of a score and 17 percentile
		// buttons each, over ten thousand Tab stops of one repeated row.
		sweep: { query: '&layouts=ergopti,azerty,bepo,qwerty', ready: '#la-tabs [role="tab"]' }
	},
	{
		name: 'Optimiser',
		path: UI + 'layout_optimizer/index.html',
		ready: '.layout-optimizer h1',
		tabs: '.lo-tabs'
	},
	{
		name: 'Essayer',
		path: UI + 'layout_try/index.html',
		ready: '#input-text[data-emulation-state="ready"]',
		// The layout list, the text area and « Clear »: a page of three controls, no tabs.
		minStops: 3
	}
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
 * page's content (on the body or out of the document). Also reads whether it
 * shows a focus indicator: its outline, shadow, border, background or
 * underline focused against the same element blurred (the focus is put back at
 * once). Each read waits two frames, as theme.css runs its transitions for
 * 0.01 ms under reduced motion.
 */
async function focusedStop() {
	const element = document.activeElement;
	if (!element || element === document.body || element === document.documentElement) return null;
	const settle = () =>
		new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
	const look = (node) => {
		const css = getComputedStyle(node);
		return [
			css.outlineStyle === 'none' || parseFloat(css.outlineWidth) === 0
				? 'none'
				: css.outlineStyle + css.outlineWidth + css.outlineColor,
			css.boxShadow,
			css.borderColor,
			css.backgroundColor,
			css.textDecorationLine
		].join('|');
	};
	// A ring drawn on the wrapper (:focus-within) is the field's indicator too.
	const ring = element.parentElement;
	const both = () => look(element) + (ring ? '#' + look(ring) : '');
	// Elements of one kind (tag, classes, role, parent's tag and classes) share
	// their focus style: the first of a kind is read, the others reuse it, so a
	// page of hundreds of like rows is walked in minutes.
	const kind = [element, ring]
		.map((node) => (node ? `${node.tagName}.${node.className}[${node.getAttribute('role')}]` : ''))
		.join('<');
	const known = (window.__focusLooks = window.__focusLooks || new Map());
	let indicated = known.get(kind);
	if (indicated === undefined) {
		await settle();
		const focused = both();
		element.blur();
		await settle();
		indicated = focused !== both();
		element.focus();
		await settle();
		known.set(kind, indicated);
	}
	// The element's place in document order, from a list kept until the DOM
	// changes: a page of thousands of elements is not listed at every stop.
	if (!window.__elementOrder) {
		window.__elementOrder = { places: null };
		new MutationObserver(() => {
			window.__elementOrder.places = null;
		}).observe(document, { childList: true, subtree: true });
	}
	if (!window.__elementOrder.places)
		window.__elementOrder.places = new Map(
			Array.from(document.querySelectorAll('*')).map((node, index) => [node, index])
		);
	const order = window.__elementOrder.places.get(element);
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
		element.checkVisibility({ contentVisibilityAuto: true }) &&
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
		tabindex: element.tabIndex,
		indicated
	};
}

/**
 * Presses one key until the focus leaves the page's content.
 * @returns {Promise<{stops: object[], left: boolean}>}
 */
async function walk(page, key) {
	// The walk starts from the matching end of the document whatever the checks
	// before it focused: a blur alone leaves the browser's sequential focus
	// starting point where the focus stood.
	await page.evaluate((atEnd) => {
		const mark = document.createElement('i');
		mark.tabIndex = -1;
		if (atEnd) document.body.append(mark);
		else document.body.prepend(mark);
		mark.focus();
		mark.remove();
	}, key !== 'Tab');
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
async function open(browser, origin, target, query = '') {
	const context = await browser.newContext({ viewport: VIEWPORT });
	// Records every pointer and key listener, so the operability check sees
	// what only a mouse could use (lib/keyboard-operability.cjs).
	await context.addInitScript(operability.instrumentListeners, {
		pointer: operability.POINTER_EVENTS,
		keys: operability.KEY_EVENTS
	});
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/') && !request.url().startsWith('blob:'))
			errors.push('unexpected request: ' + request.url());
	});
	page.on('dialog', (dialog) => errors.push('native dialog: ' + dialog.message()));
	await page.goto(origin + target.path + '?lang=fr' + query);
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
	if (REPORT) reported.push(...problems.map((problem) => `${label}: ${problem}`));
	else assert.deepEqual(problems, [], label + ': the keyboard walk must pass');
	// The outline a screen reader moves through: one h1, no skipped level, named landmarks.
	const outline = await page.evaluate(collectOutline);
	assert.deepEqual(outlineProblems(outline), [], label + ': headings and landmarks');
	const operable = await operabilityProblems(page, label, forward.stops);
	if (REPORT) reported.push(...operable.problems);
	else assert.deepEqual(operable.problems, [], label + ': every control operable by keyboard');
	console.log(
		`  ${label}: ${forward.stops.length} stops, out at both ends; ` +
			`${outline.headings.length} headings, ${outline.landmarks.length} landmarks; ` +
			`${operable.controls} controls, ${operable.images} images; ` +
			`${operable.markup.div} div and ${operable.markup.span} span in the DOM`
	);
	return forward.stops.length;
}

/**
 * Opens every other tab of a page's main tab list and checks what it shows:
 * a forward Tab walk, the outline and every operability rule, so a control
 * shown only under one tab is held to them too. The tab the page opened on was
 * walked already, folded and unfolded, unless the sweep runs on its own link.
 * @returns {Promise<number>} The tabs checked.
 */
async function sweepTabs(page, target, everyTab = false) {
	const { names, first } = await page.evaluate((selector) => {
		const tabs = Array.from(document.querySelectorAll(selector + ' [role="tab"]'));
		return {
			names: tabs.map((tab) => tab.textContent.replace(/\s+/g, ' ').trim()),
			first: tabs.findIndex((tab) => tab.getAttribute('aria-selected') === 'true')
		};
	}, target.tabs);
	assert.ok(names.length > 1, `${target.name}: its tab list ${target.tabs} holds tabs`);
	for (let index = 0; index < names.length; index++) {
		if (index === first && !everyTab) continue;
		await page.evaluate(
			([selector, at]) => document.querySelectorAll(selector + ' [role="tab"]')[at].click(),
			[target.tabs, index]
		);
		await page.waitForFunction(() => !document.querySelector('[aria-busy="true"]'), null, {
			timeout: 120000
		});
		const label = `${target.name} › ${names[index]}`;
		const forward = await walk(page, 'Tab');
		const problems = walkProblems({
			forward: forward.stops,
			forwardLeft: forward.left,
			backward: [],
			backwardLeft: false
		}).filter((problem) => !problem.includes('going backward'));
		const outline = await page.evaluate(collectOutline);
		problems.push(...outlineProblems(outline).map((problem) => 'outline: ' + problem));
		const operable = await operabilityProblems(page, label, forward.stops);
		const all = problems.map((problem) => `${label}: ${problem}`).concat(operable.problems);
		if (REPORT) reported.push(...all);
		else assert.deepEqual(all, [], label + ': walk, outline and operability');
		console.log(`  ${label}: ${forward.stops.length} stops, ${operable.controls} controls`);
	}
	return names.length;
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
				assert.ok(
					stops >= (target.minStops || 5),
					target.name + ' must offer its controls to the keyboard'
				);
				if (target.name === 'Comparer') {
					await page.evaluate(() =>
						document.querySelectorAll('#la-details details, #la-settings').forEach((node) => {
							node.open = true;
						})
					);
					const unfolded = await check(page, 'Comparer unfolded');
					assert.ok(unfolded > stops, 'the unfolded settings must add their controls to the walk');
				}
				if (target.sweep) {
					const swept = await open(
						browser,
						origin,
						{ ...target, ready: target.sweep.ready },
						target.sweep.query
					);
					try {
						await sweepTabs(swept.page, target, true);
						assert.deepEqual(swept.errors, [], target.name + ': no error on the swept link');
					} finally {
						await swept.context.close();
					}
				} else if (target.tabs) await sweepTabs(page, target);
				assert.deepEqual(errors, [], target.name + ': no page error and no outside request');
			} finally {
				await context.close();
			}
		}
	} finally {
		await browser.close();
		await new Promise((resolve) => server.close(resolve));
	}
	if (REPORT) {
		for (const problem of reported) console.log('  ' + problem);
		console.log(`${reported.length} problems`);
		if (reported.length) process.exitCode = 1;
		return;
	}
	console.log('PASS studio-keyboard.playwright');
}

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});

module.exports = { focusedStop, walk };
