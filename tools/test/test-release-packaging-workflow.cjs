// tools/test/test-release-packaging-workflow.cjs

/**
 * Regression guard for release-only packaging commands that the ordinary
 * driver and package tests do not execute. The Windows bundle implementation
 * moved from lib/ to infra/, while the release stamp retained the old path.
 * Separately, `tar | head` under `pipefail` makes a successful archive listing
 * fail when head closes the pipe early. The macOS bundle smoke test also used
 * the inner Mach-O directly, bypassing the Launch Services context that Finder
 * and `open` provide and causing AppKit to terminate its embedded GUI child.
 * A later form invoked `open` without waiting, so the launch request could end
 * while the nested runtime was still moving from early to managed logging.
 * These defects surfaced only after every functional CI job had passed.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const workflowPath = path.join(root, '.github', 'workflows', 'ci.yml');
const workflow = fs.readFileSync(workflowPath, 'utf8');
const windowsToolchainContractPath = path.join(
	root,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'updater',
	'windows_release_toolchain.json'
);
const windowsToolchainContract = JSON.parse(
	fs.readFileSync(windowsToolchainContractPath, 'utf8')
);
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

const windowsToolchainStep = workflow.match(
	/- name: Download authenticated Windows compiler toolchain([\s\S]*?)(?=\n\s{6}- name:)/
);
if (!windowsToolchainStep) {
	errors.push('the Windows release must have one authenticated compiler-toolchain step');
} else {
	const body = windowsToolchainStep[1];
	if (
		!body.includes('windows_release_toolchain.json') ||
		!body.includes('ConvertFrom-Json')
	) {
		errors.push('the Windows compiler toolchain must consume its shared authenticated contract');
	}
	for (const token of [
		'$contract.runtime.url',
		'$contract.runtime.sha256',
		'$contract.compiler.url',
		'$contract.compiler.sha256',
		'Get-FileHash',
	]) {
		if (!body.includes(token)) {
			errors.push(`the Windows compiler toolchain is missing pinned token ${token}`);
		}
	}
	if (/gh release download|--pattern\s+['"]?\*\.zip|Select-Object\s+-First\s+1/i.test(body)) {
		errors.push('the Windows compiler toolchain must not select a mutable or ambiguous archive');
	}
}

for (const [component, expected] of Object.entries({
	runtime: {
		version: '2.0.19',
		asset: 'AutoHotkey_2.0.19.zip',
		sha256: '4e0d0e65655066a646a210951320feaef0729a3597177131adaec4066bef5869',
	},
	compiler: {
		tag: 'Ahk2Exe1.1.37.02a2',
		asset: 'Ahk2Exe1.1.37.02a2.zip',
		sha256: 'c29b8c3a5124850d79fc9e66e2ca79677c377d7f31631ad3022ba159c5d9e3be',
	},
})) {
	for (const [field, value] of Object.entries(expected)) {
		if (windowsToolchainContract[component]?.[field] !== value) {
			errors.push(`the Windows ${component} contract must pin ${field}=${value}`);
		}
	}
	if (!/^https:\/\/github\.com\/AutoHotkey\//.test(windowsToolchainContract[component]?.url)) {
		errors.push(`the Windows ${component} contract must use an exact official GitHub URL`);
	}
}

const windowsSigningStep = workflow.match(
	/- name: Sign and verify ErgoptiPlus\.exe([\s\S]*?)(?=\n\s{6}- name:)/
);
if (!windowsSigningStep) {
	errors.push('the Windows release must sign and verify the compiled executable');
} else {
	const body = windowsSigningStep[1];
	for (const token of [
		'ERGOPTI_RELEASE_PRERELEASE',
		'WINDOWS_SIGNING_CERTIFICATE_BASE64',
		'WINDOWS_SIGNING_CERTIFICATE_PASSWORD',
		'WINDOWS_SIGNER_SUBJECT',
		'$missing.Count -eq $required.Count',
		'$missing.Count -gt 0',
		'Stable Windows releases require every signing secret.',
		'Partial Windows signing configuration',
		'Publishing an unsigned Windows artifact for the dev prerelease channel.',
		'signtool',
		'Get-AuthenticodeSignature',
		"Status -ne 'Valid'",
		'SignerCertificate.Subject',
	]) {
		if (!body.includes(token)) {
			errors.push(`the Windows signing gate is missing ${token}`);
		}
	}
	if (!body.includes('ERGOPTI_RELEASE_PRERELEASE -ceq "true"')) {
		errors.push('only an explicit dev prerelease may omit every Windows signing secret');
	}
	if (/if:\s*\$\{\{[^\n]*prerelease/.test(body)) {
		errors.push('the Windows signing step must validate partial secret sets at runtime');
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
	if (!/open -n -g -W "\$APP"\s*&/.test(macosSmokeStep[1])) {
		errors.push('the macOS smoke test must retain its Launch Services request through startup');
	}
	if (/"\$APP\/Contents\/MacOS\/ErgoptiPlus"\s*&/.test(macosSmokeStep[1])) {
		errors.push('the macOS smoke test must not execute the inner Mach-O directly');
	}
	if (!/pgrep -f -x "\$APP\/Contents\/MacOS\/ErgoptiPlus"/.test(macosSmokeStep[1])) {
		errors.push('the macOS smoke test must track the exact launcher PID after `open`');
	}
	if (!/OPEN_PID=\$!/.test(macosSmokeStep[1]) || !/wait "\$OPEN_PID"/.test(macosSmokeStep[1])) {
		errors.push('the macOS smoke test must own and reap the waiting `open` process');
	}
	for (const token of [
		'/tmp/ErgoptiPlus_boot.log',
		'/tmp/ErgoptiPlus_errors_boot.log',
		'cat "$LUA_BOOT_LOG"',
		'cat "$LUA_BOOT_ERRORS_LOG"',
	]) {
		if (!macosSmokeStep[1].includes(token)) {
			errors.push(`the macOS smoke test must surface early-boot diagnostic ${token}`);
		}
	}
}

if (errors.length > 0) {
	console.error('[ERROR] Release packaging workflow is unsafe:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log('[OK] Release packaging stamps live sources and avoids pipefail/SIGPIPE traps.');
