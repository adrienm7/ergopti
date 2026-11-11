// tools/test/browser/layout-editor.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Unified Layout Editor Browser Regression
 * DESCRIPTION:
 * Drives the standalone editor page (the one the website frames) in Chromium
 * from a loopback server: edit a key and see its legend, type through a dead
 * key in the live preview, save the TOML and read it back, import a registry
 * .keylayout, export it unchanged, convert it, import the navigation layer,
 * and check that no raw locale key is shown in any of the 21 locales. Page
 * errors and requests outside the loopback origin fail the gate.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
const { shared } = require('../../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const KEYLAYOUT = path.join(ROOT, 'static', 'layouts', 'registry', 'ergopti', 'ergopti.keylayout');
const NAV = shared('keymap', 'layers.recommended.toml');
const SOURCE_FIXTURE = shared('tests', 'corpus', 'layouts', 'source', 'source.toml');
const LOCALES = JSON.parse(fs.readFileSync(shared('data', 'locale_order.json'), 'utf8')).order;
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

/** Serves the shared tree read-only on loopback. */
function serve() {
	const server = http.createServer((request, response) => {
		const file = path.resolve(shared(), new URL(request.url, 'http://localhost').pathname.slice(1));
		if (
			!file.startsWith(shared() + path.sep) ||
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
		server.listen(0, '127.0.0.1', () => resolve(server));
	});
}

async function open(browser, origin, lang) {
	const context = await browser.newContext({
		acceptDownloads: true,
		viewport: { width: 1280, height: 900 }
	});
	await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/') && !request.url().startsWith('blob:'))
			errors.push(`unexpected request: ${request.url()}`);
	});
	page.on('dialog', (dialog) => errors.push(`native dialog: ${dialog.message()}`));
	await page.goto(`${origin}/ui/layout_editor/index.html?lang=${lang}`);
	await page.waitForFunction(() => document.title && !document.title.startsWith('layout_editor.'));
	return { page, errors };
}

async function downloaded(page, click) {
	const [download] = await Promise.all([page.waitForEvent('download'), click()]);
	return {
		name: download.suggestedFilename(),
		text: fs.readFileSync(await download.path(), 'utf8')
	};
}

/** The layout manager page with a recording Linux-style bridge, as ErgoptiPlus hosts it. */
async function exerciseManager(browser, origin) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	const strings = JSON.parse(fs.readFileSync(shared('data', 'locales', 'en.json'), 'utf8'));
	await page.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.__posted = [];
		window.webkit = {
			messageHandlers: {
				layout_manager_bridge: { postMessage: (payload) => window.__posted.push(payload) }
			}
		};
	}, strings);
	await page.goto(`${origin}/ui/layout_manager/index.html`);
	const state = {
		platform: 'linux',
		shortcut_menu_path: 'shortcuts/menu.lua',
		index: { layouts: [] },
		installed: {},
		provided: {},
		builtin: {}
	};
	await page.evaluate((state) => window.initData({ strings: {}, state }), state);
	assert.equal(
		await page.locator('#btn-editor').isVisible(),
		false,
		'no editor without host support'
	);
	assert.equal(
		await page.locator('#btn-compose').isVisible(),
		true,
		'that host keeps the composer'
	);
	await page.evaluate(
		(state) =>
			window.initData({
				strings: {},
				state,
				source_editor: true,
				source_pick: true,
				nav_apply: true
			}),
		state
	);
	assert.equal(
		await page.locator('#btn-compose').isVisible(),
		false,
		'the editor replaces the composer'
	);
	await page.click('#btn-editor');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'source_open'));
	await page.evaluate(() => window.sourceData({ text: null, folder: 'layout_sources/' }));
	await page.waitForSelector('#layout-editor #le-board');
	assert.equal(await page.locator('#layout-view').isVisible(), false);
	// The inline host lists the names table: the magnifier names a character at once.
	assert.equal(await page.evaluate(() => typeof UNICODE_NAMES_DATA), 'object');
	await page.click('#le-board [data-code="KeyQ"]');
	await page.selectOption('#le-kind', 'text');
	await page.click('.le-palette summary');
	await page.hover('#le-palette .le-glyph[title="U+00E9"]');
	assert.match(await page.textContent('#le-magnifier-rows'), /LATIN SMALL LETTER E WITH ACUTE/);
	await page.click('#le-save');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'source_save'));
	const posted = await page.evaluate(() => window.__posted.find((p) => p.action === 'source_save'));
	assert.equal(posted.filename, 'my_layout.toml');
	assert.match(posted.text, /format = "ergopti-layout"/);
	await page.evaluate(() =>
		window.sourceResult({ ok: true, detail: '/c/my_layout.toml', filename: 'my_layout.toml' })
	);
	assert.match(await page.textContent('#le-message'), /ErgoptiPlus/);

	// Fill sources come from the composer host's own list.
	await page.click('#le-fill summary');
	await page.click('#le-fill-load');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_open'));
	const keylayoutText = fs.readFileSync(KEYLAYOUT, 'utf8');
	await page.evaluate(
		(text) =>
			window.composerData({
				sources: [{ id: 'ergopti', name: 'Ergopti', convention: 'iso', text }]
			}),
		keylayoutText
	);
	await page.waitForSelector('#le-fill-source option[value="ergopti"]', { state: 'attached' });
	assert.equal(
		await page.locator('#composer').isVisible(),
		false,
		'the composer section stays closed'
	);

	// A host with a native panel (macOS) opens files for the page.
	await page.click('#le-open');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'source_pick'));
	await page.evaluate((text) => window.sourcePicked({ filename: 'mine.toml', text }), posted.text);
	assert.match(await page.textContent('#le-message'), /mine\.toml/);

	// The source's navigation layer applies through the host's navigation layer save.
	await page.selectOption('#le-nav-hold', 'CapsLock');
	await page.setInputFiles('#le-nav-file', NAV);
	await page.waitForSelector('[data-layer="nav"].active');
	await page.click('#le-apply-nav');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'nav_save'));
	const nav = await page.evaluate(() => window.__posted.find((p) => p.action === 'nav_save'));
	assert.match(nav.text, /\[layers\.nav\.all\]/);
	await page.evaluate(() => window.navResult({ saved: true, applied: true, errors: [] }));
	assert.equal(await page.textContent('#le-message'), strings['layout_editor.status.nav_applied']);
	await page.click('#le-apply-nav');
	await page.evaluate(() =>
		window.navResult({
			saved: false,
			applied: false,
			errors: [{ code: 'unknown_action', detail: 'KeyA' }]
		})
	);
	assert.match(await page.textContent('#le-message'), /unknown_action/);

	// « Install and use » goes through the composer host with the source and its compiled layout.
	await page.click('#le-install');
	await page.click('#le-confirm-yes');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_save'));
	const install = await page.evaluate(() =>
		window.__posted.find((p) => p.action === 'composer_save')
	);
	assert.equal(install.use, true);
	assert.match(install.source, /format = "ergopti-layout"/);
	assert.match(install.keylayout, /<keyboard /);
	assert.equal(install.declaration, undefined);
	// The drivers perform this table for what the .keylayout cannot hold.
	const table = JSON.parse(install.emulation);
	assert.equal(table.format, 'ergopti-layout-emulation');
	assert.match(install.source, new RegExp(`id = "${table.layout}"`));
	await page.evaluate(() =>
		window.composerResult({ action: 'composer_save', ok: true, used: true })
	);
	assert.equal(await page.textContent('#le-message'), strings['layout_editor.status.installed']);
	await page.click('#le-close');
	assert.equal(await page.locator('#layout-view').isVisible(), true);
	assert.deepEqual(errors, []);
	await page.close();
}

(async () => {
	const server = await serve();
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch(
		process.env.CHROMIUM_EXECUTABLE ? { executablePath: process.env.CHROMIUM_EXECUTABLE } : {}
	);
	try {
		const { page, errors } = await open(browser, origin, 'en');

		// A key edit shows on the board and in the saved source.
		await page.click('#le-board [data-code="KeyA"]');
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', 'æ');
		await page.click('#le-apply');
		assert.equal(await page.textContent('#le-board [data-code="KeyA"] .le-legend'), 'æ');

		// The name search loads the names table lazily, then maps a result to the key.
		assert.equal(await page.evaluate(() => typeof UNICODE_NAMES_DATA), 'undefined');
		await page.click('#le-board [data-code="KeyW"]');
		await page.selectOption('#le-kind', 'text');
		await page.click('.le-palette summary');
		await page.fill('#le-name-search', 'e*acute');
		await page.fill('#le-name-limit', '3');
		await page.press('#le-name-search', 'Enter');
		await page.waitForSelector('#le-name-results [data-point="U+00E9"]');
		assert.equal(await page.locator('#le-name-results .le-glyph').count(), 3);
		assert.match(await page.textContent('#le-name-count'), /3/);
		await page.hover('#le-name-results [data-point="U+00E9"]');
		assert.equal(await page.textContent('#le-magnifier-glyph'), 'é');
		assert.match(
			await page.textContent('#le-magnifier-rows'),
			/U\+00E9 LATIN SMALL LETTER E WITH ACUTE · Latin-1 Supplement/
		);
		await page.click('#le-name-results [data-point="U+00E9"]');
		assert.equal(await page.inputValue('#le-text'), 'é');
		await page.click('#le-apply');
		assert.equal(await page.textContent('#le-board [data-code="KeyW"] .le-legend'), 'é');
		// A rendered page keeps the palette open with its last answer.
		assert.equal(await page.locator('#le-name-results [data-point="U+00E9"]').count(), 1);
		// Dropping a result on another key maps that key to the character (the two are
		// far apart on the page, so the drag events carry one DataTransfer directly).
		const transfer = await page.evaluateHandle(() => new DataTransfer());
		await page.dispatchEvent('#le-name-results [data-point="U+00C9"]', 'dragstart', {
			dataTransfer: transfer
		});
		await page.dispatchEvent('#le-board [data-code="KeyE"]', 'drop', { dataTransfer: transfer });
		assert.equal(await page.textContent('#le-board [data-code="KeyE"] .le-legend'), 'É');
		// Hovering a key magnifies its legend; Copy puts it on the clipboard.
		await page.hover('#le-board [data-code="KeyE"]');
		assert.equal(await page.textContent('#le-magnifier-glyph'), 'É');
		await page.click('#le-magnifier-copy');
		assert.equal(await page.evaluate(() => navigator.clipboard.readText()), 'É');
		await page.click('#le-undo');
		await page.click('#le-undo');

		// A dead key with a rule types its composition in the preview.
		await page.click('#le-dead-keys summary');
		await page.fill('#le-dead-id', 'circ');
		await page.fill('#le-dead-terminator', '^');
		await page.click('#le-dead-add');
		await page.fill('#le-rule-input', 'æ');
		await page.fill('#le-rule-output', 'ǣ');
		await page.click('#le-rule-add');
		await page.click('#le-board [data-code="BracketLeft"]');
		await page.selectOption('#le-kind', 'dead_key');
		await page.selectOption('#le-dead', 'circ');
		await page.click('#le-apply');
		await page.focus('#le-preview-input');
		await page.keyboard.press('BracketLeft');
		await page.keyboard.press('KeyA');
		await page.keyboard.press('BracketLeft');
		await page.keyboard.press('BracketLeft');
		assert.equal(await page.textContent('#le-preview-output'), 'ǣ^');

		const saved = await downloaded(page, () => page.click('#le-save'));
		assert.equal(saved.name, 'my_layout.toml');
		assert.match(saved.text, /format = "ergopti-layout"/);
		assert.match(saved.text, /dead_key = "circ"/);

		// Undo reverts the last edit.
		await page.click('#le-undo');
		assert.equal(await page.textContent('#le-board [data-code="BracketLeft"] .le-legend'), '');

		// A .keylayout imports verbatim, exports unchanged, then converts to editable layers.
		await page.selectOption('#le-import-convention', 'iso');
		await page.setInputFiles('#le-open-file', KEYLAYOUT);
		await page.waitForSelector('#le-preserved');
		assert.equal(await page.locator('#le-macos-format').count(), 0, 'an import keeps its variant');
		assert.equal(await page.getAttribute('#le-export-macos', 'data-format'), 'iso');
		const exported = await downloaded(page, () => page.click('#le-export-macos'));
		assert.equal(exported.text, fs.readFileSync(KEYLAYOUT, 'utf8'));
		await page.click('#le-convert');
		await page.click('#le-confirm-yes');
		await page.waitForSelector('#le-lost');
		assert.notEqual(await page.textContent('#le-board [data-code="KeyA"] .le-legend'), '');
		// The converted source compiles both variants through the shared compiler.
		// The macOS drop-down chooses the download: one .keylayout, or the bundle as one ZIP.
		await page.selectOption('#le-macos-format', 'ansi');
		const compiled = await downloaded(page, () => page.click('#le-export-macos'));
		assert.match(compiled.text, /<keyboard /);
		assert.notEqual(compiled.text, fs.readFileSync(KEYLAYOUT, 'utf8'));
		await page.selectOption('#le-macos-format', 'iso');
		const iso = await downloaded(page, () => page.click('#le-export-macos'));
		assert.notEqual(iso.text, compiled.text, 'ISO and ANSI differ');
		await page.selectOption('#le-macos-format', 'bundle');
		const [bundle] = await Promise.all([
			page.waitForEvent('download'),
			page.click('#le-export-macos')
		]);
		assert.match(bundle.suggestedFilename(), /\.bundle\.zip$/);
		assert.equal(
			fs
				.readFileSync(await bundle.path())
				.subarray(0, 2)
				.toString('latin1'),
			'PK'
		);

		// Drag and drop swaps two keys; copy and paste repeats one.
		const legendOf = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
		const [a, s] = [await legendOf('KeyA'), await legendOf('KeyS')];
		await page.dragAndDrop('#le-board [data-code="KeyA"]', '#le-board [data-code="KeyS"]');
		assert.deepEqual([await legendOf('KeyA'), await legendOf('KeyS')], [s, a]);
		await page.click('#le-board [data-code="KeyA"]');
		await page.click('#le-copy');
		await page.click('#le-board [data-code="KeyD"]');
		await page.click('#le-paste');
		assert.equal(await legendOf('KeyD'), s);

		// The ANSI board has no ISO extra key; Windows flags and exact stickers apply.
		await page.selectOption('#le-board-form', 'ansi');
		assert.equal(await page.locator('#le-board [data-code="IntlBackslash"]').count(), 0);
		await page.selectOption('#le-board-form', 'iso');
		await page.click('#le-windows summary');
		await page.fill('#le-win-flags', 'kllf_altgr');
		await page.click('#le-win-flags-apply');
		assert.equal(await page.inputValue('#le-win-flags'), 'kllf_altgr');
		await page.fill('#le-sticker-mm', '18');
		await page.dispatchEvent('#le-sticker-mm', 'change');
		assert.match(await page.getAttribute('#le-stickers', 'style'), /--le-sticker-size:18mm/);
		await page.click('#le-undo');

		// KbdEdit's automatic case mapping fills Shift, replacing it only when asked.
		await page.click('[data-layer="base"]');
		await page.click('#le-board [data-code="KeyD"]');
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', 'ŵ');
		await page.check('#le-case-overwrite');
		await page.click('#le-apply');
		await page.click('[data-layer="shift"]');
		assert.equal(await legendOf('KeyD'), 'Ŵ');
		// Stickers print the chosen levels and can hide a Shift legend that is only the capital.
		const sticker = (level) =>
			page.evaluate(
				(cls) =>
					[...document.querySelectorAll(`#le-stickers .le-sticker-${cls}`)].map(
						(e) => e.textContent
					),
				level
			);
		assert.ok((await sticker('shift')).includes('Ŵ'));
		await page.click('#le-sticker-levels summary');
		await page.check('#le-sticker-hide-case');
		assert.ok(!(await sticker('shift')).includes('Ŵ'), 'the capital of the base is hidden');
		await page.click('#le-sticker-levels summary');
		await page.uncheck('#le-sticker-layer-shift');
		assert.equal((await sticker('shift')).length, 0, 'an unchosen level is not printed');
		// « Move every key »: the Shift layer's mappings go to the base layer at once.
		await page.click('#le-move-all summary');
		await page.selectOption('#le-move-target', 'base');
		await page.click('#le-move-layer');
		assert.equal(await legendOf('KeyD'), '', 'the moved layer is empty');
		await page.click('[data-layer="base"]');
		assert.equal(await legendOf('KeyD'), 'Ŵ');
		await page.click('#le-undo');
		await page.click('#le-undo');

		// The composer's job: fill the base layer from AZERTY. This loopback server
		// has no registry folder, so the panel says the catalogue list failed.
		await page.click('[data-layer="base"]');
		await page.click('#le-fill summary');
		await page.click('#le-fill-load');
		await page.waitForSelector('#le-fill-source');
		assert.equal(await page.locator('#le-fill .le-message.error').count(), 1);
		await page.selectOption('#le-fill-source', 'azerty');
		await page.selectOption('#le-fill-level', 'base');
		await page.click('#le-fill-apply');
		await page.click('#le-confirm-yes');
		assert.equal(await legendOf('KeyQ'), 'a');

		// The navigation layer imports as a layer and exports as layers.toml again.
		await page.selectOption('#le-nav-hold', 'CapsLock');
		await page.setInputFiles('#le-nav-file', NAV);
		await page.waitForSelector('[data-layer="nav"].active');
		const nav = await downloaded(page, () => page.click('#le-export-nav'));
		assert.equal(nav.name, 'layers.toml');
		assert.match(nav.text, /\[layers\.nav\.all\]/);

		// Reopening the saved source restores it.
		const reopened = path.join(require('node:os').tmpdir(), `layout-editor-${process.pid}.toml`);
		fs.writeFileSync(reopened, saved.text);
		try {
			await page.setInputFiles('#le-open-file', reopened);
			await page.waitForFunction(() => document.querySelector('#le-name').value === 'My layout');
		} finally {
			fs.rmSync(reopened);
		}

		// The preview types through the web emulation: a tap-hold's tap and a shortcut.
		await page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
		await page.waitForFunction(() => document.querySelector('#le-name').value === 'Source Fixture');
		await page.focus('#le-preview-input');
		await page.keyboard.press('KeyA');
		await page.keyboard.press('Space');
		await page.keyboard.press('Control+KeyA');
		assert.equal(await page.textContent('#le-preview-output'), 'a ⟨control+KeyB⟩');
		assert.deepEqual(errors, []);
		await page.close();

		// Inside the layout manager window, the same editor saves through the host.
		await exerciseManager(browser, origin);

		// Every locale names every visible string.
		for (const lang of LOCALES) {
			const opened = await open(browser, origin, lang);
			for (const selector of ['#le-dead-keys summary', '#le-modifiers summary'])
				await opened.page.click(selector);
			await opened.page.click('#le-board [data-code="KeyQ"]');
			const raw = await opened.page.evaluate(() => {
				const texts = [document.title];
				for (const node of document.querySelectorAll('body *')) {
					if (node.children.length === 0) texts.push(node.textContent);
					if (node.placeholder) texts.push(node.placeholder);
					if (node.title) texts.push(node.title);
				}
				return texts.filter((text) => /layout_editor\.|sg_actions\.|layer_editor\./.test(text));
			});
			assert.deepEqual(raw, [], `${lang}: raw locale keys are shown`);
			assert.deepEqual(opened.errors, [], `${lang}: page errors`);
			await opened.page.close();
		}
		console.log(`ok - layout editor page: editing, preview, files and ${LOCALES.length} locales`);
	} finally {
		await browser.close();
		server.close();
	}
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
