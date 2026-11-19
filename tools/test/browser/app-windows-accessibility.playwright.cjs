// tools/test/browser/app-windows-accessibility.playwright.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Accessibility Ratchet
 * DESCRIPTION:
 * Opens every WebView window of Ergopti+ (the pages under
 * static/ergopti_plus/_shared/ui/ that a driver shows in its own window, not
 * the Studio pages the site frames) in headless Chromium, from a loopback
 * server that serves static/ as the hosts' virtual hosts do. A fake host
 * answers the page's bridge messages and fills it with fixture data
 * (app-windows-fixtures.cjs), so the scan sees the window as a user does.
 * Each window, in each of its fixture states, is then:
 * 1. scanned by axe-core (WCAG 2.0, 2.1 and 2.2, levels A and AA) in the light
 *    and the dark colour schemes;
 * 2. walked with Tab to the end and back with Shift+Tab (WCAG 2.1.2 no
 *    keyboard trap, 2.4.3 focus order, 2.4.7 focus visible), every stop
 *    showing a focus indicator of its own;
 * 3. read as an outline (heading-landmarks.cjs): one h1, no skipped heading
 *    level, one main landmark, every other landmark named.
 * 4. searched for an unresolved locale key in any visible text or accessible
 *    name (lib/raw-locale-keys.cjs), which fails the run outright.
 * Every axe rule's node count and every window's walk problems are counted
 * and compared with the committed baseline beside this file: a new row or a
 * higher count fails, so the violations can only go down. The maintainer
 * asked for a totally accessible project on 2026-11-16 (TODO « Full
 * accessibility »).
 *
 * The page posts over the Windows bridge (window.chrome.webview) by default;
 * --bridge=webkit posts over window.webkit.messageHandlers instead, the
 * macOS and Linux hosts' bridge, and must give the same counts.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { collectOutline, outlineProblems } = require('../lib/heading-landmarks.cjs');
const { walkProblems } = require('../lib/keyboard-walk.cjs');
const { catalogueShape, pageRawKeys } = require('../lib/raw-locale-keys.cjs');
const { WINDOWS } = require('./app-windows-fixtures.cjs');

// --root=dir serves another copy of static/ (an older commit's, to prove a fix
// by scanning the code it replaced); the fixtures and the baseline stay these.
const ROOT_FLAG = process.argv.find((arg) => arg.startsWith('--root='));
const STATIC_ROOT = ROOT_FLAG
	? path.resolve(ROOT_FLAG.slice('--root='.length))
	: path.resolve(__dirname, '..', '..', '..', 'static');
const UI = '/ergopti_plus/_shared/ui/';
const MANIFEST = JSON.parse(
	fs.readFileSync(path.join(STATIC_ROOT, 'ergopti_plus', '_shared', 'ui', 'apps.manifest.json'))
);
const BASELINE_PATH = path.join(__dirname, 'app-windows-accessibility-baseline.json');
// What a raw locale key looks like on screen (the catalogue's keys and namespaces).
const RAW_KEY_SHAPE = catalogueShape();
const COLOR_SCHEMES = Object.freeze(['light', 'dark']);
const BRIDGES = Object.freeze(['windows', 'webkit']);
const WCAG_TAGS = Object.freeze([
	'wcag2a',
	'wcag2aa',
	'wcag21a',
	'wcag21aa',
	'wcag22a',
	'wcag22aa'
]);
// The rule name under which a window's keyboard-walk problems are counted.
const WALK_RULE = 'keyboard-walk';
// The rule name under which a window's heading and landmark problems are counted.
const OUTLINE_RULE = 'heading-landmarks';
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.mjs': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json',
	'.svg': 'image/svg+xml',
	'.png': 'image/png',
	'.woff2': 'font/woff2',
	'.toml': 'text/plain'
};

/**
 * Serves static/ read-only on loopback, as the hosts' virtual hosts serve a window.
 * @param {number} port - 0 for any free port.
 */
function serve(port) {
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
		server.listen(port, '127.0.0.1', () => resolve(server));
	});
}

/**
 * The fake host, run in the page before its own scripts: the seed the real
 * hosts prepend (locale), the bridge of one driver family, and a message log.
 * A fixture's host function, when it has one, answers each message the page
 * posts, as the native host does with ExecuteScript / evaluateJavaScript.
 * @param {{bridge: string, family: string, locale: string, host: string|null}} seed
 */
function installFakeHost(seed) {
	window._i18n_locale = seed.locale;
	window.__hostMessages = [];
	// The fixture's answer, compiled from its source in the page's own realm.
	const answer = seed.host ? (0, eval)('(' + seed.host + ')') : null;
	const receive = (raw) => {
		let message = raw;
		if (typeof raw === 'string')
			try {
				message = JSON.parse(raw);
			} catch (_) {
				message = raw;
			}
		window.__hostMessages.push(message);
		if (answer) setTimeout(() => answer(message), 0);
	};
	if (seed.family === 'windows')
		window.chrome = {
			webview: {
				postMessage: receive,
				addEventListener() {},
				removeEventListener() {}
			}
		};
	else
		window.webkit = {
			messageHandlers: {
				[seed.bridge]: { postMessage: (payload) => receive(JSON.parse(JSON.stringify(payload))) }
			}
		};
}

/**
 * Describes the focused element, or null when the focus is outside the
 * window's content. Also reads whether the element shows a focus indicator:
 * its outline, shadow, border, background or underline while focused,
 * compared with the same element blurred (the focus is put back at once, and
 * stays keyboard-visible). Each read waits two frames: under reduced motion
 * theme.css still runs every transition for 0.01 ms, and a read in the same
 * frame as the focus change sees the start value (an outline 0 px wide).
 */
async function focusedStop() {
	const element = document.activeElement;
	if (!element || element === document.body || element === document.documentElement) return null;
	const settle = () =>
		new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
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
	await settle();
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
	const look = (css) =>
		[
			css.outlineStyle === 'none' || parseFloat(css.outlineWidth) === 0
				? 'none'
				: css.outlineStyle + css.outlineWidth + css.outlineColor,
			css.boxShadow,
			css.borderColor,
			css.backgroundColor,
			css.textDecorationLine
		].join('|');
	// A ring drawn on the wrapper (:focus-within, the action picker's search
	// bar) is the field's indicator too.
	const ring = element.parentElement;
	const around = () => (ring ? '#' + look(getComputedStyle(ring)) : '');
	// A focus that scrolls its element into view can paint its ring a few
	// frames late (a scrolling table box): the focused look is read until it
	// shows a ring, for at most ten frames.
	let focused = look(style) + around();
	for (let frame = 0; frame < 10 && focused.startsWith('none|none|'); frame++) {
		await settle();
		focused = look(getComputedStyle(element)) + around();
	}
	// A date or time field takes one Tab per segment while it stays the active
	// element: blurring it would send the focus back to its first segment and
	// loop the walk, so its indicator is read from its focused look alone.
	const segmented = /^(date|time|datetime-local|month|week)$/.test(element.type || '');
	let indicated = !focused.startsWith('none|none|');
	if (!segmented) {
		element.blur();
		await settle();
		indicated = focused !== look(getComputedStyle(element)) + around();
		element.focus();
		await settle();
	}
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
 * Presses one key until the focus leaves the window's content.
 * @returns {Promise<{stops: object[], left: boolean}>}
 */
async function walk(page, key) {
	// The walk starts from the matching end of the document whatever a state
	// clicked: a focused element removed at once leaves the browser's
	// sequential focus starting point where it stood.
	await page.evaluate((atEnd) => {
		const mark = document.createElement('span');
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
		// The next segment of the same date field is the same stop.
		if (stops.length && stops[stops.length - 1].id === stop.id) continue;
		stops.push(stop);
		// A stop met twice before the focus left: the focus is held.
		if (seen.has(stop.id)) break;
		seen.add(stop.id);
	}
	return { stops, left: false };
}

/**
 * Walks the window both ways; the problems of the walk and every stop
 * without a focus indicator of its own.
 */
async function walkWindow(page) {
	const forward = await walk(page, 'Tab');
	const backward = await walk(page, 'Shift+Tab');
	const problems = walkProblems({
		forward: forward.stops,
		forwardLeft: forward.left,
		backward: backward.stops,
		backwardLeft: backward.left
	});
	const unmarked = new Set();
	for (const stop of forward.stops)
		if (!stop.indicated && !unmarked.has(stop.key)) {
			unmarked.add(stop.key);
			problems.push(stop.id + ' shows no focus indicator');
		}
	return { problems, stops: forward.stops.length };
}

/** Runs axe on the window and returns its violations as counted rows. */
async function scanPage(page, axeSource) {
	await page.evaluate(axeSource);
	return page.evaluate(async (tags) => {
		const result = await window.axe.run(document, {
			runOnly: { type: 'tag', values: tags },
			resultTypes: ['violations'],
			iframes: false
		});
		return result.violations.map((violation) => ({
			rule: violation.id,
			impact: violation.impact,
			help: violation.help,
			nodes: violation.nodes.length,
			targets: violation.nodes.slice(0, 5).map((node) => node.target.join(' '))
		}));
	}, WCAG_TAGS);
}

/**
 * Opens one window with its fake host in one colour scheme, fills it, and
 * returns the page with the errors seen so far.
 */
async function openWindow(browser, origin, target, scheme, family) {
	// A pane with no window of its own (the release notes inside the Windows
	// update prompt) states its size in the fixture.
	const app = target.size || MANIFEST.apps[target.id];
	assert.ok(app, 'Unknown app window: ' + target.id);
	const context = await browser.newContext({
		viewport: { width: app.width, height: app.height },
		colorScheme: scheme,
		reducedMotion: 'reduce'
	});
	context.setDefaultTimeout(30000);
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push('page error: ' + error.message));
	page.on('request', (request) => {
		const url = request.url();
		if (!url.startsWith(origin + '/') && !url.startsWith('blob:') && !url.startsWith('data:'))
			errors.push('unexpected request: ' + url);
	});
	page.on('dialog', (dialog) => {
		errors.push('native dialog: ' + dialog.message());
		dialog.dismiss().catch(() => {});
	});
	await context.route(
		(url) => !url.href.startsWith(origin + '/'),
		(route) => route.abort()
	);
	await page.addInitScript(installFakeHost, {
		bridge: target.bridge,
		family,
		locale: 'fr',
		host: target.host ? target.host.toString() : null
	});
	if (target.seed) await page.addInitScript(target.seed.script, target.seed.arg);
	await page.goto(origin + UI + target.id + '/index.html');
	if (target.fill) await target.fill(page);
	await page.locator(target.ready).first().waitFor({ state: 'visible' });
	await page.waitForFunction(() => !document.querySelector('[aria-busy="true"]'));
	return { context, page, errors };
}

/** The states of a window: the filled window, then each fixture state. */
function statesOf(target) {
	return [{ name: 'filled', enter: null }, ...(target.states || [])];
}

/**
 * Scans and walks every window in every state and scheme.
 * @returns {Promise<Array<{window: string, scheme: string, state: string, rule: string, nodes: number}>>}
 */
async function auditWindows(chromium, windows, family, port) {
	const axeSource = fs.readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8');
	const server = await serve(port);
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch();
	const findings = [];
	try {
		for (const target of windows)
			for (const state of statesOf(target))
				for (const scheme of COLOR_SCHEMES) {
					const { context, page, errors } = await openWindow(
						browser,
						origin,
						target,
						scheme,
						family
					);
					try {
						if (state.enter) await state.enter(page);
						for (const violation of await scanPage(page, axeSource))
							findings.push({ window: target.id, scheme, state: state.name, ...violation });
						// The walk and the texts do not depend on the colours: once per state.
						if (scheme === 'light') {
							// An unresolved locale key read as a name is no name at all: a
							// window that shows one fails outright, outside the ratchet.
							assert.deepEqual(
								await page.evaluate(pageRawKeys, RAW_KEY_SHAPE),
								[],
								`${target.id} (${state.name}) shows raw locale keys`
							);
							const { problems, stops } = await walkWindow(page);
							if (problems.length)
								findings.push({
									window: target.id,
									scheme,
									state: state.name,
									rule: WALK_RULE,
									impact: 'serious',
									help: 'Tab and Shift+Tab walk',
									nodes: problems.length,
									targets: problems
								});
							assert.ok(stops >= 1, target.id + ' (' + state.name + ') offers no keyboard stop');
							const outline = outlineProblems(await page.evaluate(collectOutline));
							if (outline.length)
								findings.push({
									window: target.id,
									scheme,
									state: state.name,
									rule: OUTLINE_RULE,
									impact: 'moderate',
									help: 'Heading order and landmarks',
									nodes: outline.length,
									targets: outline
								});
							console.log(`  ${target.id} (${state.name}): ${stops} stops`);
						}
						assert.deepEqual(errors, [], target.id + ' (' + state.name + ', ' + scheme + ')');
					} finally {
						await context.close();
					}
				}
	} finally {
		await browser.close();
		await new Promise((resolve) => server.close(resolve));
	}
	return findings;
}

/**
 * Key of one counted row.
 * @param {{window: string, scheme: string, state: string, rule: string}} row
 * @returns {string}
 */
function rowKey(row) {
	return [row.window, row.scheme, row.state, row.rule].join(' | ');
}

/**
 * Turn the findings into the baseline shape: key to number of nodes.
 * @returns {Object<string, number>} Sorted by key so the file diff stays readable.
 */
function countsOf(findings) {
	const counts = {};
	for (const finding of findings) counts[rowKey(finding)] = finding.nodes;
	return Object.fromEntries(Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)));
}

/**
 * Compare the measured counts with the baseline.
 * @returns {{regressions: string[], improvements: string[]}}
 */
function compareWithBaseline(current, baseline) {
	const regressions = [];
	const improvements = [];
	for (const [key, nodes] of Object.entries(current)) {
		const allowed = Object.hasOwn(baseline, key) ? baseline[key] : 0;
		if (nodes > allowed) regressions.push(key + ': ' + nodes + ' node(s), baseline ' + allowed);
		else if (nodes < allowed) improvements.push(key + ': ' + nodes + ' < ' + allowed);
	}
	for (const [key, allowed] of Object.entries(baseline))
		if (!Object.hasOwn(current, key)) improvements.push(key + ': 0 < ' + allowed);
	return { regressions, improvements };
}

/**
 * Read the committed baseline; a missing or malformed file is an error, not
 * an empty baseline, so the gate cannot pass by losing its reference.
 * @returns {Object<string, number>}
 */
function readBaseline() {
	const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
	assert.ok(baseline && typeof baseline === 'object' && !Array.isArray(baseline), 'Baseline shape');
	const ids = new Set(WINDOWS.map((target) => target.id));
	for (const [key, nodes] of Object.entries(baseline)) {
		const parts = key.split(' | ');
		assert.equal(parts.length, 4, 'Baseline key: ' + key);
		assert.ok(ids.has(parts[0]), 'Baseline window not audited: ' + key);
		assert.ok(COLOR_SCHEMES.includes(parts[1]), 'Baseline scheme: ' + key);
		assert.ok(Number.isSafeInteger(nodes) && nodes > 0, 'Baseline count: ' + key);
	}
	return baseline;
}

/**
 * Usage: [--bridge=windows|webkit] [--only=id[,id]] [--update-baseline]
 * [--report=file.json] [--port=n] [--root=static-dir]. The server takes any free port unless
 * --port names one. --only audits a subset while fixing a window and
 * prints every finding without comparing.
 */
async function main(args = process.argv.slice(2)) {
	for (const flag of args)
		assert.ok(
			flag === '--update-baseline' || /^--(report|only|bridge|port|root)=/.test(flag),
			'Unknown argument ' + flag
		);
	const value = (name) => {
		const flag = args.find((arg) => arg.startsWith('--' + name + '='));
		return flag ? flag.slice(name.length + 3) : null;
	};
	const family = value('bridge') || 'windows';
	assert.ok(BRIDGES.includes(family), 'Unknown bridge ' + family);
	const only = value('only');
	const ids = only ? only.split(',') : null;
	for (const id of ids || [])
		assert.ok(
			WINDOWS.some((target) => target.id === id),
			'Unknown window ' + id
		);
	assert.ok(
		!(only && args.includes('--update-baseline')),
		'A partial scan cannot set the baseline'
	);
	assert.ok(
		!(ROOT_FLAG && args.includes('--update-baseline')),
		'Another tree cannot set the baseline'
	);
	const windows = ids ? WINDOWS.filter((target) => ids.includes(target.id)) : WINDOWS;
	const port = Number(value('port') || 0);
	assert.ok(Number.isSafeInteger(port) && port >= 0 && port < 65536, 'Bad port');
	const findings = await auditWindows(require('playwright').chromium, windows, family, port);
	const report = value('report');
	if (report) fs.writeFileSync(report, JSON.stringify(findings, null, '\t') + '\n');
	const current = countsOf(findings);
	const total = Object.values(current).reduce((sum, nodes) => sum + nodes, 0);
	if (only) {
		for (const finding of findings)
			console.log(
				'  ' +
					rowKey(finding) +
					' [' +
					finding.impact +
					'] ' +
					finding.nodes +
					': ' +
					finding.targets.join(', ')
			);
		console.log('App windows accessibility: ' + total + ' node(s) in ' + ids.join(', ') + '.');
		return;
	}
	if (args.includes('--update-baseline')) {
		fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, '\t') + '\n');
		console.log('App windows accessibility: baseline written (' + total + ' node(s)).');
		return;
	}
	const { regressions, improvements } = compareWithBaseline(current, readBaseline());
	if (improvements.length)
		console.log(
			'App windows accessibility: fewer violations than the baseline; lower it with --update-baseline:\n  ' +
				improvements.join('\n  ')
		);
	assert.deepEqual(regressions, [], 'New accessibility violations (the ratchet only goes down)');
	console.log(
		`App windows accessibility: ${windows.length} windows, ${total} node(s), within the baseline, ` +
			`PASS in Chromium over the ${family} bridge.`
	);
}

module.exports = {
	BASELINE_PATH,
	COLOR_SCHEMES,
	WALK_RULE,
	OUTLINE_RULE,
	rowKey,
	countsOf,
	compareWithBaseline,
	readBaseline,
	main
};
if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
