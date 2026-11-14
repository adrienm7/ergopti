// tools/test/browser/layout-editor.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Unified Layout Editor Browser Regression
 * DESCRIPTION:
 * Drives the standalone editor page (the one the website frames) in Chromium
 * from a loopback server: edit a key and see its legend, type through a dead
 * key in the live preview, save the TOML and read it back, import a registry
 * .keylayout, export it unchanged, convert it, import the navigation layer,
 * show and add the Base, Shift, AltGr and Shift+AltGr layers from the layer
 * selector, lay out at phone width in light and dark without a sideways page
 * scroll, fit every key label inside its key, override shortcuts per modifier
 * combination through save and reload, and check that no raw locale key is shown in any tool tab of the 21
 * locales. Page errors and requests outside the loopback origin fail the gate.
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
const NAV = shared('layouts', 'data', 'layers.recommended.toml');
const SOURCE_FIXTURE = shared('tests', 'corpus', 'layouts', 'source', 'source.toml');
const LOCALES = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locale_order.json'), 'utf8')
).order;
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

// The XKB converter data the site serves beside the shared tree, at the URL the
// standalone host computes from the page (../../../../ergopti/linux/...).
const XKB_DATA_URL = '/ergopti/linux/xkb_generation/data/';
const XKB_DATA = path.join(ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');

/** Serves the shared tree and the XKB converter data read-only on loopback. */
function serve() {
	const server = http.createServer((request, response) => {
		const pathname = new URL(request.url, 'http://localhost').pathname;
		const [root, relative] = pathname.startsWith(XKB_DATA_URL)
			? [XKB_DATA, pathname.slice(XKB_DATA_URL.length)]
			: [shared(), pathname.slice(1)];
		const file = path.resolve(root, relative);
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

/**
 * Gives every browser the removal semantics of the engines that commit a focused
 * field's change while removing it (Chromium in CI, the drivers' webviews):
 * replaceChildren removes the old children one by one and, before removing the
 * one holding focus, fires that field's change while it is still attached. A
 * handler that re-renders there makes the replacement throw, as it did in CI on
 * 2026-11-14; other Chromium builds do not fire it, so the page must not depend
 * on either behaviour. Runs in the page (from worker G's 90b2446702).
 */
function commitFocusedFieldOnRemoval() {
	const replace = Element.prototype.replaceChildren;
	Element.prototype.replaceChildren = function (...nodes) {
		for (const child of [...this.childNodes]) {
			const active = document.activeElement;
			if (active && active !== document.body && child.contains(active))
				active.dispatchEvent(new Event('change', { bubbles: true }));
			if (child.parentNode !== this)
				throw new DOMException(
					"Failed to execute 'replaceChildren' on 'Element': The node to be removed is no longer a child of this node.",
					'NotFoundError'
				);
			child.remove();
		}
		replace.apply(this, nodes);
	};
}

async function open(browser, origin, lang) {
	const context = await browser.newContext({
		acceptDownloads: true,
		viewport: { width: 1280, height: 900 }
	});
	await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
	await context.addInitScript(commitFocusedFieldOnRemoval);
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

/** Shows one of the editor's secondary tools (the tab strip under the board). */
function tool(page, id) {
	return page.click(`#le-tools [data-tool="${id}"]`);
}

/** The raw locale keys the page shows (texts, placeholders and titles). */
function rawKeys(page) {
	return page.evaluate(() => {
		const texts = [document.title];
		for (const node of document.querySelectorAll('body *')) {
			if (node.children.length === 0) texts.push(node.textContent);
			if (node.placeholder) texts.push(node.placeholder);
			if (node.title) texts.push(node.title);
			if (node.getAttribute('aria-label')) texts.push(node.getAttribute('aria-label'));
		}
		return texts.filter((text) => /layout_editor\.|sg_actions\.|layer_editor\./.test(text));
	});
}

async function downloaded(page, click) {
	const [download] = await Promise.all([page.waitForEvent('download'), click()]);
	return {
		name: download.suggestedFilename(),
		text: fs.readFileSync(await download.path(), 'utf8')
	};
}

/** The layout editor's own window with a recording Linux-style bridge, as ErgoptiPlus hosts it. */
async function exerciseManager(browser, origin) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await page.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.__posted = [];
		window.webkit = {
			messageHandlers: {
				layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
			}
		};
	}, strings);
	await page.goto(`${origin}/ui/layout_editor_window/index.html`);
	const state = {
		platform: 'linux',
		shortcut_menu_path: 'shortcuts/menu.lua',
		index: { layouts: [] },
		installed: {},
		provided: {},
		builtin: {}
	};
	await page.evaluate(
		(state) =>
			window.initData({
				strings: {},
				state,
				source_editor: true,
				source_pick: true,
				nav_apply: true,
				emulate: true
			}),
		state
	);
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'ready'));
	// The host answers the window's ready with the last saved source.
	await page.evaluate(() => window.sourceData({ text: null, folder: 'layout_sources/' }));
	await page.waitForSelector('#layout-editor #le-board');
	// (layout-editor-no-null-text) A section that renders nothing (the « Start
	// from » panel when no start is open) leaves no text node behind: the root
	// once received null and showed « null » under the toolbar.
	assert.deepEqual(
		await page.evaluate(() =>
			Array.from(document.getElementById('layout-editor').childNodes)
				.filter((node) => node.nodeType === Node.TEXT_NODE)
				.map((node) => node.textContent)
		),
		[],
		'the editor root holds elements only'
	);
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
	await tool(page, 'fill');
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

	// A host with a native panel (macOS) opens files for the page.
	await page.click('#le-open');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'source_pick'));
	await page.evaluate((text) => window.sourcePicked({ filename: 'mine.toml', text }), posted.text);
	assert.match(await page.textContent('#le-message'), /mine\.toml/);

	// The source's navigation layer applies through the host's navigation layer save.
	await tool(page, 'navigation');
	await page.selectOption('#le-nav-hold', 'CapsLock');
	await page.setInputFiles('#le-nav-file', NAV);
	await page.waitForSelector('[data-layer="nav"].active');
	await tool(page, 'export');
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

	// « Emulate without installing » stores the source for the driver's emulation alone.
	assert.equal(await page.textContent('#le-install'), strings['layout_editor.btn.install']);
	assert.equal(await page.textContent('#le-install-hint'), strings['layout_editor.install_hint']);
	assert.equal(await page.textContent('#le-emulate-hint'), strings['layout_editor.emulate_hint']);
	await page.click('#le-emulate');
	await page.click('#le-confirm-yes');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_emulate'));
	const emulate = await page.evaluate(() =>
		window.__posted.find((p) => p.action === 'composer_emulate')
	);
	assert.equal(emulate.use, undefined, 'nothing is selected in the system');
	assert.equal(emulate.source, install.source);
	assert.equal(emulate.keylayout, install.keylayout);
	assert.equal(emulate.emulation, install.emulation);
	await page.evaluate(() =>
		window.composerResult({ action: 'composer_emulate', ok: false, code: 'emulate_failed' })
	);
	assert.equal(
		await page.textContent('#le-message'),
		strings['layout_editor.error.emulate_failed']
	);
	await page.click('#le-emulate');
	await page.click('#le-confirm-yes');
	await page.evaluate(() =>
		window.composerResult({ action: 'composer_emulate', ok: true, used: true })
	);
	assert.equal(await page.textContent('#le-message'), strings['layout_editor.status.emulated']);

	// « New » starts blank or from a reference or a catalogue layout of the host.
	await page.click('#le-new');
	const starts = await page.$$eval('#le-start [data-start]', (buttons) =>
		buttons.map((button) => button.dataset.start)
	);
	assert.deepEqual(starts, ['blank', 'qwerty', 'azerty', 'ergopti']);
	await page.click('#le-start [data-start="ergopti"]');
	if (await page.locator('#le-confirm-yes').count()) await page.click('#le-confirm-yes');
	await page.waitForSelector('#le-start', { state: 'detached' });
	await tool(page, 'details');
	assert.equal(await page.inputValue('#le-name'), 'My Ergopti');
	await page.click('#le-new');
	await page.click('#le-start [data-start="blank"]');
	await page.waitForSelector('#le-start', { state: 'detached' });
	assert.equal(await page.inputValue('#le-name'), strings['layout_editor.default_name']);
	// « Close » closes the editor's own window through the host.
	await page.click('#le-close');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'close'));
	assert.deepEqual(errors, []);
	await page.close();
}

/**
 * The layer selector shows the four character levels of any layout, adds a missing
 * one in one click, finds a level by its modifiers whatever the layer is called,
 * and lists the layout's other layers.
 */
async function exerciseLayerSelector(browser, origin) {
	const { page, errors } = await open(browser, origin, 'en');
	const levels = () =>
		page.$$eval('#le-layerbar [data-level]', (buttons) =>
			buttons.map((b) => [
				b.dataset.level,
				b.dataset.layer || null,
				b.classList.contains('missing')
			])
		);
	assert.deepEqual(await levels(), [
		['base', 'base', false],
		['shift', null, true],
		['altgr', null, true],
		['shift_altgr', null, true]
	]);
	assert.equal(await page.getAttribute('[data-layer="base"]', 'aria-selected'), 'true');
	// A blank layout names no key by its raw code (« KeyQ », « Digit1 », « MetaLeft »).
	const codes = await page.$$eval('#le-board .le-key', (keys) =>
		keys
			.filter((key) => key.querySelector('.le-code').textContent === key.dataset.code)
			.map((key) => key.dataset.code)
	);
	assert.deepEqual(codes, [], 'raw key codes shown on the board');
	// A missing level is added with its modifiers and shown at once.
	await page.click('#le-layerbar [data-level="altgr"]');
	await page.waitForSelector('[data-layer="altgr"].active');
	const map = async (code, text) => {
		await page.click(`#le-board [data-code="${code}"]`);
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', text);
		await page.click('#le-apply');
	};
	await map('KeyQ', '@');
	const legendOf = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	assert.equal(await legendOf('KeyQ'), '@');
	await page.click('[data-layer="base"]');
	assert.equal(await legendOf('KeyQ'), '', 'the base layer keeps its own key');
	await map('KeyW', 'w');
	await page.click('[data-layer="altgr"]');
	// Another layer shows its own value only, never the base character as a hint.
	assert.equal(await legendOf('KeyW'), '');
	assert.equal(await page.textContent('#le-board [data-code="KeyW"] .le-code'), '');
	await page.click('[data-layer="altgr"]');
	assert.equal(await legendOf('KeyQ'), '@');
	const saved = await downloaded(page, () => page.click('#le-save'));
	assert.match(saved.text, /id = "altgr"\s+required = \[ ?"alt" ?\]/);
	// « Manage layers… » opens the layer tool; Undo removes the added level again.
	await page.click('#le-manage-layers');
	await page.waitForSelector('#le-layers #le-layer-add');
	// Three edits: the AltGr layer, its KeyQ and the base KeyW.
	for (let undo = 0; undo < 3; undo++) await page.click('#le-undo');
	await page.waitForSelector('#le-layerbar [data-level="altgr"].missing');
	// A source names its levels freely: AltGr is the layer held with Right Alt.
	await page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
	await page.waitForSelector('[data-layer="option"][data-level="altgr"]');
	assert.deepEqual(await levels(), [
		['base', 'base', false],
		['shift', 'shift', false],
		['altgr', 'option', false],
		['shift_altgr', null, true]
	]);
	assert.deepEqual(
		await page.$$eval('#le-layerbar .le-other-layers [data-layer]', (buttons) =>
			buttons.map((b) => b.dataset.layer)
		),
		['kana', 'command']
	);
	// The chips read as the keycaps name their modifiers; the id stays in the tooltip.
	const chips = await page.$$eval('#le-layerbar .le-other-layers [data-layer]', (buttons) =>
		buttons.map((b) => [b.textContent, b.title])
	);
	assert.deepEqual(chips, [
		['kana_lock', 'kana (kana_lock)'],
		['Win / ⌘ / Super', 'command (meta)']
	]);
	const en = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await tool(page, 'layers');
	await page.fill('#le-layer-id', 'shift_caps_lock');
	await page.check('#le-layer-required input[value="shift"]');
	await page.check('#le-layer-required input[value="caps_lock"]');
	await page.click('#le-layer-add');
	assert.equal(
		await page.textContent('[data-layer="shift_caps_lock"]'),
		`${en['layer_editor.key.shift']} + ${en['layer_editor.key.caps_lock']}`
	);
	assert.match(
		await page.getAttribute('[data-layer="shift_caps_lock"]', 'title'),
		/^shift_caps_lock /
	);
	await page.click('[data-layer="option"]');
	assert.equal(await page.getAttribute('[data-layer="option"]', 'aria-selected'), 'true');
	// The analysis panel lives in the side slot and survives a render.
	const panel = await page.$('#le-side-slot > .la-panel');
	assert.ok(panel, 'the analysis panel is in the side slot');
	await page.click('[data-layer="base"]');
	assert.ok(
		await panel.evaluate((node) => node.isConnected && node.parentElement.id === 'le-side-slot')
	);
	// Every section reaches the page as an element: a hidden one is not printed as « null ».
	assert.deepEqual(
		await page.$$eval('#layout-editor', ([root]) =>
			[...root.childNodes].filter((node) => node.nodeType !== 1).map((node) => node.textContent)
		),
		[]
	);
	assert.deepEqual(errors, []);
	await page.context().close();
}

/**
 * The « Shortcuts » view: a key with no override reads « = » (same as the base
 * key); an override for any modifier combination sends any chord, is marked on
 * the board, listed with Edit and Remove, named by the export tab for the
 * targets that cannot hold it, and kept through save and reload.
 */
async function exerciseShortcuts(browser, origin) {
	const { page, errors } = await open(browser, origin, 'en');
	// « é » on the base layer, where Ergopti has it, so Ctrl+é is Ctrl + that key.
	await page.click('#le-board [data-code="KeyW"]');
	await page.selectOption('#le-kind', 'text');
	await page.fill('#le-text', 'é');
	await page.click('#le-apply');
	await page.click('#le-shortcut-view');
	assert.equal(await page.getAttribute('#le-shortcut-view', 'aria-selected'), 'true');
	assert.equal(await page.getAttribute('[data-layer="base"]', 'aria-selected'), 'false');
	const key = (code) =>
		page.$eval(`#le-board [data-code="${code}"]`, (node) => ({
			legend: node.querySelector('.le-legend').textContent,
			overridden: node.classList.contains('overridden'),
			same: node.classList.contains('same')
		}));
	assert.deepEqual(await key('KeyW'), { legend: '=', overridden: false, same: true });
	assert.equal(await page.locator('#le-shortcut-none').count(), 1);
	const define = async (code, from, sendKey, to) => {
		await page.click(`#le-board [data-code="${code}"]`);
		for (const mod of from) await page.check(`#le-shortcut-from input[value="${mod}"]`);
		await page.selectOption('#le-shortcut-send', sendKey);
		for (const mod of to) await page.check(`#le-shortcut-to input[value="${mod}"]`);
		await page.click('#le-shortcut-add');
	};
	// Ctrl+é sends Ctrl+Shift+C; Ctrl+A sends Ctrl+B.
	await define('KeyW', ['control'], 'KeyC', ['control', 'shift']);
	await define('KeyQ', ['control'], 'KeyB', ['control']);
	assert.ok((await key('KeyW')).overridden, 'an overridden key is marked');
	assert.ok((await key('KeyQ')).overridden);
	assert.ok((await key('KeyE')).same);
	// A combination needs a modifier: the refusal says so and nothing is added.
	await page.click('#le-board [data-code="KeyE"]');
	await page.click('#le-shortcut-add');
	assert.match(await page.textContent('#le-message'), /modifier/);
	assert.ok((await key('KeyE')).same);
	// Edit changes the chord sent; Cancel leaves the override as it was.
	await page.click('#le-board [data-code="KeyQ"]');
	assert.equal(await page.locator('#le-shortcuts li').count(), 1);
	await page.click('#le-shortcuts .le-shortcut-edit');
	assert.ok(await page.isChecked('#le-shortcut-from input[value="control"]'));
	assert.equal(await page.inputValue('#le-shortcut-send'), 'KeyB');
	await page.click('#le-shortcut-cancel');
	await page.click('#le-shortcuts .le-shortcut-edit');
	await page.check('#le-shortcut-from input[value="alt"]');
	await page.click('#le-shortcut-add');
	assert.equal(
		await page.locator('#le-shortcuts li').count(),
		1,
		'the edited combination replaces the old one'
	);
	await page.click('#le-undo');
	assert.equal(await page.locator('#le-shortcuts li').count(), 1);
	// Remove, then undo, keeps the history honest.
	await page.click('#le-shortcuts .le-shortcut-remove');
	assert.equal(await page.locator('#le-shortcuts li').count(), 0);
	await page.click('#le-undo');
	assert.equal(await page.locator('#le-shortcuts li').count(), 1);
	// The one-action default: every other combination of é acts as the key C,
	// chosen in the list; the explicit Ctrl override above still wins.
	await page.click('#le-board [data-code="KeyW"]');
	await page.selectOption('#le-shortcut-key', 'KeyC');
	assert.equal((await key('KeyW')).legend, 'C +1');
	// … or picked on the board: KeyE acts as KeyR.
	await page.click('#le-board [data-code="KeyE"]');
	await page.click('#le-shortcut-key-pick');
	assert.equal(await page.getAttribute('#le-shortcut-key-pick', 'aria-pressed'), 'true');
	await page.click('#le-board [data-code="KeyR"]');
	assert.equal((await key('KeyE')).legend, 'R');
	assert.ok((await key('KeyE')).overridden);
	assert.equal(await page.inputValue('#le-shortcut-key'), 'KeyR');
	// « Same as the base key » clears it, and undo brings it back.
	await page.selectOption('#le-shortcut-key', '');
	assert.ok((await key('KeyE')).same);
	await page.click('#le-undo');
	assert.equal((await key('KeyE')).legend, 'R');
	// The export tab names the targets that cannot hold them.
	await tool(page, 'export');
	assert.match(await page.textContent('#le-export-shortcuts'), /\(4\)/);
	assert.match(await page.textContent('#le-export-shortcuts'), /ErgoptiPlus/);
	// Save and reload: both overrides come back from the TOML.
	const saved = await downloaded(page, () => page.click('#le-save'));
	const sorted = (list) => list.slice().sort();
	assert.deepEqual(
		require('smol-toml')
			.parse(saved.text)
			.shortcuts.map((entry) => [
				entry.key,
				sorted(entry.modifiers),
				entry.send_key,
				sorted(entry.send_modifiers)
			]),
		[
			['KeyW', ['control'], 'KeyC', ['control', 'shift']],
			['KeyQ', ['control'], 'KeyB', ['control']]
		]
	);
	const parsedKeys = require('smol-toml').parse(saved.text).keys;
	assert.equal(parsedKeys.KeyW.shortcut_key, 'KeyC');
	assert.equal(parsedKeys.KeyE.shortcut_key, 'KeyR');
	const reopened = path.join(require('node:os').tmpdir(), `layout-shortcuts-${process.pid}.toml`);
	fs.writeFileSync(reopened, saved.text);
	try {
		await page.click('#le-new');
		await page.click('#le-start [data-start="blank"]');
		if (await page.locator('#le-confirm-yes').count()) await page.click('#le-confirm-yes');
		await page.setInputFiles('#le-open-file', reopened);
	} finally {
		fs.rmSync(reopened);
	}
	await page.click('#le-shortcut-view');
	assert.ok((await key('KeyW')).overridden);
	assert.ok((await key('KeyQ')).overridden);
	await page.click('#le-board [data-code="KeyW"]');
	assert.match(await page.textContent('#le-shortcuts li'), /→ .*C/);
	assert.equal(await page.inputValue('#le-shortcut-key'), 'KeyC');
	assert.equal((await key('KeyE')).legend, 'R');
	// Back on a layer, the board edits mappings again.
	await page.click('[data-layer="base"]');
	assert.equal(await page.textContent('#le-board [data-code="KeyW"] .le-legend'), 'é');
	assert.deepEqual(errors, []);
	await page.context().close();
}

/**
 * Every key label stays inside its key: a long one shrinks to fit, and one still
 * too long at the smallest size is cut with an ellipsis and shown whole in the
 * key's tooltip, on every layer, both geometries, wide and at phone width.
 */
async function exerciseLongLabels(browser, origin) {
	const { page, errors } = await open(browser, origin, 'en');
	const map = async (code, text) => {
		await page.click(`#le-board [data-code="${code}"]`);
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', text);
		await page.click('#le-apply');
	};
	const LONG = 'Bonjour tout le monde, voici un très long texte';
	await map('KeyA', LONG);
	await map('KeyS', 'ÉÉÉÉ');
	await map('Space', '→ → → → → → → → → → → →');
	await map('Backspace', 'Effacer en arrière');
	// A dead key with a long terminator, and the same labels on a second layer.
	await tool(page, 'dead_keys');
	await page.fill('#le-dead-id', 'long');
	await page.fill('#le-dead-terminator', 'ˆ˜¨˝˘');
	await page.click('#le-dead-add');
	await page.click('#le-board [data-code="KeyD"]');
	await page.selectOption('#le-kind', 'dead_key');
	await page.selectOption('#le-dead', 'long');
	await page.click('#le-apply');
	await page.click('#le-layerbar [data-level="altgr"]');
	await page.waitForSelector('[data-layer="altgr"].active');
	await map('KeyQ', LONG);
	await map('Digit1', '«»«»«»«»');
	const overflowing = () =>
		page.$$eval('#le-board .le-key', (keys) =>
			keys
				.map((key) => {
					const legend = key.querySelector('.le-legend');
					const box = key.getBoundingClientRect();
					const text = legend.getBoundingClientRect();
					const inside =
						legend.scrollWidth <= legend.clientWidth ||
						getComputedStyle(legend).textOverflow === 'ellipsis';
					const fits = text.left >= box.left - 0.5 && text.right <= box.right + 0.5;
					const whole = !legend.textContent || key.title.includes(legend.textContent);
					return inside && fits && whole ? null : key.dataset.code;
				})
				.filter(Boolean)
		);
	for (const width of [1440, 375]) {
		await page.setViewportSize({ width, height: 900 });
		for (const form of ['iso', 'ansi']) {
			await page.selectOption('#le-board-form', form);
			for (const layer of ['base', 'altgr']) {
				await page.click(`[data-layer="${layer}"]`);
				assert.deepEqual(await overflowing(), [], `${width}px ${form} ${layer}: labels overflow`);
			}
		}
	}
	// The long sentence is cut and named whole by its tooltip; a short one only shrinks.
	await page.setViewportSize({ width: 1440, height: 900 });
	await page.click('[data-layer="base"]');
	assert.ok(
		await page.$eval('#le-board [data-code="KeyA"] .le-legend', (n) => n.classList.contains('cut'))
	);
	assert.ok(
		(await page.getAttribute('#le-board [data-code="KeyA"]', 'title')).endsWith(LONG),
		'the tooltip holds the whole label'
	);
	const ss = await page.$eval('#le-board [data-code="KeyS"] .le-legend', (n) => ({
		cut: n.classList.contains('cut'),
		size: parseFloat(getComputedStyle(n).fontSize)
	}));
	assert.ok(!ss.cut && ss.size >= 9, 'a short label is not cut');
	assert.deepEqual(errors, []);
	await page.context().close();
}

/** At phone width, in light and dark, the page never scrolls sideways and stacks its columns. */
async function exercisePhoneWidth(browser, origin) {
	const backgrounds = [];
	for (const colorScheme of ['light', 'dark']) {
		const context = await browser.newContext({
			viewport: { width: 375, height: 812 },
			colorScheme
		});
		const page = await context.newPage();
		const errors = [];
		page.on('pageerror', (error) => errors.push(error.message));
		await page.goto(`${origin}/ui/layout_editor/index.html?lang=fr`);
		await page.waitForSelector('#le-board');
		await page.click('#le-board [data-code="KeyA"]');
		const layout = await page.evaluate(() => {
			const box = (selector) => document.querySelector(selector).getBoundingClientRect();
			const inside = (selector) =>
				[...document.querySelectorAll(selector)].every((node) => {
					const rect = node.getBoundingClientRect();
					return rect.left >= 0 && rect.right <= window.innerWidth;
				});
			return {
				pageWidth: document.documentElement.scrollWidth,
				viewport: window.innerWidth,
				toolbarInside: inside('.le-toolbar button'),
				levelsInside: inside('#le-layerbar [data-level]'),
				toolTabsInside: inside('#le-tools [data-tool]'),
				boardScrolls: (() => {
					const scroller = document.querySelector('.le-board-scroll');
					return scroller.scrollWidth > scroller.clientWidth;
				})(),
				smallestKey: Math.min(
					...[...document.querySelectorAll('#le-board .le-key')].map(
						(key) => key.getBoundingClientRect().width
					)
				),
				inspectorBelowBoard: box('#le-inspector').top >= box('#le-board').bottom,
				toolsBelowInspector: box('#le-tools').top >= box('#le-inspector').bottom,
				background: getComputedStyle(document.querySelector('#layout-editor')).backgroundColor
			};
		});
		assert.equal(layout.pageWidth, layout.viewport, `${colorScheme}: no sideways page scroll`);
		assert.ok(layout.toolbarInside, `${colorScheme}: the primary toolbar fits the screen`);
		assert.ok(layout.levelsInside, `${colorScheme}: the four levels fit the screen`);
		assert.ok(layout.inspectorBelowBoard, `${colorScheme}: the inspector stacks under the board`);
		assert.ok(layout.toolsBelowInspector, `${colorScheme}: the tools come last`);
		assert.ok(layout.toolTabsInside, `${colorScheme}: every tool tab is shown whole`);
		// The keys keep a readable size: the board scrolls sideways on its own, the page does not.
		assert.ok(layout.boardScrolls, `${colorScheme}: the board has its own sideways scroll`);
		assert.ok(
			layout.smallestKey >= 36,
			`${colorScheme}: keys stay readable (${layout.smallestKey})`
		);
		// Every key can be reached: the last one scrolls into view and is clicked.
		await page.locator('#le-board [data-code="ArrowRight"]').scrollIntoViewIfNeeded();
		await page.click('#le-board [data-code="ArrowRight"]');
		assert.equal(
			await page.textContent('#le-inspector h2'),
			await page.getAttribute('#le-board [data-code="ArrowRight"]', 'title')
		);
		assert.equal(
			await page.evaluate(() => document.documentElement.scrollWidth),
			layout.viewport,
			`${colorScheme}: scrolling the board does not scroll the page`
		);
		// Every tool opens without widening the page.
		for (const id of await page.$$eval('#le-tools [data-tool]', (tabs) =>
			tabs.map((tab) => tab.dataset.tool)
		)) {
			await tool(page, id);
			assert.equal(
				await page.evaluate(() => document.documentElement.scrollWidth),
				layout.viewport,
				`${colorScheme}: the ${id} tool fits the screen`
			);
		}
		backgrounds.push(layout.background);
		assert.deepEqual(errors, []);
		await context.close();
	}
	assert.notEqual(backgrounds[0], backgrounds[1], 'the dark theme changes the page background');
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

		// A tap-hold delay or a virtual key outside its shared value schema
		// declaration is refused with the text naming the range, and nothing is
		// applied (value-validation).
		const strings = JSON.parse(
			fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
		);
		const thresholdRange = strings['dialog.value_check.range_integer_unit']
			.replace('{1}', '1')
			.replace('{2}', '10000')
			.replace('{3}', strings['value_check.unit.ms']);
		await page.click('#le-group-tap_hold summary');
		await page.click('#le-group-key summary');
		for (const typed of ['0', '10001', '2.5', '']) {
			await page.fill('#le-threshold', typed);
			await page.click('#le-tap-hold-apply');
			assert.equal(await page.textContent('#le-message'), thresholdRange, `threshold ${typed}`);
			assert.equal(
				await page.locator('#le-tap-hold-remove').count(),
				0,
				`no tap-hold for ${typed}`
			);
		}
		const virtualKeyRange = strings['dialog.value_check.range_integer']
			.replace('{1}', '0')
			.replace('{2}', '255');
		for (const typed of ['256', '-1']) {
			await page.fill('#le-virtual-key', typed);
			await page.click('#le-key-apply');
			assert.equal(await page.textContent('#le-message'), virtualKeyRange, `virtual key ${typed}`);
		}

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
		await tool(page, 'dead_keys');
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
		await tool(page, 'details');
		await page.selectOption('#le-import-convention', 'iso');
		await page.setInputFiles('#le-open-file', KEYLAYOUT);
		await page.waitForSelector('#le-preserved');
		await tool(page, 'export');
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

		// Linux XKB and Windows KLC download from the shared converters run in the page.
		const [xkb] = await Promise.all([page.waitForEvent('download'), page.click('#le-export-xkb')]);
		assert.equal(xkb.suggestedFilename(), 'ergopti_xkb.zip');
		const xkbBytes = fs.readFileSync(await xkb.path());
		assert.equal(xkbBytes.subarray(0, 2).toString('latin1'), 'PK');
		for (const name of ['ergopti.xkb', 'ergopti.XCompose', 'xkb_types.txt', 'export.json'])
			assert(xkbBytes.includes(`ergopti_xkb/${name}`), `the XKB archive holds ${name}`);
		// The KLC needs its Windows metadata first: the refusal says so.
		await page.click('#le-export-klc');
		await page.waitForSelector('.le-message.error');
		await tool(page, 'windows');
		await page.fill('#le-win-locale', 'fr-FR');
		await page.fill('#le-win-layout-id', '0000040c');
		await page.fill('#le-win-dll-name', 'kbdergo');
		await page.click('#le-win-klc-apply');
		await tool(page, 'export');
		const [klc] = await Promise.all([page.waitForEvent('download'), page.click('#le-export-klc')]);
		assert.equal(klc.suggestedFilename(), 'kbdergo.klc');
		// The site says where the Windows DLL and installer come from, and offers no
		// in-app install or emulation.
		assert.match(await page.textContent('#le-dll-note'), /node tools\/kbd-dll\.cjs build/);
		// The four Windows DLLs, written in the page with no compiler.
		const [dll] = await Promise.all([page.waitForEvent('download'), page.click('#le-export-dll')]);
		assert.equal(dll.suggestedFilename(), 'kbdergo-dll.zip');
		const dllZip = fs.readFileSync(await dll.path());
		assert.deepEqual([...dllZip.subarray(0, 4)], [0x50, 0x4b, 0x03, 0x04], 'a ZIP');
		for (const arch of ['x86', 'wow64', 'x64', 'arm64'])
			assert.ok(dllZip.includes(`kbdergo/${arch}/kbdergo.dll`), `${arch} image in the ZIP`);
		assert.ok(
			dllZip.includes(Buffer.from('KbdLayerDescriptor')),
			'the images export KbdLayerDescriptor'
		);
		assert.equal(await page.locator('#le-install, #le-emulate').count(), 0);
		const klcBytes = fs.readFileSync(await klc.path());
		assert.deepEqual([...klcBytes.subarray(0, 2)], [0xff, 0xfe], 'MSKLC UTF-16LE with a BOM');
		assert.match(klcBytes.toString('utf16le'), /KBD\tkbdergo\t/);
		await page.click('#le-undo');

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
		await tool(page, 'windows');
		await page.fill('#le-win-flags', 'kllf_altgr');
		await page.click('#le-win-flags-apply');
		assert.equal(await page.inputValue('#le-win-flags'), 'kllf_altgr');
		await tool(page, 'stickers');
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
		await tool(page, 'stickers');
		await page.check('#le-sticker-hide-case');
		assert.ok(!(await sticker('shift')).includes('Ŵ'), 'the capital of the base is hidden');
		await page.uncheck('#le-sticker-layer-shift');
		assert.equal((await sticker('shift')).length, 0, 'an unchosen level is not printed');
		// « Move every key »: the Shift layer's mappings go to the base layer at once.
		await tool(page, 'layers');
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
		await tool(page, 'fill');
		await page.click('#le-fill-load');
		await page.waitForSelector('#le-fill-source');
		assert.equal(await page.locator('#le-fill .le-message.error').count(), 1);
		await page.selectOption('#le-fill-source', 'azerty');
		await page.selectOption('#le-fill-level', 'base');
		await page.click('#le-fill-apply');
		await page.click('#le-confirm-yes');
		assert.equal(await legendOf('KeyQ'), 'a');

		// The navigation layer imports as a layer and exports as layers.toml again.
		await tool(page, 'navigation');
		await page.selectOption('#le-nav-hold', 'CapsLock');
		await page.setInputFiles('#le-nav-file', NAV);
		await page.waitForSelector('[data-layer="nav"].active');
		await tool(page, 'export');
		const nav = await downloaded(page, () => page.click('#le-export-nav'));
		assert.equal(nav.name, 'layers.toml');
		assert.match(nav.text, /\[layers\.nav\.all\]/);

		// Reopening the saved source restores it.
		const reopened = path.join(require('node:os').tmpdir(), `layout-editor-${process.pid}.toml`);
		fs.writeFileSync(reopened, saved.text);
		await tool(page, 'details');
		try {
			await page.setInputFiles('#le-open-file', reopened);
			await page.waitForFunction(() => document.querySelector('#le-name').value === 'My layout');
		} finally {
			fs.rmSync(reopened);
		}

		// A render that does not move the focus (the locale arriving, a host answer) while a
		// field holds an uncommitted edit: removing the field fires its blur, whose change
		// renders again inside the first render, and the outer replaceChildren once threw
		// « The node to be removed is no longer a child … blur event handler » (CI 43611195865).
		await page.fill('#le-description', 'typed, not yet committed');
		assert.equal(
			await page.evaluate(() => document.activeElement && document.activeElement.id),
			'le-description',
			'the edited field keeps the focus'
		);
		await page.evaluate(() => window.layoutEditor.render());
		assert.deepEqual(errors, [], 'a render while a field is being edited throws nothing');
		assert.equal(
			await page.inputValue('#le-description'),
			'typed, not yet committed',
			'the edit is committed, not lost, by that render'
		);
		// A file opened while a text field holds an uncommitted edit: the edit belongs to
		// the document being replaced, so the opened file keeps its own name (worker G's case).
		await page.fill('#le-name', 'Uncommitted edit');
		await page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
		await page.waitForFunction(() => document.querySelector('#le-name').value === 'Source Fixture');
		assert.deepEqual(errors, [], 'opening a file while a field is being edited throws nothing');

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
		await exerciseLayerSelector(browser, origin);
		await exercisePhoneWidth(browser, origin);
		await exerciseLongLabels(browser, origin);
		await exerciseShortcuts(browser, origin);

		// Every locale names every visible string.
		for (const lang of LOCALES) {
			const opened = await open(browser, origin, lang);
			await opened.page.click('#le-board [data-code="KeyQ"]');
			for (const summary of await opened.page.$$('#le-inspector details > summary'))
				await summary.click();
			const raw = await rawKeys(opened.page);
			const tools = await opened.page.$$eval('#le-tools [data-tool]', (tabs) =>
				tabs.map((tab) => tab.dataset.tool)
			);
			for (const id of tools) {
				await tool(opened.page, id);
				raw.push(...(await rawKeys(opened.page)));
			}
			await opened.page.click('#le-shortcut-view');
			await opened.page.click('#le-board [data-code="KeyQ"]');
			raw.push(...(await rawKeys(opened.page)));
			assert.deepEqual(raw, [], `${lang}: raw locale keys are shown`);
			assert.deepEqual(opened.errors, [], `${lang}: page errors`);
			await opened.page.close();
		}
		console.log(
			`ok - layout editor page: editing, layer selector, phone width, preview, files and ${LOCALES.length} locales`
		);
	} finally {
		await browser.close();
		server.close();
	}
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
