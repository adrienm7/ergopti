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

const PAGE = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui/metrics_apps/index.html');
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
	__ergopti_host: 'linux',
	webkit: { messageHandlers: { metrics_apps_bridge: { postMessage() {} } } },
	bootstrapMetricsAppsData() { calls.bootstrap += 1; },
	receive_live_update() { calls.live += 1; },
};
const sandbox = {
	window,
	decodeHostBridgeResponse: (_isBase64, payload) => payload,
	createVisibilityPoller() {},
	JSON,
};
vm.runInNewContext(script, sandbox);

const answer = (manifest) => window.__hostBridgeResponse('metrics_apps_bridge', false, { metrics_manifest: manifest });
answer({ '2026-09-24': { firefox: { chars: 10 } } });
answer({ '2026-09-24': { firefox: { chars: 10 } } });
answer({ '2026-09-24': { firefox: { chars: 10 } } });
const failures = [];
if (calls.bootstrap !== 1) failures.push(`three identical answers bootstrapped ${calls.bootstrap} time(s), expected 1`);
if (calls.live !== 0) failures.push(`identical answers triggered ${calls.live} live update(s), expected 0`);
answer({ '2026-09-24': { firefox: { chars: 25 } } });
if (calls.bootstrap !== 1 || calls.live !== 1) {
	failures.push(`a changed answer must merge once without re-bootstrapping (bootstrap ${calls.bootstrap}, live ${calls.live})`);
}

if (failures.length) {
	for (const failure of failures) console.error(`\x1b[31m[ERROR] ${failure}\x1b[0m`);
	process.exit(1);
}
console.log('\x1b[32m[OK] the apps metrics window keeps its state across the Linux poll.\x1b[0m');
