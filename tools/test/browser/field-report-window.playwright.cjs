// tools/test/browser/field-report-window.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Field Report Window Behaviour
 * DESCRIPTION:
 * Drives the shared field report window (_shared/ui/field_report/) in Chromium
 * as the three hosts do:
 * 1. the page asks for its run with "ready" and offers nothing to act on but
 *    Close and Stop before the run ends; a window opened during the run
 *    starts from the states its init names;
 * 2. each step's state reaches its line and the live region, said again in
 *    the user's language when the strings land after the step;
 * 3. at the end the counts, the verdict and the folder are shown, Stop is
 *    gone and the three end buttons are enabled with the open-folder label the
 *    host named;
 * 4. buttons send action names only, never a path or a URL; action results
 *    reach the live region; the Linux bridge response reaches the same entry
 *    point.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const http = require('node:http');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../../../static/ergopti_plus/_shared');
const en = JSON.parse(fs.readFileSync(path.join(ROOT, 'core/i18n/data/locales/en.json'), 'utf8'));

/** Serves the shared tree: the page and the locale it fetches. */
function serve() {
	const server = http.createServer((request, response) => {
		const pathname = new URL(request.url, 'http://localhost').pathname;
		const file = pathname.startsWith('/data/locales/')
			? path.join(ROOT, 'core/i18n/data/locales', path.basename(pathname))
			: path.resolve(ROOT, 'ui', '.' + pathname);
		if (!file.startsWith(ROOT + path.sep) || !fs.existsSync(file)) {
			response.writeHead(404).end();
			return;
		}
		const type = file.endsWith('.js')
			? 'text/javascript'
			: file.endsWith('.css')
				? 'text/css'
				: file.endsWith('.json')
					? 'application/json'
					: 'text/html';
		response.setHeader('content-type', type);
		response.end(fs.readFileSync(file));
	});
	return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

/** The label a key renders as, placeholders filled in order. */
function label(key, ...args) {
	let index = 0;
	return String(en[key]).replace(/%s/g, () => String(args[index++]));
}

async function main() {
	const server = await serve();
	let browser;
	try {
		browser = await chromium.launch({
			headless: true,
			...(process.env.CHROMIUM_EXECUTABLE
				? { executablePath: process.env.CHROMIUM_EXECUTABLE }
				: {}),
			args: ['--no-sandbox']
		});
		const page = await browser.newPage();
		await page.addInitScript(() => {
			window.messages = [];
			window.webkit = {
				messageHandlers: {
					field_report: { postMessage: (message) => window.messages.push(message) }
				}
			};
		});
		const base = `http://127.0.0.1:${server.address().port}`;
		await page.addInitScript((locales) => {
			window.__i18n_base = locales;
			window._i18n_locale = 'en';
		}, base + '/data/locales/');
		await page.goto(base + '/field_report/index.html');
		await page.waitForFunction(() => window.messages.includes('ready'));
		const disabled = (id) => page.locator('#' + id).isDisabled();
		for (const id of ['btn-open', 'btn-copy', 'btn-issue'])
			assert.ok(await disabled(id), id + ' waits for the end of the run');
		assert.ok(!(await disabled('btn-close')), 'Close always works');

		// A host may send a step before the strings land: the line follows them
		await page.evaluate(() => {
			window._i18n_strings = {};
			window.receiveFieldReport({
				type: 'init',
				steps: [
					{ id: 'field_network', title: 'Test network' },
					{ id: 'field_composer', title: 'Test the composed layout' }
				],
				not_run: [{ id: 'driver_reload', reason: 'needs_collector' }],
				open_key: 'field_report.open_finder'
			});
			window.receiveFieldReport({ type: 'step', id: 'field_network', state: 'running' });
		});
		await page.evaluate((strings) => window.i18n_apply(strings), en);
		assert.equal(
			await page.locator('#status').innerText(),
			label('field_report.announce', 1, 2, 'Test network', en['field_report.state.running'])
		);
		await page.evaluate(() => {
			window.receiveFieldReport({ type: 'step', id: 'field_network', state: 'pass' });
			window.receiveFieldReport({ type: 'step', id: 'field_composer', state: 'fail' });
			window.receiveFieldReport({ type: 'step', id: 'unknown', state: 'pass' });
		});
		const lines = await page.locator('#steps li').allInnerTexts();
		assert.deepEqual(lines, [
			'Test network — ' + en['field_report.state.pass'],
			'Test the composed layout — ' + en['field_report.state.fail'],
			'driver_reload — ' +
				en['field_report.state.not_run'] +
				' — ' +
				en['field_check.all.reason.needs_collector']
		]);
		assert.equal(
			await page.locator('#steps li.fail').count(),
			1,
			'a failed step is marked as such'
		);
		assert.equal(await page.locator('#summary').isHidden(), true, 'no summary before the end');

		await page.evaluate(() =>
			window.receiveFieldReport({
				type: 'done',
				passed: false,
				interrupted: false,
				counts: { pass: 1, fail: 1 },
				folder: '/Users/me/Library/Application Support/Ergopti/field-run/results/app-1'
			})
		);
		assert.equal(await page.locator('#summary').isHidden(), false);
		assert.equal(await page.locator('#verdict').innerText(), en['field_check.all.verdict_fail']);
		assert.equal(await page.locator('#counts li').count(), 2);
		assert.match(
			await page.locator('#folder').innerText(),
			/Application Support\/Ergopti\/field-run\/results\/app-1$/
		);
		assert.ok(await page.locator('#btn-cancel').isHidden(), 'Stop is gone once the run ended');
		for (const id of ['btn-open', 'btn-copy', 'btn-issue'])
			assert.ok(!(await disabled(id)), id + ' is enabled at the end');
		assert.equal(await page.locator('#btn-open').innerText(), en['field_report.open_finder']);

		for (const [id, action] of [
			['btn-open', 'open_folder'],
			['btn-copy', 'copy'],
			['btn-issue', 'issue'],
			['btn-close', 'close']
		]) {
			await page.locator('#' + id).click();
			const last = await page.evaluate(() => window.messages[window.messages.length - 1]);
			assert.deepEqual(last, { action }, id + ' sends its action name only');
		}
		await page.evaluate(() =>
			window.receiveFieldReport({ type: 'action', action: 'copy', ok: true })
		);
		assert.equal(await page.locator('#status').innerText(), en['field_check.copied']);
		await page.evaluate(() => {
			const payload = btoa(JSON.stringify({ type: 'action', action: 'issue', ok: false }));
			window.__hostBridgeResponse('field_report', true, payload);
		});
		assert.equal(await page.locator('#status').innerText(), en['field_report.action_failed']);

		// A window opened during the run starts from the states so far; an
		// interrupted run says so; Stop asks the host to stop it
		await page.evaluate(() => {
			window.receiveFieldReport({
				type: 'init',
				steps: [
					{ id: 'a', title: 'A', state: 'pass' },
					{ id: 'b', title: 'B', state: 'bogus' }
				],
				not_run: [],
				open_key: 'field_report.open_files'
			});
		});
		assert.deepEqual(await page.locator('#steps li').allInnerTexts(), [
			'A — ' + en['field_report.state.pass'],
			'B — ' + en['field_report.state.pending']
		]);
		await page.locator('#btn-cancel').click();
		assert.deepEqual(await page.evaluate(() => window.messages[window.messages.length - 1]), {
			action: 'cancel'
		});
		await page.evaluate(() =>
			window.receiveFieldReport({
				type: 'done',
				passed: false,
				interrupted: true,
				counts: {},
				folder: '/tmp/x'
			})
		);
		assert.equal(await page.locator('#verdict').innerText(), en['field_check.all.interrupted']);
		console.log('[OK] field report window: progress, end of run, actions and the Linux bridge.');
	} finally {
		if (browser) await browser.close();
		server.close();
	}
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
