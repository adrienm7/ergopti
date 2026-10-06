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
				: ['test-hs', 'e2e-hs', 'package-macos', 'launch', 'tooltip-canvas'];
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
	assert.match(
		body,
		/sudo python3 "\$GITHUB_WORKSPACE\/tools\/ci\/ubuntu_apt\.py" -y lua5\.4 lua-luv libxml2-utils/
	);
	for (const [name, command] of [
		['Install shared UI browsers', 'node tools/ci/install-playwright.cjs chromium webkit'],
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
	['node tools/ci/install-playwright.cjs chromium webkit', 'npx playwright install chromium'],
	["if: matrix.suite == 'js'", "if: matrix.suite == 'never'"],
	[
		'- uses: actions/checkout@v4',
		'- uses: actions/checkout@v4\n        with:\n          fetch-depth: 0'
	]
]) {
	const changed = core.replace(from, to);
	assert.notEqual(changed, core, from + ' must actually mutate the shared gate');
	assert.throws(() => checkCore(changed), from);
}

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
/** Requires every isolated LLM runner, including deferred pointer dismissal, to gate CI. */
function checkIsolatedLlmSuites(body) {
	const step = pipeline.step(body, 'Run isolated AHK LLM suites');
	assert.equal(pipeline.stepField(step, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(step, 'if'), null);
	assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	const lines = pipeline.runOf(step);
	const block = pipeline.scriptBlock(lines, 'foreach ($name in @(');
	assert.match(block[0], /^foreach /, 'the suite loop must execute outside conditional wrappers');
	const names = [...block[0].matchAll(/"(run_[a-z_]+\.ahk)"/g)].map((match) => match[1]);
	assert.equal(new Set(names).size, names.length, 'each isolated suite runs once');
	for (const name of [
		'run_llm_model_browser.ahk',
		'run_llm_model_menu_disabled.ahk',
		'run_llm_pointer_dismiss.ahk'
	])
		assert.ok(names.includes(name), name + ' must be a mandatory native suite');
	const nativeBody = block.filter((line) => !line.trimStart().startsWith('#')).join('\n');
	assert.doesNotMatch(
		nativeBody,
		/\b(?:continue|break|return)\b/,
		'selected suites cannot be skipped'
	);
	assert.match(nativeBody, /\$runner = Join-Path \$tests \$name/);
	assert.match(
		nativeBody,
		/\$proc = Start-Process -FilePath \$ahk -ArgumentList @\("\/ErrorStdOut", \$runner\)/
	);
	assert.match(nativeBody, /-Wait -PassThru/);
	assert.match(nativeBody, /if \(\$proc\.ExitCode -ne 0\) \{ \$failed \+= 1 \}/);
	assert.match(nativeBody, /validate-ahk-suite-manifest\.cjs/);
	assert.match(nativeBody, /--input \$env:ERGOPTI_AHK_RESULTS_FILE --json \$manifestFile/);
	assert.match(nativeBody, /if \(\$LASTEXITCODE -ne 0\) \{ \$failed \+= 1 \}/);
	assert.ok(pipeline.blockExits(pipeline.scriptBlock(lines, 'if ($failed -gt 0) {'), '1'));
}
checkIsolatedLlmSuites(sourceBoot);
for (const [from, to] of [
	[', "run_llm_pointer_dismiss.ahk"', ''],
	['- name: Run isolated AHK LLM suites', '- name: Run isolated AHK LLM suites\n        if: false'],
	[
		'- name: Run isolated AHK LLM suites',
		'- name: Run isolated AHK LLM suites\n        continue-on-error: true'
	],
	['$runner = Join-Path $tests $name', '$runner = Join-Path $tests "run_llm_model_browser.ahk"'],
	[
		'$runner = Join-Path $tests $name',
		'if ($name -eq "run_llm_pointer_dismiss.ahk") { continue }\n              $runner = Join-Path $tests $name'
	],
	['$proc = Start-Process -FilePath $ahk', '$proc = Write-Output -FilePath $ahk'],
	['if ($proc.ExitCode -ne 0) { $failed += 1 }', 'if ($proc.ExitCode -ne 0) { $failed += 0 }'],
	[
		'--input $env:ERGOPTI_AHK_RESULTS_FILE --json $manifestFile',
		'--input $env:UNUSED_RESULTS_FILE --json $manifestFile'
	],
	['if ($LASTEXITCODE -ne 0) { $failed += 1 }', 'if ($LASTEXITCODE -ne 0) { $failed += 0 }'],
	[
		'if ($failed -gt 0) { Write-Error "$failed isolated LLM suite(s) failed."; exit 1 }',
		'if ($failed -gt 0) { Write-Error "$failed isolated LLM suite(s) failed."; exit 0 }'
	]
]) {
	const originalStep = pipeline.step(sourceBoot, 'Run isolated AHK LLM suites');
	const mutatedStep = originalStep.replace(from, to);
	assert.notEqual(
		mutatedStep,
		originalStep,
		'the isolated-suite mutant must change its real subject'
	);
	const mutated = sourceBoot.replace(originalStep, mutatedStep);
	assert.throws(() => checkIsolatedLlmSuites(mutated), from);
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

/** Requires the actual zero-status assertion, excluding quoted and commented decoys. */
function checkNativeIdentityStatusAssertion(runtime) {
	const code = runtime.replace(
		/\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|\/(?![/*])(?:\\[^\r\n]|\[(?:\\[^\r\n]|[^\]\\])*\]|[^/\\\r\n])+\/[dgimsuvy]*|'(?:\\[\s\S]|[^'\\])*'|"(?:\\[\s\S]|[^"\\])*"|`(?:\\[\s\S]|[^`\\])*`/g,
		(literal) => literal.replace(/[^\r\n]/g, ' ')
	);
	assert.match(
		code,
		/^[\t ]*assert\s*\.\s*equal\s*\(\s*identity\s*\.\s*status\s*,\s*0\s*[,)]/m,
		'the native own-image status must be asserted equal to integer zero'
	);
}

for (const actual of [
	"assert.equal(identity.status, 0, 'native own-image status');",
	"assert.equal(\n\tidentity.status,\n\t0,\n\t'native own-image status'\n);"
])
	checkNativeIdentityStatusAssertion(actual);
for (const decoy of [
	'assert.equal(result.status, 0);',
	'assert.equal(identity.status, 1);',
	'assert.equal(identity.status, 0.5);',
	"assert.equal(identity.status, '0');",
	'assert.ok(identity.status === 0);',
	'assert.notEqual(identity.status, 0);',
	'other.assert.equal(identity.status, 0);',
	'// assert.equal(identity.status, 0);',
	'/*\nassert.equal(identity.status, 0);\n*/',
	"const text = 'assert.equal(identity.status, 0);';",
	'const text = `\nassert.equal(identity.status, 0);\n`;'
])
	assert.throws(() => checkNativeIdentityStatusAssertion(decoy), decoy);

/** The native fixture must report its own canonical image without relaxing admission. */
function checkCompiledFixtureNormalization(source, runtime) {
	checkNativeIdentityStatusAssertion(runtime);
	for (const token of [
		'if (args.Length != 0 && args[0].StartsWith("--", StringComparison.Ordinal))',
		'CanonicalExistingFile(Process.GetCurrentProcess().MainModule.FileName)',
		'{ "executable", OwnExecutable() }',
		'!Path.IsPathRooted(path)',
		'Path.GetPathRoot(path).Length < 3',
		'piece == "." || piece == ".."',
		'!String.Equals(Path.GetFullPath(path), canonical, StringComparison.OrdinalIgnoreCase)',
		'!SamePhysicalFile(path, canonical)',
		'!File.Exists(path) || Directory.Exists(path)',
		'GetLongPathNameW(path, result, (uint)result.Capacity)',
		'size == 0 || size >= result.Capacity || size != result.Length',
		'!File.Exists(canonical) || Directory.Exists(canonical)',
		'SamePhysicalFile(alias, expected)',
		'shortSize > 0 && shortSize < shortBuffer.Capacity && shortSize == shortBuffer.Length',
		'var launchPath = forceNoShortAlias ? expected : alias;',
		'var aliasObserved = !String.Equals(launchPath, expected, StringComparison.OrdinalIgnoreCase);',
		'new ProcessStartInfo(launchPath, "--own-image")',
		'SamePhysicalFile(invalid, expected)',
		'Environment.CurrentDirectory = priorDirectory;',
		'new string[] { driveRelative, rootRelative, dotted, parentDotted }',
		'An existing malformed native module spelling was admitted.',
		'!SamePhysicalFile(expected, foreign)',
		'GetFileInformationByHandle(first, out a)',
		'GetFileInformationByHandle(second, out b)',
		'a.Volume == b.Volume && a.IndexHigh == b.IndexHigh && a.IndexLow == b.IndexLow',
		'SamePhysicalFile(module, canonical)',
		'(bool)receipt["same_file"] && (bool)receipt["alias_observed"] == aliasObserved',
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
	assert.doesNotMatch(
		source,
		/Path\.GetFullPath\(path\), path,/,
		'Framework alias expansion cannot be refused before native canonical admission'
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
		' --identity-controls-no-short-alias ',
		'assert.equal(noShortAlias.status, 0',
		"assert.equal(noShortAlias.stderr, ''",
		"assert.equal(noShortAlias.stdout.trim(), identityMessage + 'unavailable (forced control).')",
		' --unknown; exit $LASTEXITCODE',
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
	['Path.GetPathRoot(path).Length < 3', 'false'],
	['piece == "." || piece == ".."', 'false'],
	[
		'!String.Equals(Path.GetFullPath(path), canonical, StringComparison.OrdinalIgnoreCase)',
		'false'
	],
	['!SamePhysicalFile(path, canonical)', 'false'],
	['SamePhysicalFile(invalid, expected)', 'true'],
	['Environment.CurrentDirectory = priorDirectory;', '// restoration omitted'],
	['size == 0 || size >= result.Capacity || size != result.Length', 'size == 0'],
	['SamePhysicalFile(alias, expected)', 'true'],
	['shortSize > 0 && shortSize < shortBuffer.Capacity && shortSize == shortBuffer.Length', 'true'],
	['var launchPath = forceNoShortAlias ? expected : alias;', 'var launchPath = alias;'],
	[
		'var aliasObserved = !String.Equals(launchPath, expected, StringComparison.OrdinalIgnoreCase);',
		'var aliasObserved = true;'
	],
	['new ProcessStartInfo(launchPath, "--own-image")', 'new ProcessStartInfo(expected, "--unused")'],
	['!SamePhysicalFile(expected, foreign)', 'true'],
	[
		'(bool)receipt["same_file"] && (bool)receipt["alias_observed"] == aliasObserved',
		'(bool)receipt["same_file"]'
	],
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
	['identity.status,\n\t\t\t0,', 'result.status,\n\t\t\t0,'],
	['identity.status,\n\t\t\t0,', 'identity.status,\n\t\t\t1,'],
	['assert.equal(\n\t\t\tidentity.status,', 'assert.notEqual(\n\t\t\tidentity.status,'],
	["'foreign-executable'", "'ready'"],
	[' --identity-controls ', ' --unused '],
	[' --identity-controls-no-short-alias ', ' --unused '],
	['assert.equal(noShortAlias.status, 0', 'assert.equal(noShortAlias.status, 1'],
	["assert.equal(noShortAlias.stderr, ''", "assert.ok(noShortAlias.stderr === ''"],
	[
		"assert.equal(noShortAlias.stdout.trim(), identityMessage + 'unavailable (forced control).')",
		"assert.equal(noShortAlias.stdout.trim(), identityMessage + 'observed.')"
	],
	["assert.equal(identity.stderr, ''", "assert.ok(identity.stderr === ''"]
]) {
	assert.ok(compiledRuntime.includes(from), 'the mutation must alter the actual native control');
	assert.throws(
		() => checkCompiledFixtureNormalization(compiledFixture, compiledRuntime.replaceAll(from, to)),
		from
	);
}
// Native stderr is diagnostic input only; it cannot supply success or raw payload.
{
	const describe = require('./support/windows-launch-runtime.cjs').describeNativeIdentityFailure;
	assert.equal(
		typeof describe,
		'function',
		'the actual native status owner must expose its closed classifier'
	);
	const known = 'The native alias does not resolve to the exact controlled module.';
	const raw = 'private-error-payload-marker';
	const native = {
		stderr:
			'Unhandled Exception: System.InvalidOperationException: ' +
			known +
			'\r\n' +
			'   at WindowsLaunchChild.IdentityControls(String[] args) in C:\\' +
			raw +
			':line 1\r\n',
		stdout: raw
	};
	const closed = JSON.parse(describe(native, compiledFixture));
	assert.equal(closed.exception_type, 'System.InvalidOperationException');
	assert.equal(closed.fixture_refusal, known);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'native.exe : Unhandled Exception: System.InvalidOperationException: ' + known },
				compiledFixture
			)
		).fixture_refusal,
		known
	);
	assert.deepEqual(closed.fixture_frames, ['IdentityControls']);
	assert.equal(closed.stderr_characters, native.stderr.length);
	assert.equal(closed.stdout_characters, raw.length);
	assert(!describe(native, compiledFixture).includes(raw));
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.InvalidOperationException: ' + raw },
				compiledFixture
			)
		).fixture_refusal,
		'unobserved'
	);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.InvalidOperationException: ' + known + raw },
				compiledFixture
			)
		).fixture_refusal,
		'unobserved'
	);
	assert.equal(
		JSON.parse(describe({ stderr: 'System.Private' + raw + ': ' + raw }, compiledFixture))
			.exception_type,
		'unobserved'
	);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.ComponentModel.Win32Exception: ' + raw },
				compiledFixture
			)
		).exception_type,
		'System.ComponentModel.Win32Exception'
	);
	assert.equal(
		JSON.parse(
			describe(
				{ stderr: 'Unhandled Exception: System.ComponentModel.Win32Exception: ' + raw },
				compiledFixture
			)
		).fixture_refusal,
		'unobserved'
	);
	assert.deepEqual(
		JSON.parse(describe({ stderr: 'at Private.' + raw + '()' }, compiledFixture)).fixture_frames,
		[]
	);
	assert.deepEqual(JSON.parse(describe({ stderr: { raw }, stdout: { raw } }, compiledFixture)), {
		exception_type: 'unobserved',
		fixture_refusal: 'unobserved',
		fixture_frames: [],
		stderr_characters: 0,
		stdout_characters: 0
	});
	assert(
		compiledRuntime.includes('describeNativeIdentityFailure(identity, fixtureSource)'),
		'the actual status assertion must consume the closed native stderr classifier'
	);
}

// The fixture must supply the canonical package location without relaxing recordWindows.
{
	const canonicalDirectory =
		require('./support/windows-launch-runtime.cjs').canonicalFixtureDirectory;
	assert.equal(
		typeof canonicalDirectory,
		'function',
		'the actual native owner must expose its directory admission'
	);
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-canonical-fixture-root-'));
	try {
		const target = path.join(owned, 'actual');
		const alias = path.join(owned, 'alias');
		fs.mkdirSync(target);
		fs.symlinkSync(target, alias, process.platform === 'win32' ? 'junction' : 'dir');
		const canonical = canonicalDirectory(alias);
		assert.equal(
			canonical,
			fs.realpathSync.native(target),
			'an actual alias must resolve through the native owner'
		);
		assert.notEqual(
			alias,
			canonical,
			'the positive control must have independently different spellings'
		);
		const originalIdentity = fs.statSync(alias, { bigint: true });
		const canonicalIdentity = fs.statSync(canonical, { bigint: true });
		assert.equal(originalIdentity.dev, canonicalIdentity.dev);
		assert.equal(
			originalIdentity.ino,
			canonicalIdentity.ino,
			'the canonical image must be the same physical directory'
		);
		const packageBytes = 'independent canonical package fixture';
		const canonicalPackage = path.join(canonical, 'ErgoptiPlus.exe');
		const requestedPackage = path.join(alias, 'ErgoptiPlus.exe');
		fs.writeFileSync(canonicalPackage, packageBytes);
		const native = windowsStartup();
		native.executable = canonicalPackage;
		native.receipt.executable = canonicalPackage;
		native.launched_sha256 = crypto.createHash('sha256').update(packageBytes).digest('hex');
		const observation = path.join(owned, 'observation.json');
		const output = path.join(owned, 'recorded.json');
		fs.writeFileSync(
			observation,
			JSON.stringify({
				marker_seen: true,
				crashed_early: false,
				marker_seconds: 1,
				native_startup: native
			})
		);
		const oldSha = process.env.GITHUB_SHA;
		try {
			process.env.GITHUB_SHA = 'a'.repeat(40);
			assert.throws(
				() => recordWindows(observation, requestedPackage, output),
				/not the launched executable/,
				'the old requested-spelling policy must fail the unchanged strict product validator'
			);
			assert.equal(fs.existsSync(output), false, 'an alias mismatch must publish no evidence');
			recordWindows(observation, canonicalPackage, output);
			assert.equal(
				JSON.parse(fs.readFileSync(output, 'utf8')).package_sha256,
				native.launched_sha256,
				'the native canonical fixture must record actual same-file package bytes'
			);
		} finally {
			if (oldSha === undefined) delete process.env.GITHUB_SHA;
			else process.env.GITHUB_SHA = oldSha;
		}
		const foreign = path.join(owned, 'foreign');
		fs.mkdirSync(foreign);
		const foreignPort = { statSync: fs.statSync, realpathSync: { native: () => foreign } };
		assert.throws(
			() => canonicalDirectory(alias, foreignPort),
			/another file/,
			'a native image of a foreign directory must not replace the actual owned directory'
		);
		let physicalReads = 0;
		const foreignDevice = {
			statSync: () => ({
				isDirectory: () => true,
				dev: originalIdentity.dev + (physicalReads++ === 0 ? 0n : 1n),
				ino: originalIdentity.ino
			}),
			realpathSync: { native: () => target }
		};
		assert.throws(
			() => canonicalDirectory(alias, foreignDevice),
			/another device/,
			'equal file indices on another device do not establish physical ownership'
		);
		assert.throws(
			() =>
				canonicalDirectory(alias, {
					statSync: fs.statSync,
					realpathSync: { native: () => 'relative-directory' }
				}),
			/actual absolute native directory/
		);
		const file = path.join(owned, 'regular-file');
		fs.writeFileSync(file, 'actual regular file');
		assert.throws(() => canonicalDirectory(file), /must be directories/);
		const unknownIdentity = {
			statSync: () => ({ isDirectory: () => true, dev: 0n, ino: 0n }),
			realpathSync: { native: () => target }
		};
		assert.throws(() => canonicalDirectory(alias, unknownIdentity), /independent file identities/);
		const textualIdentity = {
			statSync: () => ({ isDirectory: () => true, dev: '1', ino: '1' }),
			realpathSync: { native: () => target }
		};
		assert.throws(() => canonicalDirectory(alias, textualIdentity), /independent file identities/);
		assert.equal(
			fs.existsSync(target),
			true,
			'refused projections must not retire the actual fixture'
		);
		assert.equal(
			fs.existsSync(foreign),
			true,
			'foreign identity refusal must not delete a sibling'
		);
	} finally {
		fs.rmSync(owned, { recursive: true, force: true });
	}
	assert.ok(
		compiledRuntime.includes('const temporary = canonicalFixtureDirectory(acquiredDirectory);')
	);
	assert.ok(
		compiledRuntime.includes('fs.rmSync(acquiredDirectory, { recursive: true, force: true });')
	);
}

// The launch job has no npm install: every native control must load with builtins only.
{
	const childProcess = require('node:child_process');
	const runtimePath = require.resolve('./support/windows-startup-log-runtime.cjs');
	const result = childProcess.spawnSync(
		process.execPath,
		[
			'-e',
			`
		const Module = require('node:module');
		const originalLoad = Module._load;
		Module._load = function(request, parent, isMain) {
			if (!Module.isBuiltin(request) && !request.startsWith('.') && !require('node:path').isAbsolute(request))
				throw new Error('Third-party modules are unavailable in the native launch job');
			return originalLoad.call(this, request, parent, isMain);
		};
		const runtime = require(process.argv[1]);
		if (typeof runtime !== 'function' || typeof runtime.readStartupLogCatalog !== 'function')
			throw new Error('The actual native catalogue owner was not loaded');
	`,
			runtimePath
		],
		{ encoding: 'utf8', timeout: 10000, windowsHide: true }
	);
	assert.ok(
		!result.error && result.status === 0,
		'the actual native runtime must load without third-party modules'
	);
	assert.equal(result.stderr, '');
	const readCatalog = require(runtimePath).readStartupLogCatalog;
	const recipe = pipeline.runOf(
		pipeline.step(
			pipeline.job('launch-windows'),
			'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)'
		)
	);
	const actual = readCatalog(recipe);
	assert.ok(
		actual.segments.length > 0,
		'the real canonical TOML catalogue must be admitted by its native workflow reader'
	);
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-log-catalog-'));
	try {
		const catalogPath = path.join(directory, 'catalog.toml');
		const command = recipe.find((line) => line.includes('$catalogJson = & python -c '));
		const fixtureRecipe = [
			command.replace(
				/"\$env:GITHUB_WORKSPACE\\[^"\r\n]+"/,
				'"$env:GITHUB_WORKSPACE\\catalog.toml"'
			)
		];
		fs.writeFileSync(
			catalogPath,
			'[app]\nfolder_name="owned-name"\n[logs.windows]\nbase="PRIVATE_ROOT"\nsegments=["{app}","trace"]\n[logs.files]\nunified_prefix="daily_"\nextension=".txt"\n'
		);
		assert.deepEqual(
			readCatalog(fixtureRecipe, directory),
			{
				base: 'PRIVATE_ROOT',
				segments: ['owned-name', 'trace'],
				prefix: 'daily_',
				extension: '.txt'
			},
			'the existing Python source command must resolve independent TOML fields and the application placeholder'
		);
		fs.writeFileSync(catalogPath, '[app\nPRIVATE_CATALOG_ERROR');
		assert.throws(
			() => readCatalog(fixtureRecipe, directory),
			/native log catalogue reader refused/
		);
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
	const valid = { status: 0, stdout: JSON.stringify(actual), stderr: '' };
	for (const response of [
		{ ...valid, status: null, signal: 'SIGTERM' },
		{ ...valid, status: 1 },
		{ ...valid, error: new Error('PRIVATE_CATALOG_ERROR') },
		{ ...valid, stdout: 'PRIVATE_CATALOG_ERROR' },
		{ ...valid, stderr: 'PRIVATE_CATALOG_ERROR' },
		{ ...valid, stdout: '{}' },
		{ ...valid, stdout: JSON.stringify({ ...actual, segments: ['..'] }) },
		{ ...valid, stdout: JSON.stringify({ ...actual, prefix: false }) }
	]) {
		assert.throws(
			() => readCatalog(recipe, pipeline.ROOT, () => response),
			(error) => !/PRIVATE_CATALOG_ERROR/.test(error.message),
			'native reader refusal must not project private streams'
		);
	}
	assert.throws(() => readCatalog([]), /one actual owner/);
	const command = recipe.find((line) => line.includes('$catalogJson = & python -c '));
	assert.throws(() => readCatalog([command, command]), /one actual owner/);
	assert.throws(
		() =>
			readCatalog([
				command.replace(
					/"\$env:GITHUB_WORKSPACE\\[^"\r\n]+"/,
					'"$env:GITHUB_WORKSPACE\\..\\catalog.toml"'
				)
			]),
		/inside its repository/
	);
}

// Exercise the actual Windows consumer after the catalogue reader returns its flat packet.
{
	const vm = require('node:vm');
	const runtimePath = require.resolve('./support/windows-startup-log-runtime.cjs');
	const module = { exports: {} };
	const cases = [];
	const ownedRoots = new Set();
	let catalogueCalls = 0;
	const catalog = {
		base: 'ERGOPTI_TEST_LOG_ROOT',
		segments: ['independent-app', 'trace'],
		prefix: 'independent_daily_',
		extension: '.txt'
	};
	function nativeSpawn(program, arguments_, options) {
		if (program === 'python') {
			catalogueCalls++;
			assert.equal(arguments_[0], '-c');
			assert.equal(options.timeout, 5000);
			return { status: 0, stdout: JSON.stringify(catalog), stderr: '' };
		}
		assert.equal(program, 'pwsh.exe', 'only the actual native collector boundary is replaced');
		assert.deepEqual(Array.from(arguments_.slice(0, 3)), [
			'-NoProfile',
			'-NonInteractive',
			'-File'
		]);
		assert.equal(options.timeout, 30000, 'the existing native collector keeps its deadline');
		const defaultRoot = options.env.ERGOPTI_TEST_LOG_ROOT;
		assert.equal(
			typeof defaultRoot,
			'string',
			'the flat catalogue base owns the native environment'
		);
		assert.equal(path.basename(defaultRoot), 'private-local-app-data');
		assert.equal(options.env.GITHUB_WORKSPACE, pipeline.ROOT);
		const scenario = path.dirname(defaultRoot);
		ownedRoots.add(path.dirname(scenario));
		const smoke = options.env.ERGOPTI_STARTUP_SMOKE_DIR !== '';
		const selected = smoke ? options.env.ERGOPTI_STARTUP_SMOKE_DIR : defaultRoot;
		assert.equal(path.dirname(selected), scenario);
		const observer = fs.readFileSync(arguments_[3], 'utf8');
		assert.ok(observer.includes('Write-StartupOwnershipEvidence $proc'));
		const bootstrap = path.join(selected, 'independent-app', 'trace', 'bootstrap.log');
		const present = fs.existsSync(bootstrap);
		cases.push(`${smoke ? 'smoke' : 'normal'}-${present ? 'present' : 'absent'}`);
		const logs = ['bootstrap.log', 'independent_daily_2026-10-04.txt'];
		const rows = logs.map((log) => {
			if (!present)
				return {
					log,
					status: 'unavailable',
					cause: 'Owned fixture log is absent.'
				};
			const bytes = fs.readFileSync(bootstrap);
			return {
				log,
				status: 'observed',
				size_bytes: bytes.length,
				read_bytes: 4096,
				truncated: true,
				tail: bytes.subarray(bytes.length - 4096).toString('utf8')
			};
		});
		return {
			status: 0,
			stdout: rows.map((row) => JSON.stringify(row)).join('\n'),
			stderr: ''
		};
	}
	vm.runInNewContext(
		fs.readFileSync(runtimePath, 'utf8'),
		{
			module,
			exports: module.exports,
			process: { platform: 'win32', env: {} },
			Buffer,
			console: { log() {} },
			require(name) {
				if (name === 'node:child_process') return { spawnSync: nativeSpawn };
				if (name === '../ci-pipeline.cjs') return pipeline;
				return require(name);
			}
		},
		{ filename: runtimePath, timeout: 10000 }
	);
	assert.equal(typeof module.exports, 'function');
	module.exports();
	assert.equal(catalogueCalls, 1, 'the real consumer acquires one strict catalogue packet');
	assert.deepEqual(cases, ['smoke-present', 'smoke-absent', 'normal-present', 'normal-absent']);
	assert.equal(ownedRoots.size, 1, 'all four actual scenarios share one acquired fixture owner');
	for (const directory of ownedRoots)
		assert.equal(fs.existsSync(directory), false, 'the actual consumer retires its fixture');
}

require('./support/windows-launch-runtime.cjs')();

require('./support/windows-startup-log-runtime.cjs')();

// CI_INSTALLED_ARCHIVE_EVIDENCE_BEGIN
{
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ci-installed-archive-evidence-'));
	try {
		const observation = path.join(root, 'result.json');
		fs.writeFileSync(observation, JSON.stringify({ scenario: 'upgraded', failures: [] }));
		const previousSha = process.env.GITHUB_SHA,
			previousRunner = process.env.MATRIX_RUNNER;
		try {
			process.env.GITHUB_SHA = 'a'.repeat(40);
			process.env.MATRIX_RUNNER = 'macos-15';
			for (const extension of ['tar.xz', 'zip']) {
				const selected = path.join(root, 'installed.' + extension);
				const unselected = path.join(root, 'other-' + extension);
				const output = path.join(root, 'evidence-' + extension + '.json');
				fs.writeFileSync(selected, 'Actual installed immutable bytes: ' + extension);
				fs.writeFileSync(unselected, 'Another valid archive, never installed');
				recordMac(observation, selected, output);
				const actual = JSON.parse(fs.readFileSync(output));
				assert.equal(
					actual.package_sha256,
					crypto.createHash('sha256').update(fs.readFileSync(selected)).digest('hex')
				);
				assert.notEqual(
					actual.package_sha256,
					crypto.createHash('sha256').update(fs.readFileSync(unselected)).digest('hex')
				);
				assert.equal(actual.scenario, 'upgraded');
				assert.deepEqual(actual.failures, []);
			}
		} finally {
			if (previousSha === undefined) delete process.env.GITHUB_SHA;
			else process.env.GITHUB_SHA = previousSha;
			if (previousRunner === undefined) delete process.env.MATRIX_RUNNER;
			else process.env.MATRIX_RUNNER = previousRunner;
		}
	} finally {
		fs.rmSync(root, { recursive: true });
	}
	console.log('Actual installed-archive evidence controls: 2');
}
// CI_INSTALLED_ARCHIVE_EVIDENCE_END
