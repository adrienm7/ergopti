// tools/test/test-metrics-apps-linux-poll.cjs

/**
 * ==============================================================================
 * MODULE: The Apps Metrics Window Under The Linux Poll
 * DESCRIPTION:
 * On Linux the apps metrics page asks for a refresh every 2 s, and every
 * answer re-bootstrapped the whole dashboard: charts rebuilt, filters and
 * categories reset, even when nothing had changed. The page's own inline
 * bootstrap script is run here in a sandbox: an identical answer must change
 * nothing, and a changed one must only merge the new data.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { installHostCapabilities } = require('./support/host-capabilities.cjs');
const assert = require('node:assert/strict');

const PAGE = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/ui/metrics_apps/index.html'
);
const html = fs.readFileSync(PAGE, 'utf8');
const start = html.indexOf('(function () {\n\t\t\t\tfunction apply_prefetch');
const end = html.indexOf('})();', start);
if (start === -1 || end === -1) {
	console.error('\x1b[31m[ERROR] the apps page bootstrap script was not found.\x1b[0m');
	process.exit(1);
}
const script = html.slice(start, end + '})();'.length);

const calls = { bootstrap: 0, live: 0 };
const window = {
	__ergopti_host_capabilities: { document_bridge: true },
	webkit: { messageHandlers: { metrics_apps_bridge: { postMessage() {} } } },
	bootstrapMetricsAppsData() {
		calls.bootstrap += 1;
	},
	receive_live_update() {
		calls.live += 1;
	}
};
const sandbox = {
	window,
	decodeHostBridgeResponse: (_isBase64, payload) => payload,
	createVisibilityPoller() {},
	JSON
};
vm.createContext(sandbox);
installHostCapabilities(sandbox);
vm.runInContext(script, sandbox);

const answer = (manifest) =>
	window.__hostBridgeResponse('metrics_apps_bridge', false, { metrics_manifest: manifest });
answer({ '2026-09-24': { firefox: { chars: 10 } } });
answer({ '2026-09-24': { firefox: { chars: 10 } } });
answer({ '2026-09-24': { firefox: { chars: 10 } } });
const failures = [];
if (calls.bootstrap !== 1)
	failures.push(`three identical answers bootstrapped ${calls.bootstrap} time(s), expected 1`);
if (calls.live !== 0)
	failures.push(`identical answers triggered ${calls.live} live update(s), expected 0`);
answer({ '2026-09-24': { firefox: { chars: 25 } } });
if (calls.bootstrap !== 1 || calls.live !== 1) {
	failures.push(
		`a changed answer must merge once without re-bootstrapping (bootstrap ${calls.bootstrap}, live ${calls.live})`
	);
}

if (failures.length) {
	for (const failure of failures) console.error(`\x1b[31m[ERROR] ${failure}\x1b[0m`);
	process.exit(1);
}
console.log('\x1b[32m[OK] the apps metrics window keeps its state across the Linux poll.\x1b[0m');

// Execute the actual category owner, selected-filter state and bootstrap too.
// DOM drawing and the native transport remain explicit ports.
const actual = vm.createContext({
	console,
	document: {
		getElementById() {
			return null;
		}
	},
	makeHostBridge() {
		return () => {};
	},
	createVisibilityPoller() {},
	decodeHostBridgeResponse: (_base64, payload) => payload
});
actual.window = actual;
installHostCapabilities(actual);
actual.__ergopti_host_capabilities = { document_bridge: true };
actual.webkit = { messageHandlers: { metrics_apps_bridge: { postMessage() {} } } };
for (const file of ['helpers.js', 'state.js', 'main.js']) {
	vm.runInContext(fs.readFileSync(path.join(path.dirname(PAGE), file), 'utf8'), actual, {
		filename: file
	});
}
let renders = 0;
actual.renderDashboard = () => {
	renders++;
};
vm.runInContext(script, actual);
const receive = (payload) => actual.__hostBridgeResponse('metrics_apps_bridge', false, payload);
const manifest = { '2026-09-24': { 'Synthetic editor': { category: 'Productivity', chars: 10 } } };
receive({
	metrics_manifest: manifest,
	user_categories: { 'Synthetic editor': { type: 'Productivity', score: 0 } }
});
vm.runInContext(
	"currentPeriod='month';currentSelectedDate='2026-09-24';currentCategoryFilter=new Set(['chosen']);",
	actual
);
const preferences = () =>
	vm.runInContext(
		'JSON.stringify([currentPeriod,currentSelectedDate,[...currentCategoryFilter]])',
		actual
	);
const original = preferences();
const category = () => vm.runInContext("getAppCategory('Synthetic editor','Productivity')", actual);
assert.equal(category().score, 0);
receive({
	metrics_manifest: manifest,
	user_categories: { 'Synthetic editor': { type: 'Productivity', score: 2 } }
});
assert.equal(
	category().score,
	2,
	'score-only changes must publish even with an identical manifest'
);
assert.equal(preferences(), original, 'category publication must preserve selected filters');
assert.equal(renders, 1);
receive({
	metrics_manifest: manifest,
	user_categories: { 'Synthetic editor': { type: 'Productivity', score: 2 } }
});
assert.equal(renders, 1, 'identical categories must not draw again');
receive({ metrics_manifest: { '2026-09-24': { 'Synthetic editor': { chars: 20 } } } });
assert.equal(
	category().score,
	2,
	'a manifest-only response must retain the accepted category owner'
);
receive({ metrics_manifest: manifest, user_categories: {} });
assert.equal(category().score, 0, 'explicitly empty categories clear the override');
assert.equal(preferences(), original);
console.log('Linux category-only publication with real shared scripts: OK');
