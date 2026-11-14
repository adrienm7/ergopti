// tools/test/browser/site-structure.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Site Structure Browser Regression
 * DESCRIPTION:
 * Drives a built static site in Chromium and WebKit, on desktop and phone
 * viewports: the home page presents Ergopti as the project with its three
 * products, the header menu keeps the maintainer's order, Ergopti Studio lives
 * at /studio and the former /editeur address forwards there through its
 * prerendered redirect page. Page errors, local HTTP failures and requests
 * outside the loopback origin fail the gate. CI runs it on the received
 * production site right after the artifact smoke test.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const smoke = require('./site-artifact-smoke.playwright.cjs');

// Header menu order the maintainer set on 2026-11-14: Ergopti is the project,
// its products are the layout (home), Ergopti+ and Ergopti Studio.
const MENU_TITLES = Object.freeze([
	'Accueil',
	'Ergopti+',
	'Studio',
	'Benchmarks',
	'Utilisation',
	'Informations'
]);
const PROJECT_CARDS = Object.freeze([
	['disposition', '/#debut'],
	['ergopti-plus', '/ergopti-plus'],
	['studio', '/studio']
]);
// Same size as the browser context runBrowsers opens.
const DESKTOP_VIEWPORT = Object.freeze({ width: 1440, height: 900 });
const PHONE_VIEWPORT = Object.freeze({ width: 390, height: 844 });

/** Assert the shown Ergopti Studio page, reached by any address. */
async function expectStudio(page, origin, basePath) {
	await page.waitForURL(origin + basePath + '/studio');
	await page.locator('h1').first().waitFor({ state: 'visible' });
	assert.equal((await page.locator('h1').first().textContent()).trim(), 'Ergopti Studio');
	assert.equal(await page.title(), 'Ergopti Studio');
	assert.equal(
		await page.locator('#menu-pages a[href="studio"]').getAttribute('aria-current'),
		'page',
		'The Studio menu entry marks the current page'
	);
}

/** Read the home page's project section: product order and resolved targets. */
async function projectCards(page, origin, basePath) {
	const cards = page.locator('#projet-ergopti a.card');
	await cards.first().waitFor({ state: 'visible' });
	const rows = [];
	for (let index = 0; index < (await cards.count()); index += 1) {
		const card = cards.nth(index);
		rows.push([
			await card.getAttribute('data-product'),
			new URL(await card.getAttribute('href'), page.url()).href,
			await card.boundingBox()
		]);
	}
	assert.deepEqual(
		rows.map(([product, href]) => [product, href]),
		PROJECT_CARDS.map(([product, route]) => [product, origin + basePath + route]),
		'Home presents the three Ergopti products in order'
	);
	return rows.map((row) => row[2]);
}

/** Project section, menu order, Studio route and the prerendered /editeur redirect on desktop and phone. */
async function exerciseSiteStructure(page, origin, basePath) {
	await page.setViewportSize(DESKTOP_VIEWPORT);
	await page.goto(origin + basePath + '/', { waitUntil: 'networkidle' });
	const titles = await page.locator('#menu-pages > a .title').allTextContents();
	assert.deepEqual(
		titles.map((title) => title.replace(/\s+/g, '')),
		MENU_TITLES.slice(),
		'Header menu order'
	);
	const desktop = await projectCards(page, origin, basePath);
	assert.ok(
		desktop.every((box) => Math.abs(box.y - desktop[0].y) < 1),
		'Desktop shows the three product cards on one row'
	);
	await Promise.all([
		page.waitForURL(origin + basePath + '/studio'),
		page.locator('#projet-ergopti a.card[data-product="studio"]').click()
	]);
	await expectStudio(page, origin, basePath);

	const redirect = await page.goto(origin + basePath + '/editeur', { waitUntil: 'networkidle' });
	assert.ok(redirect?.ok(), 'The former editor address answers');
	await expectStudio(page, origin, basePath);

	await page.setViewportSize(PHONE_VIEWPORT);
	try {
		await page.goto(origin + basePath + '/', { waitUntil: 'networkidle' });
		const phone = await projectCards(page, origin, basePath);
		assert.ok(
			phone.every(
				(box, index) =>
					Math.abs(box.x - phone[0].x) < 1 &&
					box.x >= 0 &&
					box.x + box.width <= PHONE_VIEWPORT.width &&
					(index === 0 || box.y > phone[index - 1].y)
			),
			'Phone stacks the product cards inside the viewport'
		);
		const menuHeight = () => page.locator('#menu').evaluate((menu) => menu.clientHeight);
		assert.equal(await menuHeight(), 0, 'Phone menu starts folded');
		await page.locator('label.menu-icon').click();
		await page.waitForFunction(() => document.getElementById('menu').clientHeight > 0);
		const studio = page.locator('#menu-pages a[href="studio"]');
		await studio.waitFor({ state: 'visible' });
		await Promise.all([page.waitForURL(origin + basePath + '/studio'), studio.click()]);
		await expectStudio(page, origin, basePath);
	} finally {
		await page.setViewportSize(DESKTOP_VIEWPORT);
	}
}

/** Serve the built site on loopback and run the structure checks in one engine. */
async function runEngine(engine, site, basePath) {
	const serverErrors = [];
	const server = http.createServer((request, response) =>
		smoke.serveRequest(site, basePath, request, response, serverErrors)
	);
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
				const page = await context.newPage();
				page.setDefaultTimeout(15000);
				page.on('pageerror', (error) => errors.push(error.message));
				page.on('console', (message) => {
					if (message.type() === 'error') errors.push(message.text());
				});
				page.on('response', (response) => {
					if (new URL(response.url()).origin === origin && response.status() >= 400)
						errors.push(response.url() + ' HTTP ' + response.status());
				});
				// The smoke test's inert fixtures answer the GitHub API, fonts and
				// analytics; any other remote request fails the gate.
				await page.route('**/*', async (route) => {
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
		'Site structure: project section, menu order, Ergopti Studio and the /editeur redirect PASS on desktop and phone in Chromium and WebKit.'
	);
}

module.exports = { MENU_TITLES, PROJECT_CARDS, exerciseSiteStructure, runEngine, main };
if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
