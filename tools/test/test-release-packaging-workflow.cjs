// tools/test/test-release-packaging-workflow.cjs

/**
 * Regression guard for release-only packaging commands that the ordinary
 * driver and package tests do not execute. The Windows bundle implementation
 * moved from lib/ to infra/, while the release stamp retained the old path.
 * Separately, `tar | head` under `pipefail` makes a successful archive listing
 * fail when head closes the pipe early. Both defects surfaced only after every
 * functional CI job had passed.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const workflowPath = path.join(root, '.github', 'workflows', 'ci.yml');
const workflow = fs.readFileSync(workflowPath, 'utf8');
const errors = [];

const stampStep = workflow.match(
	/- name: Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL([\s\S]*?)(?=\n\s{6}- name:)/
);
if (!stampStep) {
	errors.push('the Windows release bundle-stamp step is missing');
} else {
	if (!/windows\\infra\\bundle\.ahk/.test(stampStep[1])) {
		errors.push('the Windows release must stamp the live infra/bundle.ahk implementation');
	}
	if (/windows\\lib\\bundle\.ahk/.test(stampStep[1])) {
		errors.push('the Windows release still stamps the removed lib/bundle.ahk path');
	}
}

const linuxBundleStep = workflow.match(
	/- name: Package the installable bundle([\s\S]*?)(?=\n\s{6}- name:)/
);
if (!linuxBundleStep) {
	errors.push('the Linux installable-bundle step is missing');
} else if (/tar -tzf[^\n|]*\|\s*head(?:\s|$)/.test(linuxBundleStep[1])) {
	errors.push('the Linux release must not pipe tar into head under pipefail (tar exits on SIGPIPE)');
}

if (errors.length > 0) {
	console.error('[ERROR] Release packaging workflow is unsafe:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log('[OK] Release packaging stamps live sources and avoids pipefail/SIGPIPE traps.');
