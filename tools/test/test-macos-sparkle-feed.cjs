// tools/test/test-macos-sparkle-feed.cjs

/**
 * Regression guard for the channel-specific Sparkle release contract. The
 * update channel is derived from the prerelease flag once, in ci.yml's plan
 * job; the macOS box stamps it into the bundle and the appcast, and the
 * release job publishes the feed of that same channel.
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');

const root = path.resolve(__dirname, '..', '..');
const workflow = pipeline.text();
const buildScript = fs.readFileSync(path.join(root, 'tools', 'build', 'build_macos_app.sh'), 'utf8');
const launcherSource = fs.readFileSync(
	path.join(root, 'static', 'ergopti_plus', 'macos', 'launcher', 'Sources', 'ErgoptiPlus', 'main.swift'),
	'utf8'
);
const menuSource = fs.readFileSync(
	path.join(root, 'static', 'ergopti_plus', 'macos', 'ui', 'menu', 'init.lua'),
	'utf8'
);
const aboutSource = fs.readFileSync(
	path.join(root, 'static', 'ergopti_plus', 'macos', 'ui', 'menu', 'menu_about.lua'),
	'utf8'
);
const errors = [];

// job() throws when package-macos is missing, so no check below can pass
// against an empty slice.
const macosJob = pipeline.job('package-macos');
const channelExpression = '${{ inputs.channel }}';
const channelAssignments = [...macosJob.matchAll(/ERGOPTI_CHANNEL:\s*(.+)/g)].map(
	(match) => match[1].trim()
);

if (channelAssignments.length !== 2) {
	errors.push(`the macOS package job must stamp exactly two channel consumers, found ${channelAssignments.length}`);
}
if (channelAssignments.some((value) => value !== channelExpression)) {
	errors.push('both the macOS bundle and appcast must stamp the channel the box receives from plan');
}

// One channel rule, in plan. Every other consumer receives its result, so the
// bundle, the appcast, the Windows stamp and the published feed cannot disagree.
const planMeta = pipeline.step(pipeline.job('plan'), 'Compute tag and version');
const channelRule = 'if [ "$prerelease" = "true" ]; then channel="dev"; else channel="main"; fi';
if (!planMeta.includes(channelRule) || !planMeta.includes('emit channel "$channel"')) {
	errors.push('plan must derive the update channel from the prerelease flag and emit it');
}
if ((workflow.match(/channel="dev"/g) ?? []).length !== 1) {
	errors.push('the prerelease-to-channel rule must exist once in the pipeline, in plan');
}
if (workflow.includes("prerelease == 'true' && 'dev' || 'main'") || /\$channel\s*=\s*if\s*\(\s*\$prerelease/.test(workflow)) {
	errors.push('a job re-derives the channel from prerelease instead of reading plan\'s channel output');
}
for (const caller of ['macos', 'windows']) {
	if (!/^\s+channel:\s*\$\{\{\s*needs\.plan\.outputs\.channel\s*\}\}\s*$/m.test(pipeline.job(caller))) {
		errors.push(`ci.yml's ${caller} caller must pass channel: \${{ needs.plan.outputs.channel }}`);
	}
}
for (const [label, value] of [
	...[...workflow.matchAll(/ERGOPTI_CHANNEL:\s*(.+)/g)].map((match) => ['ERGOPTI_CHANNEL', match[1].trim()]),
	...[...workflow.matchAll(/\$channel\s*=\s*(.+)/g)].map((match) => ['$channel', match[1].trim()]),
]) {
	if (!/^"?\$\{\{\s*(?:inputs\.channel|needs\.plan\.outputs\.channel)\s*\}\}"?$/.test(value)) {
		errors.push(`${label} must read inputs.channel or needs.plan.outputs.channel, got ${value}`);
	}
}

// A release must fail rather than skip its signature: a skipped signature
// writes no appcast, and the tag and the immutable release used to be created
// before the feed step noticed.
for (const name of ['Sign zip with Sparkle EdDSA key', 'Generate Sparkle appcast']) {
	if (!/^\s+if:\s*inputs\.release\s*$/m.test(pipeline.step(macosJob, name))) {
		errors.push(`"${name}" must run on every release (if: inputs.release), never on the key's presence`);
	}
}
if (/SPARKLE_ED_PRIVATE_KEY\s*!=\s*''/.test(workflow)) {
	errors.push('no macOS release step may be skipped because SPARKLE_ED_PRIVATE_KEY is empty');
}
if (!/if \[ -z "\$SPARKLE_ED_PRIVATE_KEY" \]; then\s*echo "::error::[^\n]*\n\s*exit 1/.test(
	pipeline.step(macosJob, 'Sign zip with Sparkle EdDSA key'))) {
	errors.push('a release without SPARKLE_ED_PRIVATE_KEY must fail the signing step');
}

if (!buildScript.includes('/sparkle-appcasts/appcast-$ERGOPTI_CHANNEL.xml')) {
	errors.push('SUFeedURL must target the mutable channel-specific Sparkle feed branch');
}
if (!buildScript.includes('<key>CFBundleURLTypes</key>') ||
	!buildScript.includes('<string>ergoptiplus</string>')) {
	errors.push('the outer bundle must register the private updater command URL scheme');
}
if (!buildScript.includes('<key>SUEnableAutomaticChecks</key>        <true/>') ||
	!buildScript.includes('<key>SUScheduledCheckInterval</key>       <integer>86400</integer>')) {
	errors.push('Sparkle must own automatic checks at the declared 24-hour cadence');
}
// A scheduled check may only fetch the appcast. With SUAllowsAutomaticUpdates
// true, one tick of Sparkle's "Automatically download and install" checkbox
// made every later check download silently and install on quit
// (updater-consent-2026-09-25).
if (!/<key>SUAllowsAutomaticUpdates<\/key>\s*<false\/>/.test(buildScript) ||
	/<key>SUAllowsAutomaticUpdates<\/key>\s*<true\/>/.test(buildScript) ||
	/<key>SUAutomaticallyUpdate<\/key>\s*<true\/>/.test(buildScript)) {
	errors.push('the launcher bundle must declare SUAllowsAutomaticUpdates false: Sparkle must never download before consent');
}
// Sparkle's standard interface ships English windows that cannot follow the
// driver's language (and modal alerts that stall the launcher's main queue):
// the launcher must present every update window through its catalog driver.
const launcherSourcesDir = path.join(root, 'static', 'ergopti_plus', 'macos', 'launcher', 'Sources', 'ErgoptiPlus');
const launcherSwift = fs.readdirSync(launcherSourcesDir)
	.filter((name) => name.endsWith('.swift'))
	.map((name) => fs.readFileSync(path.join(launcherSourcesDir, name), 'utf8'))
	.join('\n');
if (/SPUStandardUpdaterController|SPUStandardUserDriver/.test(launcherSwift)) {
	errors.push('the launcher must not use the standard Sparkle interface, which is English-only');
}
if (!launcherSource.includes('userDriver: userDriver') || !launcherSwift.includes('final class CatalogUpdateUserDriver')) {
	errors.push('the launcher must drive Sparkle through the catalog-localized user driver');
}
const policyAt = launcherSource.indexOf('UpdateConsentPolicy.refusal(');
const startAt = launcherSource.search(/\.(?:startUpdater|start)\(\)/);
if (policyAt < 0 || startAt < 0 || policyAt > startAt) {
	errors.push('the launcher must prove the consent-only policy on the live updater before starting it');
}
if (menuSource.includes('Updater.start_background_checks') ||
	aboutSource.includes('menu.about.frequency_menu') ||
	aboutSource.includes('Updater.restart_background_checks')) {
	errors.push('Lua must not retain a second update timer or expose controls that do not configure Sparkle');
}
if (/Rename appcast|_appcast-(?:main|dev)|build\/macos\/_appcast/.test(workflow)) {
	errors.push('the published appcast basename must not be renamed behind SUFeedURL');
}
if (!macosJob.includes('OUTPUT_PATH: build/macos/appcast-${{ inputs.channel }}.xml')) {
	errors.push('appcast output must use the same resolved channel as the bundle');
}
if (!pipeline.step(macosJob, 'Upload the macOS package').includes('build/macos/appcast-*.xml')) {
	errors.push('the macOS artifact must preserve the exact appcast-{channel}.xml basename');
}
const feedPublishStep = pipeline.step(pipeline.job('release'), 'Publish channel feed for Sparkle');
if (!/^\s+ERGOPTI_CHANNEL:\s*\$\{\{\s*needs\.plan\.outputs\.channel\s*\}\}\s*$/m.test(feedPublishStep)) {
	errors.push('the published feed must be the channel plan resolved');
}
if (!/git -C "\$worktree" push origin "HEAD:refs\/heads\/\$\{branch\}"/.test(feedPublishStep)) {
	errors.push('finalization must commit and push the channel feed to its dedicated mutable branch');
} else if (/gh release (?:create|upload) sparkle-feed/.test(feedPublishStep)) {
	errors.push('an immutable GitHub release cannot own a channel feed that changes every release');
} else if (!feedPublishStep.includes('raw.githubusercontent.com/${{ github.repository }}/${branch}/appcast-')) {
	errors.push('publication verification must read the same raw branch URL stamped into SUFeedURL');
} else if (!feedPublishStep.includes('--retry-all-errors') ||
	!feedPublishStep.includes('--retry-max-time 90') ||
	!feedPublishStep.includes('--retry 12')) {
	errors.push('raw appcast verification must tolerate the bounded post-push propagation window');
}

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-appcast-'));
try {
	const archivePath = path.join(fixtureRoot, 'ErgoptiPlus.app.zip');
	const signaturePath = path.join(fixtureRoot, 'signature.txt');
	const outputPath = path.join(fixtureRoot, 'appcast-dev.xml');
	const archive = Buffer.from('faithful Sparkle appcast fixture\n', 'utf8');
	const signature = `${'A'.repeat(86)}==`;
	fs.writeFileSync(archivePath, archive);
	fs.writeFileSync(
		signaturePath,
		`sparkle:edSignature="${signature}" length="${archive.length}"\n`
	);

	const toPosix = (value) => value.replace(/^([A-Za-z]):/, '/$1').replaceAll('\\', '/');
	const bash =
		process.platform === 'win32' && fs.existsSync('C:/Program Files/Git/bin/bash.exe')
			? 'C:/Program Files/Git/bin/bash.exe'
			: 'bash';
	const generated = spawnSync(bash, [toPosix(path.join(root, 'tools', 'build', 'generate_appcast.sh'))], {
		encoding: 'utf8',
		env: {
			...process.env,
			ERGOPTI_VERSION: '0.0.0-dev.117',
			ERGOPTI_BUILD: '117',
			ERGOPTI_CHANNEL: 'dev',
			SPARKLE_SIG_FILE: toPosix(signaturePath),
			ZIP_PATH: toPosix(archivePath),
			GH_OWNER: 'adrienm7',
			GH_REPO: 'ergopti',
			OUTPUT_PATH: toPosix(outputPath),
		},
	});
	if (generated.status !== 0) {
		errors.push(`the appcast generator rejected a faithful sign_update fragment: ${generated.stderr.trim()}`);
	} else {
		const xml = fs.readFileSync(outputPath, 'utf8');
		const xmlCheck = spawnSync('xmllint', ['--noout', outputPath], { encoding: 'utf8' });
		if (xmlCheck.error) {
			errors.push(`xmllint is required to validate the generated appcast: ${xmlCheck.error.message}`);
		} else if (xmlCheck.status !== 0) {
			errors.push(`the generated appcast is not parseable XML: ${(xmlCheck.stderr ?? '').trim()}`);
		}
		if ((xml.match(/sparkle:edSignature=/g) ?? []).length !== 1) {
			errors.push('the generated enclosure must contain exactly one Sparkle signature');
		}
		if (!xml.includes(`sparkle:edSignature="${signature}" length="${archive.length}"`)) {
			errors.push('the generated enclosure must preserve the validated signature and archive length');
		}
	}
} finally {
	fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log('[OK] macOS Sparkle release metadata is channel-specific.');
