// tools/test/browser/site-structure.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Site Structure Browser Regression
 * DESCRIPTION:
 * Drives a built static site in Chromium and WebKit, on desktop and phone
 * viewports, against the structure the maintainer set on 2026-11-14: a short
 * home page presenting the three products, a three-entry header menu with an
 * icon each, the layout version selector only on the Disposition Ergopti
 * pages, the local navigation of each section, Ergopti+ sub-pages that render
 * only their own sections, and every former address (with its anchors)
 * forwarded by a prerendered redirect. Page errors, local HTTP failures and
 * unexpected remote requests fail the gate. CI runs it on the received
 * production site right after the artifact smoke test.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const smoke = require('./site-artifact-smoke.playwright.cjs');

// Header menu: the three products, in the maintainer's order.
const MENU = Object.freeze([
	['disposition', 'Ergopti', '/ergopti'],
	['ergopti-plus', 'Ergopti+', '/ergopti-plus'],
	['studio', 'Studio', '/studio']
]);
// Home page cards: the same products under their full names.
const HOME_CARDS = Object.freeze([
	['disposition', 'Disposition Ergopti', '/ergopti'],
	['ergopti-plus', 'Ergopti+', '/ergopti-plus'],
	['studio', 'Ergopti Studio', '/studio']
]);
// Where the layout version selector must and must not be.
const VERSION_SELECTOR = Object.freeze({
	present: ['/ergopti', '/ergopti/benchmarks'],
	absent: ['/', '/ergopti-plus', '/ergopti-plus/hotstrings', '/studio']
});
// Each Ergopti+ page renders exactly these sections, so a page never pays
// for another one's demos, frames and images.
const ERGOPTI_PLUS_SECTIONS = Object.freeze({
	'/ergopti-plus': ['ep-demo', 'ep-promesses'],
	'/ergopti-plus/presentation': ['ep-pourqui', 'ep-ergopti', 'ep-comparatif'],
	'/ergopti-plus/hotstrings': ['ep-hotstrings', 'ep-perso-hotstrings'],
	'/ergopti-plus/ia': ['ep-ia'],
	'/ergopti-plus/fonctionnalites': ['ep-tapholds', 'ep-raccourcis', 'ep-trackpad', 'ep-metriques'],
	'/ergopti-plus/configuration': ['ep-personnalisation', 'ep-confidentialite'],
	'/ergopti-plus/installation': ['ep-demarrer', 'ep-telecharger'],
	'/ergopti-plus/faq': ['ep-faq']
});
// Former addresses and where each must land, anchors included.
const REDIRECTS = Object.freeze([
	['/editeur', '/studio'],
	['/benchmarks', '/ergopti/benchmarks'],
	['/informations', '/ergopti/informations'],
	['/informations#changelog', '/ergopti/informations#changelog'],
	['/informations/#changelog', '/ergopti/informations#changelog'],
	['/utilisation', '/ergopti/installation'],
	['/utilisation#linux', '/ergopti/installation#linux'],
	['/utilisation#keyboard_emulation', '/ergopti/utilisation#keyboard_emulation'],
	['/#keyboard_frequences', '/ergopti/presentation#keyboard_frequences'],
	['/ergopti-plus#ep-ia', '/ergopti-plus/ia#ep-ia'],
	['/ergopti-plus#ep-telecharger', '/ergopti-plus/installation#ep-telecharger'],
	['/ergopti-plus#ep-faq', '/ergopti-plus/faq#ep-faq']
]);
const DESKTOP_VIEWPORT = Object.freeze({ width: 1440, height: 900 });
const PHONE_VIEWPORT = Object.freeze({ width: 390, height: 844 });

/** Visit a route and wait for the hydrated header. */
async function visit(page, origin, basePath, route) {
	const response = await page.goto(origin + basePath + route, { waitUntil: 'networkidle' });
	assert.ok(response?.ok(), 'Route refused: ' + route);
	await page.locator('#menu-pages').waitFor({ state: 'attached' });
}

/** Header menu: three products in order, each with its icon and the current one marked. */
async function expectMenu(page, current) {
	const entries = await page.locator('#menu-pages > a').evaluateAll((links) =>
		links.map((link) => ({
			product: link.dataset.product,
			title: link.querySelector('.title').textContent.replace(/\s+/g, ''),
			icon: link.querySelector('img.product-icon')?.naturalWidth > 0,
			current: link.getAttribute('aria-current') === 'page'
		}))
	);
	assert.deepEqual(
		entries,
		MENU.map(([product, title]) => ({ product, title, icon: true, current: product === current })),
		'Header menu: three products with icons, current one marked'
	);
}

/** Bounding boxes of the home page cards, after checking their names and targets. */
async function homeCards(page, origin, basePath) {
	const cards = page.locator('#accueil a.product');
	await cards.first().waitFor({ state: 'visible' });
	const rows = await cards.evaluateAll((links) =>
		links.map((link) => ({
			product: link.dataset.product,
			name: link.querySelector('.product-name').textContent.trim(),
			href: link.href,
			icon: link.querySelector('img').naturalWidth > 0,
			box: link.getBoundingClientRect().toJSON()
		}))
	);
	assert.deepEqual(
		rows.map(({ product, name, href, icon }) => ({ product, name, href, icon })),
		HOME_CARDS.map(([product, name, route]) => ({
			product,
			name,
			href: origin + basePath + route,
			icon: true
		})),
		'Home presents the three products in order'
	);
	return rows.map((row) => row.box);
}

/** Home page: the project, its one-line naming and the three product cards. */
async function exerciseHome(page, origin, basePath) {
	await visit(page, origin, basePath, '/');
	assert.equal(await page.locator('h1').first().textContent(), 'Ergopti');
	const naming = await page.locator('.accueil-naming').textContent();
	for (const name of ['Ergopti', 'Disposition Ergopti', 'Ergopti+', 'Ergopti Studio'])
		assert.ok(naming.includes(name), 'Home naming line names ' + name);
	assert.equal(await page.locator('#keyboard_presentation').count(), 0, 'No layout on home');
	await expectMenu(page, undefined);
	const boxes = await homeCards(page, origin, basePath);
	assert.ok(
		boxes.every((box) => Math.abs(box.y - boxes[0].y) < 1),
		'Desktop shows the three product cards on one row'
	);
}

/**
 * Each embedded driver window loads once: hydration once replaced the
 * prerendered (relative) frame address with the client's absolute one, which
 * reloaded every window and cut off its first load.
 */
async function expectSingleFrameLoads(page, origin, basePath, route) {
	const loads = [];
	const record = (request) => {
		if (request.isNavigationRequest() && request.frame() !== page.mainFrame())
			loads.push(request.url());
	};
	page.on('request', record);
	try {
		await visit(page, origin, basePath, route);
		await page.locator('.frame-wrap iframe[src]').first().waitFor({ state: 'attached' });
		await smoke.settleFrames(page);
		// Hydration ran before networkidle; give a late replacement time to show.
		await page.waitForTimeout(500);
	} finally {
		page.off('request', record);
	}
	assert.ok(loads.length > 0, 'The page embeds driver windows: ' + route);
	assert.equal(
		new Set(loads).size,
		loads.length,
		'Each driver window loads once: ' + loads.join(', ')
	);
}

/** Version selector only on the layout pages; section navigation marks the page. */
async function exerciseSections(page, origin, basePath) {
	for (const route of VERSION_SELECTOR.present) {
		await visit(page, origin, basePath, route);
		await page.locator('#version-selection').waitFor({ state: 'visible' });
		await expectMenu(page, 'disposition');
	}
	for (const route of VERSION_SELECTOR.absent) {
		await visit(page, origin, basePath, route);
		assert.equal(await page.locator('#version-selection').count(), 0, 'No selector on ' + route);
	}
	await visit(page, origin, basePath, '/ergopti/benchmarks');
	const current = page.locator('nav.subnav a[aria-current="page"]');
	assert.equal(await current.textContent(), 'Benchmarks');
	await Promise.all([
		page.waitForURL(origin + basePath + '/ergopti/informations'),
		page.locator('nav.subnav a[href$="ergopti/informations"]').click()
	]);
	await page.locator('#changelog').waitFor({ state: 'attached' });
	assert.equal(await current.textContent(), 'Informations');

	for (const [route, ids] of Object.entries(ERGOPTI_PLUS_SECTIONS)) {
		await visit(page, origin, basePath, route);
		await expectMenu(page, 'ergopti-plus');
		const shown = await page
			.locator('section[id^="ep-"]')
			.evaluateAll((sections) => sections.map((section) => section.id));
		assert.deepEqual(shown, ids, 'Ergopti+ page renders only its own sections: ' + route);
		assert.equal(await page.locator('nav.subnav a[aria-current="page"]').count(), 1);
	}
	await expectSingleFrameLoads(page, origin, basePath, '/ergopti-plus/hotstrings');
	// The Ergopti+ version (the release the page resolved) shows on its pages.
	await page.locator('.ep-version', { hasText: /^Ergopti\+ v\d/ }).waitFor();

	await visit(page, origin, basePath, '/studio');
	await expectMenu(page, 'studio');
	assert.equal((await page.locator('h1').first().textContent()).trim(), 'Ergopti Studio');
	assert.equal(await page.title(), 'Ergopti Studio');
}

/** Every former address lands on its new page, anchors included. */
async function exerciseRedirects(page, origin, basePath) {
	for (const [from, to] of REDIRECTS) {
		const target = origin + basePath + to;
		// The redirect replaces the location while the first page is still
		// loading; a long-lived page then sometimes never settled its next
		// navigation, so each former address opens in a page of its own.
		const fresh = await page.context().newPage();
		try {
			await fresh.goto(origin + basePath + from, { waitUntil: 'commit' });
			await fresh.waitForURL(target);
			await fresh.locator('#menu-pages').waitFor({ state: 'attached' });
			assert.equal(fresh.url(), target, 'Former address ' + from);
		} finally {
			await fresh.close();
		}
	}
}

/** Phone: stacked home cards, a folding menu, section tabs inside the screen. */
async function exercisePhone(page, origin, basePath) {
	await page.setViewportSize(PHONE_VIEWPORT);
	try {
		await visit(page, origin, basePath, '/');
		const boxes = await homeCards(page, origin, basePath);
		assert.ok(
			boxes.every(
				(box, index) =>
					Math.abs(box.x - boxes[0].x) < 1 &&
					box.x >= 0 &&
					box.x + box.width <= PHONE_VIEWPORT.width &&
					(index === 0 || box.y > boxes[index - 1].y)
			),
			'Phone stacks the product cards inside the viewport'
		);
		const menuHeight = () => page.locator('#menu').evaluate((menu) => menu.clientHeight);
		assert.equal(await menuHeight(), 0, 'Phone menu starts folded');
		await page.locator('label.menu-icon').click();
		await page.waitForFunction(() => document.getElementById('menu').clientHeight > 0);
		await expectMenu(page, undefined);
		const studio = page.locator('#menu-pages a[data-product="studio"]');
		await studio.waitFor({ state: 'visible' });
		await Promise.all([page.waitForURL(origin + basePath + '/studio'), studio.click()]);

		for (const route of ['/ergopti/informations', '/ergopti-plus/faq']) {
			await visit(page, origin, basePath, route);
			const tab = page.locator('nav.subnav a[aria-current="page"]');
			await tab.waitFor({ state: 'visible' });
			const box = await tab.boundingBox();
			assert.ok(
				box.x >= 0 && box.x + box.width <= PHONE_VIEWPORT.width,
				'Current section tab is in view on a phone: ' + route
			);
			assert.ok(
				(await page.evaluate(() => document.documentElement.scrollWidth)) <= PHONE_VIEWPORT.width,
				'No sideways page scroll on a phone: ' + route
			);
		}
	} finally {
		await page.setViewportSize(DESKTOP_VIEWPORT);
	}
}

/** The whole structure check, in one browser page. */
async function exerciseSiteStructure(page, origin, basePath) {
	await exerciseHome(page, origin, basePath);
	await exerciseSections(page, origin, basePath);
	await exerciseRedirects(page, origin, basePath);
	await exercisePhone(page, origin, basePath);
}

/**
 * GitHub Pages answers /x with a 301 to /x/ when the site has x/index.html and
 * no x.html; the former pages are written that way so both forms reach them.
 * @returns {string|null} The address to redirect to, if any.
 */
function directorySlash(site, basePath, raw) {
	const [pathname, query] = raw.split('?');
	if (
		!pathname.startsWith(basePath + '/') ||
		pathname.endsWith('/') ||
		path.posix.extname(pathname)
	)
		return null;
	const relative = decodeURIComponent(pathname.slice(basePath.length + 1));
	const directory = path.join(site, relative, 'index.html');
	if (!fs.existsSync(directory) || fs.existsSync(path.join(site, relative + '.html'))) return null;
	return pathname + '/' + (query === undefined ? '' : '?' + query);
}

/** Serve the built site on loopback and run the structure checks in one engine. */
async function runEngine(engine, site, basePath) {
	const serverErrors = [];
	const server = http.createServer((request, response) => {
		const slash = directorySlash(site, basePath, request.url);
		if (slash) {
			response.writeHead(301, { Location: slash });
			response.end();
			return;
		}
		smoke.serveRequest(site, basePath, request, response, serverErrors);
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', resolve);
	});
	try {
		const origin = 'http://127.0.0.1:' + server.address().port;
		const errors = [];
		await smoke.withBrowser(engine, async (browser) => {
			const context = await browser.newContext({
				serviceWorkers: 'block',
				viewport: { ...DESKTOP_VIEWPORT }
			});
			try {
				// Listeners and routing sit on the context, so every page the
				// checks open (one per former address) is watched the same way.
				context.setDefaultTimeout(15000);
				context.on('weberror', (error) => errors.push(error.error().message));
				context.on('console', (message) => {
					if (message.type() === 'error') errors.push(message.text());
				});
				context.on('response', (response) => {
					if (new URL(response.url()).origin === origin && response.status() >= 400)
						errors.push(response.url() + ' HTTP ' + response.status());
				});
				// The smoke test's inert fixtures answer the GitHub API, fonts and
				// analytics; any other remote request fails the gate.
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
					errors.push('Unexpected remote request: ' + url);
					return route.abort();
				});
				const page = await context.newPage();
				await exerciseSiteStructure(page, origin, basePath);
			} finally {
				await context.close();
			}
		});
		assert.deepEqual(errors, [], 'Browser or local resource failures');
		assert.deepEqual(serverErrors, [], 'Static site server refused a resource');
	} finally {
		await new Promise((resolve, reject) =>
			server.close((error) => (error ? reject(error) : resolve()))
		);
	}
}

/** Check one built site directory under its declared base path in both CI engines. */
async function main(args = process.argv.slice(2)) {
	assert.equal(args.length, 2, 'Expected site-directory base-path (empty or /dev)');
	const [site, basePath] = [path.resolve(args[0]), args[1]];
	assert.ok(basePath === '' || basePath === '/dev', 'Unknown site base path');
	const playwright = require('playwright');
	for (const name of ['chromium', 'webkit']) await runEngine(playwright[name], site, basePath);
	console.log(
		'Site structure: home, menu, version selector, section pages and former addresses PASS on desktop and phone in Chromium and WebKit.'
	);
}

module.exports = {
	MENU,
	HOME_CARDS,
	VERSION_SELECTOR,
	ERGOPTI_PLUS_SECTIONS,
	REDIRECTS,
	exerciseSiteStructure,
	runEngine,
	main
};
if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
