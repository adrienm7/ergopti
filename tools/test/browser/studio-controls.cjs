// tools/test/browser/studio-controls.cjs

/**
 * ==============================================================================
 * MODULE: Studio Controls Browser Cases
 * DESCRIPTION:
 * The Studio's document tab strip and its controls, driven in Chromium by
 * layout-editor.playwright.cjs on its loopback server (run alone, it serves
 * the shared tree itself). The maintainer looked at the Studio on 2026-11-19:
 * the tab chip was cramped and its outline broken, the editor's tab still
 * read « Mon Ergopti », « Load a file » hid under « Your own text », and no
 * button may hold a colon.
 *
 * WHAT IS CHECKED:
 * 1. (tab-strip) Every tab and « + » share one height and one middle line;
 *    the chosen tab is filled, bold and barred, not coloured alone; its
 *    « Duplicate » and « Close » are icon buttons kept off the tab's border
 *    and evenly spaced, whose focus ring stays inside the tab; texts hold
 *    4.5:1 and icons 3:1, in light and dark, at 1280 and 320 px.
 * 2. (restored-start-name) A workspace saved while the start copy was named
 *    « Mon Ergopti » opens with the copy's current name and its stored id; a
 *    tab whose keys differ from the start keeps the name it has.
 * 3. (corpus-file-button) « Load a corpus file » shows on the Comparer's
 *    « Home » under a built-in corpus: tinted, bold, with an icon and the
 *    formats it reads, 4.5:1; the file it loads becomes the chosen corpus.
 * 4. (no-colon-button) colonButtons lists every button, disclosure, tab and
 *    button-styled label whose text holds a colon (a drawn key typing « : »
 *    aside), for the 21-locale loops of the editor and the Comparer in
 *    layout-editor.playwright.cjs and the optimiser's own run.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { shared } = require('../../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const KEYLAYOUT = path.join(ROOT, 'static', 'layouts', 'registry', 'ergopti', 'ergopti.keylayout');
// The page's former name for its Ergopti start copy (before 2026-11-19).
const RETIRED_NAME = 'Mon Ergopti';
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

/** The locale's strings, read as the page reads them. */
function stringsOf(lang) {
	return JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', `${lang}.json`), 'utf8')
	);
}

/**
 * (no-colon-button) The texts of the page's buttons that hold a colon, « : »
 * or « ： » (maintainer, 2026-11-19): buttons, disclosures, tabs and the
 * labels drawn as buttons (a file picker's « .la-file-button »), shown or not.
 * @param {import('playwright').Page|import('playwright').Frame} page
 * @returns {Promise<string[]>}
 */
function colonButtons(page) {
	return page.evaluate(() =>
		[
			...document.querySelectorAll(
				'button, summary, [role="button"], [role="tab"], .la-file-button, input[type="button"], input[type="submit"]'
			)
		]
			// A key of a drawn keyboard shows the character it types (« : » too).
			.filter((node) => !node.closest('[data-code]'))
			.map((node) =>
				(node.tagName === 'INPUT' ? node.value : node.textContent).replace(/\s+/g, ' ').trim()
			)
			.filter((text) => /[:：]/.test(text))
	);
}

/** Routes the registry to Ergopti alone, as the site serves it. */
async function routeRegistry(context) {
	const keylayout = fs.readFileSync(KEYLAYOUT, 'utf8');
	await context.route('**/layouts/registry/index.json', (route) =>
		route.fulfill({
			contentType: 'application/json',
			body: JSON.stringify({
				layouts: [
					{
						id: 'ergopti',
						name: 'Ergopti',
						file: 'ergopti.keylayout',
						keycode_convention: 'iso'
					}
				]
			})
		})
	);
	await context.route('**/layouts/registry/ergopti.keylayout', (route) =>
		route.fulfill({ contentType: 'text/plain', body: keylayout })
	);
}

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
			return {
				top: r.top,
				bottom: r.bottom,
				left: r.left,
				right: r.right,
				height: r.height
			};
		};
		const items = [...document.querySelectorAll('#le-layout-tabs .le-layout-tab-item')];
		const add = document.getElementById('le-tab-add');
		return {
			add: {
				...box(add),
				icon: Boolean(add.querySelector('svg[aria-hidden="true"]'))
			},
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
			const context = await browser.newContext({
				viewport: { width, height: 900 },
				colorScheme
			});
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

/**
 * (restored-start-name) The start copy a workspace kept under its former name.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseRestoredStartName(browser, origin) {
	const en = stringsOf('en');
	const copyName = en['layout_editor.start.copy_name'].replace('{name}', 'Ergopti');
	const context = await browser.newContext({
		viewport: { width: 1280, height: 900 }
	});
	await routeRegistry(context);
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	const url = `${origin}/ui/layout_editor/index.html?lang=en`;
	const tabNames = () =>
		page.$$eval('#le-layout-tabs .le-layout-tab', (tabs) => tabs.map((tab) => tab.textContent));
	const settled = () =>
		page.waitForFunction((text) => {
			const node = document.querySelector('#le-autosave');
			return node && node.textContent.startsWith(text);
		}, en['layout_editor.tabs.autosave.saved']);
	await page.goto(url);
	await page.waitForFunction(
		(expected) => document.querySelector('#le-name').value === expected,
		copyName
	);
	await settled();
	// The workspace as the page saved it before the rename: the same start copy
	// named « Mon Ergopti », and a second tab, its keys changed, under that name too.
	const stored = await page.evaluate(
		async ({ copyName, retired }) => {
			const store = LayoutEditorWorkspace.indexedDbStore(window);
			const saved = LayoutEditorWorkspace.parse(await store.load());
			const [start] = saved.tabs;
			const named = (text) => text.replace(JSON.stringify(copyName), JSON.stringify(retired));
			const edited = LayoutSourceIO.parse(start.text).doc;
			const keys = edited.layers[0].keys;
			keys[Object.keys(keys)[0]] = { text: 'ŵ' };
			const tabs = [
				{ text: named(start.text), dirty: false },
				{ text: named(LayoutSourceIO.serialize(edited)), dirty: false }
			];
			await store.save(LayoutEditorWorkspace.serialize(tabs, 0));
			return {
				id: LayoutSourceIO.parse(start.text).doc.layout.id,
				text: tabs[0].text
			};
		},
		{ copyName, retired: RETIRED_NAME }
	);
	assert.ok(stored.text.includes(RETIRED_NAME), 'the stored tab reads « Mon Ergopti »');
	await page.reload();
	await page.waitForFunction(
		(expected) => document.querySelector('#le-layout-tabs .le-layout-tab').textContent === expected,
		copyName
	);
	assert.deepEqual(
		await tabNames(),
		[copyName, RETIRED_NAME],
		'the start copy takes its current name; an edited tab keeps its own'
	);
	await settled();
	const resaved = await page.evaluate(async () =>
		LayoutEditorWorkspace.parse(await LayoutEditorWorkspace.indexedDbStore(window).load())
	);
	assert.ok(resaved.tabs[0].text.includes(JSON.stringify(copyName)), 'the new name is saved');
	assert.ok(resaved.tabs[0].text.includes(`id = ${JSON.stringify(stored.id)}`), 'its id stays');
	assert.equal(await page.isDisabled('#le-undo'), true, 'the rename is not an edit to undo');
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (corpus-file-button) « Load a corpus file » on the Comparer's « Home »,
 * under the corpus picker whatever corpus is chosen: a tinted button with an
 * icon, the formats it reads beside it, and a file it loads becomes the
 * chosen corpus.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseCorpusFileButton(browser, origin) {
	const en = stringsOf('en');
	for (const colorScheme of ['light', 'dark'])
		for (const width of [1280, 320]) {
			const where = `${colorScheme} ${width} px`;
			const context = await browser.newContext({ viewport: { width, height: 900 }, colorScheme });
			const page = await context.newPage();
			const errors = [];
			page.on('pageerror', (error) => errors.push(error.message));
			await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en`);
			await page.waitForFunction(
				() => document.getElementById('la-results').getAttribute('aria-busy') === 'false',
				null,
				{ timeout: 120000 }
			);
			assert.notEqual(await page.inputValue('#la-corpus'), 'custom', `${where}: a built-in text`);
			const button = page.locator('.la-corpus-card .la-file-button');
			assert.equal(await button.isVisible(), true, `${where}: the button is shown`);
			const look = await page.evaluate(() => {
				const node = document.querySelector('.la-corpus-card .la-file-button');
				const rgb = (text) => (text.match(/[\d.]+/g) || []).slice(0, 4).map(Number);
				const luminance = ([r, g, b]) => {
					const lin = (c) => {
						const v = c / 255;
						return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
					};
					return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
				};
				// The button's fill over the card behind it.
				let back = [255, 255, 255];
				const layers = [];
				for (let at = node; at; at = at.parentElement) {
					const colour = rgb(getComputedStyle(at).backgroundColor);
					if (colour.length === 3 || colour[3] > 0) layers.push(colour);
					if (colour.length === 3 || colour[3] === 1) break;
				}
				for (const layer of layers.reverse()) {
					const alpha = layer.length === 4 ? layer[3] : 1;
					back = back.map((c, i) => layer[i] * alpha + c * (1 - alpha));
				}
				const [x, y] = [luminance(rgb(getComputedStyle(node).color)), luminance(back)].sort(
					(m, n) => n - m
				);
				const style = getComputedStyle(node);
				const icon = node.querySelector('svg');
				return {
					text: node.textContent.trim(),
					icon: Boolean(icon) && icon.getAttribute('aria-hidden') === 'true',
					contrast: (x + 0.05) / (y + 0.05),
					height: node.getBoundingClientRect().height,
					weight: Number(style.fontWeight),
					tinted:
						style.backgroundColor !== getComputedStyle(node.closest('.la-card')).backgroundColor,
					formats: document.getElementById('la-file-formats').textContent,
					formatsShown: document.getElementById('la-file-formats').getClientRects().length > 0,
					accept: document.getElementById('la-file').accept,
					scroll: document.documentElement.scrollWidth - window.innerWidth
				};
			});
			assert.equal(look.text, en['layout_analysis.corpus.file'], `${where}: its words`);
			assert.ok(look.icon, `${where}: a hidden icon`);
			assert.ok(look.contrast >= 4.5, `${where}: text ${look.contrast}`);
			assert.ok(look.height >= 40 && look.weight >= 600, `${where}: a prominent button`);
			assert.ok(look.tinted, `${where}: tinted apart from its card`);
			assert.ok(look.formatsShown, `${where}: the formats beside it`);
			for (const format of ['TXT', 'DOCX', 'ODT', 'PDF'])
				assert.ok(look.formats.includes(format), `${where}: ${look.formats} names ${format}`);
			assert.ok(/\.pdf\b/.test(look.accept) && /\.docx\b/.test(look.accept), look.accept);
			assert.ok(look.scroll <= 0, `${where}: no sideways scroll`);
			// A file loaded under a built-in text becomes the chosen corpus.
			const text = 'Le vif zéphyr jubile sur les kumquats du clown gracieux.';
			await page.setInputFiles('#la-file', {
				name: 'mon-texte.txt',
				mimeType: 'text/plain',
				buffer: Buffer.from(text)
			});
			await page.waitForFunction(() => document.getElementById('la-corpus').value === 'custom');
			assert.equal(await page.inputValue('#la-text'), text, `${where}: its text`);
			assert.equal(await page.textContent('#la-file-name'), 'mon-texte.txt');
			assert.deepEqual(errors, [], `${where}: page errors`);
			await context.close();
		}
}

/**
 * (no-colon-button) The optimiser's buttons in every locale: none holds a colon.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseOptimizerButtons(browser, origin) {
	const locales = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locale_order.json'), 'utf8')
	).order;
	const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	for (const lang of locales) {
		await page.goto(`${origin}/ui/layout_optimizer/index.html?lang=${lang}`);
		await page.waitForFunction(() => {
			const title = document.querySelector('.layout-optimizer h1');
			return title && title.textContent && !title.textContent.startsWith('layout_optimizer.');
		});
		assert.deepEqual(await colonButtons(page), [], `${lang}: optimiser buttons hold a colon`);
	}
	assert.deepEqual(errors, []);
	await page.close();
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
		await exerciseRestoredStartName(browser, origin);
		await exerciseCorpusFileButton(browser, origin);
		await exerciseOptimizerButtons(browser, origin);
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

module.exports = {
	exerciseTabStrip,
	exerciseRestoredStartName,
	exerciseCorpusFileButton,
	exerciseOptimizerButtons,
	colonButtons
};
