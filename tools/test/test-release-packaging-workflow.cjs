// tools/test/test-release-packaging-workflow.cjs

/**
 * Regression guard for release-only packaging commands that the ordinary
 * driver and package tests do not execute. The Windows bundle implementation
 * moved from lib/ to infra/, while the release stamp retained the old path.
 * Separately, `tar | head` under `pipefail` makes a successful archive listing
 * fail when head closes the pipe early. The macOS bundle smoke test also used
 * the inner Mach-O directly, bypassing the Launch Services context that Finder
 * and `open` provide and causing AppKit to terminate its embedded GUI child.
 * These defects surfaced only after every functional CI job had passed.
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

const macosSmokeStep = workflow.match(
	/- name: Smoke test built ErgoptiPlus\.app \(crash-on-launch guard\)([\s\S]*?)(?=\n\s{6}- name:)/
);
if (!macosSmokeStep) {
	errors.push('the macOS release bundle smoke-test step is missing');
} else {
	if (!/open -n -g "\$APP"/.test(macosSmokeStep[1])) {
		errors.push('the macOS smoke test must launch the .app through Launch Services');
	}
	if (/"\$APP\/Contents\/MacOS\/ErgoptiPlus"\s*&/.test(macosSmokeStep[1])) {
		errors.push('the macOS smoke test must not execute the inner Mach-O directly');
	}
	if (!/pgrep -f -x "\$APP\/Contents\/MacOS\/ErgoptiPlus"/.test(macosSmokeStep[1])) {
		errors.push('the macOS smoke test must track the exact launcher PID after `open`');
	}
}

if (errors.length > 0) {
	console.error('[ERROR] Release packaging workflow is unsafe:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log('[OK] Release packaging stamps live sources and avoids pipefail/SIGPIPE traps.');
