// tools/test/support/source-boot-runtime.cjs

/** Runs the source observer's real native success, refusal and cleanup paths. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

module.exports = function checkSourceBootRuntime(root, temporary) {
	const executable = path.join(temporary, 'source-child.exe');
	const quote = (value) => "'" + value.replaceAll("'", "''") + "'";
	function invoke(binary, args, env = {}) {
		const run = spawnSync(binary, ['-NoProfile', '-NonInteractive', ...args], {
			cwd: root,
			encoding: 'utf8',
			windowsHide: true,
			timeout: 30000,
			env: { ...process.env, ...env }
		});
		assert.ifError(run.error);
		assert.notEqual(run.status, null, 'the native observer must produce an exit receipt');
		return run;
	}
	const compile = invoke(
		path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe'),
		[
			'-Command',
			"$ErrorActionPreference = 'Stop'; Add-Type -TypeDefinition ([IO.File]::ReadAllText(" +
				quote(path.join(root, 'tools/test/fixtures/source_boot_child.cs')) +
				')) -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll -OutputType ConsoleApplication -OutputAssembly ' +
				quote(executable)
		]
	);
	assert.equal(compile.status, 0, compile.stdout + compile.stderr);
	const observer = path.join(root, 'tools/test/fixtures/observe_ahk_source_boot.ps1');
	invokeCensusControls();
	function invokeCensusControls() {
		const controls = invoke('pwsh.exe', [
			'-File',
			path.join(root, 'tools/test/fixtures/test_source_boot_terminal_census.ps1'),
			'-Observer',
			observer,
			'-Executable',
			executable,
			'-Root',
			temporary
		]);
		assert.equal(controls.status, 0, controls.stdout + controls.stderr);
		assert.match(controls.stdout, /Ten actual census branch controls/);
		assert.match(controls.stdout, /Two exact native child exits/);
	}
	for (const [scenario, refusal] of [
		['ready', null],
		['missing-receipt', /no complete readiness/],
		['early-exit', /exited with 7/],
		['foreign-nonce', /another process/],
		['delayed-hang', /did not exit within/],
		['receipt-then-error', /exited with 7/],
		['missing-logs', /no durable logs/],
		['logged-error', /startup logged failures/],
		['reload-missing-receipt', /no complete readiness/],
		['malformed-flags', /another process or an incomplete boot/]
	]) {
		const probe = path.join(temporary, scenario);
		fs.mkdirSync(probe);
		const entry = path.join(probe, 'private entry.ahk');
		fs.writeFileSync(entry, '; Native fixture argument, never executed.\n');
		const observerArgs = [
			'-File',
			observer,
			'-Entry',
			entry,
			'-Ahk',
			executable,
			'-Root',
			probe,
			'-Nonce',
			'a'.repeat(32),
			'-ReadyTimeoutSeconds',
			'10',
			'-ExitTimeoutMs',
			'500',
			'-CleanupTimeoutMs',
			'1000'
		];
		if (scenario === 'reload-missing-receipt') observerArgs.push('-ExpectReload');
		const run = invoke('pwsh.exe', observerArgs, {
			ERGOPTI_SOURCE_CHILD_SCENARIO: scenario
		});
		const evidence = path.join(probe, 'observation.json');
		if (refusal === null) {
			assert.equal(run.status, 0, run.stdout + run.stderr);
			assert.equal(JSON.parse(fs.readFileSync(evidence, 'utf8')).exit_code, 0);
		} else {
			assert.notEqual(run.status, 0, scenario + ' must refuse admission');
			assert.match(
				run.stdout + run.stderr,
				refusal,
				scenario + ' must fail for its intended contract'
			);
			assert.equal(
				fs.existsSync(evidence),
				false,
				scenario + ' must publish no accepted observation'
			);
		}
		const remaining = invoke('pwsh.exe', [
			'-Command',
			'$owned = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -ieq ' +
				quote(executable) +
				' }); if ($owned.Count -ne 0) { throw "An owned source fixture survived cleanup." }'
		]);
		assert.equal(remaining.status, 0, remaining.stdout + remaining.stderr);
	}
	console.log('[OK] Ten native source observer scenarios prove refusal and process cleanup.');
};
