// Exercises the real page against delayed host initialization in Chromium.
'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const http = require('node:http');
const { chromium } = require('playwright');

async function main() {
	const root = path.resolve(__dirname, '../../../static/ergopti_plus/_shared/ui');
	const server = http.createServer((request, response) => {
		const file = path.resolve(root, '.' + new URL(request.url, 'http://localhost').pathname);
		if (!file.startsWith(root + path.sep)) {
			response.writeHead(404).end();
			return;
		}
		let content;
		try {
			content = fs.readFileSync(file);
		} catch (_) {
			response.writeHead(404).end();
			return;
		}
		response.setHeader(
			'content-type',
			file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html'
		);
		response.end(content);
	});
	await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
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
					prompt_bridge: {
						postMessage: (message) => window.messages.push(message)
					}
				}
			};
		});
		await page.goto(`http://127.0.0.1:${server.address().port}/prompt_editor/index.html`);
		const first = {
			edit_id: 'p',
			epoch: 7,
			title: 'Prompt',
			name: 'Original',
			mode: 'parallel',
			prompt: 'Original prompt'
		};
		// init() moves the focus to the name field 100 ms after it fills the form.
		// A timer of the same delay queued after it fires after it, so no later
		// step types into a field that deferred focus then takes away.
		const initialize = (seed) =>
			page.evaluate((value) => {
				window.init(value);
				return new Promise((resolve) => setTimeout(resolve, 100));
			}, seed);
		await initialize(first);
		await page.locator('#p-name').fill('Edited');
		await page.locator('#e-out').fill('Edited prompt');
		await page.locator('#p-mode').selectOption('batch');
		await initialize(first);
		assert.equal(await page.locator('#p-name').inputValue(), 'Edited');
		assert.equal(await page.locator('#e-out').innerText(), 'Edited prompt');
		await page.evaluate(() => window.doSave());
		const save = await page.evaluate(() =>
			window.messages.find((message) => message.action === 'save')
		);
		assert.equal(save.name, 'Edited');
		assert.equal(save.prompt, 'Edited prompt');
		assert.equal(save.epoch, 7);
		assert.equal(save.batch, true);
		const next = { ...first, edit_id: 'q', epoch: 8, name: 'Next', prompt: 'New source' };
		await initialize(next);
		assert.equal(await page.locator('#p-name').inputValue(), 'Next');
		await initialize(first);
		assert.equal(await page.locator('#p-name').inputValue(), 'Next');
		// The token suggestions are a list box the editor owns: the highlight
		// the arrow keys move is named through aria-activedescendant, so a
		// screen reader announces it (WCAG 4.1.2).
		assert.equal(await page.evaluate(() => document.activeElement.id), 'p-name');
		await page.locator('#e-out').click();
		await page.keyboard.press('End');
		await page.keyboard.type(' {');
		const editor = page.locator('#e-out');
		await page.locator('#ac-popup.on [role="option"]').first().waitFor();
		assert.equal(await page.locator('#ac-popup').getAttribute('role'), 'listbox');
		assert.equal(await editor.getAttribute('aria-controls'), 'ac-popup');
		assert.equal(await editor.getAttribute('aria-activedescendant'), 'ac-option-0');
		await page.keyboard.press('ArrowDown');
		assert.equal(await editor.getAttribute('aria-activedescendant'), 'ac-option-1');
		assert.equal(await page.locator('#ac-option-1').getAttribute('aria-selected'), 'true');
		assert.equal(await page.locator('#ac-option-0').getAttribute('aria-selected'), 'false');
		await page.keyboard.press('Enter');
		assert.equal(await editor.getAttribute('aria-activedescendant'), null, 'closed, no highlight');
		assert.equal(await page.locator('#e-out var.token-chip').last().textContent(), '{n}');
		console.log('prompt editor preserves drafts and admits newer sessions in Chromium');
	} finally {
		if (browser) await browser.close();
		await new Promise((resolve) => server.close(resolve));
	}
}
main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
