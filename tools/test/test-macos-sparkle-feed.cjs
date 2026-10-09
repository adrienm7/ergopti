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
		function execute(tool, args, filesystem = fs) {
			const target = args.includes('--verify') ? args[3] : args[2];
			const payload = filesystem.readFileSync(target);
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
		const {
			ArchiveContractFilesystem,
			loadPublicationProducer,
			verifyArchiveFilesystemModel
		} = require('./fixtures/archive-contract-filesystem.cjs');
		const defaults = JSON.parse(
			fs.readFileSync(require('../lib/paths.cjs').shared('modules/updater/defaults.json'), 'utf8')
		);
		verifyArchiveFilesystemModel(os.tmpdir());
		const model = new ArchiveContractFilesystem(os.tmpdir());
		const owner = loadPublicationProducer(
			path.resolve(__dirname, '../build/macos-release-publication.cjs'),
			model
		);
		const owned = model.mkdtempSync(path.join(os.tmpdir(), 'sparkle-link-contract-'));
		const positive = path.join(owned, 'positive');
		const negative = path.join(owned, 'negative');
		model.mkdirSync(positive);
		model.mkdirSync(negative);
		try {
			for (const archive of policy) {
				const bytes = fs.readFileSync(path.join(directory, archive.name));
				model.writeFileSync(path.join(positive, archive.name), bytes);
				model.writeFileSync(path.join(negative, archive.name), bytes);
			}
			const modelExecute = (tool, args) => execute(tool, args, model);
			const signed = owner.signArchives(positive, 'owned-signer', 'owned-key', {
				execute: modelExecute,
				defaults
			});
			assert.deepEqual(
				signed.archives.map((record) => record.name),
				policy.map((archive) => archive.name)
			);
			assert.equal(
				observations.length,
				policy.length * 2,
				'the actual closed owner signs and verifies both real seeded archive bytes'
			);
			observations.length = 0;
			model.unlinkSync(path.join(negative, policy[0].name));
			model.symlinkSync(policy[1].name, path.join(negative, policy[0].name));
			assert.throws(() =>
				owner.signArchives(negative, 'owned-signer', 'owned-key', {
					execute: modelExecute,
					defaults
				})
			);
			assert.equal(
				observations.length,
				0,
				'the actual preferred-link refusal acquires no signer or fallback'
			);
			assert.equal(model.existsSync(path.join(negative, owner.RECEIPT)), false);
			assert.equal(
				model.descriptors.size,
				0,
				'every publication read retires its exact descriptor'
			);
		} finally {
			model.rmSync(owned, { recursive: true });
		}
		assert.deepEqual(model.readdirSync(os.tmpdir()), []);
		if (process.platform !== 'win32') {
			// The original physical POSIX refusal remains the same mandatory contract.
			fs.unlinkSync(path.join(directory, policy[0].name));
			fs.symlinkSync(policy[1].name, path.join(directory, policy[0].name));
			assert.throws(() =>
				Publication.signArchives(directory, 'owned-signer', 'owned-key', { execute })
			);
			assert.equal(observations.length, 0);
		}
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
		const shim = path.join(bin, process.platform === 'win32' ? 'gh-shim.cjs' : 'gh');
		fs.writeFileSync(
			shim,
			`#!${process.execPath}\n` +
				`
'use strict';
const fs = require('node:fs'), path = require('node:path');
if (process.platform !== 'win32' || path.basename(process.execPath).toLowerCase() === 'gh.exe') {
const args = process.platform === 'win32'
 ? [path.basename(process.argv[1]), ...process.argv.slice(2)]
 : process.argv.slice(2);
fs.appendFileSync(process.env.OWNED_GH_CALLS, JSON.stringify(args) + '\\n');
if (args[0] === 'api') {
 if (process.env.OWNED_GH_HTTP_REFUSAL === '1') { process.stderr.write('INERT_PRIVATE_GH_FAILURE'); process.exit(1); }
 fs.writeSync(1, fs.readFileSync(process.env.OWNED_GH_RELEASE));
} else if (args[0] === 'release' && args[1] === 'download') {
 fs.copyFileSync(process.env.OWNED_GH_PAYLOAD, path.join(args[args.indexOf('--dir') + 1], args[args.indexOf('--pattern') + 1]));
} else if (args[0] === 'release' && args[1] === 'view') {
 const raw = JSON.parse(fs.readFileSync(process.env.OWNED_GH_RELEASE));
 fs.writeSync(1, JSON.stringify({isDraft: raw.draft, tagName: raw.tag_name, assets: raw.assets.map(({name,size}) => ({name,size}))}));
} else process.exit(2);
process.exit(0);
}
`,
			{ mode: 0o700 }
		);
		// Windows executes PE binaries rather than a POSIX executable shebang.
		if (process.platform === 'win32') fs.copyFileSync(process.execPath, path.join(bin, 'gh.exe'));
		const environment = {
			...process.env,
			PATH: bin + path.delimiter + process.env.PATH,
			OWNED_GH_CALLS: callPath,
			OWNED_GH_RELEASE: rawPath,
			OWNED_GH_PAYLOAD: payloadPath
		};
		if (process.platform === 'win32')
			environment.NODE_OPTIONS =
				(process.env.NODE_OPTIONS || '') +
				' --require ' +
				JSON.stringify(shim.replaceAll('\\', '/'));
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
	assert.match(result.stderr, /Ran 48 tests in /);
	// The two existing POSIX signal controls also remain excluded on Windows.
	const skipped = process.platform === 'win32' ? 19 : process.platform === 'darwin' ? 1 : 0;
	assert.match(
		result.stderr,
		skipped ? new RegExp(`\\nOK \\(skipped=${skipped}\\)\\s*$`) : /\nOK\s*$/
	);
	console.log(
		`Sparkle transport controls: ${48 - skipped} passed, ${skipped} platform cases skipped.`
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
	assert.match(fixture, /testOwnedCensusPathAdmitsParentAliasWithoutAdoptingDirectoryReplacement/);
	assert.match(fixture, /let paths = try roots\.map \{ try ownedCensusPath\(\$0\) \}/);
	assert.match(fixture, /\["python3", helper\.path, "census"\] \+ paths/);
	assert.match(fixture, /Darwin\.realpath\(spelling, nil\)/);
	assert.match(fixture, /target\.st_dev == original\.st_dev, target\.st_ino == original\.st_ino/);
	assert.match(fixture, /metadata\.st_dev == owned\.device, metadata\.st_ino == owned\.inode/);
	assert.match(fixture, /String\(cString: resolved\) == owned\.physicalSpelling/);
	assert.match(fixture, /return owned\.physicalSpelling/);
	assert.match(fixture, /XCTAssertThrowsError\(try ownedCensusPath\(child\)\)/);
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
	assert.match(child, /willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest/);
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

// Bounded server-exit facts must reuse the existing exit ACK and preserve failure.
try {
	const assert = require('node:assert/strict');
	const { annotation, evaluate } = require('../diagnostics/swift_xctest_evidence.cjs');
	const nativeFile = path.join(
		root,
		'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
	);
	const fixture = fs.readFileSync(nativeFile, 'utf8');
	function assertServerExitDiagnosticSource(source) {
		const factsStart = source.indexOf('func observedTerminationFacts()');
		const facts = source.slice(
			factsStart,
			source.indexOf('/// Repeated observations reuse', factsStart)
		);
		assert.match(
			facts,
			/guard launched, observedExit, !process\.isRunning else \{ return \.unavailable \}/
		);
		assert.match(
			facts,
			/case \.exit where \(0\.\.\.255\)\.contains\(status\): return \.exit\(status\)/
		);
		assert.match(
			facts,
			/case \.uncaughtSignal where \(1\.\.\.64\)\.contains\(status\): return \.signal\(status\)/
		);
		assert.doesNotMatch(
			facts,
			/observeExit\(|\.wait\(|\.terminate\(|kill\(|\.run\(|read|close|stdout|stderr/
		);
		const formatterStart = source.indexOf('private func serverExitRefusalMessage(');
		const formatter = source.slice(
			formatterStart,
			source.indexOf('private struct OwnedCensusDirectory', formatterStart)
		);
		assert.match(formatter, /case Failure\.deadline: code = "deadline"/);
		assert.match(formatter, /case "server-retirement": code = "exit-status"/);
		assert.match(formatter, /case "native-child-signal": code = "native-signal"/);
		assert.match(formatter, /default: code = "unavailable"/);
		assert.match(formatter, /default: reason = "unavailable"; status = "unavailable"/);
		assert.doesNotMatch(
			formatter,
			/localizedDescription|String\(describing:|stdout|stderr|\.path|nonce/
		);
		const cleanupStart = source.indexOf('attempt("server-exit")');
		const cleanup = source.slice(
			cleanupStart,
			source.indexOf('attempt("server-terminal")', cleanupStart)
		);
		assert.match(cleanup, /if server\.process\.isRunning \{ server\.process\.terminate\(\) \}/);
		assert.match(cleanup, /let retired = try server\.finish\(10\)/);
		assert.match(
			cleanup,
			/guard retired.status == 0 else \{ throw Failure\.evidence\("server-retirement"\) \}/
		);
		assert.match(
			cleanup,
			/catch \{\s*XCTFail\(serverExitRefusalMessage\(error, termination: server\.observedTerminationFacts\(\)\)\)\s*throw error/
		);
		assert.match(source, /func testServerExitRefusalMessageProjectsOnlyClosedFacts\(\)/);
	}
	assertServerExitDiagnosticSource(fixture);
	for (const [reason, mutated] of [
		[
			'unobserved child status',
			fixture.replace(
				'guard launched, observedExit, !process.isRunning',
				'guard launched, !process.isRunning'
			)
		],
		[
			'diagnostic acquires another wait',
			fixture.replace(
				'let status = process.terminationStatus',
				'let status = process.terminationStatus; _ = observeExit(0)'
			)
		],
		[
			'raw error export',
			fixture.replace('default: code = "unavailable"', 'default: code = error.localizedDescription')
		],
		[
			'primary failure swallowed',
			fixture.replace(
				'XCTFail(serverExitRefusalMessage(error, termination: server.observedTerminationFacts()))\n\t\t\t\t\t\tthrow error',
				'XCTFail(serverExitRefusalMessage(error, termination: server.observedTerminationFacts()))'
			)
		]
	])
		assert.throws(() => assertServerExitDiagnosticSource(mutated), reason);
	// This independent authentic XCTest fixture exercises the actual annotation owner.
	const fixedFacts =
		'Native Sparkle server retirement refusal: code=deadline native_reason=signal native_status=9';
	const text = [
		"Test Suite 'All tests' started at 2026-10-05 01:00:00.000.",
		"Test Case '-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testArchive]' started.",
		nativeFile + ':777: error: failed - ' + fixedFacts,
		"Test Case '-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testArchive]' failed (0.100 seconds).",
		"Test Suite 'All tests' failed at 2026-10-05 01:00:01.000.",
		'\t Executed 1 test, with 1 failure (0 unexpected) in 0.100 (0.110) seconds'
	].join('\n');
	const verdict = evaluate(text, 1, 0, root);
	const diagnostic = verdict.failures.find((failure) => failure.message.endsWith(fixedFacts));
	assert.notEqual(diagnostic, undefined, 'real XCTest failures expose only closed server facts');
	assert.equal(
		annotation(diagnostic),
		'::error title=Swift XCTest failure,file=static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift,line=777::failed - ' +
			fixedFacts
	);
	assert.equal(verdict.exit_status, 1);
	assert.equal(verdict.complete, false, 'a observed exit signal is not retirement success');
	assert.equal(
		evaluate(fixedFacts, 1, 0, root).failures.some((failure) =>
			failure.message.endsWith(fixedFacts)
		),
		false,
		'a raw print cannot stand in for the native XCTest diagnostic'
	);
	console.log(
		'Sparkle server-exit refusal uses bounded existing native exit facts without changing retirement.'
	);
} catch (error) {
	errors.push(`Native Sparkle server-exit diagnostic guard failed: ${error.message}`);
}

// An admitted Foundation parent alias must cross the helper API physically.
try {
	const assert = require('node:assert/strict');
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	const helper = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_sparkle_archive_fixture.py'),
		'utf8'
	);
	function assertPhysicalHelperInputs(source) {
		assert.match(source, /\["python3", helper\.path, "serve", try ownedCensusPath\(www\), nonce\]/);
		assert.doesNotMatch(source, /"serve", www\.path/);
		assert.match(source, /let paths = try roots\.map \{ try ownedCensusPath\(\$0\) \}/);
		assert.match(source, /\["python3", helper\.path, "census"\] \+ paths/);
		assert.match(source, /helper\.path, physical\], root: root/);
	}
	assertPhysicalHelperInputs(fixture);
	assert.match(helper, /observed\("canonical", lambda: path\.resolve\(\) != path\)/);
	assert.throws(
		() =>
			assertPhysicalHelperInputs(
				fixture.replace('"serve", try ownedCensusPath(www)', '"serve", www.path')
			),
		'original lexical alias handoff fails the exact source composition guard'
	);
	console.log(
		'Sparkle native serve and census use retained physical directory identity; canonical helper admission stays strict.'
	);
} catch (error) {
	errors.push(`Native Sparkle physical helper input guard failed: ${error.message}`);
}

// SPARKLE_STARTUP_DIAGNOSTIC_CONTROLS_BEGIN
// Fixed startup facts never substitute readiness, native exit or retirement.
try {
	const assert = require('node:assert/strict');
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	const helper = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_sparkle_archive_fixture.py'),
		'utf8'
	);
	function assertStartupProjection(source, python) {
		assert.ok(python.indexOf('startup_phase("python-entry")') < python.indexOf('import ctypes'));
		assert.match(python, /os\.environ\.get\("ERGOPTI_SPARKLE_STARTUP_DIAGNOSTICS"\) == "1"/);
		assert.match(python, /len\(sys\.argv\) == 4[\s\S]*sys\.argv\[1\] == "serve"/);
		assert.match(python, /type\(phase\) is not str or phase not in _STARTUP_PHASES/);
		assert.match(python, /os\.write\(1, frame\) != len\(frame\)/);
		assert.match(
			python,
			/except BaseException as failure:\n        [^\n]*\n        primary_failure = failure\n        raise/
		);
		assert.match(python, /finally:\n            server\.server_close\(\)/);
		assert.match(
			python,
			/if primary_failure is None and trace_failure is not None:\n            raise trace_failure/
		);
		assert.match(python, /signal\.signal\(signal\.SIGTERM, server\.request_stop\)/);
		assert.match(source, /workerTimeout: Double = 60, startupDiagnostics: Bool = false/);
		assert.match(
			source,
			/if readable \{ descriptor = open\(url.path, O_RDWR \| O_CREAT \| O_EXCL \| O_NOFOLLOW, 0o600\) \}/
		);
		assert.match(
			source,
			/else \{ descriptor = open\(url.path, O_WRONLY \| O_CREAT \| O_EXCL \| O_NOFOLLOW, 0o600\) \}/
		);
		assert.match(
			source,
			/"serve", try ownedCensusPath\(www\), nonce\], root: root, startupDiagnostics: true/
		);
		const capture = source.slice(
			source.indexOf('private func observeStartupCapture()'),
			source.indexOf('private func emitStartupNoticeOnce()')
		);
		assert.match(
			capture,
			/guard startupDiagnostics, launched, observedExit, !startupObserved, !closedStreams\.contains\(0\)/
		);
		assert.match(capture, /startupObserved = true/);
		assert.match(capture, /fstat\(streams\[0\]\.fileDescriptor, &metadata\)/);
		assert.match(capture, /metadata\.st_nlink == 1/);
		assert.match(capture, /metadata\.st_size >= 0, metadata\.st_size <= 512/);
		assert.match(capture, /read\(upToCount: 513\), bytes\.count == Int\(metadata\.st_size\)/);
		assert.doesNotMatch(
			capture,
			/\bopen\(|Data\(contentsOf:|readToEnd|\.wait\(|\.terminate\(|kill\(|\.close\(/
		);
		const parser = source.slice(
			source.indexOf('private static func parseStartupFrames('),
			source.indexOf('private struct Receipt')
		);
		assert.match(parser, /bytes\.count <= 512/);
		assert.match(parser, /bytes\.allSatisfy\(\{ \$0 < 128 \}\), bytes\.last == 10/);
		assert.match(parser, /observed > index/);
		assert.match(parser, /index != -1 \|\| phase == \.pythonEntry/);
		assert.match(
			source,
			/guard process\.terminationReason == \.exit else \{ throw Failure\.evidence\("native-child-signal"\) \}/
		);
		assert.match(
			source,
			/guard retired\.status == 0 else \{ throw Failure\.evidence\("server-retirement"\) \}/
		);
		assert.match(source, /let listening = try waitFor\("server-start", root: www, seconds: 10\)/);
		assert.match(source, /func testStartupFramesDistinguishActualPrefixEmptyAndRefusedCapture\(\)/);
	}
	assertStartupProjection(fixture, helper);
	for (const [name, candidate, python] of [
		[
			'unobserved stdout capture',
			fixture.replace(
				'guard startupDiagnostics, launched, observedExit, !startupObserved',
				'guard startupDiagnostics, launched, !startupObserved'
			),
			helper
		],
		['unbounded startup read', fixture.replace('read(upToCount: 513)', 'readToEnd()'), helper],
		[
			'foreign path reopened',
			fixture.replace(
				'try streams[0].seek(toOffset: 0)',
				'let foreign = try Data(contentsOf: stdout); try streams[0].seek(toOffset: 0)'
			),
			helper
		],
		['duplicate stage admission', fixture.replace('observed > index', 'observed >= index'), helper],
		[
			'signal accepted as retirement',
			fixture.replace('guard process.terminationReason == .exit else', 'guard true else'),
			helper
		],
		[
			'instrumentation masks primary',
			fixture,
			helper.replace(
				'if primary_failure is None and trace_failure is not None:',
				'if trace_failure is not None:'
			)
		]
	])
		assert.throws(() => assertStartupProjection(candidate, python), name);
	console.log(
		'Sparkle startup diagnostics reuse the exact post-exit capture; native signal/readiness/retirement remain strict.'
	);
} catch (error) {
	errors.push(`Native Sparkle startup diagnostic guard failed: ${error.message}`);
}
// SPARKLE_STARTUP_DIAGNOSTIC_CONTROLS_END

// SPARKLE_NUMERIC_BIND_CONTROLS_BEGIN
// Numeric loopback authority must not introduce an unrelated reverse-DNS wait.
try {
	const assert = require('node:assert/strict');
	const helper = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_sparkle_archive_fixture.py'),
		'utf8'
	);
	function assertNumericLoopbackBinding(python) {
		const start = python.indexOf('    class PrivateServer(http.server.HTTPServer):');
		assert.ok(start >= 0);
		const end = python.indexOf('        def process_request(', start);
		assert.ok(end > start);
		const binding = python.slice(start, end);
		assert.match(binding, /def server_bind\(self\):/);
		assert.match(binding, /http\.server\.socketserver\.TCPServer\.server_bind\(self\)/);
		assert.match(binding, /self\.server_name, self\.server_port = self\.server_address\[:2\]/);
		assert.doesNotMatch(binding, /getfqdn\s*\(/);
		assert.ok(
			binding.indexOf('TCPServer.server_bind(self)') <
				binding.indexOf('self.server_name, self.server_port')
		);
		assert.match(python, /server = PrivateServer\(\("127\.0\.0\.1", 0\), Handler\)/);
		assert.match(python, /timeout = 5/);
		assert.match(python, /server\.timeout = 0\.2/);
		assert.match(python, /server\.handle_request\(\)/);
		assert.match(python, /finally:\n            server\.server_close\(\)/);
	}
	assertNumericLoopbackBinding(helper);
	for (const [name, needle, replacement] of [
		[
			'original reverse DNS dependency',
			'http.server.socketserver.TCPServer.server_bind(self)',
			'http.server.HTTPServer.server_bind(self)'
		],
		['manufactured bind success', 'http.server.socketserver.TCPServer.server_bind(self)', 'pass'],
		[
			'manufactured port',
			'self.server_name, self.server_port = self.server_address[:2]',
			'self.server_name, self.server_port = "127.0.0.1", 1'
		]
	]) {
		assert.equal(helper.split(needle).length - 1, 1, 'One exact numeric binding mutation');
		const candidate = helper.replace(needle, replacement);
		assert.throws(() => assertNumericLoopbackBinding(candidate), name);
	}
	console.log(
		'Sparkle private loopback binds its real socket and port without reverse-DNS authority; native retirement remains mandatory.'
	);
} catch (error) {
	errors.push(`Native Sparkle numeric loopback binding guard failed: ${error.message}`);
}
// SPARKLE_NUMERIC_BIND_CONTROLS_END

// SPARKLE_SIGNATURE_APPLICATION_FACTS_BEGIN
// Actual signer/exit diagnostics add observations while the original refusal remains mandatory.
try {
	const assert = require('node:assert/strict');
	const { annotation, evaluate } = require('../diagnostics/swift_xctest_evidence.cjs');
	const nativeFile = path.join(
		root,
		'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
	);
	const fixture = fs.readFileSync(nativeFile, 'utf8');
	function assertSignerApplicationFacts(source) {
		const start = source.indexOf('private enum SignatureProbe:');
		const end = source.indexOf('private let manager =', start);
		assert.ok(start >= 0 && end > start, 'Closed diagnostic source is present');
		const closed = source.slice(start, end);
		assert.match(closed, /case installedKey = "installed-key", foreignKey = "foreign-key"/);
		assert.match(closed, /signature64: Bool, independentValid: Bool/);
		assert.match(closed, /installedValid: Bool, payloadEqual: Bool\?, signatureEqual: Bool\?/);
		assert.match(closed, /\? "true" : "false" \} \?\? "unavailable"/);
		assert.doesNotMatch(
			closed,
			/localizedDescription|String\(describing:|Data|stdout|stderr|\.path|nonce|\.wait\(|finish\(|terminate\(|kill\(/
		);
		assert.match(closed, /fact == "application-retirement"/);
		assert.match(closed, /projected = Failure\.evidence\("server-retirement"\)/);
		assert.match(closed, /else \{ projected = error \}/);
		assert.match(closed, /serverExitRefusalMessage\(projected, termination: termination\)/);
		assert.match(
			source,
			/if label == "application-exit", let application \{\s*XCTFail\(applicationExitRefusalMessage\(error, termination: application\.observedTerminationFacts\(\)\)\)/
		);
		assert.match(
			source,
			/let retired = try application\.finish\(15\)\s*guard retired.status == 0 else \{ throw Failure\.evidence\("application-retirement"\) \}/
		);
		assert.match(
			source,
			/let independentInstalledSignature = try\? key\.signature\(for: payload\)/
		);
		assert.match(
			source,
			/let installedSignatureEqual = independentInstalledSignature\.map \{ \$0 == signatureBytes \}/
		);
		assert.match(
			source,
			/let officialForeignSignature = try XCTUnwrap\(Data\(base64Encoded: foreignSignature\)\)/
		);
		assert.match(
			source,
			/let copiedForeignPayload = try Data\(contentsOf: foreignArchives\.appendingPathComponent\("ErgoptiPlus.app.tar.xz"\)\)/
		);
		assert.match(
			source,
			/let officialForeignValid = foreignKey\.publicKey\.isValidSignature\(officialForeignSignature, for: payload\)/
		);
		assert.match(
			source,
			/let officialInstalledValid = key\.publicKey\.isValidSignature\(officialForeignSignature, for: payload\)/
		);
		assert.match(source, /let foreignPayloadEqual = copiedForeignPayload == payload/);
		assert.match(source, /XCTAssertEqual\(officialForeignSignature.count, 64,/);
		assert.match(source, /XCTAssertTrue\(officialForeignValid,/);
		assert.match(source, /XCTAssertFalse\(officialInstalledValid,/);
		assert.match(source, /XCTAssertTrue\(foreignPayloadEqual,/);
		assert.match(source, /XCTAssertEqual\(signatureBytes.count, 64,/);
		assert.match(
			source,
			/XCTAssertFalse\(foreignKey\.publicKey\.isValidSignature\(signatureBytes, for: payload\),/
		);
		assert.match(
			source,
			/guard !copiedForeignPayload\.isEmpty else \{ throw Failure\.evidence\("signature-payload-empty"\) \}/
		);
		assert.match(source, /var alteredPayload = copiedForeignPayload/);
		assert.match(source, /alteredPayload\[alteredPayload\.startIndex\] \^= 0x01/);
		assert.match(source, /XCTAssertEqual\(alteredPayload.count, payload.count,/);
		assert.match(
			source,
			/XCTAssertTrue\(!foreignKey\.publicKey\.isValidSignature\(officialForeignSignature, for: alteredPayload\)\s*&& !key\.publicKey\.isValidSignature\(signatureBytes, for: alteredPayload\),\s*"Both official signatures must refuse a one-byte change to the independently authenticated archive"\)/
		);
		assert.match(source, /func testSignatureAndApplicationFactsContainOnlyClosedObservations\(\)/);
	}
	assertSignerApplicationFacts(fixture);
	for (const [label, before, after] of [
		[
			'foreign public-key admission replaced',
			'let officialForeignValid = foreignKey.publicKey.isValidSignature(officialForeignSignature, for: payload)',
			'let officialForeignValid = true'
		],
		[
			'installed key refusal replaced',
			'let officialInstalledValid = key.publicKey.isValidSignature(officialForeignSignature, for: payload)',
			'let officialInstalledValid = false'
		],
		[
			'payload identity replaced',
			'let foreignPayloadEqual = copiedForeignPayload == payload',
			'let foreignPayloadEqual = true'
		],
		[
			'counterfactual foreign signature refusal replaced',
			'XCTAssertTrue(!foreignKey.publicKey.isValidSignature(officialForeignSignature, for: alteredPayload)',
			'XCTAssertTrue(true'
		],
		[
			'counterfactual installed signature refusal replaced',
			'&& !key.publicKey.isValidSignature(signatureBytes, for: alteredPayload)',
			'&& true'
		],
		[
			'counterfactual byte mutation removed',
			'alteredPayload[alteredPayload.startIndex] ^= 0x01',
			'alteredPayload[alteredPayload.startIndex] ^= 0x00'
		],
		[
			'installed signature opposite-key refusal replaced',
			'XCTAssertFalse(foreignKey.publicKey.isValidSignature(signatureBytes, for: payload),',
			'XCTAssertFalse(false,'
		],
		[
			'counterfactual length admission replaced',
			'XCTAssertEqual(alteredPayload.count, payload.count,',
			'XCTAssertEqual(payload.count, payload.count,'
		]
	]) {
		assert.equal(fixture.split(before).length - 1, 1, 'One exact independent mutation');
		assert.throws(() => assertSignerApplicationFacts(fixture.replace(before, after)), label);
	}
	const fixed =
		'Native Sparkle application retirement refusal: code=exit-status native_reason=exit native_status=78';
	const transcript = [
		"Test Suite 'All tests' started at 2026-10-06 01:00:00.000.",
		"Test Case '-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testArchive]' started.",
		nativeFile + ':777: error: failed - ' + fixed,
		"Test Case '-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testArchive]' failed (0.100 seconds).",
		"Test Suite 'All tests' failed at 2026-10-06 01:00:01.000.",
		'\t Executed 1 test, with 1 failure (0 unexpected) in 0.100 (0.110) seconds'
	].join('\n');
	const verdict = evaluate(transcript, 1, 0, root);
	const refusal = verdict.failures.find((failure) => failure.message.endsWith(fixed));
	assert.notEqual(refusal, undefined, 'Authentic XCTest carries only fixed application exit facts');
	assert.match(
		annotation(refusal),
		/::failed - Native Sparkle application retirement refusal: code=exit-status native_reason=exit native_status=78$/
	);
	assert.equal(verdict.exit_status, 1);
	assert.equal(verdict.complete, false);
	assert.equal(
		evaluate(fixed, 1, 0, root).failures.some((failure) => failure.message.endsWith(fixed)),
		false,
		'Raw output never becomes native retirement proof'
	);
	console.log(
		'Sparkle independent signer and already-observed application exit facts preserve original refusal predicates.'
	);
} catch (error) {
	errors.push(`Native Sparkle signer/application diagnostic guard failed: ${error.message}`);
}
// SPARKLE_SIGNATURE_APPLICATION_FACTS_END

// SPARKLE_CHILD_REFUSAL_VISIBILITY_BEGIN
// Closed child refusal facts reuse the original observed exit and cached capture.
try {
	const assert = require('node:assert/strict');
	const { evaluate, annotation } = require('../diagnostics/swift_xctest_evidence.cjs');
	const file = path.join(
		root,
		'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
	);
	const fixture = fs.readFileSync(file, 'utf8');
	const child = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_sparkle_archive_child.swift'),
		'utf8'
	);
	function assertClosedChildVisibility(source) {
		const start = source.indexOf('func observedChildRefusalCode() -> String? {');
		const end = source.indexOf('\n\t\t}', start);
		assert.ok(start >= 0 && end > start, 'Actual cached native capture observer is present');
		const observer = source.slice(start, end);
		assert.match(observer, /guard launched, observedExit, !process\.isRunning, let cachedReceipt,/);
		assert.match(observer, /cachedReceipt\.status == 78 else \{ return nil \}/);
		assert.match(observer, /parseChildRefusalCode\(cachedReceipt\.stderr\)/);
		assert.doesNotMatch(observer, /finish\(|wait|open\(|read|terminate\(|kill\(|close\(/);
		assert.match(source, /frames\.count == 1, let frame = frames\.first/);
		assert.match(
			source,
			/ChildRefusalCode\(rawValue: String\(frame\.dropFirst\(prefix\.count\)\)\)/
		);
		assert.match(source, /text\.utf8\.count <= 16_384, text\.hasSuffix\("\\n"\)/);
		assert.match(
			source,
			/if let code = application\.observedChildRefusalCode\(\) \{\s*XCTFail\("Native Sparkle child refusal: category=" \+ code\)/
		);
	}
	assertClosedChildVisibility(fixture);
	for (const [before, after] of [
		[
			'cachedReceipt.status == 78 else { return nil }',
			'cachedReceipt.status >= 0 else { return nil }'
		],
		['parseChildRefusalCode(cachedReceipt.stderr)', 'cachedReceipt.stderr'],
		['frames.count == 1, let frame = frames.first', 'frames.count >= 1, let frame = frames.first']
	]) {
		assert.equal(fixture.split(before).length - 1, 1, 'One exact source mutation');
		const mutated = fixture.replace(before, () => after);
		assert.throws(() => assertClosedChildVisibility(mutated));
	}
	for (const code of [
		'configuration',
		'target-root',
		'target-bundle',
		'receipt-publication',
		'control',
		'transport'
	]) {
		assert.equal(
			child.split('SPARKLE_CHILD_REFUSAL/1 ' + code + '\\n').length - 1,
			1,
			'One literal failed-branch category emission'
		);
	}
	assert.match(
		child,
		/guard let nativeRoot = nativeDirectoryPath\(rootPath\), nativeRoot == rootPath else/
	);
	assert.match(
		child,
		/guard nativeDirectoryPath\(Bundle\.main\.bundleURL\.path\) == nativeRoot \+ "\/installed\/ErgoptiPlus.app" else/
	);
	assert.match(child, /try stream\.close\(\)[\s\S]*guard link\(stage\.path, target\.path\) == 0/);
	const fixed = 'Native Sparkle child refusal: category=target-root';
	const makeTranscript = (message) =>
		[
			"Test Suite 'All tests' started at 2026-10-06 01:00:00.000.",
			"Test Case '-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testArchive]' started.",
			file + ':777: error: failed - ' + message,
			"Test Case '-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testArchive]' failed (0.100 seconds).",
			"Test Suite 'All tests' failed at 2026-10-06 01:00:01.000.",
			'\t Executed 1 test, with 1 failure (0 unexpected) in 0.100 (0.110) seconds'
		].join('\n');
	const old = evaluate(
		makeTranscript(
			'Native Sparkle application retirement refusal: code=exit-status native_reason=exit native_status=78'
		),
		1,
		0,
		root
	);
	assert.equal(
		old.failures.some((failure) => failure.message.endsWith(fixed)),
		false,
		'Actual old exit annotation cannot expose the child branch'
	);
	const result = evaluate(makeTranscript(fixed), 1, 0, root);
	const failure = result.failures.find((entry) => entry.message.endsWith(fixed));
	assert.notEqual(failure, undefined);
	assert.match(
		annotation(failure),
		/::failed - Native Sparkle child refusal: category=target-root$/
	);
	assert.equal(result.exit_status, 1, 'Diagnostic observation preserves failure');
	assert.equal(
		evaluate(fixed, 1, 0, root).failures.some((entry) => entry.message.endsWith(fixed)),
		false,
		'Raw print is not an annotated native failure'
	);
} catch (error) {
	errors.push(`Native Sparkle child refusal visibility guard failed: ${error.message}`);
}
// SPARKLE_CHILD_REFUSAL_VISIBILITY_END

// SPARKLE_CHILD_POSIX_ADMISSION_BEGIN
// The signed root is the captured native directory, not a Foundation alias.
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
	function assertNativeChildPaths(signed, receiver) {
		assert.match(signed, /"FixtureRoot": try ownedCensusPath\(root\), "FixtureNonce": nonce/);
		const start = receiver.indexOf('private func nativeDirectoryPath(_ path: String) -> String? {');
		const end = receiver.indexOf('\nlet application = NSApplication.shared', start);
		assert.ok(start >= 0 && end > start, 'The native admission precedes application startup');
		const admission = receiver.slice(start, end);
		assert.match(admission, /Darwin\.realpath\(path, nil\)/);
		assert.match(admission, /defer \{ free\(resolved\) \}/);
		assert.match(admission, /Darwin\.lstat\(resolved, &metadata\) == 0/);
		assert.match(admission, /metadata\.st_mode & mode_t\(S_IFMT\) == mode_t\(S_IFDIR\)/);
		assert.match(admission, /return String\(validatingUTF8: resolved\)/);
		assert.match(
			admission,
			/guard let nativeRoot = nativeDirectoryPath\(rootPath\), nativeRoot == rootPath else/
		);
		assert.match(
			admission,
			/guard nativeDirectoryPath\(Bundle\.main\.bundleURL\.path\) == nativeRoot \+ "\/installed\/ErgoptiPlus.app" else/
		);
		assert.doesNotMatch(admission, /resolvingSymlinksInPath|standardized|root\.path == rootPath/);
	}
	assertNativeChildPaths(fixture, child);
	for (const [before, after] of [
		['"FixtureRoot": try ownedCensusPath(root)', '"FixtureRoot": root.path']
	]) {
		assert.equal(fixture.split(before).length - 1, 1);
		assert.throws(() => assertNativeChildPaths(fixture.replace(before, after), child));
	}
	for (const [before, after] of [
		['nativeRoot == rootPath else', 'nativeRoot != rootPath else'],
		['nativeRoot + "/installed/ErgoptiPlus.app"', 'nativeRoot + "/source/ErgoptiPlus.app"'],
		[
			'return String(validatingUTF8: resolved)',
			'return URL(fileURLWithPath: path).resolvingSymlinksInPath().path'
		]
	]) {
		assert.equal(child.split(before).length - 1, 1);
		assert.throws(() => assertNativeChildPaths(fixture, child.replace(before, after)));
	}
} catch (error) {
	errors.push(`Native Sparkle POSIX child admission guard failed: ${error.message}`);
}
// SPARKLE_CHILD_POSIX_ADMISSION_END

// NATIVE_SPARKLE_UPDATE_PROGRESS_BEGIN
try {
	const assert = require('node:assert/strict');
	const child = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_sparkle_archive_child.swift'),
		'utf8'
	);
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	const progressEnum = fixture.slice(
		fixture.indexOf('private enum UpdateProgressEvent:'),
		fixture.indexOf('private enum UpdateProgressCapture:')
	);
	assert.doesNotMatch(progressEnum, /,\s*\n\s*case\b/);
	assert.equal((progressEnum.match(/\be[0-9]+ = "[a-z0-9-]+"/g) || []).length, 42);
	assert.match(
		child,
		/guard unlink\(stage.path\) == 0 else \{ throw Failure.refused \}\s*progress\(event\)/
	);
	assert.match(
		child,
		/progress\("updater-start-attempt"\)\s*try owner.start\(\)\s*progress\("updater-started"\)/
	);
	assert.match(child, /progress\("check-requested-1"\)\s*owner.checkForUpdates\(\)/);
	assert.match(
		child,
		/showUserInitiatedUpdateCheck\(cancellation: @escaping \(\) -> Void\) \{ progress\("user-check-" \+ String\(phase\)\) \}/
	);
	assert.match(
		fixture,
		/guard launched, observedExit, let cachedReceipt else \{ return \.unavailable \}/
	);
	assert.match(
		fixture,
		/parseUpdateProgress\(cachedReceipt.stdout,\s*expectedPID: process.processIdentifier\)/
	);
	assert.match(fixture, /text.utf8.count <= 4096/);
	assert.match(fixture, /!events.contains\(event\)/);
	assert.match(fixture, /guard events.first == \.e0/);
	assert.match(fixture, /CFGetTypeID\(number\) != CFBooleanGetTypeID\(\)/);
	assert.match(fixture, /number.doubleValue == Double\(number.intValue\)/);
	assert.match(
		fixture,
		/let retired = try application.finish\(15\)\s*guard retired.status == 0 else \{ throw Failure.evidence\("application-retirement"\) \}/
	);
	assert.match(fixture, /waitFor\("refused-1", root: root\)/);
	console.log(
		'[OK] Native Sparkle progress uses exact retired capture and authentic admitted-resource counter without granting acceptance.'
	);
} catch (error) {
	errors.push('Native Sparkle bounded progress guard: ' + error.message);
}
// NATIVE_SPARKLE_UPDATE_PROGRESS_END

// NATIVE_SPARKLE_STARTUP_ADMISSION_REFUSAL_IDENTITY_BEGIN
try {
	const assert = require('node:assert/strict');
	const child = fs.readFileSync(
		path.join(root, 'tools/diagnostics/macos_sparkle_archive_child.swift'),
		'utf8'
	);
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	function admission(source, producer) {
		assert.match(
			producer,
			/record\("start-refused", details: \["errors": identities\(error\)\]\)\s*startupAdmissionRefusal\(error, startReturned: startReturned\)/
		);
		assert.match(producer, /var startReturned = false/);
		assert.match(
			producer,
			/try owner.start\(\)\s*progress\("updater-started"\)\s*startReturned = true\s*guard !owner.automaticallyChecksForUpdates/
		);
		assert.match(producer, /startReturned \? "policy-validation" : "native-start"/);
		assert.match(
			producer,
			/switch native.domain[\s\S]*?case SUSparkleErrorDomain: domain = "sparkle"[\s\S]*?case NSCocoaErrorDomain: domain = "cocoa"[\s\S]*?default: domain = "other"/
		);
		const emit = producer.slice(
			producer.indexOf('private func startupAdmissionRefusal('),
			producer.indexOf('/// Capture only typed error identities')
		);
		assert.match(emit, /let native = error as NSError/);
		assert.match(emit, /String\(native.code\)/);
		assert.doesNotMatch(
			emit,
			/localizedDescription|userInfo|\.path|absoluteString|String\(describing:/
		);
		const observe = source.slice(
			source.indexOf('func observedStartupAdmissionRefusalIdentity()'),
			source.indexOf('func observedChildRefusalCode()')
		);
		assert.match(observe, /guard launched, observedExit, let cachedReceipt else \{ return nil \}/);
		assert.match(
			observe,
			/parseStartupAdmissionRefusalIdentity\(cachedReceipt.stdout,\s*expectedPID: process.processIdentifier\)/
		);
		assert.doesNotMatch(observe, /Data\(|FileHandle|Thread|Date\(|finish\(|terminate\(|read/);
		assert.match(source, /!startupIdentitySeen, events.last == \.e9/);
		assert.match(source, /StartupAdmissionRefusalStage\(rawValue: fields\[0\]\)/);
		assert.match(source, /String\(code\) == codeFields\[1\]/);
		assert.match(source, /frames.count == 1/);
		assert.match(
			source,
			/Native Sparkle startup admission refusal: stage=unavailable domain=unavailable code=unavailable/
		);
		assert.match(
			source,
			/testStartupAdmissionRefusalIdentityRequiresExactRetiredProgressAndFixedTypedFields/
		);
		assert.match(source, /stage=policy-validation domain=other code=0/);
	}
	admission(fixture, child);
	for (const [from, to] of [
		[
			'guard launched, observedExit, let cachedReceipt else { return nil }',
			'guard launched, let cachedReceipt else { return nil }'
		],
		['!startupIdentitySeen, events.last == .e9', '!startupIdentitySeen'],
		['String(code) == codeFields[1]', 'true']
	]) {
		assert.equal(fixture.split(from).length - 1, 1);
		const changed = fixture.replace(from, to);
		assert.notEqual(changed, fixture);
		assert.throws(() => admission(changed, child));
	}
	console.log(
		'[OK] Native Sparkle startup admission identity uses exact closed capture and actual catch stage only.'
	);
} catch (error) {
	errors.push('Native Sparkle startup admission identity guard: ' + error.message);
}
// NATIVE_SPARKLE_STARTUP_ADMISSION_REFUSAL_IDENTITY_END

// NATIVE_SPARKLE_FIXTURE_PUBLIC_KEY_BEGIN
try {
	const assert = require('node:assert/strict');
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	function assertFixturePublicKey(source) {
		// Preserve Swift string literals while excluding comments from source evidence.
		const executable = source.replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (token) =>
			token.startsWith('/') ? '' : token
		);
		const declarations = [...executable.matchAll(/private func makeBundle\(/g)];
		assert.equal(declarations.length, 1, 'One actual native bundle constructor');
		const start = declarations[0].index;
		const end = executable.indexOf('\n\tprivate func ', start + 1);
		assert.ok(end > start, 'The native bundle constructor has a closed source boundary');
		const body = executable.slice(start, end);
		assert.match(body, /publicKey: String/, 'The constructor receives the signing public key');
		const dictionaries = [
			...body.matchAll(/let plist:\s*\[String:\s*Any\]\s*=\s*\[([\s\S]*?)\n[ \t]*\]/g)
		];
		assert.equal(dictionaries.length, 1, 'One actual fixture Info.plist dictionary');
		const plist = dictionaries[0][1];
		assert.equal(
			(plist.match(/"SUPublicEDKey"\s*:/g) || []).length,
			1,
			'Sparkle reads exactly one SUPublicEDKey entry'
		);
		assert.match(
			plist,
			/"SUPublicEDKey"\s*:\s*publicKey\s*,/,
			'The admitted signing key must reach Sparkle'
		);
		assert.doesNotMatch(
			plist,
			/"SUEdPublicKey"\s*:/,
			'The ignored legacy spelling cannot replace the native key'
		);
		assert.match(
			body,
			/PropertyListSerialization\.data\(fromPropertyList: plist/,
			'The guarded dictionary is serialized into the bundle'
		);
	}
	assertFixturePublicKey(fixture);
	const entry = '"SUPublicEDKey": publicKey, ';
	for (const [label, replacement] of [
		['missing public key', ''],
		['ignored legacy spelling', '"SUEdPublicKey": publicKey, '],
		['null public key value', '"SUPublicEDKey": NSNull(), ']
	]) {
		assert.equal(fixture.split(entry).length - 1, 1, 'One exact native fixture entry');
		const changed = fixture.replace(entry, replacement);
		assert.notEqual(changed, fixture);
		assert.throws(() => assertFixturePublicKey(changed), label);
	}
	console.log('[OK] The native Sparkle fixture publishes its signing key under SUPublicEDKey.');
} catch (error) {
	errors.push('Native Sparkle fixture public key guard: ' + error.message);
}
// NATIVE_SPARKLE_FIXTURE_PUBLIC_KEY_END

// NATIVE_SPARKLE_REFUSAL_CHAIN_BEGIN
try {
	const assert = require('node:assert/strict');
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	function assertClosedRefusalChain(source) {
		const executable = source.replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (token) =>
			token.startsWith('/') ? '' : token
		);
		const begin = executable.indexOf('private static func refusalErrorChainMessage(');
		const end = executable.indexOf('\n\tprivate func ', begin);
		assert.ok(begin >= 0 && end > begin, 'Actual refusal projection is present');
		const body = executable.slice(begin, end);
		assert.match(body, /expectedPID > 0, receipt\["nonce"\] as\? String == nonce/);
		assert.match(
			body,
			/receipt\["event"\] as\? String == "refused-1", receipt\["version"\] as\? String == "1"/
		);
		assert.match(
			body,
			/pid\.stringValue == String\(expectedPID\), !errors\.isEmpty, errors\.count <= 8/
		);
		assert.match(body, /Set\(identity\.keys\) == Set\(\["domain", "code"\]\)/);
		assert.match(body, /CFGetTypeID\(value\) != CFBooleanGetTypeID\(\)/);
		assert.match(body, /String\(value\.int64Value\) == value\.stringValue/);
		assert.match(body, /case SUSparkleErrorDomain: domain = "sparkle"/);
		assert.match(body, /case NSCocoaErrorDomain: domain = "cocoa"/);
		assert.match(body, /default: domain = "other"/);
		assert.match(body, /chain\.append\(domain \+ ":" \+ String\(value\.int64Value\)\)/);
		assert.doesNotMatch(
			body,
			/userInfo|localizedDescription|String\(reflecting:|\+ nativeDomain|Data\(|FileHandle|waitFor\(|Thread|Date\(/
		);
		const read = executable.indexOf(
			'let errors = try XCTUnwrap(details["errors"] as? [[String: Any]])'
		);
		const notice = executable.indexOf(
			'print("::notice title=Native Sparkle wrong-key refusal::"',
			read
		);
		const assertion = executable.indexOf('XCTAssertTrue(errors.contains {', read);
		assert.ok(
			read >= 0 && notice > read && assertion > notice,
			'Existing captured identities are projected before the unchanged signature assertion'
		);
		assert.match(
			executable.slice(notice, assertion),
			/Self\.refusalErrorChainMessage\(errors,\s*receipt: refusal, expectedPID: application\?\.process\.processIdentifier \?\? 0, nonce: nonce\)/
		);
		for (const name of [
			'testRefusalErrorChainAdmitsOnlyBoundReceiptAndClosedDomainLabels',
			'testRefusalErrorChainRejectsForeignRecipientEventVersionAndNonce',
			'testRefusalErrorChainRejectsMalformedOrExcessiveIdentityRecords'
		])
			assert.match(executable, new RegExp('func ' + name + '\\(\\)'));
	}
	assertClosedRefusalChain(fixture);
	for (const [from, to] of [
		['receipt["nonce"] as? String == nonce', 'true'],
		['errors.count <= 8', 'errors.count <= 9'],
		[
			'chain.append(domain + ":" + String(value.int64Value))',
			'chain.append(nativeDomain + ":" + String(value.int64Value))'
		]
	]) {
		assert.equal(fixture.split(from).length - 1, 1, 'One independent refusal source mutation');
		assert.throws(() => assertClosedRefusalChain(fixture.replace(from, to)));
	}
	console.log(
		'[OK] Native wrong-key refusal diagnostics use the bound original receipt and closed error identities.'
	);
} catch (error) {
	errors.push('Native Sparkle refusal chain guard: ' + error.message);
}
// NATIVE_SPARKLE_REFUSAL_CHAIN_END

// The actual wrong-key receipt uses Sparkle's validation error, through native wrappers.
try {
	const assert = require('node:assert/strict');
	const fixture = fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
		),
		'utf8'
	);
	function requireExactValidationError(source) {
		const executable = source.replace(/"(?:\\.|[^"\\])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (token) =>
			token.startsWith('/') ? '' : token
		);
		const anchor = 'XCTAssertTrue(errors.contains {';
		assert.equal(
			executable.split(anchor).length - 1,
			1,
			'Exactly one original wrong-key assertion'
		);
		const offset = executable.indexOf(anchor);
		const end = executable.indexOf(
			'}, "Wrong-key refusal must reach actual Sparkle signature validation")',
			offset
		);
		assert.ok(end > offset, 'The original assertion and failure message remain');
		assert.match(
			executable.slice(offset, end),
			/^XCTAssertTrue\(errors\.contains \{ \$0\["domain"\] as\? String == SUSparkleErrorDomain\s*&& \(\$0\["code"\] as\? NSNumber\)\?\.intValue == Int\(SUError\.validationError\.rawValue\) $/
		);
	}
	requireExactValidationError(fixture);
	for (const replacement of ['3001', '4005', 'Int(SUError.validationError.rawValue) || true']) {
		assert.throws(() =>
			requireExactValidationError(
				fixture.replace('Int(SUError.validationError.rawValue)', replacement)
			)
		);
	}
	assert.throws(() =>
		requireExactValidationError(
			fixture.replace('$0["domain"] as? String == SUSparkleErrorDomain', 'true')
		)
	);
	console.log(
		'[OK] Wrong-key archive acceptance requires the exact native Sparkle validation error.'
	);
} catch (error) {
	errors.push('Native Sparkle exact validation error guard: ' + error.message);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log('[OK] macOS Sparkle release metadata is channel-specific.');
