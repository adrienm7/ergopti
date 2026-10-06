// tools/test/test-homebrew-cask.cjs

/**
 * ==============================================================================
 * MODULE: Homebrew Cask Guard
 * DESCRIPTION:
 * Renders the cask of a dev and of a stable release through the generator the
 * release workflow runs, and pins every name it repeats to its owner.
 *
 * FEATURES & RATIONALE:
 * 1. Channel from the registry: a dev tag renders ergoptiplus@dev, a semver
 *    tag ergoptiplus, each conflicting with the other, so installing one
 *    channel's cask replaces the other's app instead of adding a second one.
 * 2. brew upgrade updates the app with the user's other casks: no cask
 *    declares auto_updates, brew quits both bundle identifiers before replacing
 *    the bundle and relaunches the app only when it was running. livecheck
 *    reads the same appcast the app follows.
 * 3. Names repeated from the build (bundle id, app, asset, minimum macOS) and
 *    from the release workflow (appcast branch, generator call, tap
 *    repository) must match their owners, or the cask downloads or installs
 *    something the release never published.
 * 4. Invalid input (tag without v, tag owned by no channel, malformed
 *    checksum) fails instead of publishing a cask that cannot install.
 * 5. Ruby parses both casks when a Ruby interpreter is on PATH (the Linux CI
 *    runners have one).
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const Cask = require(path.join(ROOT, 'tools', 'build', 'homebrew-cask.cjs'));

const BUILD_SCRIPT = fs.readFileSync(
	path.join(ROOT, 'tools', 'build', 'build_macos_app.sh'),
	'utf8'
);
const WORKFLOW = fs.readFileSync(path.join(ROOT, '.github', 'workflows', 'ci.yml'), 'utf8');
const MACOS_README = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'README.md'),
	'utf8'
);

const SHA = 'a'.repeat(64);

// macOS release names Homebrew accepts in depends_on, by major version
const MACOS_SYMBOLS = {
	11: ':big_sur',
	12: ':monterey',
	13: ':ventura',
	14: ':sonoma',
	15: ':sequoia'
};

let failures = 0;

function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${err.message}`);
	}
}

console.log('Homebrew cask');

const dev = Cask.renderCask('v0.0.0-dev.142', SHA);
const stable = Cask.renderCask('v1.2.3', SHA);

check('a dev tag renders the dev cask, a semver tag the stable one', () => {
	assert.strictEqual(dev.token, 'ergoptiplus@dev');
	assert.strictEqual(dev.file, path.join('Casks', 'ergoptiplus@dev.rb'));
	assert.match(dev.text, /^cask "ergoptiplus@dev" do$/m);
	assert.match(dev.text, /^  version "0\.0\.0-dev\.142"$/m);
	assert.strictEqual(stable.token, 'ergoptiplus');
	assert.match(stable.text, /^  version "1\.2\.3"$/m);
});

check('each channel cask conflicts with every other channel cask', () => {
	const tokens = Cask.caskChannels().map((entry) => entry.token);
	for (const cask of [dev, stable]) {
		const conflicts = [...cask.text.matchAll(/conflicts_with cask: "([^"]+)"/g)].map((m) => m[1]);
		assert.deepStrictEqual(conflicts.sort(), tokens.filter((token) => token !== cask.token).sort());
	}
});

check('the cask downloads the tagged release asset with its checksum', () => {
	assert.match(dev.text, new RegExp(`^  sha256 "${SHA}"$`, 'm'));
	assert.ok(
		dev.text.includes(
			`url "https://github.com/${Cask.SOURCE_REPOSITORY}/releases/download/v#{version}/${Cask.ASSET_NAME}"`
		)
	);
});

check(
	'brew upgrade quits, replaces and relaunches the app, and livecheck reads the channel appcast',
	() => {
		for (const cask of [dev, stable]) {
			assert.doesNotMatch(
				cask.text,
				/auto_updates/,
				'auto_updates would make brew upgrade skip the app'
			);
			assert.ok(
				cask.text.includes(`uninstall quit: ["${Cask.BUNDLE_ID}.hammerspoon", "${Cask.BUNDLE_ID}"]`)
			);
			const marker = `"${Cask.RELAUNCH_MARKER}"`;
			const preflight = cask.text.slice(
				cask.text.indexOf('uninstall_preflight do'),
				cask.text.indexOf('uninstall quit:')
			);
			assert.ok(
				preflight.includes(`FileUtils.touch(${marker})`) && preflight.includes('if running'),
				'the marker is left only when the app was running'
			);
			const postflight = cask.text.slice(cask.text.indexOf('postflight do'));
			assert.ok(
				postflight.includes(`if File.exist?(${marker})`) &&
					postflight.includes(`FileUtils.rm_f(${marker})`) &&
					postflight.includes(`"/usr/bin/open", args: ["#{appdir}/${Cask.APP_NAME}"]`),
				'postflight relaunches only on the marker, and consumes it'
			);
			assert.ok(
				Cask.RELAUNCH_MARKER.includes(`/Library/Caches/${Cask.BUNDLE_ID}/`),
				'zap must remove the marker'
			);
		}
		const base = `https://raw.githubusercontent.com/${Cask.SOURCE_REPOSITORY}/${Cask.APPCAST_BRANCH}/`;
		assert.ok(dev.text.includes(`url "${base}appcast-dev.xml"`));
		assert.ok(stable.text.includes(`url "${base}appcast-main.xml"`));
		assert.ok(
			WORKFLOW.includes(`branch="${Cask.APPCAST_BRANCH}"`),
			'ci.yml publishes the appcasts on another branch'
		);
	}
);

check('bundle names match build_macos_app.sh', () => {
	assert.ok(BUILD_SCRIPT.includes(`BUNDLE_ID="${Cask.BUNDLE_ID}"`));
	assert.ok(BUILD_SCRIPT.includes(`APP_PATH="$BUILD_DIR/${Cask.APP_NAME}"`));
	assert.ok(BUILD_SCRIPT.includes(`ZIP_PATH="$BUILD_DIR/${Cask.ASSET_NAME}"`));
	const minimum = BUILD_SCRIPT.match(
		/<key>LSMinimumSystemVersion<\/key>\s*<string>(\d+)\.\d+<\/string>/
	);
	assert.ok(minimum, 'LSMinimumSystemVersion not found');
	assert.strictEqual(Cask.MINIMUM_MACOS, MACOS_SYMBOLS[minimum[1]]);
	assert.ok(dev.text.includes(`app "${Cask.APP_NAME}"`));
	assert.ok(
		dev.text.includes(`"#{appdir}/${Cask.APP_NAME}"`),
		'the quarantine flag is cleared on the installed app'
	);
});

check(
	'the release workflow runs the generator on the published asset and the docs name its tap',
	() => {
		assert.ok(WORKFLOW.includes('node tools/build/homebrew-cask.cjs "$TAG" "$sha" "$tap"'));
		assert.ok(WORKFLOW.includes('node tools/build/macos-release-publication.cjs download'));
		assert.ok(WORKFLOW.includes('"$tap" "$archive"'));
		const tap = WORKFLOW.match(
			/TAP_REPOSITORY: \$\{\{ github\.repository_owner \}\}\/(homebrew-[a-z-]+)/
		);
		assert.ok(tap, 'ci.yml names no tap repository');
		const owner = Cask.SOURCE_REPOSITORY.split('/')[0];
		const shortTap = `${owner}/${tap[1].replace(/^homebrew-/, '')}`;
		assert.ok(
			MACOS_README.includes(`brew tap ${shortTap}`),
			`the macOS README does not tap ${shortTap}`
		);
		for (const entry of Cask.caskChannels()) {
			assert.ok(
				MACOS_README.includes(`brew install --cask ${entry.token}`),
				`the macOS README does not install ${entry.token}`
			);
		}
	}
);

check('the release notes name the released channel cask and every channel token', () => {
	assert.ok(WORKFLOW.includes('cask="$(node tools/build/homebrew-cask.cjs --token "$CHANNEL")"'));
	assert.ok(WORKFLOW.includes('brew install --cask ${cask}'));
	assert.ok(WORKFLOW.includes('brew tap ${GITHUB_REPOSITORY_OWNER}/ergopti'));
	for (const entry of Cask.caskChannels()) {
		assert.strictEqual(Cask.tokenForChannel(entry.id), entry.token);
		assert.ok(
			WORKFLOW.includes(`\\\`${entry.token}\\\``),
			`the release notes do not name ${entry.token}`
		);
	}
	assert.throws(() => Cask.tokenForChannel('nightly'), /not a registry channel/);
});

check('invalid input fails instead of rendering', () => {
	assert.throws(() => Cask.renderCask('0.0.0-dev.1', SHA), /starts with "v"/);
	assert.throws(() => Cask.renderCask('vnot-a-version', SHA), /no update channel/);
	assert.throws(() => Cask.renderCask('v1.2.3', 'A'.repeat(64)), /SHA-256/);
});

check('the CLI writes the cask into the tap checkout', () => {
	const tap = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tap-'));
	try {
		const run = spawnSync(
			process.execPath,
			[path.join(ROOT, 'tools', 'build', 'homebrew-cask.cjs'), 'v0.0.0-dev.142', SHA, tap],
			{ encoding: 'utf8' }
		);
		assert.strictEqual(run.status, 0, run.stderr);
		assert.strictEqual(run.stdout, `${dev.file}\n`);
		assert.strictEqual(fs.readFileSync(path.join(tap, dev.file), 'utf8'), dev.text);
	} finally {
		fs.rmSync(tap, { recursive: true, force: true });
	}
});

check('Ruby parses both casks', () => {
	const probe = spawnSync('ruby', ['--version'], { encoding: 'utf8' });
	if (probe.error) {
		console.log('       (no ruby on PATH: syntax not checked here)');
		return;
	}
	for (const cask of [dev, stable]) {
		const run = spawnSync('ruby', ['-c'], { input: cask.text, encoding: 'utf8' });
		assert.strictEqual(run.status, 0, `${cask.token}: ${run.stderr}`);
	}
});

check('an admitted preferred name remains coupled to its independent hash', () => {
	const publication = require('../build/macos-release-publication.cjs');
	const preferred = publication.bindings()[0];
	const crypto = require('node:crypto');
	const tap = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-preferred-cask-'));
	try {
		const payload = path.join(tap, preferred.name);
		fs.writeFileSync(payload, Buffer.from('independent selected public archive bytes'));
		const actualHash = crypto.createHash('sha256').update(fs.readFileSync(payload)).digest('hex');
		const selected = Cask.renderCask('v0.0.0-dev.142', actualHash, preferred.name);
		assert.ok(selected.text.includes(`/v#{version}/${preferred.name}"`));
		assert.ok(selected.text.includes(`sha256 "${actualHash}"`));
		const result = spawnSync(
			process.execPath,
			[
				path.join(ROOT, 'tools/build/homebrew-cask.cjs'),
				'v0.0.0-dev.142',
				actualHash,
				tap,
				preferred.name
			],
			{ encoding: 'utf8' }
		);
		assert.equal(result.status, 0, result.stderr);
		assert.equal(fs.readFileSync(path.join(tap, selected.file), 'utf8'), selected.text);
		assert.throws(() => Cask.renderCask('v1.2.3', actualHash, 'unknown.tar.xz'), /undeclared/);
	} finally {
		fs.rmSync(tap, { recursive: true });
	}
});

check('portable Brew ownership controls remain registered and mandatory', () => {
	const controls = path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance_test.py');
	const result = spawnSync(process.platform === 'win32' ? 'python' : 'python3', [controls], {
		cwd: ROOT,
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	});
	assert.ifError(result.error);
	assert.strictEqual(result.signal, null, result.stderr);
	assert.strictEqual(result.status, 0, result.stderr);
	assert.match(result.stderr, /Ran 38 tests in /);
	assert.match(result.stderr, /\nOK\s*$/);
	assert.doesNotMatch(result.stderr, /skipped=/);
});

check(
	'owned AppleEvent compile boundary uses declared 64-bit dispatch and actual selected tools',
	() => {
		const receiver = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_receiver.c'),
			'utf8'
		);
		const helper = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
			'utf8'
		);
		assert.match(
			receiver,
			/ReceiveNextEvent\(1, &apple_event, kEventDurationForever, true, &event\)/
		);
		assert.match(receiver, /AEProcessEvent\(event\)/);
		assert.match(receiver, /ReleaseEvent\(event\)/);
		assert.doesNotMatch(receiver, /RunApplicationEventLoop\s*\(/);
		const registration = receiver.slice(
			receiver.indexOf('ProcessSerialNumber serial;'),
			receiver.indexOf('const AEEventHandlerUPP handler')
		);
		assert.ok(registration.length > 0, 'the actual native registration body must be present');
		assert.match(
			registration,
			/GetCurrentProcess\(&serial\);\s*if \(status != noErr\) \{\s*fprintf\(stderr, "Owned AppleEvent recipient current-process registration failed: %d\\n", \(int\)status\);\s*return 65;/
		);
		assert.match(
			registration,
			/TransformProcessType\(&serial, kProcessTransformToUIElementApplication\);\s*if \(status != noErr\) \{\s*fprintf\(stderr, "Owned AppleEvent recipient transform registration failed: %d\\n", \(int\)status\);\s*return 65;/
		);
		assert.match(helper, /xcode-select", "--print-path"\], confined=True/);
		assert.match(helper, /-isysroot/);
		assert.match(helper, /-fmodules-cache-path=/);
		assert.match(helper, /cache\.mkdir\(mode=0o700\)/);
		const boundary = helper.slice(
			helper.indexOf('def _admit_appleevent_boundary'),
			helper.indexOf('def ', helper.indexOf('def _admit_appleevent_boundary') + 5)
		);
		assert.doesNotMatch(boundary, /xcrun/);
	}
);

check('native XCTest invokes actual Brew acceptance and requires its complete receipt', () => {
	const fixture = fs.readFileSync(
		path.join(
			ROOT,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HomebrewArchiveAcceptanceTests.swift'
		),
		'utf8'
	);
	assert.match(
		fixture,
		/func testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState\(\) throws/
	);
	assert.match(fixture, /tools\/diagnostics\/macos_brew_archive_acceptance\.py/);
	assert.match(fixture, /process\.run\(\)/);
	assert.match(fixture, /process\.terminationStatus == 0/);
	assert.match(fixture, /attributes: \[\.posixPermissions: 0o700\]/);
	assert.match(fixture, /Set\(ownership\.keys\) == Set\(\["schema", "helper_pid", "closed"\]\)/);
	assert.match(fixture, /ownership\["closed"\] as\? Bool == true/);
	assert.match(fixture, /ownership\["helper_pid"\]/);
	assert.match(fixture, /func retireInvoker\(\) -> Bool/);
	assert.doesNotMatch(fixture, /SIGKILL/);

	assert.match(fixture, /receipt\["complete"\] as\? Bool, true/);
	assert.match(fixture, /receipt\["host_unchanged"\] as\? Bool, true/);
	assert.match(fixture, /receipt\["fixture_retained"\] as\? Bool, false/);
	assert.match(fixture, /receipt\["cleanup_errors"\] as\? \[String\], \[\]/);
	for (const name of [
		'zip_install',
		'xz_upgrade',
		'checksum_refusal_preserved',
		'checksum_retry',
		'artifact_refusal_preserved',
		'artifact_retry'
	]) {
		assert.ok(fixture.includes(`"${name}": true`), `Native receipt must acknowledge ${name}`);
	}
	assert.doesNotMatch(fixture, /XCTSkip|mock|stub/i);
});

check('native macOS CI admits the pinned Python nonreaping prerequisites', () => {
	const pipeline = require('./ci-pipeline.cjs');
	const job = pipeline.job('package-macos');
	const setupName = 'Prepare Python for native nonreaping waits';
	const admissionName = 'Admit native nonreaping Python prerequisites';
	const setup = pipeline.step(job, setupName);
	const admission = pipeline.step(job, admissionName);
	assert.equal(pipeline.stepField(setup, 'uses'), 'actions/setup-python@v5');
	assert.match(setup, /python-version: '3\.13'/);
	for (const step of [setup, admission]) {
		assert.equal(pipeline.stepField(step, 'if'), null);
		assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	}
	const order = pipeline.steps(job).map((step) => step.name);
	assert.ok(order.indexOf(setupName) < order.indexOf(admissionName));
	assert.ok(order.indexOf(admissionName) < order.indexOf('Run Swift launcher tests'));
	const lines = pipeline.runOf(admission);
	assert.equal(lines[0], "python3 - <<'PY'");
	assert.equal(lines.at(-1), 'PY');
	const script = lines.slice(1, -1).join('\n');
	for (const [version, missing, expected] of [
		[[3, 12, 12], null, 1],
		[[3, 13, 7], 'waitid', 1],
		[[3, 13, 7], 'WNOWAIT', 1],
		[[3, 13, 7], null, 0]
	]) {
		// These portable models exercise the actual admission script; native
		// WNOWAIT behavior remains owned by repeated macOS observations.
		const preparation =
			`import os, sys\nsys.platform = "darwin"\nsys.version_info = tuple(${JSON.stringify(version)})\nfor name in ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT", "CLD_EXITED", "CLD_KILLED", "CLD_DUMPED"):\n if not hasattr(os, name): setattr(os, name, None)\n` +
			(missing
				? `if hasattr(os, ${JSON.stringify(missing)}): delattr(os, ${JSON.stringify(missing)})\n`
				: '') +
			`exec(${JSON.stringify(script)})\n`;
		const result = spawnSync(
			process.platform === 'win32' ? 'python' : 'python3',
			['-c', preparation],
			{ encoding: 'utf8', timeout: 30000 }
		);
		assert.ifError(result.error);
		assert.equal(result.signal, null, result.stderr);
		assert.equal(result.status === 0 ? 0 : 1, expected, result.stderr);
		if (expected === 0) {
			assert.deepEqual(JSON.parse(result.stdout).version, version);
			assert.ok(JSON.parse(result.stdout).nonreaping_apis.includes('WNOWAIT'));
		} else {
			assert.match(result.stderr, missing ? /Missing native nonreaping APIs/ : /CPython >= 3.13/);
		}
	}
});

check('archive artifacts bind only this step session independently of TIS', () => {
	const pipeline = require('./ci-pipeline.cjs');
	const job = pipeline.job('package-macos');
	const step = pipeline.step(job, 'Run Swift launcher tests');
	const lines = pipeline.runOf(step).join('\n');
	assert.match(
		lines,
		/ERGOPTI_ARCHIVE_EVIDENCE_DIR="\$\(mktemp -d "\$RUNNER_TEMP\/swift-launcher-evidence\/archive-session\.XXXXXX"\)"/
	);
	assert.ok(
		lines.indexOf('archive_session_dir=') < lines.indexOf('export ERGOPTI_TIS_EVIDENCE_DIR=')
	);
	assert.ok(
		lines.indexOf('"scope": "swift-not-started"') <
			lines.indexOf('export ERGOPTI_TIS_EVIDENCE_DIR=')
	);
	assert.match(step, /timeout-minutes: 10/);
	const upload = pipeline.step(job, 'Retain archive diagnostic session');
	assert.equal(
		pipeline.stepField(upload, 'if'),
		"${{ always() && steps.swift-launcher-tests.outputs.archive_session_dir != '' }}"
	);
	assert.equal(pipeline.stepField(upload, 'uses'), 'actions/upload-artifact@v4');
	const pathBlock = /^ {10}path: \|\n((?: {12}.+\n?)+)/m.exec(upload)?.[1];
	assert.ok(pathBlock);
	const paths = pathBlock
		.trim()
		.split('\n')
		.map((line) => line.trim());
	assert.deepEqual(paths, [
		'${{ steps.swift-launcher-tests.outputs.archive_session_dir }}/*/*.json',
		'${{ steps.swift-launcher-tests.outputs.archive_session_dir }}/*/helper/*.json'
	]);
	assert.doesNotMatch(upload, /tis_session_dir|\*\*|cache|fixture|key|\.app/i);
});

check('archive owners publish bounded typed phase evidence before native work', () => {
	const testRoot = 'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/';
	for (const [file, owner] of [
		['HomebrewArchiveAcceptanceTests.swift', 'brew'],
		['SparkleArchiveUpdateAcceptanceTests.swift', 'sparkle']
	]) {
		const source = fs.readFileSync(path.join(ROOT, testRoot, file), 'utf8');
		assert.ok(source.includes(`ArchiveAcceptanceEvidence(owner: .${owner})`));
		assert.ok(source.includes('checkpoint("candidate.begin")'));
		assert.match(source, /checkpoint\("cleanup\.debt(?:-" \+ label|"), status: "cleanup-debt"/);
		if (owner === 'brew') assert.ok(source.includes('if evidenceRefused { canRetire = false }'));
	}
	const writer = fs.readFileSync(
		path.join(ROOT, testRoot, 'ArchiveAcceptanceEvidence.swift'),
		'utf8'
	);
	assert.match(writer, /swift-launcher-evidence/);
	assert.match(writer, /O_NOFOLLOW/);
	assert.match(writer, /bytes\.count <= 4096/);
	assert.match(writer, /sequence < 256/);
	assert.match(writer, /testRefusedPublicationNeverReplacesAnUnclosedCheckpoint/);
});

check('shared native process ownership controls remain registered and mandatory', () => {
	const result = spawnSync(
		process.platform === 'win32' ? 'python' : 'python3',
		[path.join(ROOT, 'tools/diagnostics/macos_owned_process_test.py')],
		{
			cwd: ROOT,
			encoding: 'utf8',
			timeout: 30000,
			env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
		}
	);
	assert.ifError(result.error);
	assert.strictEqual(result.signal, null, result.stderr);
	assert.strictEqual(result.status, 0, result.stderr);
	assert.match(result.stderr, /Ran 15 tests in /);
	assert.match(result.stderr, /\nOK\s*$/);
	assert.doesNotMatch(result.stderr, /skipped=/);
});

if (failures > 0) {
	console.error(`\n${failures} Homebrew cask check(s) failed.`);
	process.exit(1);
}
console.log('\nAll Homebrew cask checks passed.');
