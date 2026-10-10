// tools/test/test-managed-ollama-protocol.cjs

/** Receive portable source admission and operation closure without native credit. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

// The standalone selector is the existing collector's Windows component lane;
// the default still receives every original platform control below.
const args = process.argv.slice(2);
assert.ok(
	args.length === 0 || (args.length === 1 && args[0] === '--windows-file-port'),
	'Unknown managed Ollama receiving selector.'
);
function receiveWindowsComponentShellSetup() {
	const YAML = require('yaml');
	const workflow = YAML.parse(
		fs.readFileSync(path.resolve(__dirname, '../../.github/workflows/ci-windows.yml'), 'utf8')
	);
	const steps = workflow.jobs['test-ahk'].steps.filter(
		(step) => step.name === 'Receive managed Ollama file component'
	);
	assert.equal(steps.length, 1, 'The component has one actual PowerShell receiving owner.');
	assert.equal(steps[0].shell, 'pwsh');
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-component-shell-'));
	const source = path.join(owned, 'workflow-run.ps1');
	const control = path.join(owned, 'receive-setup.ps1');
	fs.writeFileSync(source, steps[0].run);
	// Parse the real workflow body and execute only its directory/module expressions.
	// The native31 command remains uncalled; this closes the pre-launch prerequisite.
	fs.writeFileSync(
		control,
		String.raw`param([string] $Source)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Actual component body must parse.' }
$right = 'Join-Path $env:SystemRoot ''System32/WindowsPowerShell/v1.0'''
$setup = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Right.Extent.Text -ceq $right
})
if ($setup.Count -ne 1) { throw 'Actual top-level runtime directory assignment is missing.' }
$directoryVariable = $setup[0].Left.Extent.Text
$moduleAssignments = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$env:PSModulePath' -and
    $node.Right.Extent.Text.StartsWith('(Join-Path ' + $directoryVariable + ' ')
}, $true))
$commands = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
    $node.CommandElements[0].Extent.Text -ceq ('"' + $directoryVariable + '/powershell.exe"')
}, $true))
if ($moduleAssignments.Count -ne 1 -or $commands.Count -ne 1) { throw 'Runtime directory authority is not forwarded exactly.' }
$probe = @'
param($ExpectedDirectory, $ExpectedModules, $ExpectedExecutable)
$ErrorActionPreference = 'Stop'
$capturedAutomaticDirectory = $PSHOME
$oldModulePath = $env:PSModulePath
'@ + "\n" + $setup[0].Extent.Text + "\n" + $moduleAssignments[0].Extent.Text + "\n" +
    '$observedDirectory = ' + $directoryVariable + "\n" +
    '$observedExecutable = ' + $commands[0].CommandElements[0].Extent.Text + "\n" + @'
if ($observedDirectory -cne $ExpectedDirectory) { throw 'Native PS5 directory binding differs.' }
if (-not $env:PSModulePath.StartsWith($ExpectedModules + ';')) { throw 'Native PS5 modules are not selected first.' }
if ($observedExecutable -cne $ExpectedExecutable) { throw 'Native executable binding differs.' }
if ($PSHOME -cne $capturedAutomaticDirectory) { throw 'The interpreter automatic directory was changed.' }
Write-Output 'COMPONENT-SHELL-SETUP PASS native_calls=0'
'@
$expected = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0'
$previousModules = $env:PSModulePath
try {
    & ([ScriptBlock]::Create($probe)) $expected (Join-Path $expected 'Modules') "$expected/powershell.exe"
} finally { $env:PSModulePath = $previousModules }
`
			.replace(/\\\$/g, '$')
			.replace(/\\n/g, '\n')
	);
	const result = spawnSync(
		'pwsh.exe',
		['-NoLogo', '-NoProfile', '-NonInteractive', '-File', control, source],
		{
			encoding: 'utf8',
			timeout: 15000,
			windowsHide: true
		}
	);
	assert.equal(result.error, undefined, `PowerShell setup control must start; retained ${owned}`);
	assert.equal(result.signal, null, `PowerShell setup control must retire; retained ${owned}`);
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.equal(result.stderr, '');
	assert.equal(result.stdout.replace(/\r\n/g, '\n'), 'COMPONENT-SHELL-SETUP PASS native_calls=0\n');
	process.stdout.write(result.stdout);
}

function receiveFileFixtureProducer() {
	const fixtures = path.resolve(
		__dirname,
		'../../static/ergopti_plus/windows/tests/fixtures/ollama-install-files'
	);
	const receipts = JSON.parse(fs.readFileSync(path.join(fixtures, 'receipts.json'), 'utf8'));
	assert.equal(
		Object.keys(receipts).length,
		16,
		'All declared namespace fixtures must be present.'
	);
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ollama-fixture-'));
	const producer = path.join(owned, 'build-fixtures.py');
	fs.copyFileSync(path.join(fixtures, 'build-fixtures.py'), producer);
	const result = spawnSync(pythonExecutable(), [producer], {
		encoding: 'utf8',
		timeout: 60000,
		windowsHide: true
	});
	assert.equal(result.error, undefined, `Fixture producer must start; retained ${owned}`);
	assert.equal(result.signal, null, `Fixture producer must retire; retained ${owned}`);
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.equal(result.stderr, '');
	const expected = [
		'build-fixtures.py',
		'receipts.json',
		'payloads.json',
		...Object.keys(receipts).map((name) => `${name}.zip`)
	].sort();
	assert.deepEqual(
		fs.readdirSync(owned).sort(),
		expected,
		'Producer must author every exact declared fixture.'
	);
	for (const name of expected) {
		const file = path.join(owned, name);
		assert.ok(
			fs.lstatSync(file).isFile() && !fs.lstatSync(file).isSymbolicLink(),
			'Only exact owned regular files may retire.'
		);
		assert.deepEqual(
			fs.readFileSync(file),
			fs.readFileSync(path.join(fixtures, name)),
			`Generated ${name} must preserve its canonical bytes.`
		);
	}
	// Only successful, terminal generation and the closed file census permit
	// exact unlinks; failures retain the owned namespace and never recurse.
	for (const name of expected) fs.unlinkSync(path.join(owned, name));
	fs.rmdirSync(owned);
	process.stdout.write('WINDOWS-FILE-FIXTURES generated=16 byte_exact=true native=false\n');
}
function receiveWindowsFilePort() {
	assert.equal(process.platform, 'win32', 'The Windows file-port models require native PS5.1.');
	const repository = path.resolve(__dirname, '../..');
	const psHome = path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0');
	const moduleKey = Object.keys(process.env).find((key) => key.toLowerCase() === 'psmodulepath');
	const env = { ...process.env };
	const modules = path.join(psHome, 'Modules');
	const inherited = moduleKey ? env[moduleKey] : '';
	if (moduleKey) delete env[moduleKey];
	env.PSModulePath = [
		modules,
		...inherited
			.split(';')
			.filter(
				(entry) =>
					entry && path.resolve(entry).toLowerCase() !== path.resolve(modules).toLowerCase()
			)
	].join(';');
	const helper = path.join(
		repository,
		'static/ergopti_plus/windows/modules/llm/ollama_managed_files.ps1'
	);
	let models = 0;
	for (const [script, count] of [
		['windows_ollama_file_validation_test.ps1', 13],
		['windows_ollama_file_publication_test.ps1', 4],
		['windows_ollama_file_default_paths_test.ps1', 8],
		['windows_ollama_file_final_close_test.ps1', 1]
	]) {
		const result = spawnSync(
			path.join(psHome, 'powershell.exe'),
			[
				'-NoLogo',
				'-NoProfile',
				'-NonInteractive',
				'-File',
				path.join(__dirname, script),
				'-Helper',
				helper
			],
			{ cwd: repository, env, encoding: 'utf8', timeout: 60000, windowsHide: true }
		);
		assert.equal(result.error, undefined, 'The actual source-bound model must start.');
		assert.equal(result.signal, null, 'The actual source-bound model must retire.');
		assert.equal(result.stderr, '', result.stderr);
		const stdout = result.stdout.replace(/\r\n?/g, '\n');
		if (count !== 1) {
			assert.equal(result.status, 0, stdout);
			assert.equal(stdout.split('\n').filter((line) => line.startsWith('PASS ')).length, count);
			assert.doesNotMatch(stdout, /^FAIL /m);
			assert.match(
				stdout,
				new RegExp(
					`^RESULT passed=${count} failed=0 native_calls=0(?: real_file_acquisitions=0)?\\n$`,
					'm'
				)
			);
		} else {
			// The actual CLI preserves its refusal exit; that is the control's input.
			assert.equal(result.status, 1, 'Final root-close refusal must retain the actual CLI exit1.');
			const fact = JSON.parse(stdout);
			assert.equal(fact.ok, false);
			assert.equal(fact.phase, 'refused');
			assert.equal(fact.cleanup_pending, true);
			assert.equal(fact.error, 'Injected exact final root close refusal.');
			assert.equal(fact.ticket, '1'.repeat(32));
			assert.ok(!Object.hasOwn(fact, 'executable'));
			assert.deepEqual(fact.publication_receipt, {
				ticket: '1'.repeat(32),
				root_identity: '11111111:0000000000000000',
				stage_identity: '11111111:0000000000000001',
				manifest_sha256: '2'.repeat(64),
				version_path: 'Z:\\owned\\versions\\captured',
				renamed: true,
				cleanup_pending: true
			});
		}
		models += count;
		process.stdout.write(stdout);
	}
	assert.equal(models, 26, 'All source-bound Windows model controls must be received.');
	process.stdout.write('WINDOWS-FILE-PORT models=26 native=false acquisition=false\n');
}
function receiveWindowsRuntimeHandoff() {
	assert.equal(
		process.platform,
		'win32',
		'Runtime recording receiving requires the production PS5 interpreter.'
	);
	const repository = path.resolve(__dirname, '../..');
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runtime-model-'));
	const psHome = path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0');
	const env = { ...process.env, TEMP: owned, TMP: owned };
	const moduleKey = Object.keys(env).find((key) => key.toLowerCase() === 'psmodulepath');
	if (moduleKey) delete env[moduleKey];
	env.PSModulePath = path.join(psHome, 'Modules');
	const result = spawnSync(
		path.join(psHome, 'powershell.exe'),
		[
			'-NoLogo',
			'-NoProfile',
			'-NonInteractive',
			'-File',
			path.join(
				repository,
				'static/ergopti_plus/windows/tests/unit/test_ollama_runtime_launch.ps1'
			),
			'-Source',
			path.join(repository, 'static/ergopti_plus/windows/modules/llm/ollama-runtime-launch.ps1'),
			'-PrivateRoot',
			owned
		],
		{ cwd: owned, env, encoding: 'utf8', timeout: 60000, windowsHide: true }
	);
	assert.equal(result.error, undefined, `Runtime model must start; retained ${owned}`);
	assert.equal(result.signal, null, `Runtime model must retire; retained ${owned}`);
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const stdout = result.stdout.replace(/\r\n?/g, '\n');
	const stderr = result.stderr.replace(/\r\n?/g, '\n');
	assert.equal(
		stderr,
		'Owned runtime retains image leases: exact job accounting is unavailable.\n'
	);
	assert.equal(stdout.split('\n').filter((line) => line.startsWith('PASS ')).length, 9);
	assert.doesNotMatch(stdout, /^FAIL /m);
	assert.match(stdout, /^RESULT passed=9 failed=0\n$/m);
	// The small private fixture namespace remains a retained receiving artifact.
	process.stdout.write(stdout);
	process.stdout.write('WINDOWS-RUNTIME-HANDOFF models=9 native_runtime=false http=false\n');
}
if (process.platform === 'win32') receiveWindowsComponentShellSetup();
receiveFileFixtureProducer();
if (args.length === 1) {
	receiveWindowsFilePort();
	receiveWindowsRuntimeHandoff();
	process.exit(0);
}
if (process.platform === 'win32') {
	receiveWindowsFilePort();
	receiveWindowsRuntimeHandoff();
}

const cases = [
	['tools/test/managed_ollama_runtime_policy_test.py', 7],
	['tools/test/managed_ollama_pull_test.py', 8]
];
if (process.platform !== 'win32') {
	// Real files and CLI; modeled host admission grants no native macOS credit.
	cases.push(['tools/test/macos_managed_ollama_catalogue_refusal_test.py', 12]);
	cases.push(['tools/test/macos_native_ollama_api_test.py', 20]);
	cases.push(['tools/test/macos_native_http_receiving_facts_test.py', 55]);
	cases.push(['tools/test/macos_managed_ollama_explicit_stream_test.py', 6]);
	cases.push(['tools/diagnostics/macos_managed_ollama_receiving_test.py', 16]);
	cases.push(['tools/test/managed_ollama_sessions_test.py', 11]);
	cases.push(['tools/diagnostics/macos_ollama_alias_selector_test.py', 8]);
	cases.push(['tools/diagnostics/macos_ollama_hint_metadata_test.py', 19]);
	cases.push(['tools/diagnostics/macos_ollama_serve_command_receiving_test.py', 2]);
	cases.push(['tools/diagnostics/macos_native_python_probe_io_test.py', 3]);
	cases.push(['tools/test/macos_managed_ollama_pull_caller_test.py', 11]);
	cases.push(['tools/test/macos_managed_ollama_cleanup_test.py', 36]);
	cases.push(['tools/test/managed_source_alias_test.py', 23]);
	cases.push(['tools/diagnostics/macos_owned_image_alias_test.py', 20]);
	cases.push(['tools/test/macos_native_ollama_alias_api_test.py', 5]);
	cases.push(['tools/diagnostics/macos_source_alias_owner_test.py', 19]);
	cases.push(['tools/diagnostics/macos_listener_path_identity_test.py', 12]);
	cases.push(['tools/diagnostics/macos_owned_private_session_test.py', 5]);
	cases.push(['tools/test/macos_bootstrap_tls_numeric_binding_test.py', 8]);
	cases.push(['tools/test/owned_suspended_image_portable_test.py', 3]);
	cases.push(['tools/diagnostics/macos_suspended_image_owner_test.py', 28]);
	cases.push(['tools/diagnostics/macos_ollama_bootstrap_owner_test.py', 22]);
	cases.push(['tools/diagnostics/macos_trusted_native_guardian_test.py', 10]);
	cases.push(['tools/diagnostics/macos_guardian_retirement_order_test.py', 6]);
	cases.push(['tools/diagnostics/macos_ollama_daemon_authority_test.py', 14]);
	cases.push(['tools/diagnostics/macos_managed_ollama_serve_test.py', 44]);
	cases.push(['tools/diagnostics/macos_ollama_daemon_authority_reader_test.py', 13]);
	cases.push(['tools/diagnostics/macos_native_wire_swift_dependencies_test.py', 10]);
	// Preserve the original 37 controls and add seven atomic-result receiving laws.
	cases.push(['tools/test/managed_ollama_go_evidence_test.py', 45]);
} else {
	process.stdout.write(
		'SKIP actual POSIX process peers on Windows; Apple SDK receiving is separate.\n'
	);
}
for (const [script, expected] of cases) {
	const result = spawnSync(pythonExecutable(), [script], {
		cwd: path.resolve(__dirname, '../..'),
		encoding: 'utf8',
		timeout: 60000
	});
	assert.equal(result.error, undefined, 'the portable receiver must start');
	assert.equal(result.signal, null, 'the portable receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(
		result.stderr,
		new RegExp(`Ran ${expected} ${expected === 1 ? 'test' : 'tests'} in`)
	);
	assert.match(result.stderr, /\bOK\b/);
	assert.doesNotMatch(result.stderr, /skipped=/);
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
// These injected ports are portable receiving controls, not native process
// evidence. Keep their literal corpora registered alongside the Python owner.
// Hammerspoon owns these ports on Lua 5.4. LuaJIT cannot observe the fourth
// generic-for value closing a native directory, so it cannot qualify this owner.
const runtime = 'lua5.4';
const admission = spawnSync(runtime, ['-e', 'assert(_VERSION == "Lua 5.4")'], {
	encoding: 'utf8',
	timeout: 60000
});
assert.equal(admission.error, undefined, 'the macOS portable receiver requires Lua 5.4');
assert.equal(admission.signal, null, 'the Lua 5.4 admission must retire');
assert.equal(admission.status, 0, admission.stderr || admission.stdout);
for (const [script, expected] of [
	['tools/test/managed_ollama_pull_receipt_test.lua', 41],
	['tools/test/managed_ollama_pull_adapter_test.lua', 50],
	['tools/test/managed_native_python_test.lua', 8],
	['tools/test/managed_ollama_cleanup_receipt_test.lua', 102]
]) {
	const result = spawnSync(
		runtime,
		[path.resolve(__dirname, '../..', script), path.resolve(__dirname, '../..')],
		{
			cwd: path.resolve(__dirname, '../..'),
			encoding: 'utf8',
			timeout: 60000
		}
	);
	assert.equal(result.error, undefined, 'the injected Lua receiver must start');
	assert.equal(result.signal, null, 'the injected Lua receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(result.stdout, new RegExp(`controls passed: ${expected}\\s*$`));
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
// Keep real owner phase controls registered; their ports do not grant SDK credit.
for (const [script, expectedCases, expectedAssertions] of [
	['tools/test/managed_ollama_cleanup_owner_test.lua', 58, 780],
	['tools/test/managed_ollama_legacy_cleanup_test.lua', 8, 45],
	['tools/test/native_python_probe_test.lua', 45, 331]
]) {
	const result = spawnSync(
		runtime,
		[path.resolve(__dirname, '../..', script), path.resolve(__dirname, '../..')],
		{
			cwd: path.resolve(__dirname, '../..'),
			encoding: 'utf8',
			timeout: 60000
		}
	);
	assert.equal(result.error, undefined, 'the owned deletion receiver must start');
	assert.equal(result.signal, null, 'the owned deletion receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(
		result.stdout,
		new RegExp(`controls passed: ${expectedCases} cases / ${expectedAssertions} assertions\\s*$`)
	);
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
// New command composers receive both candidate and canonical source roots.
for (const [script, expectedCases, expectedAssertions] of [
	['tools/test/managed_ollama_restart_envelope_test.lua', 5, 12],
	['tools/test/managed_ollama_serve_command_test.lua', 7, 47],
	['tools/test/managed_ollama_serve_kind_forwarding_test.lua', 6, 15],
	['tools/test/managed_ollama_hint_task_test.lua', 29, 361]
]) {
	const root = path.resolve(__dirname, '../..');
	const result = spawnSync(runtime, [path.join(root, script), root, root], {
		cwd: root,
		encoding: 'utf8',
		timeout: 60000
	});
	assert.equal(result.error, undefined, 'the command composer receiver must start');
	assert.equal(result.signal, null, 'the command composer receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(
		result.stdout,
		new RegExp(`PASS ${expectedCases} cases / ${expectedAssertions} assertions\\s*$`)
	);
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
// Load the actual pull unit over its existing explicit Hammerspoon ports.
// This receiving count is independent of native source/SDK qualification.
const pullRoot = path.resolve(__dirname, '../..');
const pullProgram = `
local root = ${JSON.stringify(pullRoot)}
local driver = root .. "/static/ergopti_plus/macos"
local shared = root .. "/static/ergopti_plus/_shared/lua"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. driver .. "/tests/stubs/?.lua;" .. package.path
_G.hs = require("hs")
assert(loadfile(driver .. "/tests/unit/ui/menu/menu_llm/test_managed_ollama_pull_activation.lua"))()
local results = require("tests.helpers").get_results()
assert(results.failed == 0 and results.passed == 16, "all pull activation controls must pass")
print("Managed pull activation controls passed: " .. results.passed)
`;
const pullResult = spawnSync(runtime, ['-e', pullProgram], {
	cwd: pullRoot,
	encoding: 'utf8',
	timeout: 60000
});
assert.equal(pullResult.error, undefined, 'the original pull receiver must start');
assert.equal(pullResult.signal, null, 'the original pull receiver must settle');
assert.equal(pullResult.status, 0, pullResult.stderr || pullResult.stdout);
assert.match(pullResult.stdout, /Managed pull activation controls passed: 16\s*$/);
process.stdout.write(pullResult.stdout);
process.stdout.write(pullResult.stderr);
process.stdout.write(
	'Native Go/macOS build, signing, model exchange and SDK admission were not executed.\n'
);
