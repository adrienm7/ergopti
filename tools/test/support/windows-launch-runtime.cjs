// tools/test/support/windows-launch-runtime.cjs

/** Executes the actual workflow observer against native children without input hooks. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('../ci-pipeline.cjs');

/** Classifies a failed native fixture without projecting its stderr payload. */
function describeNativeIdentityFailure(result, fixture) {
	const stderr = typeof result.stderr === 'string' ? result.stderr : '';
	const stdout = typeof result.stdout === 'string' ? result.stdout : '';
	const types = [
		'System.InvalidOperationException',
		'System.ComponentModel.Win32Exception',
		'System.IO.IOException',
		'System.UnauthorizedAccessException',
		'System.ArgumentException',
		'System.DllNotFoundException',
		'System.EntryPointNotFoundException',
		'System.TypeInitializationException'
	];
	const observedType =
		types.find((type) => stderr.includes('Unhandled Exception: ' + type + ':')) || 'unobserved';
	const messages = [
		...fixture.matchAll(/throw new InvalidOperationException\("([^"\n]+)"\)/g),
		...fixture.matchAll(/Require\([^\n]*,\s*"([^"\n]+)"\);/g),
		...fixture.matchAll(/^\s*"([^"\n]+)"\);$/gm)
	].map((match) => match[1]);
	const refusal =
		observedType === 'System.InvalidOperationException'
			? messages.find((message) =>
					stderr
						.split(/\r?\n/)
						.some((line) =>
							line.trim().endsWith('Unhandled Exception: ' + observedType + ': ' + message)
						)
				) || 'unobserved'
			: 'unobserved';
	const frames = [
		'CanonicalExistingFile',
		'SamePhysicalFile',
		'OwnExecutable',
		'IdentityControls',
		'Main'
	].filter((method) =>
		stderr
			.split(/\r?\n/)
			.some((line) => line.trim().startsWith('at WindowsLaunchChild.' + method + '('))
	);
	return JSON.stringify({
		exception_type: observedType,
		fixture_refusal: refusal,
		fixture_frames: frames,
		stderr_characters: stderr.length,
		stdout_characters: stdout.length
	});
}

/** Resolves the acquired fixture directory without borrowing spelling as identity. */
function canonicalFixtureDirectory(requested, fileSystem = fs) {
	const acquired = fileSystem.statSync(requested, { bigint: true });
	const canonical = fileSystem.realpathSync.native(requested);
	assert.ok(
		typeof canonical === 'string' && path.isAbsolute(canonical),
		'the acquired fixture requires an actual absolute native directory'
	);
	if (process.platform === 'win32')
		assert.ok(
			path.win32.parse(canonical).root.length >= 3,
			'the native fixture directory must be fully qualified'
		);
	const resolved = fileSystem.statSync(canonical, { bigint: true });
	assert.ok(
		acquired.isDirectory() === true && resolved.isDirectory() === true,
		'the acquired fixture and its native image must be directories'
	);
	assert.ok(
		typeof acquired.dev === 'bigint' &&
			typeof resolved.dev === 'bigint' &&
			typeof acquired.ino === 'bigint' &&
			typeof resolved.ino === 'bigint' &&
			acquired.ino > 0n &&
			resolved.ino > 0n,
		'the native fixture directory requires exact independent file identities'
	);
	assert.equal(acquired.dev, resolved.dev, 'the native directory identifies another device');
	assert.equal(acquired.ino, resolved.ino, 'the native directory identifies another file');
	return canonical;
}

module.exports = function checkWindowsLaunchRuntime() {
	if (process.platform !== 'win32') {
		console.log('[SKIP] native Windows launch refusal fixtures require Windows');
		return;
	}
	const root = path.resolve(__dirname, '../../..');
	const acquiredDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-launch-refusals-'));
	try {
		const temporary = canonicalFixtureDirectory(acquiredDirectory);
		const powerShell = path.join(
			process.env.SystemRoot,
			'System32/WindowsPowerShell/v1.0/powershell.exe'
		);
		const executable = path.join(temporary, 'child/ErgoptiPlus.exe');
		fs.mkdirSync(path.dirname(executable));
		const quote = (value) => "'" + value.replaceAll("'", "''") + "'";
		function invoke(args, env, timeout, binary = powerShell) {
			const result = spawnSync(binary, ['-NoProfile', '-NonInteractive', ...args], {
				cwd: root,
				encoding: 'utf8',
				windowsHide: true,
				timeout,
				env: { ...process.env, ...env }
			});
			assert.ifError(result.error);
			assert.notEqual(result.status, null, 'a native process exit receipt is required');
			return result;
		}
		const compile = invoke(
			[
				'-Command',
				"$ErrorActionPreference = 'Stop'; Add-Type -TypeDefinition ([IO.File]::ReadAllText(" +
					quote(path.join(root, 'tools/test/fixtures/windows_launch_child.cs')) +
					')) -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll -OutputType ConsoleApplication -OutputAssembly ' +
					quote(executable)
			],
			{},
			30000
		);
		assert.equal(compile.status, 0, compile.stdout + compile.stderr);
		assert.ok(fs.existsSync(executable), 'native fixture compilation must produce its executable');
		const identity = invoke(
			[
				'-Command',
				'& ' +
					quote(executable) +
					' --identity-controls ' +
					quote(path.join(temporary, 'identity-controls')) +
					'; exit $LASTEXITCODE'
			],
			{},
			30000
		);
		const fixtureSource = fs.readFileSync(
			path.join(root, 'tools/test/fixtures/windows_launch_child.cs'),
			'utf8'
		);
		assert.equal(
			identity.status,
			0,
			'the real native module alias controls must pass; closed native diagnostics: ' +
				describeNativeIdentityFailure(identity, fixtureSource)
		);
		assert.equal(identity.stderr, '', 'native identity controls must emit no stderr');
		const identityMessage =
			'[OK] Native own-module identity and exact long-path receipt; foreign and invalid paths are refused. Short alias capability: ';
		assert.ok(
			[identityMessage + 'observed.', identityMessage + 'unavailable.'].includes(
				identity.stdout.trim()
			),
			'the actual native capability must have an exact successful identity receipt'
		);
		const noShortAlias = invoke(
			[
				'-Command',
				'& ' +
					quote(executable) +
					' --identity-controls-no-short-alias ' +
					quote(path.join(temporary, 'identity-controls-no-short-alias')) +
					'; exit $LASTEXITCODE'
			],
			{},
			30000
		);
		assert.equal(noShortAlias.status, 0, noShortAlias.stdout + noShortAlias.stderr);
		assert.equal(noShortAlias.stderr, '');
		assert.equal(noShortAlias.stdout.trim(), identityMessage + 'unavailable (forced control).');
		const unknownMode = invoke(
			['-Command', '& ' + quote(executable) + ' --unknown; exit $LASTEXITCODE'],
			{},
			10000
		);
		assert.notEqual(unknownMode.status, 0, 'unknown native control modes must be refused');
		assert.match(unknownMode.stderr, /Unknown native identity control mode/);
		const script = pipeline
			.runOf(
				pipeline.step(
					pipeline.job('launch-windows'),
					'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)'
				)
			)
			.join('\n');
		assert.equal(
			(script.match(/\$hangBoundSeconds = 120/g) || []).length,
			1,
			'the fixture must change only the owned hang bound'
		);
		assert.ok(
			script.includes('-ArgumentList "/ErrorStdOut"'),
			'the native C# entry point must preserve the actual observer launch argument'
		);
		const probe = path.join(temporary, 'observe.ps1');
		for (const scenario of [
			'ready',
			'marker-only',
			'early-exit',
			'receipt-then-error-exit',
			'missing-logs',
			'logged-error',
			'foreign-nonce',
			'foreign-executable'
		]) {
			const bound = scenario === 'marker-only' ? 2 : 10;
			fs.writeFileSync(
				probe,
				"$ErrorActionPreference = 'Stop'\n" +
					script.replace('$hangBoundSeconds = 120', `$hangBoundSeconds = ${bound}`) +
					'\n'
			);
			const container = path.join(temporary, scenario);
			const installed = path.join(container, 'package/ergopti_plus/windows/ErgoptiPlus.exe');
			fs.mkdirSync(path.dirname(installed), { recursive: true });
			fs.copyFileSync(executable, installed);
			const result = invoke(
				['-File', probe],
				{
					RUNNER_TEMP: container,
					GITHUB_SHA: 'a'.repeat(40),
					ERGOPTI_LAUNCH_CHILD_SCENARIO: scenario
				},
				30000,
				'pwsh.exe'
			);
			const evidence = path.join(container, 'evidence.json');
			if (scenario === 'ready') {
				assert.equal(result.status, 0, result.stdout + result.stderr);
				const observation = JSON.parse(fs.readFileSync(evidence, 'utf8'));
				assert.equal(observation.native_startup.receipt.compiled, true);
				assert.equal(observation.native_startup.exit_code, 0);
			} else {
				assert.notEqual(result.status, 0, scenario + ' must fail the actual native observer');
				const failure = JSON.parse(fs.readFileSync(evidence, 'utf8'));
				assert.ok(failure.failures.length > 0, scenario + ' must retain failed evidence');
				assert.throws(
					() =>
						require('../desktop-ci-evidence.cjs').verify({
							platform: 'windows',
							needs: Object.fromEntries(
								['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows'].map((name) => [
									name,
									{ result: 'success' }
								])
							),
							evidence: [failure],
							sha: 'a'.repeat(40),
							scenarios: [],
							release: false
						}),
					/Launch reported failures/,
					scenario + ' must publish no accepted evidence'
				);
				assert.match(
					result.stdout + result.stderr,
					/native readiness|native compiled startup evidence was refused|AssertionError/,
					scenario + ' must fail for the startup contract'
				);
			}
		}
		console.log(
			'[OK] Native Windows observer rejects extraction-only, crash, stale receipt and diagnostic failures.'
		);
	} finally {
		fs.rmSync(acquiredDirectory, { recursive: true, force: true });
	}
};

module.exports.describeNativeIdentityFailure = describeNativeIdentityFailure;

module.exports.canonicalFixtureDirectory = canonicalFixtureDirectory;
