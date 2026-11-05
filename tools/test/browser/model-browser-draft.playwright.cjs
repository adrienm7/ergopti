// tools/test/browser/model-browser-draft.playwright.cjs

/** Drives the real model browser while a different download reports progress. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium, webkit } = require('playwright');
const ui = path.resolve(__dirname, '../../../static/ergopti_plus/_shared/ui/model_browser');
(async () => {
	for (const name of (process.env.ERGOPTI_MODEL_BROWSER_BROWSERS || 'chromium,webkit').split(',')) {
		assert.ok(name === 'chromium' || name === 'webkit', 'unknown browser');
		const browser = await { chromium, webkit }[name].launch({
			headless: true,
			...(name === 'chromium' && process.env.CHROMIUM_EXECUTABLE
				? { executablePath: process.env.CHROMIUM_EXECUTABLE }
				: {})
		});
		try {
			const page = await browser.newPage();
			const html = fs
				.readFileSync(path.join(ui, 'index.html'), 'utf8')
				.replace(/<script\b[^>]*><\/script>/g, '');
			await page.setContent(html);
			await page.evaluate(() => {
				window.messages = [];
				window.makeHostBridge = () => (m) => window.messages.push(m);
			});
			await page.addScriptTag({ content: fs.readFileSync(path.join(ui, 'script.js'), 'utf8') });
			await page.evaluate(() =>
				window.injectModels({
					session: 1,
					backend: 'ollama',
					models: [{ name: 'existing', backend: 'ollama' }],
					backends: [
						{ id: 'ollama', kind: 'local', brand: 'Ollama', available: true, add_model: true }
					]
				})
			);
			const input = page.locator('.add-input');
			await input.fill('qwen3:4b');
			await input.focus();
			await input.evaluate((el) => el.setSelectionRange(2, 5, 'backward'));
			await page.evaluate(() =>
				window.injectProgress({ name: 'existing', backend: 'ollama', percent: 42 })
			);
			assert.equal(
				await page.locator('.add-input').inputValue(),
				'qwen3:4b',
				'progress must not discard the draft'
			);
			assert.equal(
				await page.locator('.add-input').evaluate((el) => document.activeElement === el),
				true,
				'progress must not move keyboard focus'
			);
			assert.deepEqual(
				await page
					.locator('.add-input')
					.evaluate((el) => [el.selectionStart, el.selectionEnd, el.selectionDirection]),
				[2, 5, 'backward'],
				'progress must preserve the selection'
			);
			await page.locator('.add-input').press('Enter');
			const posted = await page.evaluate(() =>
				window.messages.filter((m) => m && m.action === 'add_model')
			);
			assert.equal(posted.length, 1);
			assert.equal(posted[0].name, 'qwen3:4b');
			await page.evaluate(() =>
				window.injectModels({
					session: 2,
					backend: 'ollama',
					models: [],
					backends: [
						{ id: 'ollama', kind: 'local', brand: 'Ollama', available: true, add_model: true }
					]
				})
			);
			assert.equal(
				await page.locator('.add-input').inputValue(),
				'',
				'a new session must not inherit the previous draft'
			);
			assert.equal(
				await page.locator('.add-input').evaluate((el) => document.activeElement === el),
				false,
				'a retired session must not focus its successor'
			);
			console.log(name + ': model download progress preserves an active draft');
		} finally {
			await browser.close();
		}
	}
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
