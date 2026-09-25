// tools/test/test-release-packaging-workflow.cjs

/**
 * Regression guard for release-only packaging commands that the ordinary
 * driver and package tests do not execute. The Windows bundle implementation
 * moved from lib/ to infra/, while the release stamp retained the old path.
 * Separately, `tar | head` under `pipefail` makes a successful archive listing
 * fail when head closes the pipe early. The macOS bundle smoke test also used
 * the inner Mach-O directly, bypassing the Launch Services context that Finder
 * and `open` provide and causing AppKit to terminate its embedded GUI child.
 * Early log creation subsequently masked a missing LuaSocket dependency: the
 * published app died immediately after the smoke test had declared success.
 * These defects surfaced only after every functional CI job had passed.
 *
 * The pipeline now spans ci.yml and one reusable workflow per OS. Each step is
 * looked up through tools/test/ci-pipeline.cjs and must exist exactly once, in
 * the package job of the OS box that builds that artifact, so a moved or
 * duplicated release step fails here instead of silently escaping the check.
 * The Windows exe job must also wait for test-ahk and never run its suites or
 * touch Defender (B1), and each release-only macOS step must run on every
 * release under its exact condition. A review then moved Sign after the
 * upload and Stamp after Compile, and removed the exe smoke's failing exit,
 * with every test green: the job's step order and the smoke's verdict are
 * pinned too, and so is the order of the macOS package job.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const pipeline = require('./ci-pipeline.cjs');

const root = path.resolve(__dirname, '..', '..');
const WINDOWS_BOX = '.github/workflows/ci-windows.yml';
const LINUX_BOX = '.github/workflows/ci-linux.yml';
const MACOS_BOX = '.github/workflows/ci-macos.yml';
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

// The one job of each box that builds its release artifact.
const PACKAGE_JOB = {
	[WINDOWS_BOX]: 'package-windows',
	[LINUX_BOX]: 'package-linux',
	[MACOS_BOX]: 'package-macos',
};
const releaseSteps = new Map();

/**
 * Returns the body of the one step named `name`, which must live in the package
 * job of `rel`, or null after recording why it could not be found there. A name
 * is resolved once, so a check that reads it again adds no second error.
 * @param {string} name Exact step name.
 * @param {string} rel Repository-relative workflow that must own the step.
 * @returns {string|null}
 */
function releaseStep(name, rel) {
	if (releaseSteps.has(name)) return releaseSteps.get(name);
	const job = PACKAGE_JOB[rel];
	let body = null;
	try {
		const found = pipeline.findStep(name);
		if (found.file === rel && found.job === job) {
			body = found.body;
		} else {
			errors.push(`step '${name}' runs in ${found.file} (job ${found.job}); it belongs in job ${job} of ${rel}`);
		}
	} catch (error) {
		errors.push(`${error.message}; job ${job} of ${rel} must run it exactly once`);
	}
	releaseSteps.set(name, body);
	return body;
}

// B1: the release exe is bundled, stamped, compiled, signed, smoked and
// uploaded by its own job on a fresh checkout. The unit and E2E suites of
// test-ahk write runtime caches next to tracked sources, and
// build_static_bundle.py bundles those directories, so any of these steps in
// test-ahk would ship test leftovers inside the signed exe; the smoke there
// would also run under the Defender configuration the test job alters.
for (const name of [
	'Build static asset bundle',
	'Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL',
	'Download authenticated Windows compiler toolchain',
	'Compile ErgoptiPlus.ahk',
	'Sign and verify ErgoptiPlus.exe',
	'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)',
	'Rename Windows keyboard layout for upload',
]) {
	releaseStep(name, WINDOWS_BOX);
}
const windowsUpload = releaseStep('Upload Windows artifacts', WINDOWS_BOX);
if (windowsUpload !== null && !/^\s+name:\s*assets-windows\s*$/m.test(windowsUpload)) {
	errors.push('the Windows release exe must be uploaded as assets-windows, the artifact release attaches');
}
const packageWindows = pipeline.job(PACKAGE_JOB[WINDOWS_BOX]);
if (!pipeline.needsOf(packageWindows).includes('test-ahk')) {
	errors.push(`${PACKAGE_JOB[WINDOWS_BOX]} must need test-ahk: a release exe is built only after the suites passed`);
}
const codeOf = (body) => body.split('\n').filter((line) => !line.trimStart().startsWith('#')).join('\n');
const testAhkCode = codeOf(pipeline.job('test-ahk'));
for (const token of ['run_all.ahk', 'run_e2e.ahk', 'MpPreference']) {
	// The token must still exist where it belongs, so the ban reads live text.
	if (!testAhkCode.includes(token)) {
		errors.push(`test-ahk no longer mentions ${token}; re-derive the B1 separation check`);
	}
	if (codeOf(packageWindows).includes(token)) {
		errors.push(`${PACKAGE_JOB[WINDOWS_BOX]} must not run ${token}: the release exe job neither tests nor touches Defender`);
	}
}

// The exe embeds the bundle when it is compiled, so the bundle is built and
// stamped first; it is signed and smoked before it is uploaded. Reordered, the
// job still runs every step and ships `__BUNDLE_VERSION__` placeholders, which
// the updater reads as a dev build, or an unsigned or unsmoked exe. That no
// step of the job can be skipped is pinned pipeline-wide by
// tools/test/test-ci-pipeline-wiring.cjs.
const WINDOWS_ORDER = [
	'Build static asset bundle',
	'Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL',
	'Compile ErgoptiPlus.ahk',
	'Sign and verify ErgoptiPlus.exe',
	'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)',
	'Rename Windows keyboard layout for upload',
	'Upload Windows artifacts',
];
const packageWindowsSteps = pipeline.steps(packageWindows).map((candidate) => candidate.name);
const windowsOrder = WINDOWS_ORDER.map((name) => packageWindowsSteps.indexOf(name));
if (windowsOrder.some((at, index) => at < 0 || (index > 0 && at <= windowsOrder[index - 1]))) {
	errors.push(`${PACKAGE_JOB[WINDOWS_BOX]} must run ${WINDOWS_ORDER.join(' < ')}; got: ${packageWindowsSteps.join(' | ')}`);
}
if (!(packageWindowsSteps.indexOf('Download authenticated Windows compiler toolchain') >= 0 &&
	packageWindowsSteps.indexOf('Download authenticated Windows compiler toolchain') <
		packageWindowsSteps.indexOf('Compile ErgoptiPlus.ahk'))) {
	errors.push(`${PACKAGE_JOB[WINDOWS_BOX]} must download the authenticated toolchain before it compiles`);
}

// The smoke's verdict is behavioural (the runtime bundle extracted, no early
// exit): its failure branch must end the step with a failing exit, or a
// crashing exe only prints an error.
const windowsSmokeStep = releaseStep('Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)', WINDOWS_BOX);
if (windowsSmokeStep !== null) {
	try {
		const verdict = pipeline.scriptBlock(pipeline.runOf(windowsSmokeStep) ?? [], 'if ($crashedEarly -or -not $markerSeen) {');
		if (!pipeline.blockExits(verdict, '1')) {
			errors.push('the Windows exe smoke must end its crash branch with exit 1');
		}
	} catch (error) {
		errors.push(`the Windows exe smoke lost its crash verdict: ${error.message}`);
	}
}

const stampStep = releaseStep('Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL', WINDOWS_BOX);
if (stampStep !== null) {
	if (!/windows\\infra\\bundle\.ahk/.test(stampStep)) {
		errors.push('the Windows release must stamp the live infra/bundle.ahk implementation');
	}
	if (/windows\\lib\\bundle\.ahk/.test(stampStep)) {
		errors.push('the Windows release still stamps the removed lib/bundle.ahk path');
	}
}

const windowsToolchainStep = releaseStep('Download authenticated Windows compiler toolchain', WINDOWS_BOX);
if (windowsToolchainStep !== null) {
	const body = windowsToolchainStep;
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

const windowsSigningStep = releaseStep('Sign and verify ErgoptiPlus.exe', WINDOWS_BOX);
if (windowsSigningStep !== null) {
	const body = windowsSigningStep;
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
	// The release profile itself (`if: inputs.release`) is allowed; skipping the
	// step on the prerelease flag is not.
	if (/if:\s*\$\{\{[^\n]*prerelease/.test(body)) {
		errors.push('the Windows signing step must validate partial secret sets at runtime');
	}
}

const linuxBundleStep = releaseStep('Package the installable bundle', LINUX_BOX);
if (linuxBundleStep !== null && /tar -tzf[^\n|]*\|\s*head(?:\s|$)/.test(linuxBundleStep)) {
	errors.push('the Linux release must not pipe tar into head under pipefail (tar exits on SIGPIPE)');
}

// The package metadata used to be logged by the per-format CI jobs, so a wrong
// control field or %files stanza showed without a Debian or Fedora box. The
// same pipefail trap applies: rpm listing into head fails a good listing.
const linuxMetadataStep = releaseStep('Log the package metadata', LINUX_BOX);
if (linuxMetadataStep !== null) {
	for (const token of ['dpkg-deb --info', 'rpm -qip', 'rpm -qlp']) {
		if (!linuxMetadataStep.includes(token)) {
			errors.push(`the Linux packages must log their metadata: ${token}`);
		}
	}
	if (/\|\s*head(?:\s|$)/.test(linuxMetadataStep)) {
		errors.push('the Linux package metadata must not be piped into head under pipefail');
	}
}

const macosSmokeStep = releaseStep('Smoke test built ErgoptiPlus.app (crash-on-launch guard)', MACOS_BOX);
if (macosSmokeStep !== null) {
	for (const token of [
		'python3 tools/diagnostics/macos_release_launch_test.py',
		'ditto -x -k build/macos/ErgoptiPlus.app.zip /Applications',
		'python3 tools/diagnostics/macos-release-launch.py /Applications/ErgoptiPlus.app',
	]) {
		if (!macosSmokeStep.includes(token)) {
			errors.push(`the macOS smoke test must exercise the extracted package: ${token}`);
		}
	}
}

// The zip is smoked, then signed, and the appcast embeds that signature; the
// upload must follow every file it carries. A signature or keylayout step
// moved past the upload leaves its file out, and the release preflight then
// stops the whole release after every box has run.
const MACOS_ORDER = [
	'Build ErgoptiPlus.app',
	'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
	'Install Sparkle signing tool',
	'Sign zip with Sparkle EdDSA key',
	'Generate Sparkle appcast',
	'Upload the macOS package',
];
const packageMacosSteps = pipeline.steps(pipeline.job(PACKAGE_JOB[MACOS_BOX])).map((candidate) => candidate.name);
const macosOrder = MACOS_ORDER.map((name) => packageMacosSteps.indexOf(name));
if (macosOrder.some((at, index) => at < 0 || (index > 0 && at <= macosOrder[index - 1]))) {
	errors.push(`${PACKAGE_JOB[MACOS_BOX]} must run ${MACOS_ORDER.join(' < ')}; got: ${packageMacosSteps.join(' | ')}`);
}
if (!(packageMacosSteps.indexOf('Package latest keylayout bundle') >= 0 &&
	packageMacosSteps.indexOf('Package latest keylayout bundle') < packageMacosSteps.indexOf('Upload the macOS package'))) {
	errors.push(`${PACKAGE_JOB[MACOS_BOX]} must package the keylayout bundle before it uploads the macOS package`);
}

// package-macos builds on every run and adds these steps on a release. Each
// must run on every release: the smoke is the only macOS 26 launch, and a
// skipped keylayout step drops Ergopti_macOS.zip without any upload error. The
// startup evidence is kept even when the smoke fails, which is when it matters.
for (const [name, condition] of [
	['Smoke test built ErgoptiPlus.app (crash-on-launch guard)', 'inputs.release'],
	['Retain packaged application startup evidence', 'always() && inputs.release'],
	['Install Sparkle signing tool', 'inputs.release'],
	['Sign zip with Sparkle EdDSA key', 'inputs.release'],
	['Generate Sparkle appcast', 'inputs.release'],
	['Package latest keylayout bundle', 'inputs.release'],
]) {
	const body = releaseStep(name, MACOS_BOX);
	if (body === null) continue;
	const actual = pipeline.stepField(body, 'if');
	if (actual !== condition) {
		errors.push(`the macOS release step '${name}' must run exactly if: ${condition}, got: ${actual}`);
	}
	if (pipeline.stepField(body, 'continue-on-error') !== null) {
		errors.push(`the macOS release step '${name}' must not set continue-on-error`);
	}
}

if (errors.length > 0) {
	console.error('[ERROR] Release packaging workflow is unsafe:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log('[OK] Release packaging stamps live sources and avoids pipefail/SIGPIPE traps.');
