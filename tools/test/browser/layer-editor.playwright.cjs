// tools/test/browser/layer-editor.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Navigation Layer Editor Browser Regression
 * DESCRIPTION:
 * Exercises the shared document and stylesheet in Chromium and WebKit using
 * each native host protocol. Measures mouse rows and blue activation keycaps
 * in both themes at the declared minimum and default window sizes. Browser
 * or page failures fail the gate; only a loopback fixture server is accessed.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { chromium, webkit } = require('playwright');
const { shared } = require('../../lib/paths.cjs');

const PRESET = fs.readFileSync(shared('keymap', 'layers.recommended.toml'), 'utf8');
const GEOMETRY = JSON.parse(fs.readFileSync(shared('ui', 'apps.manifest.json'), 'utf8')).apps
	.layer_editor;
const ROWS = [
	['MouseLeft', 'MouseMiddle', 'MouseRight'],
	['MouseBack', 'MouseForward'],
	['WheelUp', 'WheelDown'],
	['WheelLeft', 'WheelRight']
];

/** Loads the actual page with the recording bridge used by this native host. */
async function loadPage(browser, origin, os, colorScheme, size, locale) {
	const page = await browser.newPage({ colorScheme, viewport: size });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/'))
			errors.push(`unexpected request: ${request.url()}`);
	});
	const strings = JSON.parse(fs.readFileSync(shared('data', 'locales', `${locale}.json`), 'utf8'));
	await page.addInitScript(
		({ os, strings, locale }) => {
			window._i18n_strings = strings;
			window._i18n_locale = locale;
			window.__posted = [];
			if (os === 'windows') {
				window.chrome = window.chrome || {};
				window.chrome.webview = {
					postMessage: (payload) =>
						window.__posted.push(payload === 'ready' ? payload : JSON.parse(payload))
				};
			} else {
				window.webkit = {
					messageHandlers: {
						layer_editor_bridge: { postMessage: (payload) => window.__posted.push(payload) }
					}
				};
			}
		},
		{ os, strings, locale }
	);
	await page.goto(origin + '/ui/layer_editor/index.html');
	await page.evaluate(
		({ os, text }) =>
			window.init({ os, path: '/config/layers.toml', text, errors: [], layer_keys: ['AltLeft'] }),
		{ os, text: PRESET }
	);
	return { page, errors };
}

/** Measures the real cascade and layout, including bound activation keycaps. */
async function inspect(page) {
	return page.evaluate(() => {
		const probe = document.createElement('div');
		probe.style.background = 'var(--accent-soft)';
		document.body.appendChild(probe);
		const blue = getComputedStyle(probe).backgroundColor;
		probe.remove();
		const layer = document.querySelector('.key.layer-key');
		const cap = layer.querySelector('.cap');
		const styles = () => ({
			fill: getComputedStyle(cap).backgroundColor,
			border: getComputedStyle(cap).borderTopColor
		});
		const plain = styles();
		layer.classList.add('bound', 'recommended');
		const recommended = styles();
		layer.classList.remove('recommended');
		layer.classList.add('custom');
		const custom = styles();
		layer.classList.remove('bound', 'custom');
		const inputs = [...document.querySelectorAll('#mouse .key')].map((node) => {
			const rect = node.getBoundingClientRect();
			const legend = node.querySelector('.legend');
			const cap = node.querySelector('.cap');
			return {
				code: node.dataset.code,
				x: rect.x,
				y: rect.y,
				width: rect.width,
				height: rect.height,
				legend: legend.textContent,
				legendFits: legend.scrollWidth <= legend.clientWidth,
				capFits: cap.scrollHeight <= cap.clientHeight
			};
		});
		return {
			blue,
			plain,
			recommended,
			custom,
			inputs,
			chip: getComputedStyle(document.querySelector('.chip.layer-key')).backgroundColor,
			formText: getComputedStyle(document.querySelector('#form')).color,
			formBackground: getComputedStyle(document.querySelector('#form')).backgroundColor,
			overflow: document.documentElement.scrollWidth > window.innerWidth
		};
	});
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
					for (const colorScheme of ['light', 'dark']) {
						for (const size of [
							{ width: GEOMETRY.width, height: GEOMETRY.height },
							{ width: GEOMETRY.min_width, height: GEOMETRY.min_height }
						]) {
							for (const locale of ['en', 'fr', 'de']) {
								const label = `${engine}/${os}/${colorScheme}/${size.width}/${locale}`;
								const { page, errors } = await loadPage(
									browser,
									origin,
									os,
									colorScheme,
									size,
									locale
								);
								try {
									const result = await inspect(page);
									assert.deepEqual(errors, [], `${label}: page errors`);
									assert.equal(await page.evaluate(() => window.__posted[0]), 'ready', label);
									for (const state of ['plain', 'recommended', 'custom']) {
										assert.equal(result[state].fill, result.blue, `${label}: ${state} layer fill`);
										assert.match(
											result[state].border,
											/^rgb\(\d+, \d+, 255\)$/,
											`${label}: blue border`
										);
									}
									assert.notEqual(result.blue, 'rgba(0, 0, 0, 0)', `${label}: visible fill`);
									const channels = result.blue.match(/[\d.]+/g).map(Number);
									assert.ok(
										channels[2] > channels[0] &&
											channels[2] > channels[1] &&
											(channels.length === 3 || channels[3] > 0),
										`${label}: blue fill hue`
									);
									assert.equal(result.chip, result.blue, `${label}: legend chip`);
									assert.notEqual(
										result.formText,
										result.formBackground,
										`${label}: readable form selector`
									);
									assert.equal(result.overflow, false, `${label}: horizontal overflow`);
									assert.deepEqual(
										result.inputs.map((input) => input.code),
										ROWS.flat(),
										label
									);
									let previousRow = -Infinity;
									for (const row of ROWS) {
										const inputs = row.map((code) =>
											result.inputs.find((input) => input.code === code)
										);
										assert.ok(inputs[0].y > previousRow, `${label}: separated ${row} row`);
										previousRow = inputs[0].y + inputs[0].height;
										for (const [index, input] of inputs.entries()) {
											assert.ok(Math.abs(input.y - inputs[0].y) < 1, `${label}: ${input.code} row`);
											assert.ok(
												input.legend && input.legendFits && input.capFits,
												`${label}: ${input.code} readable`
											);
											assert.ok(
												input.width > 60 && input.height >= 48,
												`${label}: ${input.code} size`
											);
											if (index > 0)
												assert.ok(
													input.x >= inputs[index - 1].x + inputs[index - 1].width,
													`${label}: ${input.code} column`
												);
										}
									}
									await page.locator('[data-code="MouseLeft"]').click();
									assert.ok(
										await page.locator('#panel').textContent(),
										`${label}: mouse picker opens`
									);
									cases += 1;
								} finally {
									await page.close();
								}
							}
						}
					}
				}
			} finally {
				await browser.close();
			}
		}
		assert.equal(
			cases,
			Object.keys(engines).length * 36,
			'every engine/host/theme/size/locale case must run'
		);
		console.log(`[OK] Layer editor: ${cases} real browser layout and color cases.`);
	} finally {
		await new Promise((resolve) => server.close(resolve));
	}
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
