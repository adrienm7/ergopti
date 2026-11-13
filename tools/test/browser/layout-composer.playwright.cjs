// tools/test/browser/layout-composer.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Layout Composer Browser Regression
 * DESCRIPTION:
 * Opens the composer view of the shared layout manager page in Chromium (the
 * engine of the Windows WebView2 host) and WebKit (the macOS and Linux hosts)
 * through each native host protocol, then measures the real layout at the
 * manifest's default and minimum window sizes, a short and a wide window. The
 * drawn board must scale with the window and never cover the action buttons,
 * which must stay on screen and receive the click at their centre. Browser or
 * page failures fail the gate; only a loopback fixture server is accessed.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { chromium, webkit } = require('playwright');
const { shared } = require('../../lib/paths.cjs');

const REGISTRY = path.resolve(__dirname, '../../../static/layouts/registry');
const GEOMETRY = JSON.parse(fs.readFileSync(shared('ui', 'apps.manifest.json'), 'utf8')).apps
	.layout_manager;
const SIZES = [
	{ width: GEOMETRY.width, height: GEOMETRY.height },
	{ width: GEOMETRY.min_width, height: GEOMETRY.min_height },
	{ width: GEOMETRY.width, height: GEOMETRY.min_height },
	{ width: 1400, height: 900 }
];
const BUTTONS = ['composer-back', 'composer-remove', 'composer-save', 'composer-save-use'];
const SOURCES = JSON.parse(fs.readFileSync(path.join(REGISTRY, 'index.json'), 'utf8')).layouts.map(
	(entry) => ({
		id: entry.id,
		name: entry.name,
		convention: entry.keycode_convention,
		text: fs.readFileSync(path.join(REGISTRY, entry.file), 'utf8')
	})
);
const STRINGS = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8').replace(/^﻿/, '')
);

/** Loads the actual page with the recording bridge of this native host, composer open. */
async function loadComposer(browser, origin, os, size) {
	const page = await browser.newPage({ viewport: size });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/'))
			errors.push(`unexpected request: ${request.url()}`);
	});
	await page.addInitScript((os) => {
		window.__posted = [];
		if (os === 'windows') {
			window.chrome = window.chrome || {};
			window.chrome.webview = {
				postMessage: (payload) => window.__posted.push(JSON.parse(payload))
			};
		} else {
			window.webkit = {
				messageHandlers: {
					layout_manager_bridge: { postMessage: (payload) => window.__posted.push(payload) }
				}
			};
		}
	}, os);
	await page.goto(origin + '/ui/layout_manager/index.html');
	await page.evaluate(
		({ os, strings, sources }) => {
			window.initData({
				strings,
				state: {
					platform: os,
					shortcut_menu_path: os === 'windows' ? 'shortcuts/menu.ahk' : 'shortcuts/menu.lua',
					index: { layouts: [] },
					installed: {}
				}
			});
			window.composerData({
				platform: os,
				sources,
				declaration: null,
				active: false,
				shortcuts: os === 'linux' ? 'single' : 'full'
			});
		},
		{ os, strings: STRINGS, sources: SOURCES }
	);
	return { page, errors };
}

/** Measures the board, its keys, the scrolling body and the action buttons. */
async function inspect(page) {
	return page.evaluate((ids) => {
		const box = (node) => {
			const rect = node.getBoundingClientRect();
			return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
		};
		// Read through the button row so a page without the footer is measured,
		// and refused, by what the user sees rather than by a missing class.
		const bar = document.getElementById(ids[0]).parentElement;
		const footer = bar.closest('.composer-footer') || bar;
		const body = document.querySelector('.composer-body') || document.getElementById('composer');
		const style = getComputedStyle(body);
		return {
			viewport: { width: window.innerWidth, height: window.innerHeight },
			overflow: document.documentElement.scrollWidth > window.innerWidth,
			board: box(document.getElementById('composer-board')),
			bodyBox: box(body),
			bodyContent:
				body.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
			footer: box(footer),
			keys: [...document.querySelectorAll('#composer-board .composer-key')].map(box),
			buttons: ids.map((id) => {
				const node = document.getElementById(id);
				const rect = node.getBoundingClientRect();
				const hit = document.elementFromPoint(
					rect.left + rect.width / 2,
					rect.top + rect.height / 2
				);
				return { id, rect: box(node), hit: hit === node || node.contains(hit) };
			})
		};
	}, BUTTONS);
}

/** Asserts the layout contract of one measured window. */
function checkLayout(label, result) {
	assert.equal(result.overflow, false, `${label}: horizontal overflow`);
	assert.ok(result.keys.length > 40, `${label}: the board draws the keyboard`);
	assert.ok(
		result.board.bottom - result.board.top > 60,
		`${label}: the board keeps its height instead of collapsing`
	);
	for (const key of result.keys) {
		assert.ok(
			key.left >= result.board.left - 0.5 &&
				key.right <= result.board.right + 0.5 &&
				key.top >= result.board.top - 0.5 &&
				key.bottom <= result.board.bottom + 0.5,
			`${label}: a key is drawn outside the board`
		);
	}
	assert.ok(result.board.right <= result.viewport.width, `${label}: the board fits the window`);
	assert.ok(
		result.bodyBox.bottom <= result.footer.top + 0.5,
		`${label}: the scrolling body ends above the action bar`
	);
	for (const button of result.buttons) {
		assert.ok(
			button.rect.top >= result.footer.top && button.rect.bottom <= result.viewport.height,
			`${label}: ${button.id} is on screen in the action bar`
		);
		assert.ok(button.hit, `${label}: ${button.id} is covered by another element`);
	}
}

(async () => {
	const server = http.createServer((request, response) => {
		const relative = new URL(request.url, 'http://localhost').pathname.slice(1);
		const file = path.resolve(shared(), relative);
		if (
			!file.startsWith(shared() + path.sep) ||
			!fs.existsSync(file) ||
			!fs.statSync(file).isFile()
		) {
			response.writeHead(404);
			response.end();
			return;
		}
		const types = {
			'.html': 'text/html',
			'.js': 'text/javascript',
			'.css': 'text/css',
			'.json': 'application/json'
		};
		response.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
		fs.createReadStream(file).pipe(response);
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', resolve);
	});
	const origin = `http://127.0.0.1:${server.address().port}`;
	try {
		assert.ok(
			process.argv.length === 2 ||
				(process.argv.length === 3 && process.argv[2] === '--chromium-only'),
			'unknown browser test argument'
		);
		const engines = process.argv[2] === '--chromium-only' ? { chromium } : { chromium, webkit };
		let cases = 0;
		for (const [engine, launcher] of Object.entries(engines)) {
			const browser = await launcher.launch(
				engine === 'chromium' && process.env.CHROMIUM_EXECUTABLE
					? { executablePath: process.env.CHROMIUM_EXECUTABLE }
					: {}
			);
			try {
				for (const os of ['windows', 'macos', 'linux']) {
					const widths = {};
					for (const size of SIZES) {
						const label = `${engine}/${os}/${size.width}x${size.height}`;
						const { page, errors } = await loadComposer(browser, origin, os, size);
						try {
							assert.equal(
								await page.locator('#composer').isVisible(),
								true,
								`${label}: composer shown`
							);
							for (const form of ['iso', 'ansi']) {
								await page.selectOption('#composer-form', form);
								checkLayout(`${label}/${form}`, await inspect(page));
							}
							// The key editor adds a row under the board: the buttons stay clear.
							await page.locator('#composer-board .composer-key').first().click();
							assert.equal(await page.locator('#composer-key-editor').isVisible(), true);
							const result = await inspect(page);
							checkLayout(`${label}/editor`, result);
							widths[size.width] = Math.max(
								widths[size.width] || 0,
								result.board.right - result.board.left
							);
							const expected = Math.min(
								result.bodyContent,
								parseFloat(await page.$eval('#composer-board', (node) => node.style.maxWidth))
							);
							assert.ok(
								Math.abs(result.board.right - result.board.left - expected) < 1,
								`${label}: the board takes the available width`
							);
							assert.deepEqual(errors, [], `${label}: page errors`);
							cases += 1;
						} finally {
							await page.close();
						}
					}
					assert.ok(
						widths[1400] > widths[GEOMETRY.width] &&
							widths[GEOMETRY.width] > widths[GEOMETRY.min_width],
						`${engine}/${os}: widening the window widens the board`
					);
				}
			} finally {
				await browser.close();
			}
		}
		assert.equal(
			cases,
			Object.keys(engines).length * 3 * SIZES.length,
			'every engine/host/size case must run'
		);
		console.log(`[OK] Layout composer: ${cases} real browser responsive layout cases.`);
	} finally {
		await new Promise((resolve) => server.close(resolve));
	}
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
