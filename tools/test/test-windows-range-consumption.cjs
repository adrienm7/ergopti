// tools/test/test-windows-range-consumption.cjs

/**
 * Execute the script produced by the native AHK builder with deferred fetch and
 * body promises. Native submission must never acknowledge an unread stage.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

async function main() {
	if (process.platform !== 'win32') {
		console.log('Windows range consumption: native builder replay requires Windows.');
		return;
	}
	const ahk = ['C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe',
		'C:/Program Files/AutoHotkey/AutoHotkey64.exe'].find(candidate => fs.existsSync(candidate));
	assert.ok(ahk, 'native range script verification requires AutoHotkey v2');
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-range-consumption-'));
	try {
		const windows = path.resolve(__dirname, '../../static/ergopti_plus/windows');
		const wrapper = path.join(root, 'build.ahk');
		fs.writeFileSync(wrapper, '\uFEFF#Requires AutoHotkey v2.0\n' +
			`#Include ${windows}/infra/json.ahk\n` +
			`#Include ${windows}/modules/keylogger/keylogger_webview_range_script.ahk\n` +
			'FileAppend(KLWV_BuildRangeScript(A_Args[1], 42, A_Args[2]), "*", "UTF-8-RAW")\n');
		const url = 'file:///C:/synthetic%20range.json';
		const token = 'generation-"quoted"-\\-token';
		const result = spawnSync(ahk, ['/ErrorStdOut', wrapper, url, token], {
			windowsHide: true, encoding: 'utf8', timeout: 5000,
		});
		assert.ifError(result.error);
		assert.equal(result.status, 0, result.stdout + result.stderr);
		assert.ok(result.stdout.startsWith('fetch('), 'execute the actual generated script');
		for (const mode of ['ok', 'fetch-error', 'parse-error', 'render-error', 'bridge-error', 'terminal-error']) {
			let fetchResolve, fetchReject, bodyResolve, bodyReject;
			const body = new Promise((resolve, reject) => { bodyResolve = resolve; bodyReject = reject; });
			const messages = [], rendered = [], terminals = [], warnings = [];
			const pending = vm.runInNewContext(result.stdout, {
				fetch: (received) => {
					assert.equal(received, url);
					return new Promise((resolve, reject) => { fetchResolve = resolve; fetchReject = reject; });
				},
				console: { warn: (message) => warnings.push(message) },
				window: {
					receive_range_data: (_, id) => {
						assert.equal(id, 42);
						if (mode === 'render-error') throw new Error('synthetic render failure');
						rendered.push(id);
					},
					complete_range_request: (id, status) => {
						terminals.push({ id, status });
						if (mode === 'terminal-error') throw new Error('synthetic terminal failure');
					},
					chrome: { webview: { postMessage: (message) => {
						if (mode === 'bridge-error') throw new Error('synthetic closed bridge');
						messages.push(JSON.parse(message));
					} } },
				},
			});
			assert.deepEqual(messages, [], 'submission is not consumption');
			if (mode === 'fetch-error' || mode === 'terminal-error') fetchReject(new Error('synthetic read refusal'));
			else {
				fetchResolve({ json: () => body });
				await Promise.resolve();
				assert.deepEqual(messages, [], 'opening a response is not completion of its body read');
				if (mode === 'parse-error') bodyReject(new Error('synthetic JSON failure'));
				else bodyResolve({ historical: {}, today: {} });
			}
			if (mode === 'terminal-error') await assert.rejects(pending, /synthetic terminal failure/);
			else await pending;
			assert.deepEqual(messages, mode === 'bridge-error' ? [] : [{ action: 'range_consumed', token }]);
			assert.deepEqual(rendered, mode === 'ok' || mode === 'bridge-error' ? [42] : []);
			assert.deepEqual(terminals, mode === 'ok' || mode === 'bridge-error' ? [] : [{ id: 42, status: 'failed' }]);
			assert.equal(warnings.length, mode === 'bridge-error' ? 1 : 0);
		}
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
	console.log('Windows range consumption: six deferred native-script outcomes passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
