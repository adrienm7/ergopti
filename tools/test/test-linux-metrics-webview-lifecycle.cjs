// tools/test/test-linux-metrics-webview-lifecycle.cjs

/**
* ==============================================================================
* MODULE: Linux Metrics WebView Lifecycle Regression Test
* DESCRIPTION:
* Proves that Linux metrics polling stops while its document is hidden, owns at
* most one interval after resume, and is wired into both shared dashboards.
* ==============================================================================
*/

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const UI_ROOT = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui');
const hostBridge = fs.readFileSync(path.join(UI_ROOT, 'host_bridge.js'), 'utf8');
const metricsApps = fs.readFileSync(path.join(UI_ROOT, 'metrics_apps', 'index.html'), 'utf8');
const metricsTyping = fs.readFileSync(path.join(UI_ROOT, 'metrics_typing', 'index.html'), 'utf8');

const listeners = { document: new Map(), window: new Map() };
const intervals = new Map();
let nextIntervalId = 0;
let refreshes = 0;

const document = {
	visibilityState: 'visible',
	addEventListener(type, listener) {
		listeners.document.set(type, listener);
	},
};
const window = {
	addEventListener(type, listener) {
		listeners.window.set(type, listener);
	},
	setInterval(callback, delayMs) {
		nextIntervalId += 1;
		intervals.set(nextIntervalId, { callback, delayMs });
		return nextIntervalId;
	},
	clearInterval(intervalId) {
		intervals.delete(intervalId);
	},
	refresh() {
		refreshes += 1;
	},
};
const context = vm.createContext({ console, document, window });
vm.runInContext(hostBridge, context, { filename: 'host_bridge.js' });
vm.runInContext('window.poller = createVisibilityPoller(window.refresh, 2000)', context);

if (refreshes !== 1 || intervals.size !== 1) {
	throw new Error('a visible metrics page must start with one read and one interval');
}
listeners.window.get('pageshow')();
listeners.window.get('pageshow')();
if (refreshes !== 1 || intervals.size !== 1) {
	throw new Error('duplicate visible/resume events must not create another metrics poller');
}

document.visibilityState = 'hidden';
listeners.document.get('visibilitychange')();
if (intervals.size !== 0) {
	throw new Error('a hidden metrics page must own no polling interval');
}

document.visibilityState = 'visible';
listeners.document.get('visibilitychange')();
if (refreshes !== 2 || intervals.size !== 1) {
	throw new Error('a visible-again metrics page must catch up through exactly one interval');
}
listeners.window.get('pagehide')();
if (intervals.size !== 0) {
	throw new Error('pagehide must tear down the metrics poller');
}
listeners.window.get('pageshow')();
if (refreshes !== 3 || intervals.size !== 1) {
	throw new Error('reopening must create exactly one fresh metrics poller');
}
window.poller.stop();

if (!metricsApps.includes('createVisibilityPoller(request_linux_refresh, 2000);')) {
	throw new Error('the Linux application metrics dashboard bypasses the lifecycle poller');
}
if (!metricsTyping.includes('createVisibilityPoller(request_linux_refresh, 2000, false);')) {
	throw new Error('the Linux typing metrics dashboard bypasses the lifecycle poller');
}

console.log('1..1');
console.log('ok 1 - Linux metrics polling follows the WebView lifecycle');
