// tools/test/test-macos-sparkle-feed.cjs

/**
 * Regression guard for the channel-specific Sparkle release contract.
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..', '..');
const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), 'utf8');
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

const macosJob = workflow.match(/\n  build-macos:\n([\s\S]*?)(?=\n  build-windows:)/)?.[1] ?? '';
const channelExpression =
	"${{ needs.resolve-release-meta.outputs.prerelease == 'true' && 'dev' || 'main' }}";
const channelAssignments = [...macosJob.matchAll(/ERGOPTI_CHANNEL:\s*(.+)/g)].map(
	(match) => match[1].trim()
);

if (channelAssignments.length !== 2) {
	errors.push(`the macOS release job must stamp exactly two channel consumers, found ${channelAssignments.length}`);
}
if (channelAssignments.some((value) => value !== channelExpression)) {
	errors.push('both the macOS bundle and appcast must derive their channel from prerelease metadata');
}

if (!buildScript.includes('/sparkle-appcasts/appcast-$ERGOPTI_CHANNEL.xml')) {
	errors.push('SUFeedURL must target the mutable channel-specific Sparkle feed branch');
}
if (!buildScript.includes('<key>CFBundleURLTypes</key>') ||
	!buildScript.includes('<string>ergoptiplus</string>')) {
	errors.push('the outer bundle must register the private updater command URL scheme');
}
if (!buildScript.includes('<key>SUEnableAutomaticChecks</key>        <true/>') ||
	!buildScript.includes('<key>SUScheduledCheckInterval</key>       <integer>86400</integer>') ||
	!launcherSource.includes('startingUpdater: true')) {
	errors.push('Sparkle must own automatic checks at the declared 24-hour cadence');
}
if (menuSource.includes('Updater.start_background_checks') ||
	aboutSource.includes('menu.about.frequency_menu') ||
	aboutSource.includes('Updater.restart_background_checks')) {
	errors.push('Lua must not retain a second update timer or expose controls that do not configure Sparkle');
}
if (/Rename appcast|_appcast-(?:main|dev)|build\/macos\/_appcast/.test(workflow)) {
	errors.push('the published appcast basename must not be renamed behind SUFeedURL');
}
if (!macosJob.includes('OUTPUT_PATH: build/macos/appcast-${{ needs.resolve-release-meta.outputs.prerelease')) {
	errors.push('appcast output must use the same resolved channel as the bundle');
}
if (!macosJob.includes('build/macos/appcast-*.xml')) {
	errors.push('the macOS artifact must preserve the exact appcast-{channel}.xml basename');
}
const feedPublishStep = workflow.match(
	/- name: Publish channel feed for Sparkle([\s\S]*?)(?=\n\s{6}- name:|\n  [a-z])/
);
if (!feedPublishStep || !/git -C "\$worktree" push origin "HEAD:refs\/heads\/\$\{branch\}"/.test(feedPublishStep[1])) {
	errors.push('finalization must commit and push the channel feed to its dedicated mutable branch');
} else if (/gh release (?:create|upload) sparkle-feed/.test(feedPublishStep[1])) {
	errors.push('an immutable GitHub release cannot own a channel feed that changes every release');
} else if (!feedPublishStep[1].includes('raw.githubusercontent.com/${{ github.repository }}/${branch}/appcast-')) {
	errors.push('publication verification must read the same raw branch URL stamped into SUFeedURL');
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
