// tools/test/test-linux-runtime-native-registration.cjs

/**
 * ==============================================================================
 * MODULE: Native Linux Runtime Gate Admission
 * DESCRIPTION:
 * Independently checks mandatory planner/CI registration, truthful completed
 * receipts and serial physical probe ownership. Controlled process doubles are
 * registration evidence; real native proof remains the separately selected gate.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const Pipeline = require('./ci-pipeline.cjs');
const { run } = require('./run-linux-runtime-native.cjs');
const ROOT = path.resolve(__dirname, '../..');
const STEP = 'Qualify native runtime prerequisites';
const RUNNER = 'tools/test/run-linux-runtime-native.cjs';
const CONTRACT = 'tools/test/test-linux-runtime-native-registration.cjs';
const CONDITION_ROW =
	/\[\s*LINUX_BOX,\s*'e2e-linux',\s*'Qualify native runtime prerequisites',\s*NOT_CANCELLED,?\s*\]/;
const SOURCES = [
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
	'static/ergopti_plus/linux/adapters/http_client.lua',
	'static/ergopti_plus/linux/adapters/curl_http_client.lua',
	'static/ergopti_plus/linux/tests/hardware/run_http_owned_post_native.lua',
	'static/ergopti_plus/linux/tests/hardware/run_http_owned_post_native.py',
	RUNNER,
	'.github/workflows/ci-linux.yml'
];

const MANUAL_STEP = 'Run manual official runtime and model acceptance';
const MANUAL_EVIDENCE_STEP = 'Upload manual runtime acceptance evidence';
const MANUAL_IF =
	"${{ github.event_name == 'workflow_dispatch' && !inputs.release && !cancelled() }}";
const MANUAL_EVIDENCE_IF =
	"${{ github.event_name == 'workflow_dispatch' && !inputs.release && !cancelled() }}";
const MANUAL_FIXTURES = [
	'static/ergopti_plus/linux/tests/hardware/run_ollama_runtime_acceptance.lua',
	'static/ergopti_plus/linux/tests/hardware/run_ollama_runtime_acceptance.py'
];

/** Registers manual external proof without weakening the original 64-case gate. */
function validateManual(root) {
	const pipeline = Pipeline.open(root);
	const job = pipeline.job('test-linux');
	const step = Pipeline.step(job, MANUAL_STEP);
	assert.equal(Pipeline.stepField(step, 'if'), MANUAL_IF);
	assert.equal(Pipeline.stepField(step, 'continue-on-error'), null);
	assert.equal(Pipeline.stepField(step, 'timeout-minutes'), '18');
	const run = Pipeline.stepField(step, 'run');
	assert.match(run, /set -euo pipefail/);
	assert.match(
		run,
		/python3 static\/ergopti_plus\/linux\/tests\/hardware\/run_ollama_runtime_acceptance\.py/
	);
	assert.match(run, /--repository "\$GITHUB_WORKSPACE"/);
	assert.match(run, /--evidence "\$RUNNER_TEMP\/ollama-runtime-acceptance"/);
	assert.match(run, /--lua luajit/);
	assert.doesNotMatch(run, /\|\| true|install\.sh|ollama pull|ollama serve|--managed-data|--cache/);
	const upload = Pipeline.step(job, MANUAL_EVIDENCE_STEP);
	assert.equal(Pipeline.stepField(upload, 'if'), MANUAL_EVIDENCE_IF);
	assert.equal(Pipeline.stepField(upload, 'continue-on-error'), null);
	assert.match(upload, /uses: actions\/upload-artifact@v4/);
	assert.match(upload, /if-no-files-found: error/);
	assert.match(
		upload,
		/path: \$\{\{ runner\.temp \}\}\/ollama-runtime-acceptance\/ollama-runtime-acceptance\.json/
	);
	assert.doesNotMatch(upload, /private\.log|inference\.private|\*\*/);
	const names = Pipeline.steps(job).map((value) => value.name);
	assert(names.indexOf(MANUAL_STEP) > names.indexOf('Run the driver unit test suite'));
	assert(names.indexOf(MANUAL_STEP) < names.indexOf('Record mandatory unit evidence'));
	assert(names.indexOf(MANUAL_EVIDENCE_STEP) > names.indexOf(MANUAL_STEP));
	const py = fs.readFileSync(path.join(root, MANUAL_FIXTURES[1]), 'utf8');
	const lua = fs.readFileSync(path.join(root, MANUAL_FIXTURES[0]), 'utf8');
	for (const source of [py, lua]) {
		assert(source.includes('15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb'));
		assert(source.includes('1198635318'));
		assert(source.includes('granite4:350m-h'));
		assert.doesNotMatch(source, /ergopti-validation|\/workspace\/|--managed-data/);
	}
	assert.match(lua, /local action = "download"/);
	assert.match(lua, /original_get_owned\(url, headers, options/);
	assert.match(lua, /Http\.post_stream_owned = function/);
	assert.match(lua, /pull_operation:is_settled\(\) == true/);
	assert.match(lua, /Engine\.shutdown_runtime/);
	assert.match(lua, /wait_for_ack = true/);
	assert.match(lua, /EventLoop\.run/);
	assert.match(lua, /while uv\.loop_alive\(\) do uv\.run\("once"\) end/);
	assert.match(py, /GITHUB_EVENT_NAME.*workflow_dispatch/);
	assert.doesNotMatch(
		py,
		/\bHOME\s*=|[\'"](?:HOME|CODEX_HOME)[\'"]\s*\]\s*=/,
		'explicit XDG/model profile seams preserve inherited HOME'
	);
	assert.match(py, /return owner\.main\(args\.child_command, deadline_seconds=930\)/);
	assert.match(py, /closure\s*=\s*physical_receipt\(text\)/);
	assert.match(py, /physical_zero\s*=\s*closure\s+is\s+not\s+None/);
	assert.match(py, /physical_closure\s*=\s*closure/);
	assert.match(py, /before == after/);
	assert.match(py, /result\.returncode == 0 and stable and physical_zero/);
	assert.match(py, /return 0 if accepted else 1/);
	assert.match(py, /document\.update\(\s*passed\s*=\s*False\s*,\s*status\s*=\s*"failed"\s*,/);
}

/** Exercises the actual pure parser without importing the external installer. */
function validatePhysicalReceipt(root) {
	const control = String.raw`
import ast, json, pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
tree = ast.parse(source)
nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'physical_receipt']
assert len(nodes) == 1, 'one actual native receipt parser must exist'
namespace = {'json': json, 're': re}
exec(compile(ast.Module(body=nodes, type_ignores=[]), '<native physical receipt parser>', 'exec'), namespace)
parse = namespace['physical_receipt']
prefix = 'Native subreaper closure: '
def old(adopted):
    return f'Native subreaper: {adopted} adopted descendants physically reaped\n'
def receipt(value, adopted=0):
    return old(adopted) + prefix + json.dumps(value) + '\n'
for adopted in (0, 2):
    value = {'pending': 0, 'rescue': 0, 'adopted': adopted}
    assert parse(receipt(value, adopted)) == value, 'reaped adoption is separate from outstanding ownership'
valid = receipt({'pending': 0, 'rescue': 0, 'adopted': 0})
invalid = [
    '', old(0), prefix + json.dumps({'pending': 0, 'rescue': 0, 'adopted': 0}) + '\n',
    valid + prefix + json.dumps({'pending': 0, 'rescue': 0, 'adopted': 0}) + '\n',
    old(0) + valid, old(0) + prefix + '{broken}\n',
    old(0) + prefix + '[]\n', old(0) + prefix + 'null\n',
    receipt({'pending': 1, 'rescue': 0, 'adopted': 0}),
    receipt({'pending': 0, 'rescue': 1, 'adopted': 0}),
    receipt({'pending': 0, 'rescue': 0, 'adopted': 2}),
    receipt({'pending': 0, 'rescue': 0}),
    receipt({'pending': 0, 'rescue': 0, 'adopted': 0, 'extra': 0}),
    old(0) + prefix + '{"pending":1,"pending":0,"rescue":0,"adopted":0}\n',
    'extra ' + valid.replace(old(0), ''),
]
for key in ('pending', 'rescue', 'adopted'):
    for bad in (True, False, -1, 0.0, '0', None):
        value = {'pending': 0, 'rescue': 0, 'adopted': 0}
        value[key] = bad
        invalid.append(receipt(value))
for value in invalid:
    assert parse(value) is None, 'malformed, duplicate or outstanding physical receipt must be refused'
print(f'Native physical receipt parser: 2 admitted, {len(invalid)} refused')
`;
	const result = spawnSync(
		process.platform === 'win32' ? 'python' : 'python3',
		['-c', control, path.join(root, MANUAL_FIXTURES[1])],
		{ encoding: 'utf8', timeout: 30000 }
	);
	assert.ifError(result.error);
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout.trim(), 'Native physical receipt parser: 2 admitted, 33 refused');
}

/** Reads the actual declarations, with no implementation-generated expectations. */
function validate(root) {
	const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
	const scripts = JSON.parse(read('package.json')).scripts;
	assert.equal(scripts['test:linux:runtime-native'], `node ./${RUNNER}`);
	assert.equal(scripts['test:linux-runtime-native-registration'], `node ./${CONTRACT}`);
	const plannerPath = path.join(root, 'tools/test/verify-change.cjs');
	delete require.cache[require.resolve(plannerPath)];
	const planner = require(plannerPath);
	assert.equal(planner.GATE_COMMANDS['linux-runtime-native']?.npm, 'test:linux:runtime-native');
	for (const source of SOURCES)
		assert(
			planner.selectGates([source]).has('linux-runtime-native'),
			`${source}: mandatory native selection`
		);
	assert(read('tools/test/run-js-suite.cjs').includes(`args: ['${CONTRACT}']`));
	assert(read('tools/test/test-npm-aliases-match-the-suite.cjs').includes(`'${RUNNER}',`));
	assert.match(read('tools/test/test-ci-pipeline-wiring.cjs'), CONDITION_ROW);
	const pipeline = Pipeline.open(root);
	const job = pipeline.job('e2e-linux');
	const body = Pipeline.step(job, STEP);
	assert.equal(Pipeline.stepField(body, 'if'), '${{ !cancelled() }}');
	assert.equal(Pipeline.stepField(body, 'continue-on-error'), null);
	assert.equal(Pipeline.stepField(body, 'working-directory'), null, 'npm uses the repository root');
	assert.equal(Pipeline.stepField(body, 'timeout-minutes'), '5');
	const command = Pipeline.stepField(body, 'run');
	assert.match(command, /set -euo pipefail/);
	assert.match(command, /sudo apt-get install -y --no-install-recommends zstd/);
	assert.match(
		command,
		/npm run test:linux:runtime-native \| tee "\$RUNNER_TEMP\/linux-runtime-native\.log"/
	);
	assert.doesNotMatch(command, /\|\| true|continue-on-error|exit 0/);
	const steps = Pipeline.steps(job).map((value) => value.name);
	assert(
		steps.indexOf(STEP) > steps.indexOf('Qualify native HTTP streaming receipts'),
		'native dependencies precede this proof'
	);
	const early = Pipeline.step(job, 'Terminate real descendants after their process leader exits');
	assert.match(Pipeline.stepField(early, 'run'), /apt-get install[^\n]*lua-luv lua5\.4 curl/);
	validateManual(root);
}

/** Supplies independent complete receipts through a strictly recording spawn port. */
function fakeRun({ platform = 'linux', change = (result) => result } = {}) {
	const calls = [],
		lines = [],
		errors = [];
	const expected = new Map([
		['run_owned_process_native.lua', 'Actual owned processes: 10 passed, 0 failed'],
		['run_finite_process_port_native.lua', 'Finite shared process native: 4 passed, 0 failed.'],
		['run_service_process_port_native.lua', 'Service shared process native: 4 passed, 0 failed.'],
		['run_service_running_native.lua', 'Actual service running controls: 2 passed, 0 failed.'],
		[
			'run_ollama_install_files_native.py',
			'Install native filesystem receipts: 11 passed, 0 failed.'
		],
		['run_http_owned_post_native.py', 'Actual owned POST paired receipts: 9 passed, 0 failed.'],
		['run_native_subreaper_teardown.py', 'Native wrapper failure teardown: 2 passed, 0 failed']
	]);
	let index = 0;
	const status = run({
		platform,
		environment: { PYTHON: 'private-python', PATH: 'fixture-path', LUA_CPATH: 'existing-cpath' },
		spawn: (program, argv, options) => {
			calls.push({ program, argv, options });
			assert(!options.shell, 'native argv never crosses a shell or Windows bridge');
			if (argv[0] === '-v') return { status: 0, stdout: 'LuaJIT 2.1\n', stderr: '' };
			if (argv[0] === '-e')
				return { status: 0, stdout: `Linux native ABI ready: ${program}\n`, stderr: '' };
			const script =
				path.basename(argv[0]) === 'run_native_subreaper.py'
					? path.basename(argv[2])
					: path.basename(argv[0]);
			assert(expected.has(script), 'only independently listed probes may execute');
			const stdout =
				expected.get(script) +
				'\n' +
				(script.endsWith('_teardown.py')
					? ''
					: 'Native subreaper: 1 adopted descendants physically reaped\n');
			const paired =
				script === 'run_http_owned_post_native.py'
					? 'Actual owned POST: 4 passed, 0 failed; exact native cleanup complete.\n' +
						'Actual owned POST: 5 passed, 0 failed; exact native cleanup complete.\n' +
						'Native subreaper: 2 adopted descendants physically reaped\n'
					: '';
			return change({ status: 0, stdout: stdout + paired, stderr: '' }, index++, script);
		},
		log: (line) => lines.push(line),
		error: (line) => errors.push(line)
	});
	return { status, calls, lines, errors };
}

/** Runs the materialized controlled manual diagnostics on their Linux host contract. */
function validateDiagnosticProjection(root) {
	if (process.platform !== 'linux') {
		console.log('[DEFERRED] Controlled manual Linux diagnostics require the Linux preflight host.');
		return;
	}
	const fixture = path.join(root, 'tools/test/test-linux-runtime-acceptance-diagnostics.py');
	assert(fs.existsSync(fixture), 'the controlled diagnostics must be a durable repository fixture');
	const result = spawnSync(
		'python3',
		['--', fixture, '--source', path.join(root, MANUAL_FIXTURES[1]), '--repository', root],
		{ encoding: 'utf8', timeout: 30000 }
	);
	assert.ifError(result.error);
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const receipt = result.stderr || '';
	assert.equal((receipt.match(/^Ran 14 tests in /gm) || []).length, 1);
	assert.equal((receipt.match(/^OK$/gm) || []).length, 1);
	assert.doesNotMatch(receipt, /(?:skipped=|\bSKIP\b)/i);
	console.log('PASS: Controlled manual Linux diagnostics: 14 tests.');
}

function main() {
	validate(ROOT);
	validatePhysicalReceipt(ROOT);
	validateDiagnosticProjection(ROOT);
	for (const platform of ['darwin', 'win32']) {
		const result = fakeRun({ platform });
		assert.equal(result.status, 0);
		assert.equal(result.calls.length, 0);
		assert(result.lines.some((line) => line.includes('[DEFERRED]')));
		assert(!result.lines.some((line) => line.includes('PASS native')));
	}
	const passed = fakeRun();
	assert.equal(passed.status, 0);
	const jitAdmission = passed.calls.find(
		(call) => call.program === 'luajit' && call.argv[0] === '-e'
	);
	assert.match(jitAdmission.argv[1], /assert\(_VERSION == "Lua 5\.1"\)/);
	assert.match(jitAdmission.argv[1], /type\(jit\) == "table"/);
	assert.match(jitAdmission.argv[1], /type\(jit\.version\) == "string"/);
	assert(jitAdmission.argv[1].includes('jit.version:match("^LuaJIT %d")'));
	assert.match(jitAdmission.argv[1], /jit\.os == "Linux"/);
	assert.match(jitAdmission.argv[1], /require\("luv"\)\.os_uname\(\)\.sysname == "Linux"/);
	const lua54Admission = passed.calls.find(
		(call) => call.program === 'lua5.4' && call.argv[0] === '-e'
	);
	assert.match(lua54Admission.argv[1], /assert\(_VERSION == "Lua 5\.4"\)/);
	const physical = passed.calls.filter((call) => call.program === 'private-python');
	assert.equal(physical.length, 13);
	const pairedPhysical = physical.filter(
		(call) => path.basename(call.argv[0]) === 'run_http_owned_post_native.py'
	);
	const legacyPhysical = physical.filter(
		(call) => path.basename(call.argv[0]) !== 'run_http_owned_post_native.py'
	);
	assert.equal(legacyPhysical.length, 11, 'all original physical dispatches remain mandatory');
	assert.equal(pairedPhysical.length, 2);
	assert.deepEqual(
		pairedPhysical.map((call) => call.argv.slice(1)),
		['luajit', 'lua5.4'].map((abi) => [
			path.join(ROOT, 'static/ergopti_plus/linux'),
			'--shared-lua',
			path.join(ROOT, 'static/ergopti_plus/_shared/lua'),
			'--lua',
			abi
		])
	);
	assert(
		passed.lines.includes(
			'PASS native Linux runtime prerequisites: 82 checks (64 original, 18 owned POST)'
		)
	);
	const ordered = [
		'run_owned_process_native.lua',
		'run_finite_process_port_native.lua',
		'run_service_process_port_native.lua',
		'run_service_running_native.lua',
		'run_ollama_install_files_native.py'
	];
	assert.deepEqual(
		legacyPhysical.map((call) =>
			path.basename(call.argv[0]) === 'run_native_subreaper.py'
				? path.basename(call.argv[2])
				: path.basename(call.argv[0])
		),
		[...ordered, ...ordered, 'run_native_subreaper_teardown.py']
	);
	assert.deepEqual(
		legacyPhysical.slice(0, 4).map((call) => call.argv[1]),
		['luajit', 'luajit', 'luajit', 'luajit']
	);
	assert.deepEqual(
		legacyPhysical.slice(5, 9).map((call) => call.argv[1]),
		['lua5.4', 'lua5.4', 'lua5.4', 'lua5.4']
	);
	for (const index of [4, 9])
		assert.equal(
			legacyPhysical[index].argv[2],
			'--lua',
			'builder owns its existing subreaper internally'
		);
	for (const call of physical) {
		assert.equal(call.options.cwd, path.join(ROOT, 'static/ergopti_plus/linux'));
		assert.equal(call.options.env.LUA_CPATH, 'existing-cpath');
		assert(call.options.env.LUA_PATH.includes('../_shared/lua/?.lua'));
		assert.equal(call.options.timeout, 120000);
	}
	for (const index of [0, 4, 6, 10, 12, 5, 11]) {
		const refused = fakeRun({
			change: (result, ordinal) => (ordinal === index ? { ...result, status: 17 } : result)
		});
		assert.equal(
			refused.status,
			17,
			'either ABI, installer or teardown failure retains its actual status'
		);
		assert.equal(
			refused.calls.filter((call) => call.program === 'private-python').length,
			13,
			'later mandatory proofs remain observed'
		);
	}
	for (const invalid of [
		{ status: null, signal: 'SIGTERM' },
		{ error: new Error('missing Python') },
		{ status: 0, stdout: '' },
		{ status: 0, stdout: 'SKIP missing prerequisites\n' },
		{
			status: 0,
			stdout:
				'Actual owned processes: 9 passed, 0 failed\nNative subreaper: 0 adopted descendants physically reaped\n'
		},
		{ status: 0, stdout: 'Actual owned processes: 10 passed, 0 failed\n' },
		{
			status: 0,
			stdout:
				'Actual owned processes: 10 passed, 0 failed\nActual owned processes: 10 passed, 0 failed\nNative subreaper: 0 adopted descendants physically reaped\n'
		}
	])
		assert.notEqual(
			fakeRun({ change: (result, index) => (index === 0 ? invalid : result) }).status,
			0
		);
	const direct = 'Actual owned POST: 4 passed, 0 failed; exact native cleanup complete.\n';
	const descendant = 'Actual owned POST: 5 passed, 0 failed; exact native cleanup complete.\n';
	const pair = 'Actual owned POST paired receipts: 9 passed, 0 failed.\n';
	const reaper = 'Native subreaper: 1 adopted descendants physically reaped\n';
	for (const invalid of [
		{ status: 0, stdout: pair + direct + descendant },
		{ status: 0, stdout: pair + direct + descendant + reaper },
		{ status: 0, stdout: pair + direct + descendant + reaper.repeat(3) },
		{ status: 0, stdout: pair + direct + reaper.repeat(2) },
		{ status: 0, stdout: pair + descendant + reaper.repeat(2) },
		{ status: 0, stdout: direct + descendant + reaper.repeat(2) },
		{ status: 0, stdout: pair.repeat(2) + direct + descendant + reaper.repeat(2) },
		{ status: 0, stdout: pair + direct.repeat(2) + descendant + reaper.repeat(2) },
		{ status: 0, stdout: pair + direct + descendant.repeat(2) + reaper.repeat(2) },
		{
			status: 0,
			stdout: pair + direct + descendant + reaper.repeat(2),
			stderr: 'SKIPPED native POST'
		},
		{ status: null, signal: 'SIGTERM' },
		{ error: new Error('missing Python POST wrapper') }
	])
		for (const ordinal of [5, 11]) {
			const refused = fakeRun({
				change: (result, index) => (index === ordinal ? invalid : result)
			});
			assert.notEqual(
				refused.status,
				0,
				'both independent POST modes and reapers must complete on each ABI'
			);
			assert.equal(refused.calls.filter((call) => call.program === 'private-python').length, 13);
		}
	for (const prerequisite of [{ error: new Error('missing LuaJIT') }, { status: 0, stdout: '' }])
		assert.notEqual(
			run({ platform: 'linux', spawn: () => prerequisite, log: () => {}, error: () => {} }),
			0
		);

	let missingAbiPhysicalCalls = 0;
	assert.notEqual(
		run({
			platform: 'linux',
			spawn: (program, argv) => {
				if (argv[0] === '-v') return { status: 0, stdout: 'LuaJIT 2.1\n' };
				if (program === 'luajit') return { status: 0, stdout: 'Linux native ABI ready: luajit\n' };
				if (program === 'lua5.4') return { error: new Error('missing mandatory Lua 5.4/luv') };
				missingAbiPhysicalCalls++;
				return { status: 0 };
			},
			log: () => {},
			error: () => {}
		}),
		0,
		'a missing second ABI cannot silently use the first'
	);
	assert.equal(
		missingAbiPhysicalCalls,
		0,
		'both actual ABIs must be admitted before native fixture dispatch'
	);

	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runtime-registration-'));
	try {
		for (const name of [
			...MANUAL_FIXTURES,
			'package.json',
			'tools/test/verify-change.cjs',
			'tools/test/validate-ahk-suite-manifest.cjs',
			'tools/test/validate-ahk-e2e-manifest.cjs',
			'tools/test/test-ahk-test-coverage.cjs',
			'tools/lint/format.cjs',
			'static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json',
			'tools/test/run-js-suite.cjs',
			'tools/test/test-npm-aliases-match-the-suite.cjs',
			'tools/test/test-ci-pipeline-wiring.cjs'
		]) {
			const target = path.join(scratch, name);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.copyFileSync(path.join(ROOT, name), target);
		}
		fs.cpSync(path.join(ROOT, '.github/workflows'), path.join(scratch, '.github/workflows'), {
			recursive: true
		});
		validate(scratch);
		const relative = '.github/workflows/ci-linux.yml';
		const workflow = fs.readFileSync(path.join(scratch, relative), 'utf8');
		const body = Pipeline.step(Pipeline.open(scratch).job('e2e-linux'), STEP);
		for (const replace of [
			() => '',
			(text) => text.replace('if: ${{ !cancelled() }}', 'if: false'),
			(text) => text.replace('if: ${{ !cancelled() }}', 'if: success()'),
			(text) =>
				text.replace('timeout-minutes: 5', 'continue-on-error: true\n        timeout-minutes: 5'),
			(text) => text.replace('npm run test:linux:runtime-native', 'echo skipped-native-runtime')
		]) {
			fs.writeFileSync(path.join(scratch, relative), workflow.replace(body, replace(body)));
			assert.throws(
				() => validate(scratch),
				'missing, conditional or forgiven native qualification must be refused'
			);
		}
		fs.writeFileSync(path.join(scratch, relative), workflow);
		const manualBody = Pipeline.step(Pipeline.open(scratch).job('test-linux'), MANUAL_STEP);
		for (const replace of [
			() => '',
			(text) => text.replace(MANUAL_IF, '${{ !cancelled() }}'),
			(text) =>
				text.replace('timeout-minutes: 18', 'continue-on-error: true\n        timeout-minutes: 18'),
			(text) => text.replace('run_ollama_runtime_acceptance.py', 'echo_skipped_native.py')
		]) {
			fs.writeFileSync(
				path.join(scratch, relative),
				workflow.replace(manualBody, replace(manualBody))
			);
			assert.throws(
				() => validateManual(scratch),
				'manual proof cannot run automatically, disappear or forgive failure'
			);
		}
		fs.writeFileSync(path.join(scratch, relative), workflow);
		const luaPath = path.join(scratch, MANUAL_FIXTURES[0]);
		const luaSource = fs.readFileSync(luaPath, 'utf8');
		for (const [from, to] of [
			['15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb', '0'.repeat(64)],
			['pull_operation:is_settled() == true', 'true'],
			['Engine.shutdown_runtime', 'Engine.stop_runtime']
		]) {
			const changed = luaSource.replaceAll(from, to);
			assert.notEqual(changed, luaSource, 'causal source control must change its actual boundary');
			fs.writeFileSync(luaPath, changed);
			assert.throws(
				() => validateManual(scratch),
				'lost pin, physical model ACK or terminal owner must be detected'
			);
		}
		fs.writeFileSync(luaPath, luaSource);
		const pyPath = path.join(scratch, MANUAL_FIXTURES[1]);
		const pySource = fs.readFileSync(pyPath, 'utf8');
		for (const [from, to] of [
			[/\bpassed\s*=\s*False\b/, 'passed=True'],
			[/\bstatus\s*=\s*"failed"/, 'status="passed"']
		]) {
			const changed = pySource.replace(from, to);
			assert.notEqual(
				changed,
				pySource,
				'causal exception receipt control must change its actual boundary'
			);
			fs.writeFileSync(pyPath, changed);
			assert.throws(
				() => validateManual(scratch),
				'qualification exceptions must retain a literal failed receipt'
			);
		}
		fs.writeFileSync(pyPath, pySource);
		for (const [from, to] of [
			['closure = physical_receipt(text)', 'closure = {}'],
			['physical_zero = closure is not None', 'physical_zero = True'],
			['physical_closure=closure', 'physical_closure=None']
		]) {
			const changed = pySource.replace(from, to);
			assert.notEqual(
				changed,
				pySource,
				'physical closure control must replace its actual admission'
			);
			fs.writeFileSync(pyPath, changed);
			assert.throws(
				() => validateManual(scratch),
				'native acceptance must consume and retain the measured physical closure'
			);
		}
		fs.writeFileSync(pyPath, pySource);
		const stepContract = path.join(scratch, 'tools/test/test-ci-pipeline-wiring.cjs');
		const contract = fs.readFileSync(stepContract, 'utf8');
		const missingCondition = contract.replace(CONDITION_ROW, '');
		assert.notEqual(
			missingCondition,
			contract,
			'causal fixture must remove the actual reserved condition'
		);
		fs.writeFileSync(stepContract, missingCondition);
		assert.throws(() => validate(scratch), 'missing STEP_CONDITIONS ownership must be refused');
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
	console.log(
		'PASS: Native Linux runtime prerequisites retain mandatory registration and completed receipts.'
	);
}

if (require.main === module) main();
module.exports = { validate };
