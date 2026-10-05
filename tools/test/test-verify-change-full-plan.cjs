// tools/test/test-verify-change-full-plan.cjs

/**
 * ==============================================================================
 * MODULE: Full Verification Plan Regression Tests
 * DESCRIPTION:
 * Runs the real planning CLI without executing any platform suite. Explicit
 * full audits must include the complete command inventory, while ordinary
 * verification remains scoped to the change.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { GATE_COMMANDS, selectGates } = require('./verify-change.cjs');

const root = path.resolve(__dirname, '../..');
const cli = path.join(__dirname, 'verify-change.cjs');

function plan(args) {
	const result = spawnSync(process.execPath, [cli, '--plan', '--range=HEAD..HEAD', ...args], {
		cwd: root,
		encoding: 'utf8',
		timeout: 10000
	});
	assert.ifError(result.error);
	assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
	assert(!result.stdout.includes('=== js ==='), 'planning must never execute a gate');
	return [...result.stdout.matchAll(/^   - ([\w-]+)/gm)].map((match) => match[1]);
}

const { run: runNativeSource } = require('./run-linux-xkb-source.cjs');
const nativeCalls = [];
for (const platform of ['darwin', 'win32']) {
	const logs = [];
	assert.equal(
		runNativeSource({
			platform,
			spawn: () => assert.fail('foreign hosts must defer'),
			log: (line) => logs.push(line)
		}),
		0
	);
	assert(
		logs.some((line) => line.includes('[DEFERRED]')),
		'foreign host cannot claim native Linux qualification'
	);
}
for (const result of [{ status: 2 }, { status: null }, { error: new Error('missing luajit') }]) {
	assert.notEqual(
		runNativeSource({
			platform: 'linux',
			spawn: (...args) => {
				nativeCalls.push(args);
				return result;
			},
			error: () => {}
		}),
		0,
		'Linux prerequisite and native fixture failures must remain blocking'
	);
}
const [command, arguments_, options] = nativeCalls[0];
assert.equal(command, 'luajit');
assert.deepEqual(arguments_, ['tests/hardware/run_xkb_source_qualification.lua']);
assert.equal(options.cwd, path.join(root, 'static/ergopti_plus/linux'));
assert(
	options.env.LUA_PATH.includes('../_shared/lua/?.lua'),
	'the native fixture loads the real shared driver modules'
);
assert.equal(
	options.stdio,
	'inherit',
	'native failure diagnostics must reach the verification receipt'
);
assert.equal(GATE_COMMANDS['linux-xkb-source'].npm, 'test:linux:xkb-source');
for (const file of [
	'static/ergopti_plus/linux/adapters/xkb_source_probe.lua',
	'static/ergopti_plus/linux/modules/hotstrings/magic_key_source.lua',
	'static/ergopti_plus/linux/tests/hardware/run_xkb_source_qualification.lua',
	'static/ergopti_plus/_shared/lua/shortcuts/magic_editor.lua'
])
	assert(
		selectGates([file]).has('linux-xkb-source'),
		`${file}: native source proof must be selected`
	);

assert.equal(GATE_COMMANDS['macos-tooltip-canvas'].npm, 'test:macos-tooltip-canvas');
for (const file of [
	'tools/diagnostics/macos_tooltip_canvas.py',
	'tools/diagnostics/macos_tooltip_canvas.lua',
	'tools/diagnostics/macos_tooltip_canvas_observer.py',
	'tools/diagnostics/macos_tooltip_canvas_test.py',
	'tools/diagnostics/macos_owned_process.py',
	'tools/test/run-macos-tooltip-canvas-tests.cjs'
])
	assert(
		selectGates([file]).has('macos-tooltip-canvas'),
		`${file}: pure canvas controls must be selected`
	);
assert(selectGates(['.github/workflows/ci-macos.yml']).has('js'));

assert.equal(GATE_COMMANDS['linux-http-stream'].npm, 'test:linux:http-stream');
for (const file of [
	'static/ergopti_plus/linux/adapters/http_client.lua',
	'static/ergopti_plus/linux/modules/llm/api_ollama.lua',
	'static/ergopti_plus/linux/tests/hardware/run_http_stream_receipts.lua',
	'static/ergopti_plus/_shared/lua/llm/local_model_policy.lua'
])
	assert(
		selectGates([file]).has('linux-http-stream'),
		`${file}: actual native streaming receipt proof must be selected`
	);

assert.equal(GATE_COMMANDS['linux-runtime-native'].npm, 'test:linux:runtime-native');
for (const file of [
	'static/ergopti_plus/_shared/lua/native_worker_owner.lua',
	'static/ergopti_plus/_shared/lua/llm/process_port.lua',
	'static/ergopti_plus/_shared/lua/llm/finite_process_port.lua',
	'static/ergopti_plus/_shared/lua/llm/process_limits.lua',
	'static/ergopti_plus/_shared/lua/llm/ollama_archive_installer.lua',
	'static/ergopti_plus/linux/adapters/owned_process.lua',
	'static/ergopti_plus/linux/modules/llm/ollama_install_files.lua',
	'static/ergopti_plus/linux/tests/hardware/run_owned_process_native.lua',
	'static/ergopti_plus/linux/tests/hardware/run_finite_process_port_native.lua',
	'static/ergopti_plus/linux/tests/hardware/run_service_process_port_native.lua',
	'static/ergopti_plus/linux/tests/hardware/run_service_running_native.lua',
	'static/ergopti_plus/linux/tests/hardware/run_ollama_install_files_native.lua',
	'static/ergopti_plus/linux/tests/hardware/run_ollama_install_files_native.py',
	'static/ergopti_plus/linux/tests/hardware/run_native_subreaper.py',
	'static/ergopti_plus/linux/tests/hardware/run_native_subreaper_teardown.py',
	'tools/test/run-linux-runtime-native.cjs',
	'.github/workflows/ci-linux.yml'
])
	assert(
		selectGates([file]).has('linux-runtime-native'),
		`${file}: actual runtime prerequisite proof must be selected`
	);

const failures = [];
for (const file of [
	'docs/ERGOPTIPLUS_TODO.md',
	'tools/test/test-layouts-registry.cjs',
	'static/ergopti/linux/xkb_generation/tests/test_keystroke_vectors.py'
]) {
	assert(
		selectGates([file]).has('format'),
		`${file}: scoped verification must run CI's actual formatter`
	);
}
assert.equal(GATE_COMMANDS.format.npm, 'format:check');
assert(!GATE_COMMANDS.format.coveredBy, 'the formatter self-tests do not check source formatting');
for (const args of [['--all'], ['--all', '--diagnose']]) {
	try {
		const actual = plan(args);
		assert(
			actual.includes('hs') && actual.includes('hs-e2e'),
			'a full audit must exercise Hammerspoon'
		);
		assert.deepEqual(
			[...actual].sort(),
			Object.keys(GATE_COMMANDS)
				.filter((gate) => !GATE_COMMANDS[gate].coveredBy)
				.sort(),
			'every independent gate must appear exactly once in the full plan'
		);
		for (const [gate, spec] of Object.entries(GATE_COMMANDS)) {
			if (spec.coveredBy)
				assert(
					actual.includes(spec.coveredBy) && !actual.includes(gate),
					`${gate}: the covering suite must execute instead of its duplicate`
				);
		}
		for (const driver of ['hs', 'linux']) {
			assert(
				actual.indexOf('js') < actual.indexOf(driver),
				'generated writers must finish before driver readers'
			);
		}
	} catch (error) {
		failures.push(`${args.join(' ')}: ${error.message}`);
	}
}
assert.deepEqual(
	plan([]),
	[],
	'ordinary verification must not expand an empty change into a full audit'
);
assert.deepEqual(
	[...selectGates(['static/ergopti_plus/macos/tests/unit/test_probe.lua']).keys()],
	['hs'],
	'a focused Hammerspoon test change must not select unrelated platform suites'
);
assert.deepEqual(
	[...selectGates(['docs/audits/performance/ahk/2026_09_13/probe/report.md']).keys()],
	['format', 'report-style'],
	'a historical performance report must not rebuild every driver or run the complete JS suite'
);
assert.deepEqual(
	[...selectGates(['docs/audits/performance/ahk/report.md', 'tools/test/probe.cjs']).keys()],
	['format', 'js'],
	'tool changes must retain the full JS gate, which already covers report style'
);
for (const file of [
	'static/ergopti_plus/_shared/modules/shortcuts/magic_editor.ahk',
	'static/ergopti_plus/_shared/modules/hotstrings/scope_overrides.ahk',
	'static/ergopti_plus/_shared/modules/llm/local_model_policy.ahk',
	'static/ergopti_plus/_shared/modules/future/owner.ahk'
]) {
	const gates = selectGates([file]);
	for (const gate of ['ahk-encoding', 'ahk-suite', 'ahk-parse', 'ahk-e2e'])
		assert(gates.has(gate), `${file}: portable AHK policy must retain ${gate}`);
	assert(
		!gates.has('hs') && !gates.has('linux'),
		`${file}: AHK policy does not select unrelated Lua suites`
	);
}
const mixedAhk = selectGates([
	'docs/audits/performance/ahk/report.md',
	'static/ergopti_plus/windows/modules/keylogger/keylogger_reader_db.ahk'
]);
for (const gate of ['report-style', 'ahk-encoding', 'ahk-suite', 'ahk-parse', 'ahk-e2e']) {
	assert(mixedAhk.has(gate), `mixed report and production AHK must retain ${gate}`);
}
for (const file of [
	'docs/memory/windows-ahk.md',
	'.agents/skills/verify-change/SKILL.md',
	'static/ergopti_plus/docs/architecture.md',
	'docs/audits/ahk/report.md',
	'docs/audits/performance/probe.json'
]) {
	assert(selectGates([file]).has('js'), `${file}: non-report consumers retain the JS gate`);
}
assert.deepEqual(failures, [], 'explicit full verification cannot omit declared suites');
assert.equal(GATE_COMMANDS['report-style'].npm, 'lint:conventions:strict');
assert.match(
	fs.readFileSync(path.join(__dirname, 'run-js-suite.cjs'), 'utf8'),
	/args: \['run', '--silent', 'lint:conventions:strict'\]/,
	'the JS suite must retain the exact command that subsumes report-style'
);
console.log(
	'verify-change full plan: complete inventory, diagnostic mode and narrow defaults passed.'
);
