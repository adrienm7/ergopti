// tools/test/test-windows-metrics-range-bridge.cjs

/**
 * ============================================================================== 
 * MODULE: Windows Metrics Selected-Range Bridge Test
 * DESCRIPTION:
 * Static cross-layer regression gate for the WebView2 request/response contract
 * used when a typing-dashboard date or application filter changes.
 * ============================================================================== 
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..', '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

const data = read('static/ergopti_plus/_shared/ui/metrics_typing/data.js');
const html = read('static/ergopti_plus/_shared/ui/metrics_typing/index.html');
const host = read('static/ergopti_plus/windows/modules/keylogger/keylogger_webview.ahk');

assert.match(data, /window\.chrome\?\.webview/,
	'Windows must detect the native WebView2 bridge before falling back to macOS polling');
assert.match(data, /postMessage\(JSON\.stringify\(\{ action: 'range', \.\.\.req \}\)\)/,
	'Windows must send the selected date/app range to the native host');
assert.match(host, /case "range"/,
	'Windows host must receive the selected-range action');
assert.match(host, /KLPF_RequestRange\(which, KLWV\.metrics_dir, query, Epoch,/,
	'Windows must dispatch range projection to the asynchronous worker after the WebView callback returns');
assert.match(host, /KLWV_OnRangeBuildReady\.Bind\(which, Epoch\)/,
	'Windows range worker completion must be bound to the current dashboard epoch');
assert.match(host, /KLWV_OnRangeBuildReady\(which, Epoch, stage, \*\)/,
	'Windows must reject stale range-worker completions before rendering');
assert.match(host, /ExecuteScriptAsync\(js\)/,
	'Windows must let WebView read and decode the staged range payload off the keyboard thread');
assert.match(html, /payload\.type === 'range_data'/,
	'frontend must recognise selected-range responses');
assert.match(html, /window\.receive_range_data\(payload\.payload\)/,
	'frontend must clear loading state and render the selected-range payload');

console.log('Windows metrics selected-range bridge contract: OK');
