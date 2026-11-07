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
			// The editor's content height grows by one line for the newline. A
			// Range rectangle is not used: WebKit measures a range that starts
			// right after a hard break on the line before it.
			const layout = await page.evaluate(() => {
				const editor = document.getElementById('e-out');
				const single = editor.cloneNode(false);
				single.id = 'e-single';
				editor.after(single);
				for (const element of [editor, single]) {
					element.style.minHeight = '0';
					element.style.maxHeight = 'none';
				}
				parseToNodes('First\nSecond').forEach((node) => editor.appendChild(node));
				parseToNodes('First').forEach((node) => single.appendChild(node));
				const lineHeight = parseFloat(getComputedStyle(editor).lineHeight);
				return {
					two: editor.scrollHeight,
					one: single.scrollHeight,
					lineHeight,
					text: serializeEditor(editor),
					whiteSpace: getComputedStyle(editor).whiteSpace
				};
			});
			assert.ok(
				layout.lineHeight > 0 && layout.two - layout.one >= layout.lineHeight * 0.9,
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
