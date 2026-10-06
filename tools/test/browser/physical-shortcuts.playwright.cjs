// tools/test/browser/physical-shortcuts.playwright.cjs

/**
 * Exercises the actual shared form and recording host bridge in both renderers.
 * No browser key event is physical-position or native-publication proof.
 */
const fs = require('fs');
const { chromium, webkit } = require('playwright');
const { shared } = require('../../lib/paths.cjs');
const ui = shared('ui', 'physical_shortcuts') + '/';
let checks = 0;
const assert = (condition, label) => {
	checks++;
	if (!condition) throw new Error(label);
};
(async () => {
	const names = process.env.ERGOPTI_PHYSICAL_EDITOR_BROWSERS?.split(',') || ['chromium', 'webkit'];
	for (const name of names) {
		if (!['chromium', 'webkit'].includes(name)) throw new Error('Unknown browser');
		const browser = await { chromium, webkit }[name].launch({
			headless: true,
			...(name === 'chromium' && process.env.CHROMIUM_EXECUTABLE
				? { executablePath: process.env.CHROMIUM_EXECUTABLE }
				: {})
		});
		try {
			const page = await browser.newPage();
			const errors = [];
			page.on('pageerror', (error) => errors.push(error.message));
			await page.evaluate(() => {
				window.requests = [];
				window.webkit = {
					messageHandlers: {
						physical_shortcuts_bridge: { postMessage: (packet) => window.requests.push(packet) }
					}
				};
			});
			const html = fs
				.readFileSync(ui + 'index.html', 'utf8')
				.replace(
					'<script src="../host_bridge.js"></script>',
					'<script>' + fs.readFileSync(shared('ui', 'host_bridge.js'), 'utf8') + '</script>'
				)
				.replace(
					'<script src="script.js" defer></script>',
					'<script>' + fs.readFileSync(ui + 'script.js', 'utf8') + '</script>'
				)
				.replace(
					'<link rel="stylesheet" href="style.css" />',
					'<style>' + fs.readFileSync(ui + 'style.css', 'utf8') + '</style>'
				);
			await page.setContent(html);
			await page.waitForFunction(() => window.requests?.some((x) => x.action === 'ready'));
			const strings = {};
			for (const key of [
				'title',
				'manual-hint',
				'capture',
				'capture-reason',
				'empty',
				'add',
				'position-label',
				'modifier-label',
				'choose',
				'save',
				'cancel',
				'close',
				'edit',
				'remove',
				'source_changed',
				'save_failed',
				'saved_reopen',
				'saved',
				'unavailable'
			])
				strings[key] = key;
			const packet = {
				strings,
				entries: [],
				positions: [
					{ code: 'Backquote', available: false, reason: 'unavailable' },
					{ code: 'KeyJ', available: true },
					{ code: 'KeyK', available: true }
				],
				capture: false
			};
			await page.evaluate((data) => init(data), packet);
			assert(await page.locator('#capture').isDisabled(), 'Physical capture honestly unavailable');
			assert(
				await page.locator('#empty').isVisible(),
				'Empty default contains no fixed accent/star entries'
			);
			await page.locator('#add').click();
			assert(
				(await page.locator('#position').inputValue()) === 'KeyJ',
				'First supported native position selected'
			);
			await page.locator('#mod-ctrl').check();
			await page.locator('#choose').click();
			let chosen = await page.evaluate(() => window.requests.at(-1));
			assert(
				chosen.action === 'choose' &&
					chosen.request.code === 'KeyJ' &&
					chosen.request.mods.ctrl === true,
				'Manual W3C position and exact modifiers transported'
			);
			assert(
				chosen.request.previous_slot === null && !('source' in chosen),
				'Page has no canonical source authority'
			);
			const before = await page.evaluate(() => window.requests.length);
			await page.keyboard.press('Control+KeyA');
			assert(
				(await page.evaluate(() => window.requests.length)) === before,
				'Browser key event never becomes physical capture'
			);
			await page.evaluate((data) => selected(data), {
				request_id: chosen.request.request_id,
				token: 1,
				label: 'Unicode'
			});
			assert(await page.locator('#save').isEnabled(), 'Current native picker draft acknowledged');
			await page.locator('#position').selectOption('KeyK');
			await page.evaluate((data) => selected(data), {
				request_id: chosen.request.request_id,
				token: 1,
				label: 'Stale'
			});
			assert(
				await page.locator('#save').isDisabled(),
				'Late result cannot revive changed position draft'
			);
			await page.locator('#choose').click();
			chosen = await page.evaluate(() => window.requests.at(-1));
			await page.evaluate((data) => selected(data), {
				request_id: chosen.request.request_id,
				token: 2,
				label: 'Unicode'
			});
			await page.locator('#save').click();
			const save = await page.evaluate(() => window.requests.at(-1));
			assert(
				save.action === 'save' && save.token === 2 && !('parameter' in save),
				'Only opaque native draft token saved'
			);
			await page.evaluate(() => result({ committed: false, reason: 'save_failed' }));
			assert(
				(await page.locator('#editor').isVisible()) &&
					(await page.locator('#position').inputValue()) === 'KeyK',
				'Failed publication preserves exact form'
			);
			assert(await page.locator('#save').isEnabled(), 'Refused native commit remains retryable');
			await page.locator('#save').click();
			await page.evaluate(() =>
				result({
					committed: true,
					refreshed: true,
					entries: [
						{
							slot: 'physical_ctrl_KeyK',
							code: 'KeyK',
							mods: { ctrl: true },
							action: 'none',
							label: 'None'
						}
					]
				})
			);
			assert(
				(await page.locator('#editor').isHidden()) && (await page.locator('.entry').count()) === 1,
				'Committed inventory replaces displayed list'
			);
			await page.locator('.entry button').first().click();
			assert(
				(await page.locator('#position').inputValue()) === 'KeyK' &&
					(await page.locator('#mod-ctrl').isChecked()),
				'Edit starts from exact native record'
			);
			await page.locator('#cancel').click();
			await page.locator('.entry button').last().click();
			const remove = await page.evaluate(() => window.requests.at(-1));
			assert(
				remove.action === 'remove' && remove.slot === 'physical_ctrl_KeyK',
				'Remove carries exact displayed identity'
			);
			await page.evaluate(() => result({ committed: true, refreshed: false }));
			assert(
				(await page.locator('#add').isDisabled()) &&
					(await page.locator('#status').textContent()) === 'saved_reopen',
				'Durable success plus refused refresh truthfully fences form'
			);
			await page.evaluate((data) => init({ ...data, readonly: true, reason: 'source_changed' }), {
				strings,
				entries: [],
				positions: [],
				capture: false
			});
			assert(
				(await page.locator('#add').isDisabled()) &&
					(await page.locator('#status').textContent()) === 'source_changed',
				'Initial native source refusal visible and readonly'
			);
			assert(errors.length === 0, 'No browser errors: ' + errors.join(','));
			console.log(
				'Shared physical editor ' +
					name +
					': ' +
					checks +
					' independent assertions; no native capture/publication qualification'
			);
		} finally {
			await browser.close();
		}
	}
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
