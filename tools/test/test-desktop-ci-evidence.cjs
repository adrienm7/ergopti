// tools/test/test-desktop-ci-evidence.cjs

/**
 * ==============================================================================
 * MODULE: Desktop CI Verdict Regression Tests
 * DESCRIPTION:
 * Rejects missing or failed launch observations, incorrect commits and incomplete
 * matrices. Pins the parallel shared-core gate and the published-byte boundary.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { verify, recordMac, recordWindows } = require('./desktop-ci-evidence.cjs');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const timerContract = require('../diagnostics/hs_delayed_timer_contract.json');
const karabinerContract = require('../diagnostics/hs_karabiner_config_contract.json');
const pipeline = require('./ci-pipeline.cjs');

/** Returns the measured native admission summary that every clean launch owes. */
function timerSummary() {
	return {
		schema_version: 1,
		contract: timerContract.contract,
		runtime: 'native Hammerspoon',
		version: timerContract.runtime_version,
		complete: true,
		checks:
			Object.keys(timerContract.boolean_observations).length +
			Object.keys(timerContract.remaining_limits).length +
			Object.keys(timerContract.deliveries).length,
		nonce: 'a'.repeat(32),
		pid: 42,
		executable:
			'/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon',
		preference_restored: true
	};
}

/** Declares the complete private-file native qualification admission receipt. */
function karabinerSummary() {
	return {
		...karabinerContract.summary_fixed,
		version: '1.1.1',
		nonce: 'a'.repeat(32),
		pid: 42,
		executable:
			'/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon',
		variant_count: 8,
		manipulator_count: 480,
		preference_restored: true
	};
}

/** Returns the parent observation and the receipt from the exact compiled child. */
function windowsStartup() {
	const nonce = 'c'.repeat(32);
	const executable = 'C:\\private\\ErgoptiPlus.exe';
	return {
		nonce,
		pid: 42,
		executable,
		launched_sha256: 'b'.repeat(64),
		exit_code: 0,
		log_files: 1,
		logged_errors: [],
		receipt: {
			schema_version: 1,
			nonce,
			pid: 42,
			executable,
			compiled: true,
			build_commit: 'a'.repeat(40),
			bundle_identity: '0.0.0-dev\n' + 'a'.repeat(40),
			phase: 'ready',
			driver_ready: true,
			menu_ready: true,
			logs_flushed: true
		}
	};
}

for (const platform of ['windows', 'macos']) {
	for (const release of [false, true]) {
		const jobs =
			platform === 'windows'
				? ['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows']
				: ['test-hs', 'e2e-hs', 'package-macos', 'launch'];
		const runners =
			platform === 'windows'
				? ['windows-latest']
				: release
					? ['macos-15', 'macos-15-intel']
					: ['macos-15'];
		const scenarios =
			platform === 'windows' ? ['startup'] : ['clean', 'upgraded', 'karabiner_config'];
		const state = {
			platform,
			release,
			scenarios,
			sha: 'a'.repeat(40),
			needs: Object.fromEntries(jobs.map((job) => [job, { result: 'success' }])),
			evidence: runners.flatMap((runner) =>
				scenarios.map((scenario) => ({
					schema_version: 1,
					platform,
					runner,
					scenario,
					sha: 'a'.repeat(40),
					package_sha256: 'b'.repeat(64),
					failures: [],
					marker_seen: true,
					crashed_early: false,
					...(platform === 'windows' ? { native_startup: windowsStartup() } : {}),
					...(platform === 'macos' && scenario === 'clean'
						? { native_delayed_timer: timerSummary() }
						: {}),
					...(platform === 'macos' && scenario === 'karabiner_config'
						? { native_karabiner_config: karabinerSummary() }
						: {})
				}))
			)
		};
		verify(state);
		const rejects = (mutate) => {
			const changed = structuredClone(state);
			mutate(changed);
			assert.throws(() => verify(changed));
		};
		for (const job of jobs) {
			for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
				rejects((value) => {
					value.needs[job].result = status;
				});
			}
			rejects((value) => {
				delete value.needs[job];
			});
		}
		rejects((value) => value.evidence.pop());
		rejects((value) => value.evidence.push(value.evidence[0]));
		rejects((value) => {
			value.evidence[0].sha = 'c'.repeat(40);
		});
		rejects((value) => {
			value.evidence[0].failures = ['crash'];
		});
		rejects((value) => {
			value.evidence[0].scenario = 'unknown';
		});
		rejects((value) => {
			value.evidence[0].package_sha256 = '';
		});
		if (platform === 'windows') {
			rejects((value) => {
				delete value.evidence[0].native_startup;
			});
			for (const [field, replacement] of [
				['exit_code', 1],
				['exit_code', null],
				['log_files', 0],
				['logged_errors', ['ERROR during boot']],
				['nonce', 'd'.repeat(32)],
				['pid', 43],
				['executable', 'C:\\foreign\\ErgoptiPlus.exe'],
				['launched_sha256', 'd'.repeat(64)]
			])
				rejects((value) => {
					value.evidence[0].native_startup[field] = replacement;
				});
			for (const [field, replacement] of [
				['compiled', false],
				['build_commit', 'd'.repeat(40)],
				['bundle_identity', 'old\n' + 'd'.repeat(40)],
				['phase', 'input-init'],
				['driver_ready', false],
				['menu_ready', false],
				['logs_flushed', false],
				['nonce', 'd'.repeat(32)],
				['pid', 43],
				['executable', 'C:\\foreign\\ErgoptiPlus.exe']
			])
				rejects((value) => {
					value.evidence[0].native_startup.receipt[field] = replacement;
				});
			for (const field of Object.keys(windowsStartup().receipt))
				rejects((value) => {
					delete value.evidence[0].native_startup.receipt[field];
				});
			rejects((value) => {
				value.evidence[0].marker_seen = false;
			});
			rejects((value) => {
				value.evidence[0].crashed_early = true;
			});
		} else {
			for (const [field, replacement] of [
				['complete', false],
				['variant_count', 7],
				['manipulator_count', 0],
				['publication_scope', 'runtime-active'],
				['lease_initialized', true],
				['private_source_restored', false],
				['codec_independent', false],
				['native_equal_values_shared', false],
				['preference_restored', false],
				['nonce', ''],
				['pid', 0],
				['executable', '/foreign/Hammerspoon']
			])
				rejects((value) => {
					value.evidence.find(
						(record) => record.scenario === 'karabiner_config'
					).native_karabiner_config[field] = replacement;
				});
			for (const field of Object.keys(karabinerSummary()))
				rejects((value) => {
					delete value.evidence.find((record) => record.scenario === 'karabiner_config')
						.native_karabiner_config[field];
				});
			rejects((value) => {
				delete value.evidence.find((record) => record.scenario === 'karabiner_config')
					.native_karabiner_config;
			});
			for (const [field, replacement] of [
				['complete', false],
				['checks', 0],
				['preference_restored', false],
				['nonce', ''],
				['pid', 0],
				['version', '0.0.0'],
				['runtime', 'stubbed Hammerspoon'],
				['executable', '/other/Hammerspoon']
			])
				rejects((value) => {
					value.evidence[0].native_delayed_timer[field] = replacement;
				});
			for (const field of Object.keys(timerSummary())) {
				rejects((value) => {
					delete value.evidence[0].native_delayed_timer[field];
				});
			}
			rejects((value) => {
				delete value.evidence[0].native_delayed_timer;
			});
			rejects((value) => {
				value.evidence[0].package_sha256 = 'c'.repeat(64);
			});
		}
	}
}

const timerEvidenceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-timer-evidence-'));
try {
	const resultFile = path.join(timerEvidenceRoot, 'result.json');
	const archive = path.join(timerEvidenceRoot, 'archive.zip');
	const output = path.join(timerEvidenceRoot, 'evidence.json');
	fs.writeFileSync(archive, 'owned archive fixture');
	for (const summary of [undefined, {}, { ...timerSummary(), complete: false }]) {
		fs.writeFileSync(
			resultFile,
			JSON.stringify({ scenario: 'clean', failures: [], native_delayed_timer: summary })
		);
		assert.throws(
			() => recordMac(resultFile, archive, output),
			'recording may not admit an incomplete native probe'
		);
		assert.equal(fs.existsSync(output), false, 'a refused record must publish no evidence');
	}
	fs.writeFileSync(
		resultFile,
		JSON.stringify({ scenario: 'clean', failures: [], native_delayed_timer: timerSummary() })
	);
	recordMac(resultFile, archive, output);
	assert.deepEqual(
		JSON.parse(fs.readFileSync(output, 'utf8')).native_delayed_timer,
		timerSummary(),
		'the aggregate judge must retain the exact admitted native summary'
	);
} finally {
	fs.rmSync(timerEvidenceRoot, { recursive: true, force: true });
}

const karabinerEvidenceRoot = fs.mkdtempSync(
	path.join(os.tmpdir(), 'ergopti-native-karabiner-evidence-')
);
try {
	const resultFile = path.join(karabinerEvidenceRoot, 'result.json');
	const archive = path.join(karabinerEvidenceRoot, 'archive.zip');
	const output = path.join(karabinerEvidenceRoot, 'evidence.json');
	fs.writeFileSync(archive, 'owned archive fixture');
	for (const summary of [undefined, {}, { ...karabinerSummary(), lease_initialized: true }]) {
		fs.writeFileSync(
			resultFile,
			JSON.stringify({
				scenario: 'karabiner_config',
				failures: [],
				native_karabiner_config: summary
			})
		);
		assert.throws(
			() => recordMac(resultFile, archive, output),
			'native graph qualification must precede evidence publication'
		);
		assert.equal(
			fs.existsSync(output),
			false,
			'refused native graph evidence must never be published'
		);
	}
	fs.writeFileSync(
		resultFile,
		JSON.stringify({
			scenario: 'karabiner_config',
			failures: [],
			native_karabiner_config: karabinerSummary()
		})
	);
	recordMac(resultFile, archive, output);
	assert.deepEqual(
		JSON.parse(fs.readFileSync(output, 'utf8')).native_karabiner_config,
		karabinerSummary()
	);
} finally {
	fs.rmSync(karabinerEvidenceRoot, { recursive: true, force: true });
}

const startupEvidenceRoot = fs.mkdtempSync(
	path.join(os.tmpdir(), 'ergopti-native-startup-evidence-')
);
const savedGithubSha = process.env.GITHUB_SHA;
try {
	process.env.GITHUB_SHA = 'a'.repeat(40);
	const executable = path.join(startupEvidenceRoot, 'ErgoptiPlus.exe');
	const bytes = 'owned packaged byte fixture';
	fs.writeFileSync(executable, bytes);
	const native = windowsStartup();
	native.executable = executable;
	native.receipt.executable = executable;
	native.launched_sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
	const resultFile = path.join(startupEvidenceRoot, 'observation.json');
	const output = path.join(startupEvidenceRoot, 'evidence.json');
	const publishObservation = (observation) =>
		fs.writeFileSync(
			resultFile,
			JSON.stringify({
				marker_seen: true,
				crashed_early: false,
				marker_seconds: 1,
				native_startup: observation
			})
		);
	const foreignReceipt = structuredClone(native);
	foreignReceipt.receipt.executable = path.join(
		startupEvidenceRoot,
		'foreign sibling',
		'ErgoptiPlus.exe'
	);
	publishObservation(foreignReceipt);
	assert.throws(
		() => recordWindows(resultFile, executable, output),
		/Readiness came from another executable/
	);
	assert.equal(
		fs.existsSync(output),
		false,
		'a foreign same-basename receipt must publish no evidence'
	);
	const foreignPath = structuredClone(native);
	foreignPath.executable = path.join(startupEvidenceRoot, 'another', 'ErgoptiPlus.exe');
	foreignPath.receipt.executable = foreignPath.executable;
	publishObservation(foreignPath);
	assert.throws(() => recordWindows(resultFile, executable, output), /not the launched executable/);
	assert.equal(fs.existsSync(output), false, 'a path substitution must publish no evidence');
	publishObservation(native);
	fs.writeFileSync(executable, bytes + ' changed after launch');
	assert.throws(() => recordWindows(resultFile, executable, output), /Package bytes differ/);
	assert.equal(fs.existsSync(output), false, 'changed package bytes must publish no evidence');
	fs.writeFileSync(executable, bytes);
	recordWindows(resultFile, executable, output);
	assert.equal(
		JSON.parse(fs.readFileSync(output, 'utf8')).package_sha256,
		native.launched_sha256,
		'the successful record carries the exact launched bytes'
	);
} finally {
	if (savedGithubSha === undefined) delete process.env.GITHUB_SHA;
	else process.env.GITHUB_SHA = savedGithubSha;
	fs.rmSync(startupEvidenceRoot, { recursive: true, force: true });
}

/** Pins a fresh shallow checkout and the exact independently gated core suites. */
function checkCore(body) {
	assert.deepEqual(pipeline.needsOf(body), ['validate']);
	assert.equal(pipeline.field(body, 'if'), null);
	assert.match(body, /^      fail-fast: false$/m);
	assert.ok(
		body.includes(
			`        suite: \${{ fromJSON(github.ref == 'refs/heads/main' && '["js","properties","mutation"]' || '["js","properties"]') }}`
		)
	);
	const steps = pipeline.steps(body);
	const checkout = steps.filter(
		(step) => pipeline.stepField(step.body, 'uses') === 'actions/checkout@v4'
	);
	assert.equal(checkout.length, 1);
	assert.equal(pipeline.stepField(checkout[0].body, 'with'), null);
	assert.doesNotMatch(body, /\bgit (?:fetch|pull|clone)\b/);
	assert.equal(
		pipeline.stepField(pipeline.step(body, 'Run shared validation suite'), 'run'),
		'npm run test:${{ matrix.suite }}'
	);
	assert.ok(steps.some((step) => pipeline.stepField(step.body, 'run') === 'npm ci'));
	assert.match(body, /sudo apt-get install -y lua5\.4 libxml2-utils/);
	for (const [name, command] of [
		['Install shared UI browsers', 'npx playwright install --with-deps chromium webkit'],
		['Test shared layer editor rendering', 'npm run test:browser:layer-editor']
	]) {
		const step = pipeline.step(body, name);
		assert.equal(pipeline.stepField(step, 'if'), "matrix.suite == 'js'");
		assert.equal(pipeline.stepField(step, 'run'), command);
		assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	}
}

const core = pipeline.job('core');
checkCore(core);
for (const [from, to] of [
	['refs/heads/main', 'refs/heads/never'],
	['"js","properties","mutation"', '"js","properties"'],
	['"js","properties"', '"js"'],
	['fail-fast: false', 'fail-fast: true'],
	['needs: [validate]', 'needs: [macos]'],
	['run: npm run test:${{ matrix.suite }}', 'run: npm run test:${{ matrix.suite }} -- --only lint'],
	['run: npm run test:browser:layer-editor', 'run: echo skipped browser gate'],
	['npx playwright install --with-deps chromium webkit', 'npx playwright install chromium'],
	["if: matrix.suite == 'js'", "if: matrix.suite == 'never'"],
	[
		'- uses: actions/checkout@v4',
		'- uses: actions/checkout@v4\n        with:\n          fetch-depth: 0'
	]
])
	assert.throws(() => checkCore(core.replace(from, to)), from);

for (const [job, platform] of [
	['macos-ok', 'macos'],
	['windows-ok', 'windows']
]) {
	assert.ok(
		pipeline.job(job).includes(`node tools/test/desktop-ci-evidence.cjs verify ${platform}`)
	);
}
for (const [job, name] of [
	['launch', 'Retain launch evidence'],
	['launch-windows', 'Upload mandatory launch evidence']
]) {
	const upload = pipeline.step(pipeline.job(job), name);
	assert.match(upload, /overwrite: true/);
	assert.doesNotMatch(upload, /github\.run_attempt/);
}
const launch = pipeline.job('launch-windows');
/** Requires native refusal probes to run on Windows before package admission. */
function checkWindowsAdmission(body) {
	const admission = pipeline.step(body, 'Test native compiled startup admission');
	assert.equal(
		pipeline.stepField(admission, 'run'),
		'node tools/test/test-desktop-ci-evidence.cjs'
	);
	assert.equal(pipeline.stepField(admission, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(admission, 'if'), null);
	assert.equal(pipeline.stepField(admission, 'continue-on-error'), null);
	assert.ok(body.indexOf(admission) < body.indexOf('name: Smoke test compiled ErgoptiPlus.exe'));
}
checkWindowsAdmission(launch);

/** A fresh-clone boot must be an unconditional native Windows gate. */
function checkFreshSourceBoot(body) {
	const step = pipeline.step(body, 'Test fresh Git clone bootstrap and warm startup');
	assert.equal(pipeline.stepField(step, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(step, 'if'), null);
	assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	const run = pipeline.runOf(step).join('\n');
	assert.match(run, /\$env:ERGOPTI_AHK_EXE = \$ahk/);
	assert.match(run, /node tools\/test\/test-ahk-fresh-clone-startup\.cjs/);
	assert.match(run, /if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}/);
}
const sourceBoot = pipeline.job('test-ahk');
checkFreshSourceBoot(sourceBoot);

/** Requires bounded refusal facts without changing source admission authority. */
function checkSourceOwnerEvidence(source) {
	const body = source.match(/^function Get-SourceOwnerEvidence \{([\s\S]*?)^\}/m)?.[1];
	assert.ok(body, 'the actual native source-owner evidence producer must exist');
	const record = body.match(/return \[ordered\]@\{([\s\S]*?)\n {4}\}/)?.[1];
	assert.ok(record, 'the native evidence must have one closed record');
	assert.deepEqual(
		[...record.matchAll(/^ {8}([a-z_]+) =/gm)].map((match) => match[1]),
		[
			'schema_version',
			'native_present',
			'image_present',
			'image_exact',
			'command_present',
			'script_argument_exact'
		],
		'no process command, pathname or unrelated identity belongs in refusal evidence'
	);
	for (const predicate of [
		'schema_version = 1',
		'native_present = [bool]$nativePresent',
		'image_present = [bool]$imagePresent',
		'image_exact = [bool]($imagePresent -and $Native.ExecutablePath -ieq $Interpreter)',
		'command_present = [bool]$commandPresent',
		'script_argument_exact = [bool]($commandPresent -and\n' +
			'            [SourceBootProcess]::HasExactEntry($Native.CommandLine, $Entry))'
	])
		assert.ok(record.includes(predicate), 'the actual predicate must produce ' + predicate);
	assert.doesNotMatch(body, /OpenProcess|TerminateProcess|Get-AdmittedSourceHandle/);
	const refusal = source.match(
		/if \(\$null -eq \$native -or \$native\.ExecutablePath -ine \$Ahk -or\n {8}!\[SourceBootProcess\]::HasExactEntry\(\$native\.CommandLine, \$Entry\)\) \{([\s\S]*?)\n {4}\}/
	)?.[1];
	assert.ok(refusal, 'exact CIM image and first-script-argument admission must remain unchanged');
	assert.match(
		refusal,
		/Get-SourceOwnerEvidence -Native \$native -Interpreter \$Ahk -Entry \$Entry/
	);
	assert.match(refusal, /throw \('[^']*source-owner-evidence=' \+/);
	assert.match(refusal, /\$ownerEvidence \| ConvertTo-Json -Compress/);
}
const sourceObserver = fs.readFileSync(
	path.join(__dirname, 'fixtures/observe_ahk_source_boot.ps1'),
	'utf8'
);
/** Requires native path normalization before any source process starts. */
function checkCanonicalSourceEntry(source) {
	const canonical = source.match(
		/public static string CanonicalEntry\(string entry\) \{([\s\S]*?)^    \}/m
	)?.[1];
	assert.ok(canonical, 'the existing-file native canonical constructor must exist');
	for (const required of [
		'!Path.IsPathFullyQualified(entry) || !File.Exists(entry)',
		'string full = Path.GetFullPath(entry);',
		'GetLongPathName(full, canonical, (uint)canonical.Capacity)',
		'size == 0 || size >= canonical.Capacity || !File.Exists(canonical.ToString())',
		'return canonical.ToString();'
	])
		assert.ok(
			canonical.includes(required),
			'native canonical construction must retain ' + required
		);
	const normalize = '$Entry = [SourceBootProcess]::CanonicalEntry($Entry)';
	assert.equal(source.split(normalize).length - 1, 1, 'normalize the selected entry exactly once');
	assert.ok(source.indexOf('if ($LibraryOnly) { return }') < source.indexOf(normalize));
	assert.ok(source.indexOf(normalize) < source.indexOf('$initial = Start-Process'));
	assert.ok(source.includes('entry = $requestedEntry;'), 'observations preserve caller spelling');
	assert.ok(
		source.includes('[SourceBootProcess]::HasExactEntry($native.CommandLine, $requestedEntry)')
	);
	assert.ok(source.includes('[SourceBootProcess]::HasExactEntry($native.CommandLine, $Entry)'));
	assert.doesNotMatch(canonical, /GetFileInformationByHandle|Contains|EndsWith|GetFileName/);
}
checkCanonicalSourceEntry(sourceObserver);
for (const [from, to] of [
	['$Entry = [SourceBootProcess]::CanonicalEntry($Entry)', '$Entry = $Entry'],
	[
		'GetLongPathName(full, canonical, (uint)canonical.Capacity)',
		'GetLongPathName(entry, canonical, (uint)canonical.Capacity)'
	],
	['!Path.IsPathFullyQualified(entry) || !File.Exists(entry)', '!Path.IsPathFullyQualified(entry)'],
	['entry = $requestedEntry;', 'entry = $Entry;']
]) {
	assert.ok(
		sourceObserver.includes(from),
		'native normalization mutation must modify actual source'
	);
	assert.throws(() => checkCanonicalSourceEntry(sourceObserver.replaceAll(from, to)), from);
}
checkSourceOwnerEvidence(sourceObserver);
for (const [from, to] of [
	['function Get-SourceOwnerEvidence {', 'function MissingEvidenceProducer {'],
	['native_present = [bool]$nativePresent', 'raw_command = $Native.CommandLine'],
	[
		'image_exact = [bool]($imagePresent -and $Native.ExecutablePath -ieq $Interpreter)',
		'image_exact = [bool]$nativePresent'
	],
	[
		'[SourceBootProcess]::HasExactEntry($Native.CommandLine, $Entry))',
		'[SourceBootProcess]::HasExactEntry($Native.CommandLine, $Interpreter))'
	],
	['($ownerEvidence | ConvertTo-Json -Compress)', '($native | ConvertTo-Json -Compress)']
]) {
	assert.ok(
		sourceObserver.includes(from),
		'the source-owner mutation must modify an actual producer'
	);
	assert.throws(() => checkSourceOwnerEvidence(sourceObserver.replaceAll(from, to)), from);
}
for (const [from, to] of [
	['node tools/test/test-ahk-fresh-clone-startup.cjs', 'echo skipped source boot'],
	['$env:ERGOPTI_AHK_EXE = $ahk', '$env:UNUSED_AHK_EXE = $ahk'],
	[
		'- name: Test fresh Git clone bootstrap and warm startup',
		'- name: Test fresh Git clone bootstrap and warm startup\n        if: false'
	],
	[
		'- name: Test fresh Git clone bootstrap and warm startup',
		'- name: Test fresh Git clone bootstrap and warm startup\n        continue-on-error: true'
	]
])
	assert.throws(() => checkFreshSourceBoot(sourceBoot.replaceAll(from, to)), from);
for (const replacement of [
	'run: echo skipped native probes',
	'if: false\n        run: node tools/test/test-desktop-ci-evidence.cjs',
	'continue-on-error: true\n        run: node tools/test/test-desktop-ci-evidence.cjs'
])
	assert.throws(() =>
		checkWindowsAdmission(
			launch.replace('run: node tools/test/test-desktop-ci-evidence.cjs', replacement)
		)
	);
assert.match(launch, /name: assets-windows/);
assert.match(launch, /\$env:RUNNER_TEMP\\package\\ergopti_plus\\windows\\ErgoptiPlus\.exe/);
assert.doesNotMatch(launch, /build_static_bundle|Ahk2Exe/);
const profile = "${{ inputs.release && 'release' || 'ci' }}";
assert.ok(
	pipeline
		.step(pipeline.job('launch'), 'Retain launch evidence')
		.includes(`name: launch-gate-${profile}-`)
);
assert.ok(pipeline.job('macos-ok').includes(`pattern: launch-gate-${profile}-*`));
console.log(
	'[OK] Desktop verdicts reject incomplete launches; shared core gates run independently.'
);

/** The native fixture must report its own canonical image without relaxing admission. */
function checkCompiledFixtureNormalization(source, runtime) {
	for (const token of [
		'if (args.Length != 0 && args[0].StartsWith("--", StringComparison.Ordinal))',
		'CanonicalExistingFile(Process.GetCurrentProcess().MainModule.FileName)',
		'{ "executable", OwnExecutable() }',
		'!Path.IsPathRooted(path)',
		'!String.Equals(Path.GetFullPath(path), path, StringComparison.OrdinalIgnoreCase)',
		'!File.Exists(path) || Directory.Exists(path)',
		'GetLongPathNameW(path, result, (uint)result.Capacity)',
		'size == 0 || size >= result.Capacity || size != result.Length',
		'!File.Exists(canonical) || Directory.Exists(canonical)',
		'SamePhysicalFile(alias, expected)',
		'!SamePhysicalFile(expected, foreign)',
		'GetFileInformationByHandle(first, out a)',
		'GetFileInformationByHandle(second, out b)',
		'a.Volume == b.Volume && a.IndexHigh == b.IndexHigh && a.IndexLow == b.IndexLow',
		'SamePhysicalFile(module, canonical)',
		'(bool)receipt["same_file"] && (bool)receipt["alias_observed"]',
		'String.Equals((string)receipt["canonical"], expected, StringComparison.OrdinalIgnoreCase)',
		'using (var child = Process.Start(start)) {\n            try {\n                var handle = child.Handle;',
		'if (!child.HasExited)',
		'child.Kill();',
		'child.WaitForExit(5000)',
		'receipt["executable"] = CanonicalExistingFile(foreign);'
	])
		assert.ok(source.includes(token), 'the native own-image contract must retain ' + token);
	assert.doesNotMatch(
		source,
		/IsPathFullyQualified|GetEnvironmentVariable\("(?:EXPECTED|ERGOPTI_EXPECTED)/
	);
	for (const scenario of [
		'ready',
		'marker-only',
		'early-exit',
		'receipt-then-error-exit',
		'missing-logs',
		'logged-error',
		'foreign-nonce',
		'foreign-executable'
	])
		assert.ok(runtime.includes("'" + scenario + "'"), 'native admission must execute ' + scenario);
	for (const token of [
		'script.includes(\'-ArgumentList "/ErrorStdOut"\')',
		' --identity-controls ',
		' --unknown; exit $LASTEXITCODE',
		'assert.equal(identity.status, 0',
		"assert.equal(identity.stderr, ''",
		'assert.notEqual(unknownMode.status, 0',
		'assert.notEqual(result.status, 0',
		'failure.failures.length > 0',
		'assert.equal(result.status, 0',
		'receipt.compiled, true',
		'native_startup.exit_code, 0'
	])
		assert.ok(
			runtime.includes(token),
			'native compilation/admission controls must retain ' + token
		);
}
const compiledFixture = fs.readFileSync(
	path.join(__dirname, 'fixtures/windows_launch_child.cs'),
	'utf8'
);
const compiledRuntime = fs.readFileSync(
	path.join(__dirname, 'support/windows-launch-runtime.cjs'),
	'utf8'
);
checkCompiledFixtureNormalization(compiledFixture, compiledRuntime);
for (const [from, to] of [
	[
		'if (args.Length != 0 && args[0].StartsWith("--", StringComparison.Ordinal))',
		'if (args.Length != 0)'
	],
	[
		'CanonicalExistingFile(Process.GetCurrentProcess().MainModule.FileName)',
		'Process.GetCurrentProcess().MainModule.FileName'
	],
	['!Path.IsPathRooted(path)', 'false'],
	['size == 0 || size >= result.Capacity || size != result.Length', 'size == 0'],
	['SamePhysicalFile(alias, expected)', 'true'],
	['!SamePhysicalFile(expected, foreign)', 'true'],
	['(bool)receipt["same_file"] && (bool)receipt["alias_observed"]', '(bool)receipt["same_file"]'],
	[
		'using (var child = Process.Start(start)) {\n            try {\n                var handle = child.Handle;',
		'using (var child = Process.Start(start)) {\n            var handle = child.Handle;\n            try {'
	],
	['child.WaitForExit(5000)', 'true']
]) {
	assert.ok(compiledFixture.includes(from), 'the mutation must alter the actual native producer');
	assert.throws(
		() => checkCompiledFixtureNormalization(compiledFixture.replaceAll(from, to), compiledRuntime),
		from
	);
}
for (const [from, to] of [
	["'foreign-executable'", "'ready'"],
	[' --identity-controls ', ' --unused '],
	["assert.equal(identity.stderr, ''", "assert.ok(identity.stderr === ''"]
]) {
	assert.ok(compiledRuntime.includes(from), 'the mutation must alter the actual native control');
	assert.throws(
		() => checkCompiledFixtureNormalization(compiledFixture, compiledRuntime.replaceAll(from, to)),
		from
	);
}
require('./support/windows-launch-runtime.cjs')();

require('./support/windows-startup-log-runtime.cjs')();
