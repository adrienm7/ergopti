// tools/test/browser/studio-try.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Studio « Essayer » Browser Regression
 * DESCRIPTION:
 * Drives Ergopti Studio's « Essayer » page (_shared/ui/layout_try, maintainer
 * 2026-11-21) in Chromium from a loopback server:
 * 1. It renders ready, its text area named by its label, and types a sample
 *    of Ergopti's keys: base, Shift, AltGr (Right Alt held) and a dead key,
 *    said in the status line while it waits.
 * 2. Tab leaves the text area (WCAG 2.1.2); Backspace stays the browser's.
 * 3. ?layout=bepo selects bépo, which types its own characters; a ?layout=
 *    the library lacks is refused in words and Ergopti is typed.
 * 4. The former page's #input-text anchor lands in the text area.
 * Page errors and requests outside the loopback origin fail the gate.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
const { shared } = require('../../lib/paths.cjs');

const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

/** Serves the shared tree read-only on loopback. */
function serve() {
	const root = shared();
	const server = http.createServer((request, response) => {
		const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
		const file = path.resolve(root, pathname.slice(1));
		if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
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

/** Opens the page with a query and an anchor, waiting for its strings and its ready field. */
async function open(browser, origin, query) {
	const context = await browser.newContext({ viewport: { width: 1100, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/'))
			errors.push(`unexpected request: ${request.url()}`);
	});
	await page.goto(`${origin}/ui/layout_try/index.html${query}`);
	await page.waitForFunction(() => {
		const title = document.querySelector('.layout-try h1');
		return title && title.textContent && !title.textContent.startsWith('layout_try.');
	});
	await page.locator('#input-text[data-emulation-state="ready"]:not(:disabled)').waitFor();
	return { page, errors, context };
}

const value = (page) => page.inputValue('#input-text');

async function ergopti(browser, origin) {
	const { page, errors, context } = await open(browser, origin, '?lang=en');
	assert.equal(await page.inputValue('#lt-layout'), 'ergopti', 'Ergopti by default');
	assert.equal(
		await page.locator('#input-text').evaluate((node) => node.labels[0].textContent),
		'Type here',
		'the text area is named by its label'
	);
	await page.focus('#input-text');
	// Base level: the QWERTY keys Q W E A type Ergopti's è y o a.
	for (const code of ['KeyQ', 'KeyW', 'KeyE', 'KeyA']) await page.keyboard.press(code);
	assert.equal(await value(page), 'èyoa');
	await page.keyboard.press('Shift+KeyE');
	assert.equal(await value(page), 'èyoaO', 'Shift reaches the second level');
	// AltGr: Right Alt held, as on an OS layout without AltGr.
	await page.keyboard.down('AltRight');
	assert.match(
		await page.textContent('#lt-board-title'),
		/AltGr/,
		'the keyboard shows the AltGr level'
	);
	await page.keyboard.press('KeyA');
	await page.keyboard.up('AltRight');
	assert.equal(await value(page), 'èyoaO<', 'AltGr reaches the third level');
	// A dead key waits, says so, then gives its rule.
	await page.keyboard.press('Backslash');
	assert.match(await page.textContent('#lt-status'), /\^/, 'the waiting dead key is said');
	await page.keyboard.press('KeyD');
	assert.equal(await value(page), 'èyoaO<ê', 'the circumflex dead key then e gives ê');
	assert.equal(await page.textContent('#lt-status'), '');
	// Backspace stays the browser's.
	await page.keyboard.press('Backspace');
	assert.equal(await value(page), 'èyoaO<');
	// Tab moves on.
	await page.keyboard.press('Tab');
	assert.equal(
		await page.evaluate(() => document.activeElement.id),
		'lt-clear',
		'Tab leaves the text area'
	);
	await page.click('#lt-clear');
	assert.equal(await value(page), '');
	assert.deepEqual(errors, [], 'Ergopti page errors');
	await context.close();
}

async function chosen(browser, origin) {
	{
		const { page, errors, context } = await open(browser, origin, '?lang=en&layout=bepo');
		assert.equal(await page.inputValue('#lt-layout'), 'bepo', 'layout= selects the layout');
		await page.focus('#input-text');
		await page.keyboard.press('KeyQ');
		await page.keyboard.press('KeyW');
		assert.equal(await value(page), 'bé', 'bépo types its own characters');
		await page.selectOption('#lt-layout', 'ergopti');
		await page.focus('#input-text');
		await page.keyboard.press('KeyQ');
		assert.equal(await value(page), 'béè', 'another layout picked types at once');
		assert.deepEqual(errors, [], 'bépo page errors');
		await context.close();
	}
	{
		const { page, errors, context } = await open(
			browser,
			origin,
			'?lang=en&layout=nowhere#input-text'
		);
		assert.equal(await page.inputValue('#lt-layout'), 'ergopti');
		assert.match(
			await page.textContent('#lt-layout-error'),
			/nowhere/,
			'an unknown layout is refused in words'
		);
		assert.equal(
			await page.evaluate(() => document.activeElement.id),
			'input-text',
			'#input-text lands in the text area'
		);
		assert.deepEqual(errors, [], 'unknown layout page errors');
		await context.close();
	}
}

async function main() {
	const server = await serve();
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch();
	try {
		await ergopti(browser, origin);
		console.log('ok - Ergopti types, dead keys and AltGr included');
		await chosen(browser, origin);
		console.log('ok - layout= selects the layout');
	} finally {
		await browser.close();
		server.close();
	}
	console.log('PASS studio-try');
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
