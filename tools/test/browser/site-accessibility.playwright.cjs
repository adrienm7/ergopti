// tools/test/browser/site-accessibility.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Site Accessibility Ratchet
 * DESCRIPTION:
 * Runs axe-core (WCAG 2.0, 2.1 and 2.2, levels A and AA) on every page of a
 * built static site and inside every Ergopti Studio frame it embeds, in the
 * light and the dark colour schemes, in headless Chromium. Each violation is
 * counted per page, scheme, frame and rule, and compared with the committed
 * baseline: a new rule or a higher count fails the gate, so the number of
 * violations can only go down. A lower count asks for the baseline to be
 * lowered (--update-baseline) to lock the improvement in. The maintainer asked
 * for a totally accessible project on 2026-11-16 (TODO « Full accessibility »).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const smoke = require('./site-artifact-smoke.playwright.cjs');
const { SITE_ROUTES } = require('../../ci/site-artifact.cjs');

// Pages audited: every real page of the site, plus the pages the artifact
// smoke list does not carry (the Optimiser tab, the accessibility statement).
const AUDITED_ROUTES = Object.freeze([...SITE_ROUTES, '/studio/optimiser', '/accessibilite']);
const COLOR_SCHEMES = Object.freeze(['light', 'dark']);
// WCAG 2.2 level AA is the target; axe tags each rule with the versions and
// levels it checks.
const WCAG_TAGS = Object.freeze([
	'wcag2a',
	'wcag2aa',
	'wcag21a',
	'wcag21aa',
	'wcag22a',
	'wcag22aa'
]);
const VIEWPORT = Object.freeze({ width: 1440, height: 900 });
const BASELINE_PATH = path.join(__dirname, 'site-accessibility-baseline.json');
// A frame that settles its scripts after load (the Studio pages build their
// keyboards from fetched data) needs a quiet period before the scan.
const FRAME_QUIET_MS = 500;

/**
 * Key of one counted violation row.
 * @param {{route: string, scheme: string, frame: string, rule: string}} row
 * @returns {string}
 */
function rowKey(row) {
	return [row.route, row.scheme, row.frame, row.rule].join(' | ');
}

/**
 * Turn the scan findings into the baseline shape: key to number of nodes.
 * @param {Array<{route: string, scheme: string, frame: string, rule: string, nodes: number}>} findings
 * @returns {Object<string, number>} Sorted by key so the file diff stays readable.
 */
function countsOf(findings) {
	const counts = {};
	for (const finding of findings) counts[rowKey(finding)] = finding.nodes;
	return Object.fromEntries(Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)));
}

/**
 * Compare the measured counts with the baseline.
 * @param {Object<string, number>} current
 * @param {Object<string, number>} baseline
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
 * Read the committed baseline; a missing or malformed file is an error, not an
 * empty baseline, so the gate cannot pass by losing its reference.
 * @returns {Object<string, number>}
 */
function readBaseline() {
	const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
	assert.ok(baseline && typeof baseline === 'object' && !Array.isArray(baseline), 'Baseline shape');
	for (const [key, nodes] of Object.entries(baseline)) {
		assert.equal(key.split(' | ').length, 4, 'Baseline key: ' + key);
		assert.ok(Number.isSafeInteger(nodes) && nodes > 0, 'Baseline count: ' + key);
	}
	return baseline;
}

/**
 * Name of a frame in the findings: « page » for the top document, else the
 * framed file's path inside the site.
 */
function frameName(frame, page, origin, basePath) {
	if (frame === page.mainFrame()) return 'page';
	const url = new URL(frame.url());
	assert.equal(url.origin, origin, 'Audited frame outside the site: ' + frame.url());
	return url.pathname.slice(basePath.length + 1);
}

/** Run axe in one frame, or one element of it, and return its violations as counted rows. */
async function scanFrame(frame, axeSource, selector = null) {
	await frame.evaluate(axeSource);
	return frame.evaluate(
		async ([tags, selector]) => {
			const result = await window.axe.run(selector ? document.querySelector(selector) : document, {
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
		},
		[WCAG_TAGS, selector]
	);
}

/** Load one route in one colour scheme and scan the page and its frames. */
async function scanRoute(context, origin, basePath, route, scheme, inflight, axeSource) {
	const page = await context.newPage();
	try {
		await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
		const response = await page.goto(origin + basePath + route, { waitUntil: 'networkidle' });
		assert.ok(response?.ok(), 'Route refused: ' + route);
		await page.locator('main').first().waitFor({ state: 'visible' });
		await smoke.settleFrames(page);
		await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
		const findings = [];
		for (const frame of page.frames()) {
			if (frame !== page.mainFrame() && (frame.url() === '' || frame.url() === 'about:blank'))
				continue;
			const name = frameName(frame, page, origin, basePath);
			for (const violation of await scanFrame(frame, axeSource))
				findings.push({ route, scheme, frame: name, ...violation });
		}
		return findings;
	} finally {
		await page.close();
	}
}

/**
 * What a scan cannot see: the keyboard reaches the skip link first and opens
 * the narrow-screen menu, the settings dialog has no violation of its own, and
 * a setting reaches the Studio frame, survives a reload and resets.
 */
async function exerciseKeyboardAndSettings(context, origin, basePath, inflight, axeSource) {
	const page = await context.newPage();
	const root = (target) =>
		target.evaluate(() => document.documentElement.getAttribute('data-a11y-contrast'));
	try {
		await page.goto(origin + basePath + '/studio', { waitUntil: 'networkidle' });
		await page.locator('main').first().waitFor({ state: 'visible' });
		await smoke.settleFrames(page);
		await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
		await page.keyboard.press('Tab');
		assert.equal(
			await page.evaluate(() => document.activeElement.classList.contains('skip-link')),
			true,
			'The skip link is the first keyboard stop'
		);
		await page.keyboard.press('Enter');
		assert.equal(await page.evaluate(() => document.activeElement.id), 'contenu');
		await page.click('#a11y-settings-button');
		await page.locator('#a11y-settings').waitFor({ state: 'visible' });
		assert.deepEqual(
			await scanFrame(page.mainFrame(), axeSource, '#a11y-settings'),
			[],
			'The settings dialog has no violation'
		);
		await page.check('#a11y-contrast');
		assert.equal(await root(page), 'high', 'The setting applies to the page');
		const editor = page.frames().find((frame) => frame.url().includes('/layout_editor/'));
		assert.ok(editor, 'The Studio frames the editor');
		await editor.waitForFunction(
			() => document.documentElement.getAttribute('data-a11y-contrast') === 'high'
		);
		await page.reload({ waitUntil: 'networkidle' });
		assert.equal(await root(page), 'high', 'The setting is remembered');
		await page.click('#a11y-settings-button');
		await page.getByRole('button', { name: 'Réinitialiser' }).click();
		assert.equal(await root(page), null, 'Reset removes the setting');
		await page.keyboard.press('Escape');
		// A narrow screen: the menu opens from the keyboard and hides its links when closed.
		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto(origin + basePath + '/', { waitUntil: 'networkidle' });
		const firstLink = page.locator('#menu-pages > a').first();
		assert.equal(await firstLink.isVisible(), false, 'A closed menu hides its links');
		await page.focus('#menu-btn');
		await page.keyboard.press('Space');
		await firstLink.waitFor({ state: 'visible' });
	} finally {
		await page.close();
	}
}

/** Serve the built site on loopback and scan every audited page in Chromium. */
async function scanSite(site, basePath, chromium, routes = AUDITED_ROUTES) {
	const axeSource = fs.readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8');
	// Resource integrity is the artifact smoke and structure gates' job; this
	// scan only answers. The loopback host also makes isDev.js probe absent
	// version.json files (src/lib/js/isDev.js), which must not fail the scan.
	const server = http.createServer((request, response) =>
		smoke.serveRequest(site, basePath, request, response, [])
	);
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', resolve);
	});
	try {
		const origin = 'http://127.0.0.1:' + server.address().port;
		return await smoke.withBrowser(chromium, async (browser) => {
			const context = await browser.newContext({
				serviceWorkers: 'block',
				viewport: { ...VIEWPORT }
			});
			try {
				context.setDefaultTimeout(30000);
				const inflight = new Set();
				context.on('request', (request) => {
					if (new URL(request.url()).origin === origin) inflight.add(request);
				});
				for (const settled of ['requestfinished', 'requestfailed'])
					context.on(settled, (request) => inflight.delete(request));
				// Same inert fixtures as the structure gate: the scan never
				// depends on the network.
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
				const findings = [];
				for (const route of routes)
					for (const scheme of COLOR_SCHEMES)
						findings.push(
							...(await scanRoute(context, origin, basePath, route, scheme, inflight, axeSource))
						);
				await exerciseKeyboardAndSettings(context, origin, basePath, inflight, axeSource);
				return findings;
			} finally {
				await context.close();
			}
		});
	} finally {
		await new Promise((resolve, reject) =>
			server.close((error) => (error ? reject(error) : resolve()))
		);
	}
}

/** Print the per-page totals, the rows a reader acts on. */
function printSummary(findings, routes) {
	const perPage = new Map();
	for (const finding of findings) {
		const key = finding.route + ' (' + finding.scheme + ')';
		perPage.set(key, (perPage.get(key) || 0) + finding.nodes);
	}
	for (const route of routes)
		for (const scheme of COLOR_SCHEMES) {
			const key = route + ' (' + scheme + ')';
			console.log('  ' + key + ': ' + (perPage.get(key) || 0) + ' node(s)');
		}
}

/**
 * Usage: site-directory base-path [--update-baseline] [--report=file.json].
 * The report holds every finding with its impact and first targets, the raw
 * material of docs/audits/accessibility/.
 */
async function main(args = process.argv.slice(2)) {
	const flags = args.filter((arg) => arg.startsWith('--'));
	const positional = args.filter((arg) => !arg.startsWith('--'));
	assert.equal(positional.length, 2, 'Expected site-directory base-path (empty or /dev)');
	const [site, basePath] = [path.resolve(positional[0]), positional[1]];
	assert.ok(basePath === '' || basePath === '/dev', 'Unknown site base path');
	for (const flag of flags)
		assert.ok(
			flag === '--update-baseline' || /^--(report|only)=/.test(flag),
			'Unknown flag ' + flag
		);
	// --only=route[,route] scans a subset while fixing a page; it reports
	// without comparing, since the other pages are not measured.
	const only = flags.find((flag) => flag.startsWith('--only='));
	const routes = only ? only.slice('--only='.length).split(',') : AUDITED_ROUTES;
	for (const route of routes) assert.ok(AUDITED_ROUTES.includes(route), 'Unknown route ' + route);
	assert.ok(
		!(only && flags.includes('--update-baseline')),
		'A partial scan cannot set the baseline'
	);
	const findings = await scanSite(site, basePath, require('playwright').chromium, routes);
	const report = flags.find((flag) => flag.startsWith('--report='));
	if (report)
		fs.writeFileSync(report.slice('--report='.length), JSON.stringify(findings, null, '\t') + '\n');
	const current = countsOf(findings);
	const total = Object.values(current).reduce((sum, nodes) => sum + nodes, 0);
	printSummary(findings, routes);
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
		return;
	}
	if (flags.includes('--update-baseline')) {
		fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, '\t') + '\n');
		console.log('Site accessibility: baseline written (' + total + ' node(s)).');
		return;
	}
	const { regressions, improvements } = compareWithBaseline(current, readBaseline());
	if (improvements.length)
		console.log(
			'Site accessibility: fewer violations than the baseline; lower it with --update-baseline:\n  ' +
				improvements.join('\n  ')
		);
	assert.deepEqual(regressions, [], 'New accessibility violations (the ratchet only goes down)');
	console.log('Site accessibility: ' + total + ' node(s), within the baseline, PASS in Chromium.');
}

module.exports = {
	AUDITED_ROUTES,
	COLOR_SCHEMES,
	WCAG_TAGS,
	BASELINE_PATH,
	rowKey,
	countsOf,
	compareWithBaseline,
	readBaseline,
	scanSite,
	main
};
if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
