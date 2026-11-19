// tools/test/browser/studio-controls.cjs

/**
 * ==============================================================================
 * MODULE: Studio Controls Browser Cases
 * DESCRIPTION:
 * The Studio's document tab strip and its controls, driven in Chromium by
 * layout-editor.playwright.cjs on its loopback server (run alone, it serves
 * the shared tree itself). The maintainer looked at the Studio on 2026-11-19:
 * the tab chip was cramped and its outline broken.
 *
 * WHAT IS CHECKED:
 * 1. (tab-strip) Every tab and « + » share one height and one middle line;
 *    the chosen tab is filled, bold and barred, not coloured alone; its
 *    « Duplicate » and « Close » are icon buttons kept off the tab's border
 *    and evenly spaced, whose focus ring stays inside the tab; texts hold
 *    4.5:1 and icons 3:1, in light and dark, at 1280 and 320 px.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { shared } = require('../../lib/paths.cjs');

const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

/**
 * Reads the tab strip's geometry and colours in the page.
 * @param {import('playwright').Page} page
 */
function readStrip(page) {
	return page.evaluate(() => {
		const rgb = (text) => (text.match(/[\d.]+/g) || []).slice(0, 4).map(Number);
		const luminance = ([r, g, b]) => {
			const lin = (c) => {
				const v = c / 255;
				return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
			};
			return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
		};
		const contrast = (a, b) => {
			const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m);
			return (x + 0.05) / (y + 0.05);
		};
		// The colour a translucent fill shows over the opaque ones behind it.
		const backdrop = (node) => {
			const layers = [];
			for (let at = node; at; at = at.parentElement) {
				const colour = rgb(getComputedStyle(at).backgroundColor);
				if (colour.length === 3 || (colour.length === 4 && colour[3] > 0)) {
					layers.push(colour);
					if (colour.length === 3 || colour[3] === 1) break;
				}
			}
			let out = [255, 255, 255];
			for (const layer of layers.reverse()) {
				const alpha = layer.length === 4 ? layer[3] : 1;
				out = out.map((c, i) => layer[i] * alpha + c * (1 - alpha));
			}
			return out;
		};
		const box = (node) => {
			const r = node.getBoundingClientRect();
			return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height };
		};
		const items = [...document.querySelectorAll('#le-layout-tabs .le-layout-tab-item')];
		const add = document.getElementById('le-tab-add');
		return {
			add: { ...box(add), icon: Boolean(add.querySelector('svg[aria-hidden="true"]')) },
			items: items.map((item) => {
				const style = getComputedStyle(item);
				const bar = getComputedStyle(item, '::after');
				const tab = item.querySelector('.le-layout-tab');
				const icons = [...item.querySelectorAll('.le-layout-tab-duplicate, .le-layout-tab-close')];
				const back = backdrop(item);
				return {
					active: item.classList.contains('active'),
					box: box(item),
					fill: style.backgroundColor,
					border: parseFloat(style.borderTopWidth),
					bar: bar.content !== 'none' ? parseFloat(bar.height) : 0,
					barColour: bar.backgroundColor,
					weight: Number(getComputedStyle(tab).fontWeight),
					textContrast: contrast(rgb(getComputedStyle(tab).color), back),
					icons: icons.map((button) => {
						const svg = button.querySelector('svg');
						return {
							box: box(button),
							name: button.getAttribute('aria-label'),
							text: button.textContent.trim(),
							hidden: svg ? svg.getAttribute('aria-hidden') === 'true' : false,
							focused: button === document.activeElement,
							outlineOffset: parseFloat(getComputedStyle(button).outlineOffset),
							outlineWidth: parseFloat(getComputedStyle(button).outlineWidth),
							contrast: svg ? contrast(rgb(getComputedStyle(svg).stroke), back) : 0
						};
					})
				};
			})
		};
	});
}

/**
 * (tab-strip) The editor's document tabs, in light and dark, wide and at 320 px.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseTabStrip(browser, origin) {
	for (const colorScheme of ['light', 'dark'])
		for (const width of [1280, 320]) {
			const where = `${colorScheme} ${width} px`;
			const context = await browser.newContext({ viewport: { width, height: 900 }, colorScheme });
			const page = await context.newPage();
			const errors = [];
			page.on('pageerror', (error) => errors.push(error.message));
			await page.goto(`${origin}/ui/layout_editor/index.html?lang=fr`);
			await page.waitForSelector('#le-layout-tabs .le-layout-tab');
			await page.click('#le-tab-add');
			await page.click('.le-layout-tab[data-tab="0"]');
			// A focused « Duplicate » shows its ring: the ring must stay inside the tab.
			await page.focus('.le-layout-tab-duplicate[data-duplicate-tab="0"]');
			await page.keyboard.press('Shift+Tab');
			await page.keyboard.press('Tab');
			const strip = await readStrip(page);
			assert.equal(strip.items.length, 2, `${where}: two tabs`);
			assert.equal(
				strip.items[0].icons.filter((icon) => icon.focused).length,
				1,
				`${where}: « Duplicate » has the focus`
			);
			assert.ok(strip.add.icon, `${where}: « + » draws its icon`);
			const heights = strip.items.map((item) => item.box.height).concat(strip.add.height);
			assert.ok(
				Math.max(...heights) - Math.min(...heights) <= 1,
				`${where}: the tabs and « + » share one height (${heights.join(', ')})`
			);
			// Controls sharing a row share its middle line.
			const boxes = strip.items.map((item) => item.box).concat(strip.add);
			for (const box of boxes) {
				const mates = boxes.filter((other) => Math.abs(other.top - box.top) < box.height / 2);
				const middles = mates.map((other) => (other.top + other.bottom) / 2);
				assert.ok(
					Math.max(...middles) - Math.min(...middles) <= 1,
					`${where}: one middle line (${middles.join(', ')})`
				);
			}
			const [chosen] = strip.items.filter((item) => item.active);
			const [other] = strip.items.filter((item) => !item.active);
			assert.notEqual(chosen.fill, other.fill, `${where}: the chosen tab is filled`);
			assert.ok(
				chosen.bar >= 3 && !/rgba\(0, 0, 0, 0\)/.test(chosen.barColour),
				`${where}: barred`
			);
			assert.ok(chosen.weight > other.weight, `${where}: and bold`);
			assert.equal(other.bar, 0, `${where}: another tab has no bar`);
			for (const item of strip.items) {
				const kind = item.active ? 'chosen' : 'other';
				assert.ok(item.textContrast >= 4.5, `${where} ${kind}: text ${item.textContrast}`);
				assert.equal(item.icons.length, 2, `${where}: « Duplicate » and « Close »`);
				const inset = item.border + 2;
				for (const icon of item.icons) {
					assert.ok(icon.name && icon.text === '' && icon.hidden, `${where}: an icon button`);
					assert.ok(icon.contrast >= 3, `${where} ${kind}: icon ${icon.contrast}`);
					assert.ok(
						icon.box.top >= item.box.top + inset && icon.box.bottom <= item.box.bottom - inset,
						`${where}: the icon button is off the tab's border`
					);
					// The ring of the focused button, drawn inside it, stays off the tab's border.
					if (icon.focused) {
						const ring = icon.outlineWidth + icon.outlineOffset;
						assert.ok(icon.outlineWidth >= 2, `${where}: a focus ring`);
						assert.ok(
							icon.box.top - ring >= item.box.top + item.border &&
								icon.box.bottom + ring <= item.box.bottom - item.border,
							`${where}: the focus ring stays inside the tab`
						);
					}
				}
				const [duplicate, close] = item.icons;
				const between = close.box.left - duplicate.box.right;
				const after = item.box.right - item.border - close.box.right;
				assert.ok(
					between >= 0 && Math.abs(after - between) <= 4,
					`${where}: evenly spaced (${between} and ${after} px)`
				);
			}
			assert.deepEqual(errors, [], `${where}: page errors`);
			await context.close();
		}
}

/** Serves the shared tree read-only on loopback, for a run of this file alone. */
function serve() {
	const root = shared();
	const server = http.createServer((request, response) => {
		const file = path.resolve(root, new URL(request.url, 'http://localhost').pathname.slice(1));
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

async function main() {
	const { chromium } = require('playwright');
	const server = await serve();
	const browser = await chromium.launch();
	const origin = `http://127.0.0.1:${server.address().port}`;
	try {
		await exerciseTabStrip(browser, origin);
	} finally {
		await browser.close();
		server.close();
	}
	console.log('ok - studio controls');
}

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});

module.exports = { exerciseTabStrip };
