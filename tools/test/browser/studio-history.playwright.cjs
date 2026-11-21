// tools/test/browser/studio-history.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Studio Undo and Redo Browser Regression
 * DESCRIPTION:
 * Drives Ergopti Studio's three editing pages in Chromium from a loopback
 * server and holds the undo history the maintainer asked for on 2026-11-21
 * (_shared/ui/edit_history.js):
 * 1. Editor: each key edit is a step; Undo and Redo walk them in order, by
 *    the buttons and by Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z and Cmd+Z; a new edit
 *    after an undo clears Redo; the buttons' accessible names say the step
 *    (« Undo: change key … »); the layout saved after an undo is the one
 *    saved before the undone edit; a layout opened in the tab is a step.
 * 2. Comparer: a weight change and a « Restore » are steps, undone and redone
 *    by the buttons and the keys, each named.
 * 3. Optimiser: a settings change is a step, undone by Ctrl+Z and redone by
 *    Ctrl+Shift+Z.
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
	'.json': 'application/json',
	'.svg': 'image/svg+xml',
	'.woff2': 'font/woff2'
};
const SOURCE_FIXTURE = shared('tests', 'corpus', 'layouts', 'source', 'source.toml');

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

/** Opens one page of the shared tree in a fresh context, collecting its errors. */
async function open(browser, origin, page, ready) {
	const context = await browser.newContext({
		acceptDownloads: true,
		viewport: { width: 1280, height: 900 }
	});
	const tab = await context.newPage();
	const errors = [];
	tab.on('pageerror', (error) => errors.push(error.message));
	tab.on('request', (request) => {
		if (!request.url().startsWith(origin + '/') && !request.url().startsWith('blob:'))
			errors.push(`unexpected request: ${request.url()}`);
	});
	tab.on('dialog', (dialog) => errors.push(`native dialog: ${dialog.message()}`));
	await tab.goto(`${origin}/ui/${page}?lang=en`);
	await tab.waitForFunction(ready);
	return { page: tab, errors, context };
}

const name = (page, selector) => page.getAttribute(selector, 'aria-label');

async function downloaded(page, click) {
	const [download] = await Promise.all([page.waitForEvent('download'), click()]);
	return fs.readFileSync(await download.path(), 'utf8');
}

/** The editor: steps, keys, names, branching and the layout saved after an undo. */
async function editor(browser, origin) {
	const { page, errors, context } = await open(
		browser,
		origin,
		'layout_editor/index.html',
		() =>
			document.title &&
			!document.title.startsWith('layout_editor.') &&
			document.querySelector('#le-board .le-key')
	);
	// The editor opens on its start copy: a history of its own, with nothing to undo.
	await page.waitForFunction(() => document.querySelector('#le-undo').disabled);
	assert.match(await name(page, '#le-undo'), /^Undo \(/, 'nothing to undo names no step');
	const legend = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	const map = async (code, text) => {
		await page.click(`#le-board [data-code="${code}"]`);
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', text);
		await page.click('#le-apply');
	};
	const before = { KeyQ: await legend('KeyQ'), KeyW: await legend('KeyW') };
	await map('KeyQ', '¤');
	const afterFirst = await downloaded(page, () => page.click('#le-save'));
	await map('KeyW', '§');
	assert.equal(await legend('KeyW'), '§');
	assert.match(
		await name(page, '#le-undo'),
		/^Undo: change key .+ \(.*Z.*\)$/,
		'Undo says which key it takes back, and its shortcut'
	);
	assert.equal(await page.getAttribute('#le-undo', 'aria-keyshortcuts'), 'Control+Z Meta+Z');
	// Ctrl+Z, from the button the edit left the focus on.
	await page.focus('#le-apply');
	await page.keyboard.press('Control+z');
	assert.equal(await legend('KeyW'), before.KeyW, 'Ctrl+Z undid the last edit');
	assert.equal(await legend('KeyQ'), '¤', 'the earlier edit stays');
	assert.match(
		await name(page, '#le-redo'),
		/^Redo: change key /,
		'Redo says which step it replays'
	);
	assert.match(await page.textContent('#le-history-status'), /^Undone: change key /);
	// The layout saved after the undo is the one saved before the undone edit.
	const afterUndo = await downloaded(page, () => page.click('#le-save'));
	assert.equal(afterUndo, afterFirst, 'a layout saved after undo matches');
	await page.keyboard.press('Control+y');
	assert.equal(await legend('KeyW'), '§', 'Ctrl+Y redid it');
	await page.keyboard.press('Meta+z');
	assert.equal(await legend('KeyW'), before.KeyW, 'Cmd+Z undoes too (macOS)');
	await page.keyboard.press('Control+Shift+Z');
	assert.equal(await legend('KeyW'), '§', 'Ctrl+Shift+Z redoes');
	// Branching: an edit after an undo clears what Redo would replay.
	await page.click('#le-undo');
	assert.equal(await page.isDisabled('#le-redo'), false);
	await map('KeyE', '¶');
	assert.equal(await page.isDisabled('#le-redo'), true, 'a new edit cleared the redo steps');
	assert.equal(await legend('KeyW'), before.KeyW);
	// Two undos take back KeyE then KeyQ; the start copy is back.
	await page.click('#le-undo');
	await page.click('#le-undo');
	assert.equal(await legend('KeyQ'), before.KeyQ);
	assert.equal(await page.isDisabled('#le-undo'), true);
	// A text field keeps its own Ctrl+Z.
	await page.click('#le-board [data-code="KeyR"]');
	await page.selectOption('#le-kind', 'text');
	await page.fill('#le-text', 'ab');
	await page.focus('#le-text');
	await page.keyboard.press('Control+z');
	assert.equal(
		await page.isDisabled('#le-redo'),
		false,
		'the field kept Ctrl+Z, no history step moved'
	);
	// Opening a layout in the tab is a step, and Undo puts the replaced one back.
	const shown = await page.textContent('#le-doc-state');
	await page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
	await page.waitForFunction(
		(was) => document.querySelector('#le-doc-state').textContent !== was,
		shown
	);
	assert.match(
		await name(page, '#le-undo'),
		/^Undo: open /,
		'an opened layout is an undoable step'
	);
	await page.click('#le-undo');
	assert.equal(
		(await page.textContent('#le-doc-state')).replace(' •', ''),
		shown.replace(' •', '')
	);
	assert.deepEqual(errors, [], 'editor page errors');
	await context.close();
}

/** The Comparer: a weight edit and a restore are named steps. */
async function comparer(browser, origin) {
	const { page, errors, context } = await open(
		browser,
		origin,
		'layout_analysis/index.html',
		() => {
			const title = document.querySelector('#la-title');
			return (
				title &&
				!title.textContent.startsWith('layout_analysis.') &&
				document.querySelector('#la-undo') &&
				document.querySelector('.la-weight-list input')
			);
		}
	);
	assert.equal(await page.getAttribute('#la-undo', 'aria-disabled'), 'true');
	assert.equal(await name(page, '#la-undo'), 'Undo');
	// The weights are under « Settings », a disclosure of the home tab.
	if ((await page.getAttribute('#la-tab-home', 'aria-selected')) !== 'true')
		await page.click('#la-tab-home');
	await page.evaluate(() => {
		document.querySelector('#la-settings').open = true;
	});
	const weight = page.locator('.la-weight-list input').first();
	const original = await weight.inputValue();
	const changed = String(Number(original) + 3);
	await weight.fill(changed);
	await page.waitForFunction(
		() => document.querySelector('#la-undo').getAttribute('aria-disabled') === 'false'
	);
	assert.equal(await name(page, '#la-undo'), 'Undo: change the score weights');
	await page.click('#la-undo');
	assert.equal(await weight.inputValue(), original, 'the button undid the weight');
	assert.equal(await name(page, '#la-redo'), 'Redo: change the score weights');
	assert.equal(await page.textContent('.la-history-status'), 'Undone: change the score weights');
	await page.keyboard.press('Control+y');
	assert.equal(await weight.inputValue(), changed, 'Ctrl+Y redid it');
	// « Restore » is a step too, named after its section.
	await page.click('#la-restore');
	assert.equal(await weight.inputValue(), original);
	assert.match(await name(page, '#la-undo'), /^Undo: restore /);
	await page.keyboard.press('Control+z');
	assert.equal(await weight.inputValue(), changed, 'Ctrl+Z undid the restore');
	assert.deepEqual(errors, [], 'Comparer page errors');
	await context.close();
}

/** The Optimiser: a settings change is a named step. */
async function optimizer(browser, origin) {
	const { page, errors, context } = await open(
		browser,
		origin,
		'layout_optimizer/index.html',
		() => {
			const title = document.querySelector('.layout-optimizer h1');
			return (
				title &&
				title.textContent &&
				!title.textContent.startsWith('layout_optimizer.') &&
				document.querySelector('#lo-undo')
			);
		}
	);
	assert.equal(await page.getAttribute('#lo-undo', 'aria-disabled'), 'true');
	await page.evaluate(() => {
		document.querySelector('.lo-advanced').open = true;
	});
	const original = await page.inputValue('#lo-seconds');
	await page.fill('#lo-seconds', '17');
	await page.dispatchEvent('#lo-seconds', 'change');
	assert.equal(await name(page, '#lo-undo'), 'Undo: change the search settings');
	await page.focus('#lo-undo');
	await page.keyboard.press('Control+z');
	assert.equal(await page.inputValue('#lo-seconds'), original, 'Ctrl+Z undid the setting');
	await page.keyboard.press('Control+Shift+Z');
	assert.equal(await page.inputValue('#lo-seconds'), '17', 'Ctrl+Shift+Z redid it');
	assert.deepEqual(errors, [], 'Optimiser page errors');
	await context.close();
}

async function main() {
	const server = await serve();
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch();
	try {
		await editor(browser, origin);
		console.log('ok - editor history');
		await comparer(browser, origin);
		console.log('ok - Comparer history');
		await optimizer(browser, origin);
		console.log('ok - Optimiser history');
	} finally {
		await browser.close();
		server.close();
	}
	console.log('PASS studio-history');
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
