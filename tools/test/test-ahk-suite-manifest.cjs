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
