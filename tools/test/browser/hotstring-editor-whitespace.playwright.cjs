// tools/test/browser/hotstring-editor-whitespace.playwright.cjs

/** Checks visual line layout of an existing or pasted multiline expansion. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium, webkit } = require('playwright');

(async () => {
	const names = (process.env.ERGOPTI_HOTSTRING_EDITOR_BROWSERS || 'chromium,webkit').split(',');
	for (const name of names) {
		assert.ok(name === 'chromium' || name === 'webkit', 'unknown browser');
		const browser = await { chromium, webkit }[name].launch({
			headless: true,
			...(name === 'chromium' && process.env.CHROMIUM_EXECUTABLE
				? { executablePath: process.env.CHROMIUM_EXECUTABLE }
				: {})
		});
		try {
			const page = await browser.newPage();
			const css = fs.readFileSync(
				path.resolve(
					__dirname,
					'../../../static/ergopti_plus/_shared/ui/hotstring_editor/style.css'
				),
				'utf8'
			);
			await page.setContent(
				'<style>' +
					css +
					'</style><div id="e-out" class="output-editor" contenteditable="true"></div>'
			);
			await page.evaluate(() => {
				window.makeHostBridge = () => () => {};
			});
			const source = fs.readFileSync(
				path.resolve(
					__dirname,
					'../../../static/ergopti_plus/_shared/ui/hotstring_editor/script.js'
				),
				'utf8'
			);
			const marker = source.indexOf('// ======= 15/ Event Wiring');
			assert.ok(marker > 0, 'real editor functions must load');
			await page.addScriptTag({ content: source.slice(0, marker) });
			const layout = await page.evaluate(() => {
				const editor = document.getElementById('e-out');
				parseToNodes('First\nSecond').forEach((node) => editor.appendChild(node));
				const node = editor.firstChild;
				function lineTop(start, end) {
					const range = document.createRange();
					range.setStart(node, start);
					range.setEnd(node, end);
					return range.getBoundingClientRect().top;
				}
				return {
					first: lineTop(0, 5),
					second: lineTop(6, 12),
					text: serializeEditor(editor),
					nodes: Array.from(editor.childNodes, (child) => child.nodeName),
					whiteSpace: getComputedStyle(editor).whiteSpace,
					height: editor.getBoundingClientRect().height
				};
			});
			assert.ok(
				layout.second > layout.first,
				`${name}: a newline in the output must be visible as a new line: ${JSON.stringify(layout)}`
			);
			assert.equal(layout.text, 'First\nSecond', 'the expansion text remains unchanged');
			console.log(name + ': hotstring output editor displays literal newlines');
		} finally {
			await browser.close();
		}
	}
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
