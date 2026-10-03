// tools/test/support/windows-launch-runtime.cjs

/** Executes the actual workflow observer against native children without input hooks. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('../ci-pipeline.cjs');

module.exports = function checkWindowsLaunchRuntime() {
	if (process.platform !== 'win32') {
		console.log('[SKIP] native Windows launch refusal fixtures require Windows');
		return;
	}
	const root = path.resolve(__dirname, '../../..');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-launch-refusals-'));
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
	try {
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
		const probe = path.join(temporary, 'observe.ps1');
		for (const scenario of [
			'ready',
			'marker-only',
			'early-exit',
			'receipt-then-error-exit',
			'missing-logs',
			'logged-error',
			'foreign-nonce'
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
				assert.equal(
					fs.existsSync(evidence),
					false,
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
		fs.rmSync(temporary, { recursive: true, force: true });
	}
};
