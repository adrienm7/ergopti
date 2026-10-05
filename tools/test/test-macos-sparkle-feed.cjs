// tools/test/test-macos-sparkle-feed.cjs

/**
 * Regression guard for the channel-specific Sparkle release contract. The
 * update channel is resolved through the shared registry once, in ci.yml's plan
 * job; the macOS box stamps it into the bundle and the appcast, and the
 * release job publishes the feed of that same channel.
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');
const { bashExecutable } = require('../lib/git-bash.cjs');

const root = path.resolve(__dirname, '..', '..');
const workflow = pipeline.text();
const buildScript = fs.readFileSync(
	path.join(root, 'tools', 'build', 'build_macos_app.sh'),
	'utf8'
);
const launcherSource = fs.readFileSync(
	path.join(
		root,
		'static',
		'ergopti_plus',
		'macos',
		'launcher',
		'Sources',
		'ErgoptiPlus',
		'main.swift'
	),
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
const menuManifest = JSON.parse(
	fs.readFileSync(
		path.join(root, 'static/ergopti_plus/_shared/modules/menu/menu_manifest.json'),
		'utf8'
	)
);
const frequencyDeclaration = menuManifest.about_update_frequency_menu?.find(
	(row) => row.id === 'update_check_interval'
);
const autoCheckSource = fs.readFileSync(
	path.join(root, 'static', 'ergopti_plus', 'macos', 'modules', 'updater', 'auto_check.lua'),
	'utf8'
);
const errors = [];

// job() throws when package-macos is missing, so no check below can pass
// against an empty slice.
const macosJob = pipeline.job('package-macos');
const channelExpression = '${{ inputs.channel }}';
const channelAssignments = [...macosJob.matchAll(/ERGOPTI_CHANNEL:\s*(.+)/g)].map((match) =>
	match[1].trim()
);

if (channelAssignments.length !== 2) {
	errors.push(
		`the macOS package job must stamp exactly two channel consumers, found ${channelAssignments.length}`
	);
}
if (channelAssignments.some((value) => value !== channelExpression)) {
	errors.push(
		'both the macOS bundle and appcast must stamp the channel the lane receives from the plan'
	);
}

// One channel rule, in validate's plan. Every other consumer receives its
// result, so the bundle, the appcast, the Windows stamp and the published feed
// cannot disagree.
const planMeta = pipeline.step(pipeline.job('validate'), 'Compute tag and version');
const channelRule = 'channel="$(node tools/build/release-channel.cjs "$tag")"';
if (!planMeta.includes(channelRule) || !planMeta.includes('emit channel "$channel"')) {
	errors.push('plan must resolve the update channel through the registry and emit it');
}
if (workflow.split('node tools/build/release-channel.cjs "$tag"').length !== 2) {
	errors.push('the registry channel resolution must exist once in the pipeline, in plan');
}

if (
	workflow.includes("prerelease == 'true' && 'dev' || 'main'") ||
	/\$channel\s*=\s*if\s*\(\s*\$prerelease/.test(workflow)
) {
	errors.push(
		"a job re-derives the channel from prerelease instead of reading plan's channel output"
	);
}
for (const caller of ['macos', 'windows']) {
	if (
		!/^\s+channel:\s*\$\{\{\s*needs\.validate\.outputs\.channel\s*\}\}\s*$/m.test(
			pipeline.job(caller)
		)
	) {
		errors.push(
			`ci.yml's ${caller} caller must pass channel: \${{ needs.validate.outputs.channel }}`
		);
	}
}
for (const [label, value] of [
	...[...workflow.matchAll(/ERGOPTI_CHANNEL:\s*(.+)/g)].map((match) => [
		'ERGOPTI_CHANNEL',
		match[1].trim()
	]),
	...[...workflow.matchAll(/\$channel\s*=\s*(.+)/g)].map((match) => ['$channel', match[1].trim()])
]) {
	if (!/^"?\$\{\{\s*(?:inputs\.channel|needs\.validate\.outputs\.channel)\s*\}\}"?$/.test(value)) {
		errors.push(
			`${label} must read inputs.channel or needs.validate.outputs.channel, got ${value}`
		);
	}
}

// A release must fail rather than skip its signature: a skipped signature
// writes no appcast, and the tag and the immutable release used to be created
// before the feed step noticed.
for (const name of ['Sign declared archives with Sparkle EdDSA key', 'Generate Sparkle appcast']) {
	if (!/^\s+if:\s*inputs\.release\s*$/m.test(pipeline.step(macosJob, name))) {
		errors.push(
			`"${name}" must run on every release (if: inputs.release), never on the key's presence`
		);
	}
}
if (/SPARKLE_ED_PRIVATE_KEY\s*!=\s*''/.test(workflow)) {
	errors.push('no macOS release step may be skipped because SPARKLE_ED_PRIVATE_KEY is empty');
}
if (
	!/if \[ -z "\$SPARKLE_ED_PRIVATE_KEY" \]; then\s*echo "::error::[^\n]*\n\s*exit 1/.test(
		pipeline.step(macosJob, 'Sign declared archives with Sparkle EdDSA key')
	)
) {
	errors.push('a release without SPARKLE_ED_PRIVATE_KEY must fail the signing step');
}

if (!buildScript.includes('/sparkle-appcasts/appcast-$ERGOPTI_CHANNEL.xml')) {
	errors.push('SUFeedURL must target the mutable channel-specific Sparkle feed branch');
}
if (
	!buildScript.includes('<key>CFBundleURLTypes</key>') ||
	!buildScript.includes('<string>ergoptiplus</string>')
) {
	errors.push('the outer bundle must register the private updater command URL scheme');
}
// A scheduled check may only fetch the appcast. With SUAllowsAutomaticUpdates
// true, one tick of Sparkle's "Automatically download and install" checkbox
// made every later check download silently and install on quit
// (updater-consent-2026-09-25).
if (
	!/<key>SUAllowsAutomaticUpdates<\/key>\s*<false\/>/.test(buildScript) ||
	/<key>SUAllowsAutomaticUpdates<\/key>\s*<true\/>/.test(buildScript) ||
	/<key>SUAutomaticallyUpdate<\/key>\s*<true\/>/.test(buildScript)
) {
	errors.push(
		'the launcher bundle must declare SUAllowsAutomaticUpdates false: Sparkle must never download before consent'
	);
}
// Sparkle's standard interface ships English windows that cannot follow the
// driver's language (and modal alerts that stall the launcher's main queue):
// the launcher must present every update window through its catalog driver.
const launcherSourcesDir = path.join(
	root,
	'static',
	'ergopti_plus',
	'macos',
	'launcher',
	'Sources',
	'ErgoptiPlus'
);
const launcherSwift = fs
	.readdirSync(launcherSourcesDir)
	.filter((name) => name.endsWith('.swift'))
	.map((name) => fs.readFileSync(path.join(launcherSourcesDir, name), 'utf8'))
	.join('\n');
if (/SPUStandardUpdaterController|SPUStandardUserDriver/.test(launcherSwift)) {
	errors.push('the launcher must not use the standard Sparkle interface, which is English-only');
}
if (
	!launcherSource.includes('userDriver: userDriver') ||
	!launcherSwift.includes('final class CatalogUpdateUserDriver')
) {
	errors.push('the launcher must drive Sparkle through the catalog-localized user driver');
}
const policyAt = launcherSource.indexOf('UpdateConsentPolicy.refusal(');
const startAt = launcherSource.search(/\.(?:startUpdater|start)\(\)/);
const schedulerOffAt = launcherSource.indexOf('sparkle.automaticallyChecksForUpdates = false');
if (schedulerOffAt < 0 || schedulerOffAt > policyAt || schedulerOffAt > startAt) {
	errors.push(
		'the live Sparkle scheduler must be disabled before policy validation and start, including stored user defaults'
	);
}
if (policyAt < 0 || startAt < 0 || policyAt > startAt) {
	errors.push(
		'the launcher must prove the consent-only policy on the live updater before starting it'
	);
}
// The Lua driver owns the automatic-check cadence, as on Windows and Linux:
// Sparkle's scheduler ran once a day whatever the menu said, refused intervals
// under an hour and ignored the pause. Sparkle keeps only the authenticated
// check, download and install, started by the menu, and never installs
// silently. Its updater still starts, or those requests would find no owner.
if (
	!buildScript.includes('<key>SUEnableAutomaticChecks</key>        <false/>') ||
	!buildScript.includes('<key>SUAllowsAutomaticUpdates</key>       <false/>') ||
	buildScript.includes('<key>SUScheduledCheckInterval</key>') ||
	!launcherSource.includes('try sparkle.start()')
) {
	errors.push(
		'Sparkle must schedule no check and install nothing silently; the Lua driver owns the cadence'
	);
}
if (
	!menuSource.includes('require("modules.updater.auto_check")') ||
	!menuSource.includes('AutoCheck.start_session') ||
	!aboutSource.includes(
		'ManifestMenu.choice_row("about_update_frequency_menu", "update_check_interval"'
	) ||
	frequencyDeclaration?.type !== 'choice' ||
	frequencyDeclaration?.path !== 'updater.check_interval_seconds' ||
	frequencyDeclaration?.i18n !== 'menu.about.frequency_menu' ||
	!aboutSource.includes('checks.set_interval(seconds) == true') ||
	!aboutSource.includes('return checks.interval()') ||
	!autoCheckSource.includes('Schedule.next_due') ||
	!autoCheckSource.includes('If-None-Match')
) {
	errors.push(
		'the menu session must start the Lua automatic checks, conditional on an ETag, and About must offer their frequency'
	);
}
if (/Rename appcast|_appcast-(?:main|dev)|build\/macos\/_appcast/.test(workflow)) {
	errors.push('the published appcast basename must not be renamed behind SUFeedURL');
}
if (!macosJob.includes('OUTPUT_PATH: build/macos/appcast-${{ inputs.channel }}.xml')) {
	errors.push('appcast output must use the same resolved channel as the bundle');
}
if (!pipeline.step(macosJob, 'Upload the package').includes('build/macos/appcast-*.xml')) {
	errors.push('the macOS artifact must preserve the exact appcast-{channel}.xml basename');
}
const feedPublishStep = pipeline.step(pipeline.job('release'), 'Publish channel feed for Sparkle');
if (
	!/^\s+ERGOPTI_CHANNEL:\s*\$\{\{\s*needs\.validate\.outputs\.channel\s*\}\}\s*$/m.test(
		feedPublishStep
	)
) {
	errors.push('the published feed must be the channel the plan resolved');
}
if (!/git -C "\$worktree" push origin "HEAD:refs\/heads\/\$\{branch\}"/.test(feedPublishStep)) {
	errors.push('finalization must commit and push the channel feed to its dedicated mutable branch');
} else if (/gh release (?:create|upload) sparkle-feed/.test(feedPublishStep)) {
	errors.push('an immutable GitHub release cannot own a channel feed that changes every release');
} else if (
	!feedPublishStep.includes('raw.githubusercontent.com/${GITHUB_REPOSITORY}/${branch}/appcast-')
) {
	errors.push('publication verification must read the same raw branch URL stamped into SUFeedURL');
} else if (
	!feedPublishStep.includes('--retry-all-errors') ||
	!feedPublishStep.includes('--retry-max-time 90') ||
	!feedPublishStep.includes('--retry 12')
) {
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
	const generated = spawnSync(
		bashExecutable(),
		[toPosix(path.join(root, 'tools', 'build', 'generate_appcast.sh'))],
		{
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
				OUTPUT_PATH: toPosix(outputPath)
			}
		}
	);
	if (generated.status !== 0) {
		errors.push(
			`the appcast generator rejected a faithful sign_update fragment: ${generated.stderr.trim()}`
		);
	} else {
		const xml = fs.readFileSync(outputPath, 'utf8');
		const xmlCheck = spawnSync('xmllint', ['--noout', outputPath], { encoding: 'utf8' });
		if (xmlCheck.error) {
			errors.push(
				`xmllint is required to validate the generated appcast: ${xmlCheck.error.message}`
			);
		} else if (xmlCheck.status !== 0) {
			errors.push(`the generated appcast is not parseable XML: ${(xmlCheck.stderr ?? '').trim()}`);
		}
		if ((xml.match(/sparkle:edSignature=/g) ?? []).length !== 1) {
			errors.push('the generated enclosure must contain exactly one Sparkle signature');
		}
		if (!xml.includes(`sparkle:edSignature="${signature}" length="${archive.length}"`)) {
			errors.push(
				'the generated enclosure must preserve the validated signature and archive length'
			);
		}
	}
} finally {
	fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

// PUBLICATION_CONSUMER_TESTS_BEGIN
// Private byte/signing ports qualify coupling, not native Sparkle cryptography.
{
	const assert = require('node:assert/strict');
	const crypto = require('node:crypto');
	const Publication = require('../build/macos-release-publication.cjs');
	const policy = Publication.bindings();
	const archiveRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-publication-'));
	let cases = 0;
	function check(name, callback) {
		const directory = fs.mkdtempSync(path.join(archiveRoot, 'case-'));
		const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
		const observations = [];
		for (const [index, archive] of policy.entries())
			fs.writeFileSync(path.join(directory, archive.name), Buffer.alloc(32, index + 1));
		function execute(tool, args) {
			const target = args.includes('--verify') ? args[3] : args[2];
			const payload = fs.readFileSync(target);
			observations.push({
				tool,
				args: [...args],
				digest: crypto.createHash('sha256').update(payload).digest('hex')
			});
			if (args.includes('--verify')) {
				const accepted = crypto.verify(null, payload, publicKey, Buffer.from(args[4], 'base64'));
				return { status: accepted ? 0 : 1, stdout: '', stderr: '' };
			}
			return {
				status: 0,
				stdout: `sparkle:edSignature="${crypto.sign(null, payload, privateKey).toString('base64')}" length="${payload.length}"\n`,
				stderr: ''
			};
		}
		try {
			callback({ directory, observations, execute });
			cases++;
		} catch (error) {
			errors.push(`public archive ${name}: ${error.message}`);
		} finally {
			fs.rmSync(directory, { recursive: true });
		}
	}
	const env = (directory) => ({
		ARCHIVE_DIR: directory,
		ERGOPTI_VERSION: '0.0.0-dev.117',
		ERGOPTI_BUILD: '117',
		ERGOPTI_CHANNEL: 'dev',
		GH_OWNER: 'adrienm7',
		GH_REPO: 'ergopti',
		OUTPUT_PATH: path.join(directory, 'appcast-dev.xml')
	});
	check('actual ordered signing and feed bytes', ({ directory, observations, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		const checked = Publication.validatePublication(directory);
		assert.equal(checked[0].name, 'ErgoptiPlus.app.tar.xz');
		assert.equal(observations.length, policy.length * 2);
		for (const [index, archive] of policy.entries()) {
			assert.equal(path.basename(observations[index * 2].args[2]), archive.name);
			assert.equal(path.basename(observations[index * 2 + 1].args[3]), archive.name);
			assert.equal(observations[index * 2].digest, checked[index].sha256);
			assert.equal(observations[index * 2 + 1].digest, checked[index].sha256);
		}
		Publication.generateAppcast(env(directory));
		const xml = fs.readFileSync(env(directory).OUTPUT_PATH, 'utf8');
		assert.ok(xml.includes('/ErgoptiPlus.app.tar.xz"'));
		assert.ok(xml.includes(checked[0].fragment));
		assert.equal((xml.match(/sparkle:edSignature=/g) ?? []).length, 1);
	});
	check('appcast publication date binds the exact source revision', ({ directory, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		const revision = 'a'.repeat(40);
		const published = 'Fri, 3 Oct 2025 12:34:56 +0000';
		const requests = [];
		const inputs = { ...env(directory), GITHUB_SHA: revision };
		const dateCommand = (tool, args) => {
			requests.push({ tool, args: [...args] });
			return { status: 0, signal: null, stdout: published + '\n' };
		};
		Publication.generateAppcast(inputs, { execute: dateCommand });
		const first = fs.readFileSync(inputs.OUTPUT_PATH, 'utf8');
		Publication.generateAppcast(inputs, { execute: dateCommand });
		assert.equal(fs.readFileSync(inputs.OUTPUT_PATH, 'utf8'), first);
		assert.ok(first.includes(`<pubDate>${published}</pubDate>`));
		assert.deepEqual(
			requests,
			Array.from({ length: 2 }, () => ({
				tool: 'git',
				args: ['-C', root, 'show', '-s', '--format=%cD', revision]
			}))
		);
	});
	check(
		'appcast refuses failed or absent source-date acknowledgements',
		({ directory, execute }) => {
			Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
			const inputs = { ...env(directory), GITHUB_SHA: 'b'.repeat(40) };
			fs.writeFileSync(inputs.OUTPUT_PATH, 'previous feed');
			for (const result of [
				undefined,
				{ status: 1, stdout: 'Fri, 3 Oct 2025 12:34:56 +0000' },
				{ status: 0, signal: 'SIGTERM', stdout: 'Fri, 3 Oct 2025 12:34:56 +0000' },
				{ status: 0, error: new Error('private native failure'), stdout: '' },
				{ status: 0 },
				{ status: false, stdout: '' },
				{ status: 0, stdout: '' },
				{ status: 0, stdout: 'not a publication date' },
				{ status: 0, stdout: 'Fri, 3 Oct 2025 12:34:56 +0000\nSat, 4 Oct 2025 12:34:56 +0000' }
			]) {
				assert.throws(() => Publication.generateAppcast(inputs, { execute: () => result }));
				assert.equal(fs.readFileSync(inputs.OUTPUT_PATH, 'utf8'), 'previous feed');
			}
		}
	);
	check('appcast refuses malformed explicit source revisions', ({ directory, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		for (const revision of [
			'',
			'HEAD',
			'a'.repeat(39),
			'A'.repeat(40),
			'a'.repeat(40) + '\n',
			null,
			12
		]) {
			let commands = 0;
			assert.throws(() =>
				Publication.generateAppcast(
					{ ...env(directory), GITHUB_SHA: revision },
					{
						pubDate: 'Fri, 3 Oct 2025 12:34:56 +0000',
						execute: () => {
							commands++;
							return { status: 0, stdout: '' };
						}
					}
				)
			);
			assert.equal(commands, 0);
			assert.equal(fs.existsSync(env(directory).OUTPUT_PATH), false);
		}
	});
	check('appcast validates explicit publication dates before writing', ({ directory, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		const inputs = { ...env(directory), GITHUB_SHA: 'c'.repeat(40) };
		for (const pubDate of [
			'',
			false,
			12,
			'invalid date',
			'Fri, 3 Oct 2025 12:34:56 +0000\n',
			'Fri, 3 Oct 2025 12:34:56 +0000\r'
		]) {
			assert.throws(() => Publication.generateAppcast(inputs, { pubDate }));
			assert.equal(fs.existsSync(inputs.OUTPUT_PATH), false);
		}
		const published = 'Fri, 3 Oct 2025 12:34:56 +0000';
		Publication.generateAppcast(inputs, {
			pubDate: published,
			execute: () => assert.fail('explicit date must not execute git')
		});
		assert.ok(
			fs.readFileSync(inputs.OUTPUT_PATH, 'utf8').includes(`<pubDate>${published}</pubDate>`)
		);
	});
	check('local appcast date acknowledges current checkout source', ({ directory, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		const expected = spawnSync('git', ['-C', root, 'show', '-s', '--format=%cD', 'HEAD'], {
			encoding: 'utf8'
		});
		assert.equal(expected.status, 0, expected.stderr);
		assert.equal(expected.signal, null);
		assert.ok(expected.stdout.trim());
		Publication.generateAppcast(env(directory));
		assert.ok(
			fs
				.readFileSync(env(directory).OUTPUT_PATH, 'utf8')
				.includes(`<pubDate>${expected.stdout.trim()}</pubDate>`)
		);
	});
	check('missing fresh preferred output refuses', ({ directory, observations, execute }) => {
		fs.unlinkSync(path.join(directory, policy[0].name));
		assert.throws(() =>
			Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute })
		);
		assert.equal(observations.length, 0);
		assert.equal(fs.existsSync(path.join(directory, Publication.RECEIPT)), false);
	});
	check('native sign ACK shape', ({ directory }) => {
		let entered = 0;
		assert.throws(() =>
			Publication.signArchives(directory, 'owned-signer', 'owned-key', {
				execute: () => {
					entered++;
					return {
						status: false,
						stdout: `sparkle:edSignature="${'A'.repeat(86)}==" length="32"\n`
					};
				}
			})
		);
		assert.equal(entered, 1);
		assert.equal(fs.existsSync(path.join(directory, Publication.RECEIPT)), false);
	});
	check('native verify refusal', ({ directory, execute }) => {
		let verifies = 0;
		assert.throws(() =>
			Publication.signArchives(directory, 'owned-signer', 'owned-key', {
				execute: (tool, args) => {
					if (args.includes('--verify')) {
						verifies++;
						return { status: 1, stdout: '' };
					}
					return execute(tool, args);
				}
			})
		);
		assert.equal(verifies, 1);
		assert.equal(fs.existsSync(path.join(directory, Publication.RECEIPT)), false);
	});
	check('native signer archive race', ({ directory, execute }) => {
		let changed = 0;
		assert.throws(() =>
			Publication.signArchives(directory, 'owned-signer', 'owned-key', {
				execute: (tool, args) => {
					const result = execute(tool, args);
					if (args.includes('--verify')) {
						changed++;
						fs.writeFileSync(args[3], Buffer.alloc(32, 9));
					}
					return result;
				}
			})
		);
		assert.equal(changed, 1);
		assert.deepEqual(fs.readFileSync(path.join(directory, policy[0].name)), Buffer.alloc(32, 9));
		assert.equal(fs.existsSync(path.join(directory, Publication.RECEIPT)), false);
	});
	check('ambiguous signing receipt encoding refuses', ({ directory, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		const target = path.join(directory, Publication.RECEIPT);
		fs.writeFileSync(
			target,
			fs
				.readFileSync(target, 'utf8')
				.replace('"schema_version":1', '"schema_version":1,"schema_version":1')
		);
		assert.throws(() => Publication.validatePublication(directory));
	});
	check('same-length crossed fragment refuses before feed', ({ directory, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		const receipt = Publication.validatePublication(directory);
		fs.copyFileSync(
			path.join(directory, receipt[1].signature_name),
			path.join(directory, receipt[0].signature_name)
		);
		assert.throws(() => Publication.generateAppcast(env(directory)));
		assert.equal(fs.existsSync(env(directory).OUTPUT_PATH), false);
	});
	check('same-length substituted archive refuses', ({ directory, execute }) => {
		Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute });
		fs.writeFileSync(path.join(directory, policy[0].name), Buffer.alloc(32, 7));
		assert.throws(() => Publication.validatePublication(directory));
	});
	check('preferred symlink refuses', ({ directory, observations, execute }) => {
		fs.unlinkSync(path.join(directory, policy[0].name));
		fs.symlinkSync(policy[1].name, path.join(directory, policy[0].name));
		assert.throws(() =>
			Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute })
		);
		assert.equal(observations.length, 0);
	});
	function asset(archive, payload = Buffer.alloc(32, 1)) {
		return {
			name: archive.name,
			size: payload.length,
			digest: 'sha256:' + crypto.createHash('sha256').update(payload).digest('hex')
		};
	}
	check('unknown or draft publication state refuses', () => {
		for (const isDraft of [true, null, undefined, 0, 'false'])
			assert.throws(() =>
				Publication.selectPublished(
					{ isDraft, tagName: 'v1.2.3', assets: policy.map((a) => asset(a)) },
					'v1.2.3'
				)
			);
	});
	check('published both chooses preferred', () => {
		assert.equal(
			Publication.selectPublished(
				{ isDraft: false, tagName: 'v1.2.3', assets: policy.map((a) => asset(a)) },
				'v1.2.3'
			).name,
			'ErgoptiPlus.app.tar.xz'
		);
	});
	check('historical actual absence chooses ZIP', () => {
		assert.equal(
			Publication.selectPublished(
				{ isDraft: false, tagName: 'v1.2.3', assets: [asset(policy[1])] },
				'v1.2.3'
			).name,
			'ErgoptiPlus.app.zip'
		);
	});
	check('present malformed preferred never fallback', () => {
		const preferred = asset(policy[0]);
		delete preferred.digest;
		assert.throws(() =>
			Publication.selectPublished(
				{ isDraft: false, tagName: 'v1.2.3', assets: [preferred, asset(policy[1])] },
				'v1.2.3'
			)
		);
	});
	check('duplicate preferred never fallback', () => {
		const preferred = asset(policy[0]);
		assert.throws(() =>
			Publication.selectPublished(
				{ isDraft: false, tagName: 'v1.2.3', assets: [preferred, preferred, asset(policy[1])] },
				'v1.2.3'
			)
		);
	});
	check('actual published download binds selected bytes', ({ directory }) => {
		const downloaded = path.join(directory, 'download');
		const calls = [],
			payload = Buffer.alloc(32, 1);
		const result = Publication.downloadPublished('adrienm7/ergopti', 'v1.2.3', downloaded, {
			execute: (tool, args) => {
				calls.push([...args]);
				if (args[0] === 'api')
					return {
						status: 0,
						stdout: JSON.stringify({
							draft: false,
							tag_name: 'v1.2.3',
							assets: [asset(policy[0], payload), asset(policy[1])]
						})
					};
				fs.writeFileSync(path.join(downloaded, policy[0].name), payload);
				return { status: 0, stdout: '' };
			}
		});
		assert.equal(result.name, 'ErgoptiPlus.app.tar.xz');
		assert.equal(calls.length, 2);
		assert.equal(calls[1][calls[1].indexOf('--pattern') + 1], result.name);
		assert.equal(
			result.sha256,
			crypto
				.createHash('sha256')
				.update(fs.readFileSync(path.join(downloaded, result.name)))
				.digest('hex')
		);
	});
	check('download false receipt refuses', ({ directory }) => {
		const calls = [];
		assert.throws(() =>
			Publication.downloadPublished(
				'adrienm7/ergopti',
				'v1.2.3',
				path.join(directory, 'download'),
				{
					execute: (tool, args) => {
						calls.push([...args]);
						if (args[0] === 'api')
							return {
								status: 0,
								stdout: JSON.stringify({
									draft: false,
									tag_name: 'v1.2.3',
									assets: policy.map((a) => asset(a))
								})
							};
						return { status: false, stdout: '' };
					}
				}
			)
		);
		assert.equal(calls.length, 2);
	});
	check('download wrong bytes refuses', ({ directory }) => {
		let downloads = 0;
		assert.throws(() =>
			Publication.downloadPublished(
				'adrienm7/ergopti',
				'v1.2.3',
				path.join(directory, 'download'),
				{
					execute: (tool, args) => {
						if (args[0] === 'api')
							return {
								status: 0,
								stdout: JSON.stringify({
									draft: false,
									tag_name: 'v1.2.3',
									assets: policy.map((a) => asset(a))
								})
							};
						downloads++;
						fs.writeFileSync(path.join(directory, 'download', policy[0].name), Buffer.alloc(32, 9));
						return { status: 0, stdout: '' };
					}
				}
			)
		);
		assert.equal(downloads, 1);
	});
	// REST_GH_DIGEST_TESTS_BEGIN
	check('raw REST retains fields dropped by the actual old CLI export', ({ directory }) => {
		const raw = { draft: false, tag_name: 'v1.2.3', assets: [asset(policy[0])] };
		// GH v2.46 ReleaseAsset/ExportData lacks Digest despite a REST receipt.
		const projected = {
			isDraft: raw.draft,
			tagName: raw.tag_name,
			assets: raw.assets.map(({ name, size }) => ({ name, size }))
		};
		assert.equal(projected.assets[0].digest, undefined);
		assert.throws(() => Publication.selectPublished(projected, 'v1.2.3'));
		const calls = [];
		const selected = Publication.downloadPublished(
			'adrienm7/ergopti',
			'v1.2.3',
			path.join(directory, 'raw-download'),
			{
				execute: (tool, args) => {
					calls.push([...args]);
					if (args[0] === 'api') return { status: 0, stdout: JSON.stringify(raw) };
					if (args[0] === 'release' && args[1] === 'view')
						return { status: 0, stdout: JSON.stringify(projected) };
					fs.writeFileSync(
						path.join(directory, 'raw-download', policy[0].name),
						Buffer.alloc(32, 1)
					);
					return { status: 0, stdout: '' };
				}
			}
		);
		assert.equal(selected.name, policy[0].name);
		assert.deepEqual(calls[0], ['api', 'repos/adrienm7/ergopti/releases/tags/v1.2.3']);
		assert.equal(calls.length, 2);
	});
	check('raw REST identity and asset refusals precede download', ({ directory }) => {
		const malformedPreferred = asset(policy[0]);
		delete malformedPreferred.digest;
		const bodies = [
			{ tag_name: 'v1.2.3', assets: [asset(policy[0])] },
			{ draft: 'false', tag_name: 'v1.2.3', assets: [asset(policy[0])] },
			{ draft: false, tag_name: 'other', assets: [asset(policy[0])] },
			{ draft: false, tag_name: 'v1.2.3', assets: null },
			{ draft: false, tag_name: 'v1.2.3', assets: [malformedPreferred, asset(policy[1])] },
			{
				draft: false,
				tag_name: 'v1.2.3',
				assets: [asset(policy[0]), asset(policy[0]), asset(policy[1])]
			},
			null,
			[]
		];
		for (const [index, body] of bodies.entries()) {
			const calls = [];
			const target = path.join(directory, 'refused-' + index);
			assert.throws(() =>
				Publication.downloadPublished('adrienm7/ergopti', 'v1.2.3', target, {
					execute: (tool, args) => {
						calls.push([...args]);
						return { status: 0, stdout: JSON.stringify(body) };
					}
				})
			);
			assert.equal(calls.length, 1);
			assert.equal(calls[0][0], 'api');
			assert.equal(fs.existsSync(target), false);
		}
	});
	check('API failed HTTP and malformed process receipts refuse', ({ directory }) => {
		const body = JSON.stringify({ draft: false, tag_name: 'v1.2.3', assets: [asset(policy[0])] });
		for (const [index, receipt] of [
			{ status: 1, stdout: body }, // gh api returns nonzero for non2xx.
			{ status: false, stdout: body },
			{ status: 0, signal: 'SIGTERM', stdout: body },
			{ status: 0, stdout: '{' }
		].entries()) {
			let entered = 0;
			const target = path.join(directory, 'bad-status-' + index);
			assert.throws(() =>
				Publication.downloadPublished('adrienm7/ergopti', 'v1.2.3', target, {
					execute: () => {
						entered++;
						return receipt;
					}
				})
			);
			assert.equal(entered, 1);
			assert.equal(fs.existsSync(target), false);
		}
	});
	check('actual download CLI uses encoded REST tag and closed HTTP failure', ({ directory }) => {
		const tag = 'v1.2.3/owned-tag';
		const bin = path.join(directory, 'bin');
		fs.mkdirSync(bin);
		const rawPath = path.join(directory, 'release.json');
		const callPath = path.join(directory, 'calls.jsonl');
		const payloadPath = path.join(directory, policy[0].name);
		fs.writeFileSync(
			rawPath,
			JSON.stringify({ draft: false, tag_name: tag, assets: [asset(policy[0])] })
		);
		const shim = path.join(bin, 'gh');
		fs.writeFileSync(
			shim,
			`#!${process.execPath}\n` +
				`
'use strict';
const fs = require('node:fs'), path = require('node:path');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.OWNED_GH_CALLS, JSON.stringify(args) + '\\n');
if (args[0] === 'api') {
 if (process.env.OWNED_GH_HTTP_REFUSAL === '1') { process.stderr.write('INERT_PRIVATE_GH_FAILURE'); process.exit(1); }
 process.stdout.write(fs.readFileSync(process.env.OWNED_GH_RELEASE));
} else if (args[0] === 'release' && args[1] === 'download') {
 fs.copyFileSync(process.env.OWNED_GH_PAYLOAD, path.join(args[args.indexOf('--dir') + 1], args[args.indexOf('--pattern') + 1]));
} else if (args[0] === 'release' && args[1] === 'view') {
 const raw = JSON.parse(fs.readFileSync(process.env.OWNED_GH_RELEASE));
 process.stdout.write(JSON.stringify({isDraft: raw.draft, tagName: raw.tag_name, assets: raw.assets.map(({name,size}) => ({name,size}))}));
} else process.exit(2);
`,
			{ mode: 0o700 }
		);
		const environment = {
			...process.env,
			PATH: bin + path.delimiter + process.env.PATH,
			OWNED_GH_CALLS: callPath,
			OWNED_GH_RELEASE: rawPath,
			OWNED_GH_PAYLOAD: payloadPath
		};
		const owner = require.resolve('../build/macos-release-publication.cjs');
		const target = path.join(directory, 'cli-download');
		const success = spawnSync(
			process.execPath,
			[owner, 'download', 'adrienm7/ergopti', tag, target],
			{ encoding: 'utf8', env: environment }
		);
		assert.equal(success.status, 0, 'the actual CLI admits a source-retained REST checksum');
		assert.equal(success.stderr, '');
		const selected = JSON.parse(success.stdout);
		assert.equal(selected.name, policy[0].name);
		assert.deepEqual(
			fs.readFileSync(path.join(target, selected.name)),
			fs.readFileSync(payloadPath)
		);
		const calls = fs
			.readFileSync(callPath, 'utf8')
			.trim()
			.split('\n')
			.map((s) => JSON.parse(s));
		assert.deepEqual(calls[0], ['api', 'repos/adrienm7/ergopti/releases/tags/v1.2.3%2Fowned-tag']);
		assert.equal(calls.length, 2);
		fs.writeFileSync(callPath, '');
		const refusedTarget = path.join(directory, 'cli-refused');
		const refused = spawnSync(
			process.execPath,
			[owner, 'download', 'adrienm7/ergopti', tag, refusedTarget],
			{
				encoding: 'utf8',
				env: { ...environment, OWNED_GH_HTTP_REFUSAL: '1' }
			}
		);
		assert.equal(refused.status, 1);
		assert.equal(refused.stdout, '');
		assert.equal(refused.stderr, 'Public macOS archive operation refused.\n');
		assert.equal(refused.stderr.includes('INERT_PRIVATE_GH_FAILURE'), false);
		assert.equal(fs.existsSync(refusedTarget), false);
		assert.equal(fs.readFileSync(callPath, 'utf8').trim().split('\n').length, 1);
	});
	// REST_GH_DIGEST_TESTS_END

	fs.rmSync(archiveRoot, { recursive: true });
	if (cases !== 26) errors.push(`Only ${cases}/26 public archive callable cases succeeded.`);
	console.log(`Public archive callable cases: ${cases}/26`);
}
// PUBLICATION_CONSUMER_TESTS_END

try {
	const assert = require('node:assert/strict');
	const result = spawnSync(
		process.platform === 'win32' ? 'python' : 'python3',
		[path.join(root, 'tools/diagnostics/macos_sparkle_archive_fixture_test.py')],
		{
			cwd: root,
			encoding: 'utf8',
			timeout: 30000,
			env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
		}
	);
	assert.ifError(result.error);
	assert.equal(result.signal, null, result.stderr);
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stderr, /Ran 23 tests in /);
	const skipped = process.platform === 'win32' ? 5 : process.platform === 'darwin' ? 1 : 0;
	assert.match(
		result.stderr,
		skipped ? new RegExp(`\\nOK \\(skipped=${skipped}\\)\\s*$`) : /\nOK\s*$/
	);
	console.log(
		`Sparkle transport controls: ${20 - skipped} passed, ${skipped} platform cases skipped.`
	);
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	for (const method of [
		'testDirectNativeChildExitACKAndCaptureRetirementAreIdempotent',
		'testActualSparkleTarXZUpdateRefusesWrongKeyPreservesOldAppAndRetriesThroughRelaunch'
	]) {
		assert.ok(
			fixture.includes(`func ${method}() throws`),
			`Mandatory native XCTest ${method} is absent.`
		);
	}
	// Fixed command diagnostics cannot project private command arguments or streams.
	for (const phase of [
		'archiveBuild',
		'archiveSign',
		'archiveSignForeign',
		'generatedAppcast',
		'nativeProcessCensus'
	]) {
		assert.ok(fixture.includes(`phase: .${phase}`));
	}
	assert.match(fixture, /case command\(NativeCommandPhase, Int32\)/);
	assert.match(fixture, /checkpoint\("command\." \+ phase.rawValue \+ "\.begin"\)/);
	assert.match(fixture, /throw Failure\.command\(phase, receipt.status\)/);
	assert.doesNotMatch(fixture, /Failure\.command\(URL/);
	const annotation = fixture.slice(
		fixture.indexOf('private func annotateCensusRefusal'),
		fixture.indexOf('private func privateDirectory')
	);
	assert.match(annotation, /stdout.utf8.count <= 512/);
	assert.match(
		annotation,
		/Set\(packet.keys\) == Set\(\["schema", "code", "helper_pid", "path_errno"\]\)/
	);
	assert.match(annotation, /CFGetTypeID\(value\) != CFBooleanGetTypeID\(\)/);
	assert.match(annotation, /maximum: 4095/);
	assert.match(
		annotation,
		/var summary = "Native Sparkle census refusal: code=path-unavailable helper_pid=/
	);
	assert.match(annotation, /XCTFail\(summary\)/);
	assert.match(
		annotation,
		/if schema == 1 \{\s*guard Set\(packet.keys\) == Set\(\["schema", "code", "helper_pid", "path_errno"\]\)/
	);
	assert.match(
		annotation,
		/Set\(packet.keys\) == Set\(\["schema", "code", "helper_pid", "path_errno",\s*"bsd_bytes", "bsd_errno", "bsd_state"\]\)/
	);
	assert.match(
		annotation,
		/let schema = integer\("schema", maximum: 2\), schema == 1 \|\| schema == 2/
	);
	assert.match(annotation, /guard bytes == 136, nativeErrno == 0/);
	assert.match(
		annotation,
		/Set\(packet.keys\) == Set\(\["schema", "code", "helper_pid", "stage"\]\)/
	);
	assert.match(annotation, /\["private-root", "library", "inventory", "unexpected"\]/);
	assert.match(
		annotation,
		/Set\(packet.keys\) == Set\(\["schema", "code", "helper_pid", "reason"\]\)/
	);
	assert.match(annotation, /integer\("schema", maximum: 4\) == 4/);
	assert.match(
		annotation,
		/\["metadata", "missing", "not-absolute", "not-directory", "mode", "owner", "canonical"\]/
	);
	assert.match(
		annotation,
		/XCTFail\("Native Sparkle census refusal: code=directory-refused helper_pid=/
	);
	assert.match(fixture, /XCTFail\("Native Sparkle census refusal: code=diagnostic-unavailable"\)/);

	assert.doesNotMatch(
		annotation,
		/(?:print|XCTFail)\(stdout|summary \+= stdout|packet\["(?:argv|path|stderr|comm|name)"\]/
	);
	assert.doesNotMatch(annotation, /print\(stdout|stderr|String\(reflecting|ownedPIDs/);
	assert.match(fixture, /macos_owned_process\.py/);
	assert.match(fixture, /packet\["closed"\] as\? Bool == true/);
	assert.match(fixture, /packet\["exit_status"\] as\? NSNumber/);
	assert.match(fixture, /SUSparkleErrorDomain/);
	assert.match(fixture, /snapshot\(installed\), oldSnapshot/);
	assert.match(fixture, /snapshot\(installed\), newSnapshot/);
	assert.match(fixture, /downloaded\.count, 2/);
	assert.doesNotMatch(fixture, /XCTSkip(?:If|Unless)?\(/);
	console.log(
		'Actual Sparkle acceptance XCTest remains registered with strict retirement evidence.'
	);
} catch (error) {
	errors.push(`Native Sparkle acceptance registration failed: ${error.message}`);
}

// Native composition must parse actual publication output before the private transport routes bytes.
try {
	const assert = require('node:assert/strict');
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	const child = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_sparkle_archive_child.swift'),
		'utf8'
	);
	assert.match(fixture, /"OUTPUT_PATH=" \+ generated.path/);
	assert.match(fixture, /static\/ergopti_plus\/_shared\/modules\/updater\/defaults\.json/);
	assert.match(fixture, /let github = defaults\["github"\]/);
	assert.match(fixture, /"GH_OWNER=" \+ identity.owner, "GH_REPO=" \+ identity.name/);
	assert.match(fixture, /"FixtureArchiveOrigin": identity.archiveOrigin/);
	assert.match(fixture, /details\["origin"\] as\? String, identity.archiveOrigin/);
	assert.match(fixture, /"tools\/build\/macos-release-publication\.cjs"\)\.path, "appcast"/);
	assert.match(fixture, /let refusedFeed = try generatedFeed\(foreignArchives/);
	assert.match(fixture, /let acceptedFeed = try generatedFeed\(archives/);
	assert.match(fixture, /"sign", foreignArchives.path, signer, foreignKeyFile.path/);
	assert.match(fixture, /fetchedFeeds\.count, 2/);
	assert.match(fixture, /hash\(refusedFeed\), hash\(acceptedFeed\)/);
	assert.doesNotMatch(fixture, /<rss|private func feed\(/);
	assert.match(
		child,
		/willDownloadUpdate item: SUAppcastItem, withRequest request: NSMutableURLRequest/
	);
	assert.match(child, /item\.fileURL == origin, request\.url == origin/);
	assert.match(child, /transport\.scheme == "http", transport\.host == "localhost"/);
	assert.match(
		child,
		/transport\.user == nil, transport\.password == nil, transport\.query == nil, transport\.fragment == nil/
	);
	assert.match(child, /request\.url = transport/);
	assert.match(child, /request\.httpShouldHandleCookies = false/);
	assert.match(fixture, /"NSAppTransportSecurity": \["NSAllowsLocalNetworking": true\]/);
	assert.doesNotMatch(fixture, /NSAllowsArbitraryLoads|NSExceptionAllowsInsecureHTTPLoads/);
	console.log(
		'Native Sparkle composition consumes unchanged generated feed bytes with exact private routing.'
	);
} catch (error) {
	errors.push(`Native generated appcast composition guard failed: ${error.message}`);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log('[OK] macOS Sparkle release metadata is channel-specific.');
