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
		await page.evaluate((seed) => window.init(seed), first);
		await page.locator('#p-name').fill('Edited');
		await page.locator('#e-out').fill('Edited prompt');
		await page.locator('#p-mode').selectOption('batch');
		await page.evaluate((seed) => window.init(seed), first);
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
		await page.evaluate((seed) => window.init(seed), next);
		assert.equal(await page.locator('#p-name').inputValue(), 'Next');
		await page.evaluate((seed) => window.init(seed), first);
		assert.equal(await page.locator('#p-name').inputValue(), 'Next');
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
