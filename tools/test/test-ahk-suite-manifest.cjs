// tools/test/test-ahk-suite-manifest.cjs

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');
const pipeline = require('./ci-pipeline.cjs');

// Hosted logs may be unavailable independently of check-run annotations.
// A source-contract or fixture assertion must remain diagnosable as well.
process.on('uncaughtException', (error) => {
	if (process.env.GITHUB_ACTIONS === 'true') {
		const message = String(error.stack || error.message)
			.replaceAll('%', '%25')
			.replaceAll('\r', '%0D')
			.replaceAll('\n', '%0A');
		console.log(`::error::AHK suite contract failed: ${message}`);
	}
	console.error(error);
	process.exitCode = 1;
});

// A completed TAP receipt cannot compensate for a missing native exit receipt.
// Start-Process without -Wait must retain its handle before the child exits.
// Reading the live receipt conflicts with AutoHotkey's exclusive FileAppend.
// Require the actual workflow to retire its child before any transcript reader.
function assertPostExitTranscript(script, name) {
	const code = script.replace(/^\s*#.*$/gm, '');
	const launch = code.indexOf('$proc = Start-Process');
	const joined = code.indexOf('$proc.WaitForExit()', launch);
	assert.ok(launch >= 0 && joined > launch, `${name}: join the owned writer before reading`);
	assert.doesNotMatch(
		code.slice(0, joined),
		/Get-Content|FileStream|StreamReader|ReadLine|ReadAll|OpenRead/i,
		`${name}: no transcript reader may own the live receipt`
	);
	assert.match(
		code.slice(joined),
		/Get-Content -LiteralPath \$resultsFile -Encoding utf8 \| ForEach-Object \{ Write-Host \$_ \}/,
		`${name}: publish the complete UTF-8 transcript after native exit`
	);
}

const processReceipts = [];
for (const [job, name] of [
	['test-ahk', 'Run AHK test suite'],
	['e2e-ahk', 'Run E2E suite (Strategy A — pure engine injection)']
]) {
	const script = pipeline.runOf(pipeline.step(pipeline.job(job), name)).join('\n');
	const start =
		/\$proc = Start-Process[^\n]+\n([\s\S]*?)(?=\s*while \(-not \$proc\.HasExited\))/.exec(script);
	assert.ok(start, `${name}: asynchronous process start must exist`);
	assert.match(
		start[1],
		/\$null = \$proc\.Handle/,
		`${name}: retain the native handle before polling`
	);
	const finish = /\$proc\.WaitForExit\(\)\s*\n\s*\$exit = \$proc\.ExitCode/.exec(script);
	assert.ok(finish, `${name}: join the process before reading its exit receipt`);
	assertPostExitTranscript(script, name);
	processReceipts.push({ name, start: start[0], finish: finish[0] });
}

// Isolated runners must not overwrite the main suite's canonical TAP receipt.
const isolatedScript = pipeline
	.runOf(pipeline.step(pipeline.job('test-ahk'), 'Run isolated AHK LLM suites'))
	.join('\n');
assert.match(
	isolatedScript,
	/\$env:ERGOPTI_AHK_RESULTS_FILE = Join-Path \$env:RUNNER_TEMP "windows-ahk-isolated-\$name\.txt"/,
	'isolated runners must own distinct canonical result paths'
);
assert.ok(
	isolatedScript.indexOf('$env:ERGOPTI_AHK_RESULTS_FILE =') <
		isolatedScript.indexOf('$proc = Start-Process'),
	'assign the isolated receipt before starting each native child'
);
assert.match(
	isolatedScript,
	/validate-ahk-suite-manifest\.cjs[\s\S]*--input \$env:ERGOPTI_AHK_RESULTS_FILE/,
	'isolated native exits also require complete execution receipts'
);

for (const [job, name] of [
	['test-ahk', 'Run AHK test suite'],
	['e2e-ahk', 'Run E2E suite (Strategy A — pure engine injection)']
]) {
	const script = pipeline.runOf(pipeline.step(pipeline.job(job), name)).join('\n');
	for (const reader of [
		'Get-Content -LiteralPath $resultsFile',
		'$reader = [System.IO.FileStream]::new($resultsFile)'
	]) {
		for (const boundary of ['$proc = Start-Process', '$proc.WaitForExit()']) {
			const mutated = script.replace(boundary, `${reader}\n${boundary}`);
			assert.throws(
				() => assertPostExitTranscript(mutated, name),
				/no transcript reader may own the live receipt/,
				'a restored live reader must fail the actual workflow contract'
			);
		}
	}
	assert.throws(
		() =>
			assertPostExitTranscript(
				script.replace('Get-Content -LiteralPath $resultsFile', 'Write-Host $resultsFile'),
				name
			),
		/publish the complete UTF-8 transcript/,
		'retiring the writer cannot silently drop its transcript'
	);
}

const ahkIndex = process.argv.indexOf('--ahk');
if (ahkIndex >= 0) {
	assert.equal(process.platform, 'win32', 'native exit receipt probes require Windows');
	const ahk = process.argv[ahkIndex + 1];
	assert.ok(ahk && fs.existsSync(ahk), 'native exit receipt probes require the actual AHK binary');
	const probeRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-exit-'));
	const quote = (value) => `'${value.replaceAll("'", "''")}'`;
	try {
		// The real exclusive FileAppend must refuse the former held reader and
		// succeed once the workflow waits for native exit before reading.
		for (const receipt of processReceipts) {
			for (const heldReader of [true, false]) {
				const resultPath = path.join(probeRoot, `append-${heldReader}.txt`);
				const runner = path.join(probeRoot, `append-${heldReader}.ahk`);
				const literal = resultPath.replaceAll('`', '``').replaceAll('"', '`"');
				const line = 'owned Unicode receipt é🙂\r\n';
				fs.writeFileSync(resultPath, '');
				fs.writeFileSync(
					runner,
					[
						'\uFEFF#Requires AutoHotkey v2.0',
						'#NoTrayIcon',
						'#SingleInstance Off',
						`try FileAppend("owned Unicode receipt é🙂\`r\`n", "${literal}", "UTF-8")`,
						'catch OSError as failure {',
						' if failure.Number = 32',
						'  ExitApp(32)',
						' throw failure',
						'}',
						'ExitApp(0)',
						''
					].join('\n')
				);
				const command = [
					"$ErrorActionPreference = 'Stop'",
					`$ahk = ${quote(ahk)}; $runner = ${quote(runner)}; $resultsFile = ${quote(resultPath)}`,
					'$proc = $null; $reader = $null',
					'try {',
					...(heldReader
						? [
								'$reader = [IO.FileStream]::new($resultsFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)'
							]
						: []),
					receipt.start,
					'$clock = [Diagnostics.Stopwatch]::StartNew()',
					'while (-not $proc.HasExited) { if ($clock.ElapsedMilliseconds -ge 5000) { throw "Owned append child did not retire" }; Start-Sleep -Milliseconds 10 }',
					receipt.finish,
					`if ($null -eq $exit -or $exit -ne ${heldReader ? 32 : 0}) { throw "Exclusive append ownership verdict was refused" }`,
					...(heldReader
						? [
								'if ([IO.FileInfo]::new($resultsFile).Length -ne 0) { throw "Refused append changed the receipt" }'
							]
						: [
								`if ([IO.File]::ReadAllText($resultsFile, [Text.Encoding]::UTF8) -cne ${quote(line)}) { throw "Retired append lost UTF-8 or CRLF bytes" }`
							]),
					'Write-Output "OWNED_APPEND_CONTRACT_PASS"',
					'} finally {',
					' if ($null -ne $reader) { $reader.Dispose() }',
					' if ($null -ne $proc) {',
					'  try { if (-not $proc.HasExited) { $proc.Kill(); if (-not $proc.WaitForExit(5000)) { throw "Owned append child cleanup was refused" } } } finally { $proc.Dispose() }',
					' }',
					'}'
				].join('\n');
				const probe = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', command], {
					encoding: 'utf8',
					timeout: 30000
				});
				assert.equal(
					probe.status,
					0,
					`${receipt.name}: native append ownership ${probe.stderr || probe.error || probe.stdout}`
				);
				assert.equal(probe.stderr, '', 'the exact owned native append control must emit no errors');
				assert.equal(probe.stdout.trim(), 'OWNED_APPEND_CONTRACT_PASS');
			}
		}
		for (const receipt of processReceipts) {
			for (const expected of [0, 7]) {
				const runner = path.join(probeRoot, `exit-${expected}.ahk`);
				fs.writeFileSync(
					runner,
					`\uFEFF#Requires AutoHotkey v2.0\nSleep(200)\nExitApp(${expected})\n`
				);
				const command = [
					"$ErrorActionPreference = 'Stop'",
					`$ahk = ${quote(ahk)}; $runner = ${quote(runner)}`,
					receipt.start,
					'while (-not $proc.HasExited) { Start-Sleep -Milliseconds 10 }',
					receipt.finish,
					'if ($null -eq $exit) { throw "Native exit receipt is unavailable" }',
					'Write-Output $exit'
				].join('\n');
				const probe = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', command], {
					encoding: 'utf8',
					timeout: 30000
				});
				assert.equal(
					probe.status,
					0,
					`${receipt.name}: ${probe.stderr || probe.error || probe.stdout}`
				);
				assert.equal(
					probe.stdout.trim(),
					String(expected),
					`${receipt.name}: preserve native exit ${expected}`
				);
			}
		}
	} catch (error) {
		if (process.env.GITHUB_ACTIONS === 'true') {
			const message = error.message
				.replaceAll('%', '%25')
				.replaceAll('\r', '%0D')
				.replaceAll('\n', '%0A');
			console.log(`::error::AHK native exit probe failed: ${message}`);
		}
		throw error;
	} finally {
		fs.rmSync(probeRoot, { recursive: true, force: true });
	}
}

const beforeSlowTail = [
	'\uFEFF1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'# 2 passed, 0 failed.'
].join('\n');
const early = validateAhkSuiteManifest(beforeSlowTail);
assert.equal(
	early.complete,
	false,
	'a green-looking footer must not complete before the slow tail'
);
assert.match(early.errors.join('\n'), /planned test 3\/3 never started/);

const afterSlowTail = [
	'1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'RUNNING 3/3 - deliberately slow tail',
	'ok 3 - deliberately slow tail',
	'# 3 passed, 0 failed.'
].join('\n');
const complete = validateAhkSuiteManifest(afterSlowTail);
assert.equal(complete.complete, true, complete.errors.join('\n'));
assert.deepEqual(
	complete.executed.map((entry) => entry.index),
	[1, 2, 3]
);

for (const [status, detail] of [
	['ok', 'a different case'],
	['ok', 'fast head — unexpected suffix'],
	['not ok', 'a different case — injected failure'],
	['not ok', 'fast header — injected failure']
]) {
	const source = afterSlowTail
		.replace('ok 1 - fast head', `${status} 1 - ${detail}`)
		.replace(
			'# 3 passed, 0 failed.',
			status === 'ok' ? '# 3 passed, 0 failed.' : '# 2 passed, 1 failed.'
		);
	const mismatch = validateAhkSuiteManifest(source);
	assert.equal(
		mismatch.complete,
		false,
		`terminal identity mismatch must fail: ${status} ${detail}`
	);
	assert.match(mismatch.errors.join('\n'), /result ordinal 1.*name/);
}

const punctuationName = 'case — with diagnostic-like punctuation';
const punctuationSource = afterSlowTail.replaceAll('fast head', punctuationName);
assert.equal(
	validateAhkSuiteManifest(punctuationSource).complete,
	true,
	'a delimiter inside a passing test name is part of its identity'
);
const punctuationFailure = punctuationSource
	.replace(`ok 1 - ${punctuationName}`, `not ok 1 - ${punctuationName} — injected failure`)
	.replace('# 3 passed, 0 failed.', '# 2 passed, 1 failed.');
assert.equal(
	validateAhkSuiteManifest(punctuationFailure).complete,
	true,
	'failed results must match the full registered name before diagnostic text'
);

const missingTerminal = validateAhkSuiteManifest(
	afterSlowTail.replace('ok 3 - deliberately slow tail\n', '')
);
assert.equal(
	missingTerminal.complete,
	false,
	'RUNNING without a terminal result must fail the manifest'
);

assert.equal(complete.timed_count, 0, 'legacy transcripts have no measured cases');
assert.deepEqual(
	complete.executed.map((entry) => entry.duration_ms),
	[null, null, null]
);

const timedSource = afterSlowTail
	.replace('ok 1 - fast head', 'ok 1 - fast head\n# duration_ms 1 0')
	.replace('ok 2 - ordinary middle', 'ok 2 - ordinary middle\n# duration_ms 2 12.375')
	.replace(
		'ok 3 - deliberately slow tail',
		'ok 3 - deliberately slow tail\n# duration_ms 3 2500.00'
	);
const timed = validateAhkSuiteManifest(timedSource);
assert.equal(timed.complete, true, timed.errors.join('\n'));
assert.equal(timed.timed_count, 3);
assert.deepEqual(
	timed.executed.map((entry) => entry.duration_ms),
	[0, 12.375, 2500]
);

function rejectsTiming(source, label) {
	const result = validateAhkSuiteManifest(source);
	assert.equal(result.complete, false, label);
	assert.ok(result.errors.length > 0, `${label}: rejection must explain the failure`);
}
rejectsTiming(timedSource.replace('# duration_ms 2 12.375\n', ''), 'mixed timed and untimed cases');
rejectsTiming(`${timedSource}\n# duration_ms 1 0`, 'duplicate timing');
rejectsTiming(`${timedSource}\n# duration_ms 4 1`, 'timing outside the plan');
rejectsTiming(`${timedSource}\n# duration_ms 0 1`, 'zero timing ordinal');
rejectsTiming(
	timedSource.replace('ok 2 - ordinary middle\n', ''),
	'timing without a terminal result'
);
rejectsTiming(
	timedSource.replace(
		'ok 2 - ordinary middle\n# duration_ms 2 12.375',
		'# duration_ms 2 12.375\nok 2 - ordinary middle'
	),
	'timing before its terminal result'
);
for (const value of [
	'NaN',
	'Infinity',
	'-1',
	'-0.5',
	'1e3',
	'1ms',
	'',
	'1 2',
	'.5',
	'1.',
	'9'.repeat(400)
]) {
	rejectsTiming(
		timedSource.replace('# duration_ms 2 12.375', `# duration_ms 2 ${value}`),
		`invalid duration ${value}`
	);
}
for (const comment of [
	'# duration_ms',
	'# duration_ms x 1',
	'# duration_ms 1.5 1',
	'# duration_ms 2'
]) {
	rejectsTiming(
		`${afterSlowTail}\n${comment}`,
		`malformed timing must not enable legacy mode: ${comment}`
	);
}
const failedTimed = validateAhkSuiteManifest(
	timedSource
		.replace('ok 2 - ordinary middle', 'not ok 2 - ordinary middle — injected failure')
		.replace('# 3 passed, 0 failed.', '# 2 passed, 1 failed.')
);
assert.equal(failedTimed.complete, true, failedTimed.errors.join('\n'));
assert.equal(failedTimed.failed, 1);
assert.equal(failedTimed.executed[1].duration_ms, 12.375, 'failed cases are measured too');

require('./support/ahk-timing-runtime.cjs')(ahkIndex >= 0 ? process.argv[ahkIndex + 1] : undefined);
if (ahkIndex >= 0) {
	require('./support/ahk-menu-lifecycle-runtime.cjs')(process.argv[ahkIndex + 1]);
}

const diagnosticFixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-diagnostics-'));
try {
	const input = path.join(diagnosticFixture, 'results.tap');
	const output = path.join(diagnosticFixture, 'manifest.json');
	fs.writeFileSync(
		input,
		[
			'1..1',
			'RUNNING 1/1 - name with 100% identity',
			'ok 1 - a different identity',
			'# 1 passed, 0 failed.'
		].join('\n')
	);
	const result = spawnSync(
		process.execPath,
		[path.join(__dirname, 'validate-ahk-suite-manifest.cjs'), '--input', input, '--json', output],
		{ encoding: 'utf8', env: { ...process.env, GITHUB_ACTIONS: 'true' } }
	);
	assert.equal(result.status, 1, 'a green test count cannot override an invalid execution receipt');
	assert.match(
		result.stdout,
		/^::error::AHK execution manifest incomplete/m,
		'GitHub annotations must expose the actual receipt failure without downloading logs'
	);
	assert.match(
		result.stdout,
		/^::error::.*result ordinal 1.*100%25 identity/m,
		'the exact mismatching identity must be annotated, with reserved percent signs escaped'
	);
	const manifest = JSON.parse(fs.readFileSync(output, 'utf8'));
	assert.equal(manifest.complete, false);
	assert.equal(manifest.passed, 1);
	assert.equal(manifest.failed, 0);
	assert.match(manifest.errors.join('\n'), /result ordinal 1/);
	const longName = `long receipt ${'x'.repeat(131072)} 100% identity`;
	fs.writeFileSync(
		input,
		`1..1\nRUNNING 1/1 - ${longName}\nok 1 - mismatch\n# 1 passed, 0 failed.\n`
	);
	const buffered = spawnSync(
		process.execPath,
		[path.join(__dirname, 'validate-ahk-suite-manifest.cjs'), '--input', input],
		{
			encoding: 'utf8',
			env: { ...process.env, GITHUB_ACTIONS: 'true' }
		}
	);
	assert.equal(buffered.status, 1, 'a large diagnostic must retain its failing exit');
	assert.ok(
		buffered.stdout.includes(longName.replaceAll('%', '%25')),
		'the complete annotation must drain before the process exits'
	);
} finally {
	fs.rmSync(diagnosticFixture, { recursive: true, force: true });
}

const contractFixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-contract-'));
try {
	const preload = path.join(contractFixture, 'broken-workflow.cjs');
	for (const [removed, expected] of [
		['$null = $proc.Handle', 'retain the native handle'],
		[
			'$env:ERGOPTI_AHK_RESULTS_FILE = Join-Path',
			'isolated runners must own distinct canonical result paths'
		]
	]) {
		fs.writeFileSync(
			preload,
			[
				"const fs = require('node:fs');",
				"const path = require('node:path');",
				'const read = fs.readFileSync;',
				'fs.readFileSync = function(file, ...args) {',
				'  const result = read.call(this, file, ...args);',
				"  if (path.basename(String(file)) === 'ci-windows.yml' && typeof result === 'string') {",
				`    return result.replace(${JSON.stringify(removed)}, '# missing native receipt owner');`,
				'  }',
				'  return result;',
				'};'
			].join('\n')
		);
		const failedContract = spawnSync(process.execPath, ['--require', preload, __filename], {
			encoding: 'utf8',
			env: { ...process.env, GITHUB_ACTIONS: 'true' },
			timeout: 30000
		});
		assert.equal(failedContract.status, 1, 'a native source contract must still fail the gate');
		assert.ok(
			failedContract.stdout
				.split('\n')
				.some(
					(line) =>
						line.startsWith('::error::AHK suite contract failed:') && line.includes(expected)
				),
			'failed native ownership contract exposes its exact annotation'
		);
	}
} finally {
	fs.rmSync(contractFixture, { recursive: true, force: true });
}

console.log('AHK suite execution manifest: completeness and per-case timing guards passed.');

// Exercise the actual file-backed transport with real portable child processes.
// These validate transport and manifests, never Windows menus or AutoHotkey.
const {
	runFileBackedNative,
	describeNativeCapture
} = require('./support/file-backed-native-runner.cjs');
const transportRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-capture-contract-'));
const transportCase = (name) => {
	const directory = path.join(transportRoot, name);
	fs.mkdirSync(directory);
	return directory;
};
const nativeNames = [
	'hotstring-personal-menu-owner: releases owned descendants and preserves foreign detached menus',
	'hotstring-personal-menu-owner: command 1 preserves state after refusal 1',
	'hotstring-personal-menu-owner: command 1 preserves state after refusal 0',
	'hotstring-personal-menu-owner: command 0 preserves state after refusal 1',
	'hotstring-personal-menu-owner: command 0 preserves state after refusal 0'
];
const fiveCaseManifest = [
	'1..5',
	...nativeNames.flatMap((name, index) => [
		`RUNNING ${index + 1}/5 - ${name}`,
		`ok ${index + 1} - ${name}`,
		`# duration_ms ${index + 1} 0.125`
	]),
	'# 5 passed, 0 failed.'
].join('\n');
const streamSize = 2 * 1024 * 1024;
const streamProgram = [
	"const fs = require('node:fs');",
	`fs.writeSync(1, Buffer.alloc(${streamSize}, 65));`,
	`fs.writeSync(2, Buffer.alloc(${streamSize}, 66));`,
	'if (process.env.ERGOPTI_AHK_RESULTS_FILE) fs.writeFileSync(process.env.ERGOPTI_AHK_RESULTS_FILE, process.env.MODELED_TAP);',
	'process.exit(Number(process.env.MODELED_EXIT || 0));'
].join('\n');
try {
	// Causal predecessor: the actual default pipe transport refuses this output.
	const buffered = spawnSync(process.execPath, ['-e', streamProgram], { timeout: 10000 });
	assert.equal(buffered.error && buffered.error.code, 'ENOBUFS');

	const directory = transportCase('large-complete');
	const results = path.join(directory, 'results.txt');
	const captured = runFileBackedNative(process.execPath, ['-e', streamProgram], directory, {
		encoding: 'utf8',
		timeout: 10000,
		env: {
			...process.env,
			ERGOPTI_AHK_RESULTS_FILE: results,
			MODELED_TAP: fiveCaseManifest,
			MODELED_EXIT: '0'
		}
	});
	assert.ifError(captured.result.error);
	assert.equal(captured.result.status, 0);
	assert.equal(captured.result.signal, null);
	assert.equal(captured.result.stdout, null, 'the child has no buffered stdout capture');
	assert.equal(captured.result.stderr, null, 'the child has no buffered stderr capture');
	assert.deepEqual(fs.readFileSync(captured.captures.stdout), Buffer.alloc(streamSize, 65));
	assert.deepEqual(fs.readFileSync(captured.captures.stderr), Buffer.alloc(streamSize, 66));
	const complete = validateAhkSuiteManifest(fs.readFileSync(results, 'utf8'));
	assert.equal(complete.complete, true, complete.errors.join('\n'));
	assert.equal(complete.failed, 0);
	assert.equal(complete.passed, 5);
	assert.equal(complete.timed_count, 5);
	assert.deepEqual(
		complete.executed.map((row) => row.name),
		nativeNames
	);
	const tail = describeNativeCapture(captured.captures.stderr);
	assert.equal(tail.bytes, streamSize);
	assert.equal(tail.tail_limit_bytes, 4096);
	assert.equal(tail.tail_bytes, 4096);
	assert.equal(tail.tail_utf8, 'B'.repeat(4096));
	assert.notEqual(tail.tail_bytes, tail.bytes, 'a bounded tail cannot be credited as full output');

	const failedDirectory = transportCase('failed-exit');
	const failedResults = path.join(failedDirectory, 'results.txt');
	const failed = runFileBackedNative(process.execPath, ['-e', streamProgram], failedDirectory, {
		encoding: 'utf8',
		timeout: 10000,
		env: {
			...process.env,
			ERGOPTI_AHK_RESULTS_FILE: failedResults,
			MODELED_TAP: fiveCaseManifest,
			MODELED_EXIT: '7'
		}
	});
	assert.ifError(failed.result.error);
	assert.equal(failed.result.status, 7, 'a complete green manifest cannot replace native exit');
	assert.equal(validateAhkSuiteManifest(fs.readFileSync(failedResults, 'utf8')).complete, true);
	assert.equal(fs.statSync(failed.captures.stdout).size, streamSize);
	assert.equal(fs.statSync(failed.captures.stderr).size, streamSize);

	const timeoutDirectory = transportCase('native-timeout');
	const timed = runFileBackedNative(
		process.execPath,
		['-e', 'setInterval(() => {}, 1000)'],
		timeoutDirectory,
		{ timeout: 1000 }
	);
	assert.equal(timed.result.error && timed.result.error.code, 'ETIMEDOUT');
	assert.equal(timed.result.status, null, 'timeout cannot invent a successful native exit');
	assert.ok(fs.existsSync(timed.captures.stdout));
	assert.ok(fs.existsSync(timed.captures.stderr));

	const thrownDirectory = transportCase('spawn-throw');
	const opened = [];
	const actualOpen = fs.openSync;
	try {
		fs.openSync = function (file, ...args) {
			const descriptor = actualOpen.call(this, file, ...args);
			if (path.dirname(String(file)) === thrownDirectory) opened.push(descriptor);
			return descriptor;
		};
		assert.throws(() => runFileBackedNative(undefined, [], thrownDirectory, {}), {
			code: 'ERR_INVALID_ARG_TYPE'
		});
	} finally {
		fs.openSync = actualOpen;
	}
	assert.equal(
		opened.length,
		2,
		'both actual capture descriptors were acquired before spawn threw'
	);
	for (const descriptor of opened) assert.throws(() => fs.fstatSync(descriptor), { code: 'EBADF' });
	assert.equal(fs.statSync(path.join(thrownDirectory, 'native.stdout.log')).size, 0);
	assert.equal(fs.statSync(path.join(thrownDirectory, 'native.stderr.log')).size, 0);

	const exclusiveDirectory = transportCase('foreign-capture');
	const foreign = path.join(exclusiveDirectory, 'native.stderr.log');
	fs.writeFileSync(foreign, 'independent existing capture');
	assert.throws(
		() => runFileBackedNative(process.execPath, ['-e', 'process.exit(0)'], exclusiveDirectory, {}),
		{ code: 'EEXIST' }
	);
	assert.equal(fs.readFileSync(foreign, 'utf8'), 'independent existing capture');
	assert.equal(fs.statSync(path.join(exclusiveDirectory, 'native.stdout.log')).size, 0);
	console.log(
		'File-backed native output: 5 portable real-child/refusal controls passed; original pipe overflow reproduced.'
	);
} finally {
	fs.rmSync(transportRoot, { recursive: true, force: true });
}

// This supplemental route follows every original contract assertion. It loads
// the authentic whole runner; the fixed data-only selection never grants a
// production route, action emission or full-suite qualification.
const SNAPSHOT16_FILTER = 'windows91 snapshots:';
const SNAPSHOT16_RUNNER = 'static/ergopti_plus/windows/tests/run_all.ahk';
const SNAPSHOT16_OWNER =
	'static/ergopti_plus/_shared/ahk/tap_hold/buffered_data_snapshot_owner.ahk';
const SNAPSHOT16_TEST =
	'static/ergopti_plus/windows/tests/unit/test_buffered_data_snapshot_owner.ahk';
const SNAPSHOT16_FIXED_IMAGES = {
	[SNAPSHOT16_OWNER]: 'd049972c3566def451dedd9e9a34747e4a0dc7c3dcac600dabc419de02c84e97',
	[SNAPSHOT16_TEST]: '411e9a737b5f65be9e9eec59f7e96075130c7fd5a72e6c08fdabc7493169d992'
};
const SNAPSHOT16_NAMES = [
	'windows91 snapshots: original scalar comparison refuses clones while unchanged composite source remains current',
	'windows91 snapshots: Map mode and string case remain exact',
	'windows91 snapshots: integer and string key slots remain distinct',
	'windows91 snapshots: Array holes and order remain exact',
	'windows91 snapshots: real TOML Boolean mutation and integer substitution refuse',
	'windows91 snapshots: genuine generated action Fn Key and Mods fields are detached observations',
	'windows91 snapshots: equivalent caller and nested replacement cannot borrow original source identity',
	'windows91 snapshots: cyclic source publishes no image',
	'windows91 snapshots: substituted data getter refuses without execution',
	'windows91 snapshots: substituted container enumerator refuses without execution',
	'windows91 snapshots: original recursive helper revocation refuses and retains exact image cleanup',
	'windows91 snapshots: own helper getter cannot execute at terminal currentness',
	'windows91 snapshots: explicit image release carries no native lifecycle claim',
	'windows91 snapshots: original Current own Call replacement refuses without invocation',
	'windows91 snapshots: original recursive helper own Call replacement refuses without invocation',
	'windows91 snapshots: original generated function own Call replacement refuses without invocation'
];

/** Capture values before callbacks so a mutable returned frame cannot borrow currency. */
function snapshot16SourceSeal(frame) {
	assert.match(frame.head, /^[a-f0-9]{40}$/, 'snapshot16 requires an actual commit');
	assert.match(frame.ahk_sha256, /^[a-f0-9]{64}$/, 'snapshot16 pins the actual interpreter');
	assert.ok(Array.isArray(frame.inputs) && frame.inputs.length > 0);
	const seen = new Set();
	for (const input of frame.inputs) {
		assert.equal(typeof input.path, 'string');
		assert.ok(!seen.has(input.path), 'snapshot16 duplicate source');
		seen.add(input.path);
		assert.match(input.sha256, /^[a-f0-9]{64}$/);
		if (Object.hasOwn(SNAPSHOT16_FIXED_IMAGES, input.path)) {
			assert.equal(
				input.sha256,
				SNAPSHOT16_FIXED_IMAGES[input.path],
				'snapshot16 exact reviewed data cases'
			);
		}
	}
	for (const file of [SNAPSHOT16_RUNNER, SNAPSHOT16_OWNER, SNAPSHOT16_TEST]) {
		assert.ok(seen.has(file), `snapshot16 missing original enrolled source: ${file}`);
	}
	return JSON.stringify(frame);
}

/** A successful TAP cannot substitute for the exact synchronous native exit. */
function snapshot16ExitSeal(result) {
	assert.ok(Number.isSafeInteger(result.pid) && result.pid > 0, 'snapshot16 missing child PID');
	assert.ifError(result.error);
	assert.equal(result.signal, null, 'snapshot16 signalled child');
	assert.equal(result.status, 0, 'snapshot16 refused native exit');
	return JSON.stringify({ pid: result.pid, status: result.status, signal: result.signal });
}

/** Receive full closed bytes, including the framework's disk-only BOM. */
function snapshot16Receive(bytes, mode) {
	for (const key of ['tap', 'stdout', 'stderr']) {
		assert.ok(Buffer.isBuffer(bytes[key]), `snapshot16 missing ${key} capture`);
	}
	assert.ok(
		bytes.tap.subarray(0, 3).equals(Buffer.from([239, 187, 191])),
		'snapshot16 missing BOM'
	);
	const text = bytes.tap.toString('utf8');
	assert.ok(Buffer.from(text, 'utf8').equals(bytes.tap), 'snapshot16 malformed UTF-8');
	assert.ok(bytes.stdout.equals(bytes.tap.subarray(3)), 'snapshot16 complete stdout differs');
	assert.equal(bytes.stderr.length, 0, 'snapshot16 stderr is not empty');
	const lines = text
		.replace(/^\uFEFF/, '')
		.split(/\r?\n/)
		.filter(Boolean);
	const selected = lines.filter((line) => line.startsWith('# --only '));
	assert.equal(selected.length, 1, 'snapshot16 requires one actual selection');
	const selection = /^# --only windows91 snapshots: - 16 of ([1-9]\d*) test\(s\) selected\.$/.exec(
		selected[0]
	);
	assert.ok(selection && Number(selection[1]) >= 16, 'snapshot16 wrong selected census');
	assert.doesNotMatch(
		text,
		/^# (?:DEFERRED|QUALIFICATION_ELIGIBLE)/m,
		'snapshot16 no profile substitution'
	);
	if (mode === 'dry') {
		assert.equal(lines.filter((line) => /^1\.\./.test(line)).join('\n'), '1..16');
		assert.equal(lines.filter((line) => line === '# dry-run - skipping execution.').length, 1);
		assert.doesNotMatch(text, /^(?:RUNNING |ok |not ok |# duration_ms|# \d+ passed,)/m);
		return { registered_total: Number(selection[1]), dry_loaded: true };
	}
	assert.equal(mode, 'run');
	assert.doesNotMatch(text, /^# dry-run/m);
	const manifest = validateAhkSuiteManifest(text);
	assert.equal(manifest.complete, true, manifest.errors.join('; '));
	assert.equal(manifest.planned, 16);
	assert.equal(manifest.executed_count, 16);
	assert.equal(manifest.timed_count, 16);
	assert.equal(manifest.passed, 16);
	assert.equal(manifest.failed, 0);
	assert.deepEqual(
		manifest.executed.map((entry) => entry.name),
		SNAPSHOT16_NAMES
	);
	return { registered_total: Number(selection[1]), manifest };
}

/** Ports are controlled in JS; only the Windows host below can issue native evidence. */
function receiveSnapshot16(ports) {
	const source = snapshot16SourceSeal(ports.source());
	const phases = [];
	for (const mode of ['dry', 'run']) {
		assert.equal(
			snapshot16SourceSeal(ports.source()),
			source,
			'snapshot16 source changed before launch'
		);
		const packet = ports.run(mode);
		const exit = snapshot16ExitSeal(packet.result);
		assert.equal(
			snapshot16SourceSeal(ports.source()),
			source,
			'snapshot16 source changed during child'
		);
		const received = snapshot16Receive(ports.read(packet), mode);
		assert.equal(
			snapshot16ExitSeal(packet.result),
			exit,
			'snapshot16 exit changed during receiving'
		);
		assert.equal(
			snapshot16SourceSeal(ports.source()),
			source,
			'snapshot16 source changed during receiving'
		);
		phases.push({ mode, pid: packet.result.pid, ...received });
	}
	assert.equal(
		phases[0].registered_total,
		phases[1].registered_total,
		'snapshot16 registration changed'
	);
	return { source: JSON.parse(source), phases, full_suite_qualified: false };
}

// Handwritten execution observations exercise the same receiver, not an AHK
// source scanner. These ports never create a native qualification receipt.
const snapshot16Dry =
	'1..16\r\n# --only windows91 snapshots: - 16 of 200 test(s) selected.\r\n# dry-run - skipping execution.\r\n';
const snapshot16Tap =
	'1..16\r\n# --only windows91 snapshots: - 16 of 200 test(s) selected.\r\n' +
	SNAPSHOT16_NAMES.map(
		(name, index) =>
			`RUNNING ${index + 1}/16 - ${name}\r\nok ${index + 1} - ${name}\r\n# duration_ms ${index + 1} 1\r\n`
	).join('') +
	'# 16 passed, 0 failed.\r\n';
function snapshot16Controlled(change = () => {}) {
	const state = {
		frame: {
			head: 'a'.repeat(40),
			ahk_sha256: 'b'.repeat(64),
			inputs: [SNAPSHOT16_RUNNER, SNAPSHOT16_OWNER, SNAPSHOT16_TEST].map((file) => ({
				path: file,
				sha256: SNAPSHOT16_FIXED_IMAGES[file] || 'c'.repeat(64)
			}))
		},
		launches: []
	};
	const ports = {
		source: () => state.frame,
		run: (mode) => {
			state.launches.push(mode);
			return { mode, result: { pid: mode === 'dry' ? 101 : 102, status: 0, signal: null } };
		},
		read: (packet) => {
			const text = packet.mode === 'dry' ? snapshot16Dry : snapshot16Tap;
			return {
				tap: Buffer.from('\uFEFF' + text),
				stdout: Buffer.from(text),
				stderr: Buffer.alloc(0)
			};
		}
	};
	change(ports, state);
	return { ports, state };
}
let snapshot16Controls = 0;
function snapshot16Control(name, change, refused = true, expectedLaunches) {
	const { ports, state } = snapshot16Controlled(change);
	if (refused) assert.throws(() => receiveSnapshot16(ports), undefined, name);
	else assert.equal(receiveSnapshot16(ports).phases[1].manifest.passed, 16, name);
	if (expectedLaunches !== undefined) assert.equal(state.launches.length, expectedLaunches, name);
	snapshot16Controls += 1;
}
snapshot16Control('complete controlled observations remain explicitly non-native', () => {}, false);
function snapshot16ChangeText(edit) {
	return (ports) => {
		const read = ports.read;
		ports.read = (packet) => {
			const bytes = read(packet);
			if (packet.mode === 'run') {
				const text = edit(bytes.stdout.toString('utf8'));
				bytes.tap = Buffer.from('\uFEFF' + text);
				bytes.stdout = Buffer.from(text);
			}
			return bytes;
		};
	};
}
snapshot16Control(
	'omitted terminal result',
	snapshot16ChangeText((text) => text.replace(`ok 16 - ${SNAPSHOT16_NAMES[15]}\r\n`, ''))
);
snapshot16Control(
	'duplicate terminal result',
	snapshot16ChangeText((text) => text + `ok 16 - ${SNAPSHOT16_NAMES[15]}\r\n`)
);
snapshot16Control(
	'extra complete test cannot replace exact sixteen',
	snapshot16ChangeText((text) =>
		text
			.replace('1..16', '1..17')
			.replaceAll('/16 -', '/17 -')
			.replace(
				'# 16 passed, 0 failed.',
				'RUNNING 17/17 - extra\r\nok 17 - extra\r\n# duration_ms 17 1\r\n# 17 passed, 0 failed.'
			)
	)
);
snapshot16Control(
	'running is not a terminal result',
	snapshot16ChangeText((text) => text.slice(0, text.indexOf(`ok 16 - ${SNAPSHOT16_NAMES[15]}`)))
);
snapshot16Control(
	'different sixteen names cannot borrow the selection',
	snapshot16ChangeText((text) => text.replaceAll(SNAPSHOT16_NAMES[4], 'different genuine test'))
);
snapshot16Control(
	'missing timing',
	snapshot16ChangeText((text) => text.replace('# duration_ms 16 1\r\n', ''))
);
for (const [name, field, value] of [
	['failed exit', 'status', 7],
	['unknown exit', 'status', null],
	['signalled exit', 'signal', 'SIGTERM'],
	['missing PID', 'pid', undefined],
	['native timeout', 'error', { code: 'ETIMEDOUT' }]
]) {
	snapshot16Control(name, (ports) => {
		const run = ports.run;
		ports.run = (mode) => {
			const packet = run(mode);
			packet.result[field] = value;
			return packet;
		};
	});
}
for (const [name, mutate] of [
	[
		'absent canonical capture',
		(bytes) => {
			delete bytes.tap;
		}
	],
	[
		'missing disk BOM',
		(bytes) => {
			bytes.tap = bytes.tap.subarray(3);
		}
	],
	[
		'partial stdout',
		(bytes) => {
			bytes.stdout = bytes.stdout.subarray(0, -1);
		}
	],
	[
		'native stderr refusal',
		(bytes) => {
			bytes.stderr = Buffer.from('refused');
		}
	],
	[
		'malformed UTF-8',
		(bytes) => {
			bytes.tap = Buffer.concat([bytes.tap, Buffer.from([255])]);
		}
	]
]) {
	snapshot16Control(name, (ports) => {
		const read = ports.read;
		ports.read = (packet) => {
			const bytes = read(packet);
			mutate(bytes);
			return bytes;
		};
	});
}
snapshot16Control('dry load without the dry marker is not execution', (ports) => {
	const read = ports.read;
	ports.read = (packet) => {
		const bytes = read(packet);
		if (packet.mode === 'dry') {
			bytes.tap = Buffer.from('\uFEFF' + snapshot16Tap);
			bytes.stdout = Buffer.from(snapshot16Tap);
		}
		return bytes;
	};
});
snapshot16Control(
	'missing enrolled owner refuses before launch',
	(ports, state) => {
		state.frame.inputs.splice(1, 1);
	},
	true,
	0
);
snapshot16Control(
	'source replacement during dry refuses the second launch',
	(ports, state) => {
		const run = ports.run;
		ports.run = (mode) => {
			const packet = run(mode);
			state.frame.inputs[0].sha256 = 'd'.repeat(64);
			return packet;
		};
	},
	true,
	1
);
snapshot16Control('source replacement during final read refuses', (ports, state) => {
	const read = ports.read;
	ports.read = (packet) => {
		const bytes = read(packet);
		if (packet.mode === 'run') state.frame.head = 'd'.repeat(40);
		return bytes;
	};
});
snapshot16Control('green bytes cannot revise native exit during receiving', (ports) => {
	const read = ports.read;
	ports.read = (packet) => {
		const bytes = read(packet);
		packet.result.status = 7;
		return bytes;
	};
});
console.log(`Snapshot16 receiving: ${snapshot16Controls} controlled non-native cases passed.`);

if (ahkIndex !== -1) {
	const crypto = require('node:crypto');
	const { includeClosure } = require('./test-ahk-test-coverage.cjs');
	const root = path.resolve(__dirname, '../..');
	const ahk = fs.realpathSync(process.argv[ahkIndex + 1]);
	const runner = path.join(root, SNAPSHOT16_RUNNER);
	const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
	function snapshot16Git(args) {
		const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', timeout: 30000 });
		assert.ifError(result.error);
		assert.equal(result.signal, null);
		assert.equal(result.status, 0, 'snapshot16 native source query refused');
		assert.equal(result.stderr, '', 'snapshot16 native source query stderr');
		return result.stdout;
	}
	function source() {
		const head = snapshot16Git(['rev-parse', 'HEAD']).trim();
		if (process.env.GITHUB_ACTIONS === 'true') {
			assert.equal(head, process.env.GITHUB_SHA, 'snapshot16 exact official tested commit');
		}
		const tracked = new Map();
		for (const entry of snapshot16Git(['ls-tree', '-r', '-z', head]).split('\0').filter(Boolean)) {
			const match = /^(100644|100755) blob ([a-f0-9]{40})\t(.+)$/.exec(entry);
			if (match) tracked.set(match[3], match[2]);
		}
		const closure = [...includeClosure(runner)].map((file) =>
			path.relative(root, file).replaceAll('\\', '/')
		);
		for (const file of [SNAPSHOT16_RUNNER, SNAPSHOT16_OWNER, SNAPSHOT16_TEST])
			assert.ok(closure.includes(file), 'snapshot16 authentic whole-runner enrollment');
		const files = new Set(closure);
		for (const file of tracked.keys()) {
			if (file.startsWith('static/ergopti_plus/_shared/') && !file.endsWith('.md')) files.add(file);
		}
		for (const file of [
			'tools/test/test-ahk-suite-manifest.cjs',
			'tools/test/support/file-backed-native-runner.cjs',
			'tools/test/validate-ahk-suite-manifest.cjs',
			'tools/test/test-ahk-test-coverage.cjs'
		])
			files.add(file);
		const changed = snapshot16Git(['diff', '--name-only', '--no-ext-diff', '-z', head]).split('\0');
		for (const file of changed)
			assert.ok(!files.has(file), `snapshot16 source differs from commit: ${file}`);
		const inputs = [...files].sort().map((file) => {
			assert.ok(tracked.has(file), `snapshot16 untracked source: ${file}`);
			const full = path.join(root, file);
			let ancestor = root;
			for (const part of file.split('/')) {
				assert.ok(part !== '..' && part !== '.' && part !== '', 'snapshot16 closed source path');
				ancestor = path.join(ancestor, part);
				assert.ok(!fs.lstatSync(ancestor).isSymbolicLink(), 'snapshot16 source link refused');
			}
			assert.ok(
				fs.lstatSync(full).isFile(),
				`snapshot16 requires an original regular source: ${file}`
			);
			const bytes = fs.readFileSync(full);
			const blob = crypto
				.createHash('sha1')
				.update(`blob ${bytes.length}\0`)
				.update(bytes)
				.digest('hex');
			assert.equal(
				blob,
				tracked.get(file),
				`snapshot16 actual disk image differs from Git object: ${file}`
			);
			return { path: file, sha256: digest(bytes) };
		});
		return { head, ahk_sha256: digest(fs.readFileSync(ahk)), inputs };
	}
	// These closed, data-only children have no process-spawning cases. The
	// synchronous transport owns the exact direct child and capture descriptors;
	// this is not a global descendant-census or application-completion receipt.
	const evidence = fs.mkdtempSync(
		path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'ergopti-snapshot16-')
	);
	const launches = [];
	let receipt;
	try {
		const observed = receiveSnapshot16({
			source,
			run: (mode) => {
				const directory = path.join(evidence, mode);
				fs.mkdirSync(directory);
				const tap = path.join(directory, 'results.txt');
				const args = ['/ErrorStdOut', runner, `--only=${SNAPSHOT16_FILTER}`];
				if (mode === 'dry') args.push('--dry-run');
				const packet = runFileBackedNative(ahk, args, directory, {
					cwd: root,
					timeout: 30000,
					windowsHide: true,
					env: { ...process.env, ERGOPTI_AHK_RESULTS_FILE: tap }
				});
				packet.tap = tap;
				packet.mode = mode;
				launches.push(packet);
				return packet;
			},
			read: (packet) => ({
				tap: fs.readFileSync(packet.tap),
				stdout: fs.readFileSync(packet.captures.stdout),
				stderr: fs.readFileSync(packet.captures.stderr)
			})
		});
		receipt = {
			schema: 1,
			qualified: true,
			official_ci: process.env.GITHUB_ACTIONS === 'true',
			...observed,
			direct_child_exit_and_capture_closed: true,
			native_actions_qualified: false
		};
		console.log(
			'Snapshot16 native: exact original enrolled runner dry-loaded; 16/16 terminal cases passed; both direct children exited and capture descriptors closed; full suite remains unqualified.'
		);
	} catch (error) {
		receipt = {
			schema: 1,
			qualified: false,
			full_suite_qualified: false,
			native_actions_qualified: false,
			error: String(error.message)
		};
		throw error;
	} finally {
		receipt.launches = launches.map((packet) => ({
			mode: packet.mode,
			pid: packet.result.pid,
			status: packet.result.status,
			signal: packet.result.signal,
			error: packet.result.error && String(packet.result.error.code || packet.result.error.message),
			tap: packet.tap,
			stdout: describeNativeCapture(packet.captures.stdout),
			stderr: describeNativeCapture(packet.captures.stderr)
		}));
		fs.writeFileSync(path.join(evidence, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n', {
			flag: 'wx'
		});
		console.log(`Snapshot16 closed supplemental evidence: ${evidence}`);
	}
}
