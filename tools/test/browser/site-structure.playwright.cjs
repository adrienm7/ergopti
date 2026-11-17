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
// Ergopti Studio tabs: the editor, the layout comparison and the layout optimizer.
const STUDIO_TABS = Object.freeze([
	['/studio', 'Éditer'],
	['/studio/comparer', 'Comparer'],
	['/studio/optimiser', 'Optimiser']
]);
// Where the layout version selector must and must not be.
const VERSION_SELECTOR = Object.freeze({
	present: ['/ergopti', '/ergopti/benchmarks'],
	absent: ['/', '/ergopti-plus', '/ergopti-plus/hotstrings', '/studio']
});
// The floating button that shows the Ergopti layout belongs to the layout
// pages only (maintainer, 2026-11-14).
const REFERENCE_KEYBOARD = Object.freeze({
	present: ['/ergopti', '/ergopti/presentation', '/ergopti/benchmarks', '/ergopti/informations'],
	absent: [
		'/',
		'/ergopti-plus',
		'/ergopti-plus/installation',
		'/ergopti-plus-old',
		'/studio',
		'/studio/comparer',
		'/studio/optimiser'
	]
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
 * Each framed page (driver window, Studio tab) loads once: hydration once replaced the
 * prerendered (relative) frame address with the client's absolute one, which
 * reloaded every window and cut off its first load. The frames are lazy, so
 * the first one is brought into view before its load is awaited.
 */
async function expectSingleFrameLoads(
	page,
	origin,
	basePath,
	route,
	frames = '.frame-wrap iframe'
) {
	const loads = [];
	const record = (request) => {
		if (request.isNavigationRequest() && request.frame() !== page.mainFrame())
			loads.push(request.url());
	};
	page.on('request', record);
	try {
		await visit(page, origin, basePath, route);
		const first = page.locator(frames + '[src]').first();
		await first.waitFor({ state: 'attached' });
		// The frames are lazy: a browser starts one only near the viewport, and
		// how near depends on the engine and the connection (WebKit waits until
		// it is close; on a phone the first window sits screens below the fold).
		// Scroll to it as a reader does, so the frame starts in every engine.
		await first.scrollIntoViewIfNeeded();
		await page.waitForFunction((selector) => {
			const frame = document.querySelector(selector);
			return Boolean(
				frame && frame.contentWindow && frame.contentWindow.location.href !== 'about:blank'
			);
		}, frames + '[src]');
		await smoke.settleFrames(page);
		// Hydration ran before networkidle; give a late replacement time to show.
		await page.waitForTimeout(500);
	} finally {
		page.off('request', record);
	}
	assert.ok(loads.length > 0, 'The page embeds framed pages: ' + route);
	assert.equal(
		new Set(loads).size,
		loads.length,
		'Each framed page loads once: ' + loads.join(', ')
	);
}

/** Version selector only on the layout pages; section navigation marks the page. */
/**
 * (benchmarks-shared-engine) The benchmark page's results are the Studio's own
 * Comparer, framed: the shared library ranked by the shared engine on a shared
 * corpus, opened on French text on an ISO keyboard, with no screenshot, PDF
 * report or list of its own; the frame grows to the Comparer's height.
 * @param {import('playwright').Page} page - On /ergopti/benchmarks.
 */
async function exerciseBenchmarks(page) {
	const frame = page.locator('iframe.benchmark-frame');
	await frame.waitFor({ state: 'attached' });
	await frame.scrollIntoViewIfNeeded();
	assert.match(
		(await frame.getAttribute('src')) || '',
		/layout_analysis\/index\.html\?lang=fr&corpus=fr_nemolivier&keyboard=iso$/
	);
	const comparer = page.frameLocator('iframe.benchmark-frame');
	await page.waitForFunction(() => {
		const doc = document.querySelector('iframe.benchmark-frame').contentDocument;
		return Boolean(doc && doc.querySelectorAll('#la-table tbody tr').length > 0);
	});
	assert.equal(await comparer.locator('#la-corpus').inputValue(), 'fr_nemolivier');
	assert.equal(await comparer.locator('#la-keyboard').inputValue(), 'iso');
	assert.ok(
		await comparer.locator('#la-table tbody tr', { hasText: 'Ergopti' }).count(),
		'Ergopti is ranked among the library layouts'
	);
	await page.waitForFunction(
		() => document.querySelector('iframe.benchmark-frame').getBoundingClientRect().height > 600
	);
	assert.equal(
		await page.locator('img[alt^="Screenshot de benchmark sur le clavier"]').count(),
		0,
		'No result screenshot beside the live comparison'
	);
	assert.equal(
		await page.locator('embed[src*="benchmarks/ergol"], a[href*="benchmarks/ergol"]').count(),
		0,
		'No archived Ergo-L report beside the live comparison (maintainer, 2026-11-15)'
	);
}

async function exerciseSections(page, origin, basePath) {
	for (const route of VERSION_SELECTOR.present) {
		await visit(page, origin, basePath, route);
		await page.locator('#version-selection').waitFor({ state: 'visible' });
		await expectMenu(page, 'disposition');
	}
	for (const route of REFERENCE_KEYBOARD.present) {
		await visit(page, origin, basePath, route);
		await page.locator('#afficher-clavier-reference').waitFor({ state: 'visible' });
	}
	for (const route of REFERENCE_KEYBOARD.absent) {
		await visit(page, origin, basePath, route);
		assert.equal(
			await page.locator('#afficher-clavier-reference, #clavier-ref').count(),
			0,
			'No reference keyboard on ' + route
		);
	}
	for (const route of VERSION_SELECTOR.absent) {
		await visit(page, origin, basePath, route);
		assert.equal(await page.locator('#version-selection').count(), 0, 'No selector on ' + route);
	}
	await visit(page, origin, basePath, '/ergopti/benchmarks');
	const current = page.locator('nav.subnav a[aria-current="page"]');
	assert.equal(await current.textContent(), 'Benchmarks');
	await exerciseBenchmarks(page);
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
	for (const [route, current] of STUDIO_TABS) {
		await visit(page, origin, basePath, route);
		await expectMenu(page, 'studio');
		const tabs = await page
			.locator('nav.subnav a')
			.evaluateAll((links) =>
				links.map((link) => [link.textContent.trim(), link.getAttribute('aria-current') === 'page'])
			);
		assert.deepEqual(
			tabs,
			STUDIO_TABS.map(([, label]) => [label, label === current]),
			'Studio tabs on ' + route
		);
	}
	for (const [route] of STUDIO_TABS)
		await expectSingleFrameLoads(page, origin, basePath, route, 'main iframe');
	for (const [route] of STUDIO_TABS) await expectStudioWorkspace(page, origin, basePath, route);
}

/**
 * Ergopti Studio is an app-like workspace (maintainer, 2026-11-14): no title
 * block, introduction or table of contents around the tool, whose frame
 * spans the full width and reaches the bottom of the screen.
 */
async function expectStudioWorkspace(page, origin, basePath, route) {
	await visit(page, origin, basePath, route);
	assert.equal(await page.locator('#sidebar, bloc-introduction').count(), 0, 'Bare workspace');
	const frame = page.locator('main iframe.studio-frame');
	await frame.waitFor({ state: 'visible' });
	const box = await frame.boundingBox();
	const viewport = page.viewportSize();
	// The workspace fills the screen and the page itself never scrolls: a page
	// taller than the screen shows a classic scrollbar (WebKit, desktop Chrome
	// on Windows and Linux) that narrows the tool, which headless Chromium hides.
	const overflow = await page.evaluate(
		() => document.documentElement.scrollHeight - window.innerHeight
	);
	assert.ok(
		overflow <= 1,
		`The page around the Studio does not scroll on ${route} (${overflow} px)`
	);
	assert.ok(
		box.x <= 1 && Math.abs(box.x + box.width - viewport.width) <= 1,
		'Studio frame spans the full width on ' + route
	);
	assert.ok(
		Math.abs(box.y + box.height - viewport.height) <= 2,
		'Studio frame reaches the bottom of the screen on ' + route
	);
	// The tab bar continues the top menu's dark band, in the menu's style: no
	// page background between the header, the tabs and the tool (maintainer,
	// 2026-11-15), and text tabs, not pills.
	const bar = await page.evaluate(() => {
		const nav = document.querySelector('.studio-shell nav.subnav');
		const header = document.querySelector('header');
		const tab = nav.querySelector('a');
		return {
			background: getComputedStyle(nav).backgroundColor,
			headerBackground: getComputedStyle(header).backgroundColor,
			top: nav.getBoundingClientRect().top,
			bottom: nav.getBoundingClientRect().bottom,
			// On a phone the dev banner is a band right under the header.
			headerBottom: Math.max(
				header.getBoundingClientRect().bottom,
				...[...document.querySelectorAll('.banner')]
					.filter((banner) => getComputedStyle(banner).transform === 'none')
					.map((banner) => banner.getBoundingClientRect().bottom)
			),
			left: nav.getBoundingClientRect().left,
			width: nav.getBoundingClientRect().width,
			tabRadius: getComputedStyle(tab).borderTopLeftRadius
		};
	});
	assert.equal(
		bar.background,
		bar.headerBackground,
		'Studio tab bar in the header color on ' + route
	);
	assert.ok(
		Math.abs(bar.top - bar.headerBottom) <= 1,
		'Studio tab bar under the header on ' + route
	);
	assert.ok(Math.abs(bar.bottom - box.y) <= 1, 'Studio frame right under the tab bar on ' + route);
	assert.ok(
		bar.left <= 1 && Math.abs(bar.width - viewport.width) <= 1,
		'Studio tab bar spans the width'
	);
	assert.equal(bar.tabRadius, '0px', 'Studio tabs are text links, not pills, on ' + route);
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

		for (const [route] of STUDIO_TABS) await expectStudioWorkspace(page, origin, basePath, route);
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

/**
 * (dead-key-legend) The site's keyboard shows a dead key as its bare accent
 * with the shared marker class (src/lib/keyboard/keyLegend.js), never as a
 * combining mark on a dotted circle; its data-content keeps the data's
 * spelling, which the emulation reads.
 */
async function exerciseDeadKeyLegends(page, origin, basePath) {
	await visit(page, origin, basePath, '/ergopti');
	const dead = page.locator("keyboard-key[data-style='deadkey']");
	await dead.first().waitFor({ state: 'attached' });
	const keys = await dead.evaluateAll((nodes) =>
		nodes.map((node) => ({
			content: node.dataset.content,
			text: node.querySelector('div').textContent,
			marked: node.querySelector('div').classList.contains('key-legend-dead')
		}))
	);
	assert.ok(keys.length > 0, 'The Ergopti keyboard shows dead keys');
	for (const key of keys) {
		assert.ok(key.marked, `Dead key ${key.content} carries the marker class`);
		assert.ok(!key.text.includes('\u25cc'), `Dead key ${key.content} without a dotted circle`);
	}
	assert.ok(
		keys.some((key) => key.text === '^'),
		'The circumflex dead key reads as « ^ »'
	);
}

/**
 * (studio-site-handoff) The site's two framed Studio pages share one keyboard
 * format, and the editor's « Compare with other layouts » opens « Comparer »
 * with the edited layout ranked, as the app's Studio window does.
 */
async function exerciseStudioHandoff(page, origin, basePath) {
	await visit(page, origin, basePath, '/studio');
	const editor = page.frameLocator('iframe.studio-frame');
	await editor.locator('#le-board .le-legend.key-legend-dead').first().waitFor();
	await editor.locator('#le-board-format').selectOption('65');
	await editor.locator('#la-panel-compare').click();
	await page.waitForURL(origin + basePath + '/studio/comparer');
	const comparer = page.frameLocator('iframe.studio-frame');
	await comparer.locator('#la-table tbody tr').first().waitFor();
	assert.equal(
		await comparer.locator('#la-format').inputValue(),
		'65',
		"the Comparer keeps the editor's format"
	);
	await comparer
		.locator('#la-table tbody tr', { hasText: 'Mon Ergopti' })
		.first()
		.waitFor({ timeout: 20000 });
	// (compare-reuses-editor-entry) The handed layout is the editor_… entry the
	// Comparer lists from the editor frame: one row, not a copy beside it.
	assert.equal(
		await comparer.locator('#la-layout-list .la-layout', { hasText: 'Mon Ergopti' }).count(),
		1,
		'the edited layout is listed once'
	);
	// The format chosen in the Comparer is the editor's next time.
	await comparer.locator('#la-format').selectOption('tkl');
	await visit(page, origin, basePath, '/studio');
	await page.frameLocator('iframe.studio-frame').locator('#le-board').waitFor();
	assert.equal(
		await page.frameLocator('iframe.studio-frame').locator('#le-board-format').inputValue(),
		'tkl',
		'the editor takes the format chosen in the Comparer'
	);
	// (editor-layouts-in-comparer) The layout open in the editor frame is in the
	// Comparer frame's list on a later visit, the handoff long taken.
	await visit(page, origin, basePath, '/studio/comparer');
	await page
		.frameLocator('iframe.studio-frame')
		.locator('#la-layout-list .la-layout', { hasText: 'Mon Ergopti' })
		.first()
		.waitFor();
}

/**
 * (generated-keyboard) The drawing renders the data generated from the layout
 * source (tools/codegen/codegen-site-keyboard.cjs, its drift gate
 * test-site-keyboard-data.cjs): a table of rows and cells, every key showing
 * its generated character, every dead key named, and a dead key opening the
 * level the source gives it.
 */
async function exerciseGeneratedKeyboard(page, origin, basePath) {
	const data = JSON.parse(
		fs.readFileSync(
			path.join(__dirname, '../../../static/layouts/visualisation/ergopti_v2.2.json'),
			'utf8'
		)
	);
	const cell = (key) => data.keys.find((candidate) => candidate.key === key);
	await visit(page, origin, basePath, '/ergopti');
	const board = page.locator('#keyboard_presentation');
	await board.locator("keyboard-key[data-key='a']").waitFor({ state: 'attached' });
	const read = () =>
		board.evaluate((node) => ({
			role: node.getAttribute('role'),
			label: node.getAttribute('aria-label'),
			rows: [...node.querySelectorAll('keyboard-row')].map((row) => row.getAttribute('role')),
			keys: [...node.querySelectorAll('keyboard-key')]
				.filter((key) => key.dataset.key)
				.map((key) => ({
					key: key.dataset.key,
					role: key.getAttribute('role'),
					style: key.dataset.style ?? '',
					label: key.getAttribute('aria-label'),
					text: (key.querySelector('div') ?? key).textContent
				}))
		}));
	const press = (key) => board.locator(`keyboard-key[data-key='${key}']`).dispatchEvent('click');
	let drawn = await read();
	assert.equal(drawn.role, 'table', 'The keyboard drawing is a table');
	assert.ok(drawn.label, 'The keyboard table is named');
	assert.ok(
		drawn.rows.every((role) => role === 'row'),
		'Each keyboard row is a table row'
	);
	assert.ok(
		drawn.keys.every((key) => key.role === 'cell'),
		'Each key is a table cell'
	);
	// Base level: the letters, digits and symbols show the generated characters.
	const plain = drawn.keys.filter((key) =>
		['letter', 'french', 'chiffre', 'symbole'].includes(cell(key.key)?.type)
	);
	assert.ok(plain.length >= 40, 'The ISO drawing shows the character keys');
	for (const key of plain)
		assert.equal(key.text, cell(key.key).Primary, `Key ${key.key} shows its base character`);
	// Shift + AltGr: every dead key of that level is marked and named.
	await press('RAlt');
	await press('LShift');
	drawn = await read();
	const dead = drawn.keys.filter((key) => cell(key.key)?.['ShiftAltGr-style'] === 'deadkey');
	assert.ok(dead.length >= 7, 'The Shift AltGr level shows the dead keys');
	for (const key of dead) {
		assert.equal(key.style, 'deadkey', `Dead key on ${key.key} is marked`);
		assert.equal(key.label, 'Touche morte ' + key.text.trim(), `Dead key on ${key.key} is named`);
	}
	// The circumflex dead key opens the circumflex level of the source.
	await press('ê');
	drawn = await read();
	for (const name of ['a', 'w', 'e'])
		assert.equal(
			drawn.keys.find((key) => key.key === name).text,
			cell(name).Circonflexe,
			`The circumflex level shows ${cell(name).Circonflexe} on ${name}`
		);
}

/** The whole structure check, in one browser page. */
async function exerciseSiteStructure(page, origin, basePath) {
	await exerciseHome(page, origin, basePath);
	await exerciseSections(page, origin, basePath);
	await exerciseDeadKeyLegends(page, origin, basePath);
	await exerciseGeneratedKeyboard(page, origin, basePath);
	await exerciseStudioHandoff(page, origin, basePath);
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
	REFERENCE_KEYBOARD,
	ERGOPTI_PLUS_SECTIONS,
	REDIRECTS,
	STUDIO_TABS,
	exerciseSiteStructure,
	exerciseGeneratedKeyboard,
	runEngine,
	main
};
if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
