// tools/test/browser/keyboard-operability.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Site Keyboard Operability Gate
 * DESCRIPTION:
 * Opens every page of a built site in headless Chromium and fails on
 * anything only a mouse can use (maintainer request of 2026-11-19: « all of
 * it navigable by keyboard, on the site and in the WebView UI »):
 * 1. In the page's own document: every shown element with a pointer handler
 *    or an interactive role is reachable with Tab, has an interactive role
 *    and answers a key, or is a native control (lib/keyboard-operability.cjs).
 *    The frames it embeds are judged by their own gates with the same
 *    module: the Studio pages by studio-keyboard.playwright.cjs, the
 *    Ergopti+ app windows shown as demos by app-windows-accessibility.playwright.cjs.
 * 2. The page's own document is walked with Tab, then Shift+Tab: no trap, no
 *    repeated or hidden stop, no positive tabindex, the same way back
 *    (lib/keyboard-walk.cjs), a visible focus indicator at every stop
 *    (WCAG 2.4.7) and a focused element not hidden under the sticky header
 *    or another fixed box (2.4.11). The frames are inert for the walk: their
 *    own walks are the Studio and app window gates'.
 * 3. Every disclosure opens with Enter and closes again, every popup closes
 *    with Escape and gives the focus back to its opener, and the arrow keys
 *    move the focus inside every tab list, menu, list box, grid, radio group
 *    and tree; the narrow-screen menu is checked on a phone-sized window.
 *
 * Usage: node tools/test/browser/keyboard-operability.playwright.cjs
 * site-directory base-path [--only=route,…]. Serves the site on loopback;
 * requests leaving it are answered by the smoke gate's fixtures or refused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const smoke = require('./site-artifact-smoke.playwright.cjs');
const { SITE_ROUTES } = require('../../ci/site-artifact.cjs');
const { walkProblems } = require('../lib/keyboard-walk.cjs');
const operability = require('../lib/keyboard-operability.cjs');

const ROUTES = Object.freeze([...SITE_ROUTES, '/studio/optimiser', '/accessibilite']);
const VIEWPORT = Object.freeze({ width: 1440, height: 900 });
const PHONE_VIEWPORT = Object.freeze({ width: 390, height: 844 });
// A frame that settles its scripts after load needs a quiet period.
const FRAME_QUIET_MS = 500;

/**
 * Page function: the focused element of the page's own document, with what
 * the walk judges. A focused frame is reported as the frame.
 */
async function focusedStop() {
	const element = document.activeElement;
	if (!element || element === document.body || element === document.documentElement) return null;
	const settle = () =>
		new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
	// A focus can move its element a few frames late (the skip link slides in
	// from above the window): its box is read once it holds still.
	// A transition, however short, ends on a later frame: wait for one first.
	await new Promise((resolve) => setTimeout(resolve, 50));
	let box = element.getBoundingClientRect();
	for (let frame = 0; frame < 10; frame++) {
		await settle();
		const next = element.getBoundingClientRect();
		if (next.top === box.top && next.left === box.left && next.height === box.height) break;
		box = next;
	}
	// A stable mark per element: the live demos add and remove elements while
	// the walk runs, so a place in the document is not an identity. The order
	// is read again from the marks once the walk is over (orderStops).
	if (!element.hasAttribute('data-walk-mark'))
		element.setAttribute(
			'data-walk-mark',
			String((window.__walkMarks = (window.__walkMarks || 0) + 1))
		);
	const mark = element.getAttribute('data-walk-mark');
	const order = Array.from(document.querySelectorAll('*')).indexOf(element);
	const label = (
		element.getAttribute('aria-label') ||
		element.getAttribute('title') ||
		element.textContent ||
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
	// The focus indicator may be drawn on the element, its parent, a sibling
	// (a visually hidden input ringed on its label) or a label of it.
	const neighbours = [
		element,
		element.parentElement,
		element.previousElementSibling,
		element.nextElementSibling,
		...(element.labels ? [...element.labels] : [])
	].filter(Boolean);
	const look = () =>
		neighbours
			.map((node) => {
				const css = getComputedStyle(node);
				return [
					css.outlineStyle === 'none' || parseFloat(css.outlineWidth) === 0
						? 'none'
						: css.outlineStyle + css.outlineWidth + css.outlineColor,
					css.boxShadow,
					css.borderColor,
					css.backgroundColor,
					css.color,
					css.textDecorationLine
				].join('|');
			})
			.join('#');
	const focused = look();
	let indicated = true;
	// A frame draws its own ring inside; its walk is the Studio gate's.
	if (element.tagName !== 'IFRAME') {
		// The unfocused look is read once a transition back would be over, and
		// a second time if it still matches: a busy page can paint late.
		element.blur();
		indicated = false;
		for (let attempt = 0; attempt < 3 && !indicated; attempt++) {
			await new Promise((resolve) => setTimeout(resolve, 50));
			await settle();
			indicated = focused !== look();
		}
		element.focus({ preventScroll: true });
		await settle();
	}
	// Not hidden (WCAG 2.4.11): one of five points of the element's box shows
	// the element itself, not the sticky header or another box over it.
	let obscured = false;
	let coveredBy = '';
	if (visible) {
		const inset = Math.min(4, rect.width / 4, rect.height / 4);
		const points = [
			[rect.left + rect.width / 2, rect.top + rect.height / 2],
			[rect.left + inset, rect.top + inset],
			[rect.right - inset, rect.top + inset],
			[rect.left + inset, rect.bottom - inset],
			[rect.right - inset, rect.bottom - inset]
		];
		const hits = points.map(([x, y]) => document.elementFromPoint(x, y));
		obscured = !hits.some(
			(hit) =>
				hit !== null &&
				(hit === element ||
					element.contains(hit) ||
					hit.contains(element) ||
					(element.labels && [...element.labels].some((l) => l === hit || l.contains(hit))))
		);
		if (obscured && hits[0])
			coveredBy =
				hits[0].tagName.toLowerCase() +
				(hits[0].id ? '#' + hits[0].id : '') +
				[...hits[0].classList]
					.slice(0, 2)
					.map((c) => '.' + c)
					.join('');
	}
	const name = `${element.tagName.toLowerCase()}${element.id ? '#' + element.id : ''}`;
	return {
		id: `${name}@${mark} «${label}»`,
		key: `${name} «${label}»`,
		mark,
		order,
		visible,
		tabindex: element.tabIndex,
		indicated,
		obscured,
		coveredBy
	};
}

/**
 * Presses one key until the focus leaves the page's own document. The keys
 * pressed while a frame holds the focus walk the frame: they are counted as
 * the frame's one stop, up to the frame's element count.
 * @returns {Promise<{stops: object[], left: boolean}>}
 */
async function walk(page, key) {
	await page.evaluate(() => {
		if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
		window.scrollTo(0, 0);
	});
	const stops = [];
	const seen = new Set();
	// Every stop is an element: a walk that neither leaves nor meets a stop
	// twice ends within the document's elements, so their count bounds it.
	const elements = await page.evaluate(() => document.getElementsByTagName('*').length);
	for (let step = 0; step <= elements; step++) {
		await page.keyboard.press(key);
		const stop = await page.evaluate(focusedStop);
		if (stop === null) {
			if (stops.length > 0) return { stops, left: true };
			continue;
		}
		stops.push(stop);
		if (seen.has(stop.id)) break;
		seen.add(stop.id);
	}
	return { stops, left: false };
}

/** Read each stop's place in the document once the walk is over, from its mark. */
async function orderStops(page, stops) {
	const orders = await page.evaluate(
		(marks) => {
			const all = Array.from(document.querySelectorAll('*'));
			return marks.map((mark) => all.indexOf(document.querySelector(`[data-walk-mark="${mark}"]`)));
		},
		stops.map((stop) => stop.mark)
	);
	stops.forEach((stop, index) => (stop.order = orders[index]));
}

/**
 * The problems of the page's own Tab walk, forward and back. The frames are
 * made inert for the walk: their controls are the Studio and app window
 * gates' walks, and thousands of Tab presses through a framed Comparer would
 * only repeat them.
 */
async function walkPage(page) {
	const frames = await page.evaluate(() => {
		const live = [...document.querySelectorAll('iframe')].filter((frame) => !frame.inert);
		for (const frame of live) frame.inert = true;
		return live.length;
	});
	let forward;
	let backward;
	try {
		forward = await walk(page, 'Tab');
		backward = await walk(page, 'Shift+Tab');
	} finally {
		if (frames)
			await page.evaluate(() => {
				for (const frame of document.querySelectorAll('iframe')) frame.inert = false;
			});
	}
	await orderStops(page, forward.stops);
	await orderStops(page, backward.stops);
	const problems = walkProblems({
		forward: forward.stops,
		forwardLeft: forward.left,
		backward: backward.stops,
		backwardLeft: backward.left
	});
	const said = new Set();
	for (const stop of forward.stops) {
		if (said.has(stop.key)) continue;
		if (!stop.indicated) problems.push(stop.id + ' shows no focus indicator');
		if (stop.obscured)
			problems.push(`${stop.id} is hidden under ${stop.coveredBy || 'another box'} when focused`);
		if (!stop.indicated || stop.obscured) said.add(stop.key);
	}
	return { problems, stops: forward.stops.length };
}

/** The operability problems of the page's own document (its frames have their own gates). */
async function operabilityOf(page) {
	const rows = await page.evaluate(operability.collectOperability, {
		pointer: operability.POINTER_EVENTS,
		keys: operability.KEY_EVENTS,
		roles: operability.INTERACTIVE_ROLES
	});
	return operability.operabilityProblems(rows);
}

/** Drives each disclosure, popup and composite widget of one document from the keyboard. */
async function exerciseWidgets(frame, page) {
	const widgets = await frame.evaluate(operability.collectWidgets);
	const results = [];
	const state = (selector) =>
		frame.evaluate((target) => {
			const element = document.querySelector(target);
			const controls = element.getAttribute('aria-controls');
			const controlled = controls ? document.getElementById(controls) : null;
			return {
				expanded: element.getAttribute('aria-expanded'),
				checked: element.checked === true,
				dialog: Boolean(document.querySelector('dialog[open]')),
				shown: controlled
					? controlled.getClientRects().length > 0 &&
						getComputedStyle(controlled).visibility !== 'hidden'
					: null,
				focused: document.activeElement === element,
				name:
					element.tagName.toLowerCase() +
					(element.id ? '#' + element.id : '') +
					' «' +
					(element.getAttribute('aria-label') || element.textContent || '')
						.replace(/\s+/g, ' ')
						.trim()
						.slice(0, 40) +
					'»'
			};
		}, selector);
	const open = (before, after) =>
		(before.expanded !== 'true' && after.expanded === 'true') ||
		(!before.dialog && after.dialog) ||
		(before.shown === false && after.shown === true);
	for (const disclosure of widgets.disclosures) {
		const locator = frame.locator(disclosure.selector);
		await locator.focus();
		const before = await state(disclosure.selector);
		// Only a closed control is probed: an open one is closed by its own walk.
		if (before.expanded === 'true' || before.dialog) continue;
		await page.keyboard.press(disclosure.checkbox ? 'Space' : 'Enter');
		const after = await state(disclosure.selector);
		const result = {
			kind: 'disclosure',
			id: before.name,
			popup: disclosure.popup,
			opened: open(before, after)
		};
		if (result.opened && disclosure.popup) {
			await page.keyboard.press('Escape');
			const closed = await state(disclosure.selector);
			result.closed = closed.expanded !== 'true' && !closed.dialog;
			result.focusBack = closed.focused;
		} else if (result.opened) {
			await locator.focus();
			await page.keyboard.press(disclosure.checkbox ? 'Space' : 'Enter');
			const closed = await state(disclosure.selector);
			result.closed = !open(before, closed) && closed.expanded !== 'true';
		}
		// Leave nothing open for the next probe.
		if (result.opened && !result.closed) await page.keyboard.press('Escape');
		results.push(result);
	}
	for (const composite of widgets.composites) {
		const target = composite.start || composite.selector;
		await frame.locator(target).focus();
		const where = () =>
			frame.evaluate((selector) => {
				const widget = document.querySelector(selector);
				return (
					(widget.getAttribute('aria-activedescendant') || '') +
					'|' +
					(widget.contains(document.activeElement)
						? [...widget.querySelectorAll('*')].indexOf(document.activeElement)
						: -1)
				);
			}, composite.selector);
		const before = await where();
		await page.keyboard.press(composite.vertical ? 'ArrowDown' : 'ArrowRight');
		const after = await where();
		const inside = !after.endsWith('|-1') || after.split('|')[0] !== '';
		results.push({
			kind: 'composite',
			id: `[role="${composite.role}"] ${composite.selector}`,
			moved: inside && after !== before
		});
		await page.keyboard.press(composite.vertical ? 'ArrowUp' : 'ArrowLeft');
	}
	return operability.widgetProblems(results);
}

/** Opens one route and waits until its frames and requests settle. */
async function openRoute(context, inflight, origin, basePath, route) {
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.emulateMedia({ reducedMotion: 'reduce' });
	const response = await page.goto(origin + basePath + route, { waitUntil: 'networkidle' });
	assert.ok(response?.ok(), 'Route refused: ' + route);
	await page.locator('main').first().waitFor({ state: 'visible' });
	await smoke.settleFrames(page);
	// A request of a page already closed never finishes: the frames the walk
	// scrolled into view on the previous page would hold the set forever.
	for (const request of inflight) if (request.frame().page().isClosed()) inflight.delete(request);
	await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
	// Lazy frames load when scrolled to: loaded during the walk, they grew the
	// page under a focused element and moved it out of the window. They are
	// all loaded first, from the bottom of the page.
	await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
	await smoke.settleFrames(page);
	await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
	await page.evaluate(() => window.scrollTo(0, 0));
	return { page, errors };
}

async function withContext(browser, origin, viewport, visit) {
	const context = await browser.newContext({ serviceWorkers: 'block', viewport: { ...viewport } });
	try {
		context.setDefaultTimeout(30000);
		await context.addInitScript(operability.instrumentListeners, {
			pointer: operability.POINTER_EVENTS,
			keys: operability.KEY_EVENTS
		});
		const inflight = new Set();
		context.on('request', (request) => {
			if (new URL(request.url()).origin === origin) inflight.add(request);
		});
		for (const settled of ['requestfinished', 'requestfailed'])
			context.on(settled, (request) => inflight.delete(request));
		await context.route('**/*', async (route) => {
			const url = route.request().url();
			if (new URL(url).origin === origin) return route.continue();
			const fixture = smoke.githubFixture(url);
			if (fixture !== null)
				return route.fulfill({
					status: 200,
					contentType: 'application/json',
					headers: { 'Access-Control-Allow-Origin': '*' },
					body: JSON.stringify(fixture)
				});
			const external = smoke.authoredExternalFixture(url);
			if (external !== null) return route.fulfill({ status: 200, ...external });
			return route.abort();
		});
		await visit(context, inflight);
	} finally {
		await context.close();
	}
}

/**
 * Checks every route; returns the problems per route (empty arrays pass).
 * @returns {Promise<Map<string, string[]>>}
 */
async function checkSite(site, basePath, chromium, routes = ROUTES) {
	const server = http.createServer((request, response) =>
		smoke.serveRequest(site, basePath, request, response, [])
	);
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', resolve);
	});
	const results = new Map();
	try {
		const origin = 'http://127.0.0.1:' + server.address().port;
		await smoke.withBrowser(chromium, async (browser) => {
			await withContext(browser, origin, VIEWPORT, async (context, inflight) => {
				for (const route of routes) {
					const { page, errors } = await openRoute(context, inflight, origin, basePath, route);
					try {
						// Nothing takes the focus while the page loads: a frame that
						// focused its own field pulled the reader down the page
						// (WCAG 2.4.3, 3.2.1).
						const moved = await page.evaluate(() =>
							document.activeElement && document.activeElement !== document.body
								? document.activeElement.tagName.toLowerCase() +
									(document.activeElement.id ? '#' + document.activeElement.id : '')
								: null
						);
						const problems = moved ? [`the page moves the focus to ${moved} while it loads`] : [];
						problems.push(...(await operabilityOf(page)));
						const walked = await walkPage(page);
						problems.push(...walked.problems);
						problems.push(...(await exerciseWidgets(page.mainFrame(), page)));
						problems.push(...errors.map((error) => 'page error: ' + error));
						results.set(route, problems);
						console.log(`  ${route}: ${walked.stops} stops, ${problems.length} problem(s)`);
						for (const problem of problems) console.log('    ' + problem);
					} finally {
						await page.close();
					}
				}
			});
			// The narrow-screen menu and its button exist only on a phone.
			await withContext(browser, origin, PHONE_VIEWPORT, async (context, inflight) => {
				const route = '/';
				const { page } = await openRoute(context, inflight, origin, basePath, route);
				try {
					const problems = await operabilityOf(page);
					problems.push(...(await exerciseWidgets(page.mainFrame(), page)));
					results.set(route + ' (phone)', problems);
					console.log(`  ${route} (phone): ${problems.length} problem(s)`);
				} finally {
					await page.close();
				}
			});
		});
	} finally {
		await new Promise((resolve, reject) =>
			server.close((error) => (error ? reject(error) : resolve()))
		);
	}
	return results;
}

async function main(args = process.argv.slice(2)) {
	const flags = args.filter((arg) => arg.startsWith('--'));
	const positional = args.filter((arg) => !arg.startsWith('--'));
	assert.equal(positional.length, 2, 'Expected site-directory base-path (empty or /dev)');
	const [site, basePath] = [path.resolve(positional[0]), positional[1]];
	assert.ok(basePath === '' || basePath === '/dev', 'Unknown site base path');
	for (const flag of flags) assert.ok(/^--only=/.test(flag), 'Unknown flag ' + flag);
	const only = flags.find((flag) => flag.startsWith('--only='));
	const routes = only ? only.slice('--only='.length).split(',') : ROUTES;
	for (const route of routes) assert.ok(ROUTES.includes(route), 'Unknown route ' + route);
	const results = await checkSite(site, basePath, require('playwright').chromium, routes);
	let total = 0;
	for (const problems of results.values()) total += problems.length;
	assert.equal(
		total,
		0,
		total +
			' keyboard operability problem(s): everything a mouse can use, the keyboard must use too'
	);
	console.log(`Keyboard operability: ${results.size} page checks, no mouse-only control`);
}

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exit(1);
	});

module.exports = { ROUTES, checkSite, operabilityOf, exerciseWidgets, walkPage, focusedStop };
