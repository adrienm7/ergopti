// tools/test/browser/personal-info-editor.playwright.cjs
// Exercises native input sanitization in the real shared personal-info page.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

async function main() {
	const server = http.createServer((_request, response) => {
		response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
		response.end(
			'<div id="rows"></div><button id="btn-save"></button><button id="btn-cancel"></button>'
		);
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
		const context = await browser.newContext({
			permissions: ['clipboard-read', 'clipboard-write']
		});
		const page = await context.newPage();
		await page.goto(`http://127.0.0.1:${server.address().port}/`);
		await page.evaluate(() => {
			window.messages = [];
			window.makeHostBridge = () => (message) => window.messages.push(message);
		});
		const script = path.resolve(
			__dirname,
			'../../../static/ergopti_plus/_shared/ui/personal_info_editor/script.js'
		);
		await page.addScriptTag({ content: fs.readFileSync(script, 'utf8') });
		const values = { street_address: 'première\r\nseconde\r第三\nfin', city: 'Puteaux' };
		await page.evaluate(
			(seed) =>
				window.initData({
					fields: Object.entries(seed).map(([key, value]) => ({ key, label: key, value }))
				}),
			values
		);
		await page.locator('[name="city"]').fill('Paris');
		await page.evaluate(() =>
			window.initData({ fields: [{ key: 'city', label: 'city', value: 'Puteaux' }] })
		);
		assert.equal(
			await page.locator('[name="city"]').inputValue(),
			'Paris',
			'late initialization must preserve edits'
		);
		await page.click('#btn-save');
		let result = await page.evaluate(() => window.messages.at(-1));
		assert.deepEqual(result, { action: 'save', values: { ...values, city: 'Paris' } });
		assert.equal(
			await page.locator('[name="street_address"]').evaluate((node) => node.tagName),
			'TEXTAREA'
		);
		await page.locator('[name="street_address"]').fill('new line\nnext');
		await page.click('#btn-save');
		result = await page.evaluate(() => window.messages.at(-1));
		assert.equal(result.values.street_address, 'new line\nnext');
		await page.locator('[name="street_address"]').fill('première\nseconde\n第三\nfin');
		await page.click('#btn-save');
		result = await page.evaluate(() => window.messages.at(-1));
		assert.equal(
			result.values.street_address,
			values.street_address,
			'undoing an edit retains the original CRLF bytes'
		);
		await page.evaluate(() => navigator.clipboard.writeText('Paris\nÎle-de-France'));
		await page.locator('[name="city"]').focus();
		await page.keyboard.press(process.platform === 'darwin' ? 'Meta+A' : 'Control+A');
		await page.keyboard.press(process.platform === 'darwin' ? 'Meta+V' : 'Control+V');
		await page.click('#btn-save');
		result = await page.evaluate(() => window.messages.at(-1));
		assert.equal(
			result.values.city,
			'Paris\nÎle-de-France',
			'multiline clipboard text is retained'
		);
		const customPage = await context.newPage();
		await customPage.goto(`http://127.0.0.1:${server.address().port}/`);
		await customPage.evaluate(() => {
			window.messages = [];
			window.webkit = {
				messageHandlers: {
					hsPersonalInfo: {
						postMessage: (message) => window.messages.push(JSON.parse(JSON.stringify(message)))
					}
				}
			};
		});
		const hostBridge = path.resolve(
			__dirname,
			'../../../static/ergopti_plus/_shared/ui/host_bridge.js'
		);
		await customPage.addScriptTag({ content: fs.readFileSync(hostBridge, 'utf8') });
		await customPage.addScriptTag({ content: fs.readFileSync(script, 'utf8') });
		let injection;
		if (process.env.PERSONAL_INFO_LUAJIT) {
			const driver = path.resolve(__dirname, '../../../static/ergopti_plus/linux');
			const worker = String.raw`
package.path='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;'..package.path
package.loaded['core.logger.engine.shim']={info=function()end,error=function()end,debug=function()end,warn=function()end}
local state={dyn_hotstrings={get_info=function()return {['__proto__']='before',address='first\r\nsecond\rthird\nfourth'}end,
 get_letters=function()return {}end,get_trigger_char=function()return '★'end},
 webview_manager={eval_js=function(_,js)io.write(js);return true end},i18n={get=function(key)return key end}}
assert(require('ui.personal_info_editor.bridge').on_message({action='ready'},state).pushed)
`;
			const result = spawnSync(process.env.PERSONAL_INFO_LUAJIT, ['-e', worker], {
				cwd: driver,
				encoding: 'utf8'
			});
			assert.equal(result.status, 0, result.stderr);
			injection = result.stdout;
		} else {
			injection =
				'window.initData(' +
				JSON.stringify({
					fields: [
						{ key: '__proto__', label: 'custom', value: 'before' },
						{ key: 'address', label: 'address', value: 'first\r\nsecond\rthird\nfourth' }
					]
				}) +
				')';
		}
		await customPage.evaluate((code) => (0, eval)(code), injection);
		await customPage.locator('[name="__proto__"]').fill('after');
		await customPage.click('#btn-save');
		const encoded = await customPage.evaluate(() => JSON.stringify(window.messages.at(-1)));
		const custom = JSON.parse(encoded).values;
		assert.equal(Object.prototype.hasOwnProperty.call(custom, '__proto__'), true);
		assert.equal(custom.__proto__, 'after');
		assert.equal(custom.address, 'first\r\nsecond\rthird\nfourth');
		await context.close();
		console.log('personal-info editor preserves multiline values in Chromium');
	} finally {
		if (browser) await browser.close();
		await new Promise((resolve) => server.close(resolve));
	}
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
