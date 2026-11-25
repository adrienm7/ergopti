// tools/test/browser/user-workflows-window.playwright.cjs

/**
 * ==============================================================================
 * MODULE: User Workflows Window Behaviour
 * DESCRIPTION:
 * Drives the shared workflow editor (_shared/ui/user_workflows/) in Chromium as
 * the macOS and Linux hosts do, through the WebKit bridge hsWorkflows:
 * 1. the page asks for its data with "ready" and lists the workflows;
 * 2. a step moves with its Down button from the keyboard alone and keeps the
 *    focus; a new step is added from the « add a step » row;
 * 3. Save posts a document the shared model accepts, and a workflow the model
 *    refuses (an empty name) is never posted: the refusal is told;
 * 4. a test run highlights the step the host names, then tells its end;
 * 5. an import is stamped « import » even when its file says local, and its
 *    shell steps show the approval banner;
 * 6. Delete asks in its own button first, a second press deletes.
 *
 * ROOT CAUSE ENCODED:
 * User workflows had no editor: nothing let a person build, reorder, test or
 * share one, and an editor that saved what the drivers refuse would lose work.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const http = require('node:http');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../../../static/ergopti_plus/_shared');
const read = (rel) => JSON.parse(fs.readFileSync(path.join(ROOT, rel), 'utf8'));
const en = read('core/i18n/data/locales/en.json');

/** Serves the shared tree the page and its scripts live in. */
function serve() {
	const server = http.createServer((request, response) => {
		const file = path.resolve(ROOT, '.' + new URL(request.url, 'http://localhost').pathname);
		if (!file.startsWith(ROOT + path.sep) || !fs.existsSync(file)) {
			response.writeHead(404).end();
			return;
		}
		const type = file.endsWith('.js')
			? 'text/javascript'
			: file.endsWith('.css')
				? 'text/css'
				: 'text/html';
		response.setHeader('content-type', type);
		response.end(fs.readFileSync(file));
	});
	return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const INIT = {
	strings: en,
	catalogue: read('shortcuts/data/workflows/steps.json'),
	vocabulary: read('shortcuts/data/actions/send_keys.json'),
	timings: { wait_max_ms: 600000 },
	actions: [{ id: 'select_all', label: 'Select all' }],
	approved: {},
	doc: {
		schema_version: 1,
		workflows: [
			{
				id: 'wf_a',
				name: 'Alpha',
				origin: 'local',
				steps: [
					{ kind: 'notify', text: 'first' },
					{ kind: 'wait', duration_ms: 10 }
				]
			}
		]
	}
};

/** Opens the page with a recording WebKit bridge. */
async function open(browser, base) {
	const page = await browser.newPage();
	await page.addInitScript(() => {
		window.messages = [];
		window.webkit = {
			messageHandlers: { hsWorkflows: { postMessage: (m) => window.messages.push(m) } }
		};
	});
	await page.goto(base + '/ui/user_workflows/index.html');
	await page.waitForFunction(() => window.messages.some((m) => m.action === 'ready'));
	await page.evaluate((data) => window.initData(data), INIT);
	return page;
}

async function main() {
	const server = await serve();
	const base = 'http://127.0.0.1:' + server.address().port;
	const browser = await chromium.launch();
	let checks = 0;
	try {
		const page = await open(browser, base);
		assert.equal(await page.locator('#workflow-list button').count(), 1);
		assert.equal(await page.inputValue('#input-name'), 'Alpha');
		checks++;

		// Keyboard reorder: focus the first step's Down button and press Enter.
		await page.focus('#step-1 .btn-down');
		await page.keyboard.press('Enter');
		const titles = await page.locator('#steps > .step > fieldset > legend').allTextContents();
		assert.deepEqual(titles, [
			'1 · ' + en['workflows.step.wait'],
			'2 · ' + en['workflows.step.notify']
		]);
		const focused = await page.evaluate(() => document.activeElement.closest('.step').id);
		assert.equal(focused, 'step-2', 'the focus follows the moved step');
		checks++;

		// Add a step from the root « add a step » row.
		await page.selectOption('#add-root', 'type_text');
		await page.click('#steps > .add-step button');
		assert.equal(await page.locator('#steps > .step').count(), 3);
		await page.fill('#f-3-text', 'hello');
		await page.dispatchEvent('#f-3-text', 'change');
		checks++;

		// Save posts a valid document.
		await page.click('#btn-save');
		const saved = await page.evaluate(() =>
			window.messages.filter((m) => m.action === 'save').pop()
		);
		assert.equal(saved.doc.workflows[0].steps[2].text, 'hello');
		assert.equal(saved.doc.workflows[0].steps[0].kind, 'wait');
		checks++;

		// An empty name is refused before anything is posted.
		const before = await page.evaluate(() => window.messages.length);
		await page.fill('#input-name', '');
		await page.click('#btn-save');
		assert.equal(
			await page.evaluate(() => window.messages.length),
			before,
			'an invalid document is not posted'
		);
		assert.match(await page.textContent('#status'), new RegExp(en['workflows.refusal.bad_text']));
		await page.fill('#input-name', 'Alpha');
		checks++;

		// A test run highlights the host's step, then ends.
		await page.click('#btn-run');
		const run = await page.evaluate(() =>
			window.messages.filter((m) => m.action === 'test_run').pop()
		);
		assert.equal(run.id, 'wf_a');
		assert.equal(await page.isDisabled('#btn-stop'), false);
		await page.evaluate(() => window.onRunStep({ path: '2' }));
		assert.equal(await page.locator('#step-2.running').count(), 1);
		await page.evaluate(() => window.onRunEnd({ op: 'done' }));
		assert.equal(await page.locator('.step.running').count(), 0);
		assert.equal(await page.textContent('#status'), en['workflows.editor.run_done']);
		checks++;

		// An import is stamped « import » and its shell step asks for approval.
		await page.evaluate(() =>
			window.onImported({
				ok: true,
				workflows: [
					{
						id: 'wf_a',
						name: 'Shared',
						origin: 'local',
						steps: [{ kind: 'shell', command: 'true' }]
					}
				]
			})
		);
		assert.equal(await page.inputValue('#input-name'), 'Shared');
		assert.equal(
			await page.isVisible('#import-banner'),
			true,
			'an imported shell step shows the banner'
		);
		await page.click('#btn-approve');
		const approve = await page.evaluate(() =>
			window.messages.filter((m) => m.action === 'approve_shell').pop()
		);
		assert.equal(approve.doc.workflows[1].origin, 'import');
		assert.notEqual(approve.id, 'wf_a', 'an imported id that collides is renamed');
		checks++;

		// Delete asks in its button, a second press deletes.
		await page.click('#btn-delete');
		assert.equal(await page.locator('#workflow-list button').count(), 2);
		await page.click('#btn-delete');
		assert.equal(await page.locator('#workflow-list button').count(), 1);
		checks++;
	} finally {
		await browser.close();
		server.close();
	}
	console.log(`PASS user workflows window (${checks} checks)`);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
