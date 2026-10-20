// tools/test/test-ahk-e2e-manifest.cjs

/**
 * Exercises actual E2E admission, CLI failures and both production gate consumers.
 * Complete transcripts that omit native coverage must never pass as E2E proof.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');
const {
	validateAhkE2eManifest,
	validateAhkE2eDiscovery,
	validateAhkE2ePlanExecution
} = require('./validate-ahk-e2e-manifest.cjs');
const corpus = require('../../static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json');

/** Produces internally consistent observations even for incomplete corpus coverage. */
function transcript(entries) {
	return (
		[
			`1..${entries.length}`,
			...entries.flatMap((entry, index) => [
				`RUNNING ${index + 1}/${entries.length} - ${entry.name}`,
				`${entry.status} ${index + 1} - ${entry.name}`
			]),
			`# ${entries.filter((entry) => entry.status === 'ok').length} passed, ${entries.filter((entry) => entry.status === 'not ok').length} failed.`
		].join('\n') + '\n'
	);
}

const complete = ['pure', 'native-edit'].flatMap((tier) =>
	corpus.vectors.map((vector) => ({ name: `e2e[${tier}] ${vector.id}`, status: 'ok' }))
);
const nativeIndex = complete.findIndex((entry) => entry.name.startsWith('e2e[native-edit]'));
const cases = [
	['complete', complete, 0],
	['missing-tier', complete.slice(0, nativeIndex), 1],
	['missing-vector', complete.filter((_, index) => index !== nativeIndex), 1],
	['duplicate-vector', [...complete, complete[nativeIndex]], 1],
	[
		'unknown-vector',
		complete.map((entry, index) =>
			index === nativeIndex ? { ...entry, name: 'e2e[native-edit] unknown' } : entry
		),
		1
	],
	[
		'failed-native',
		complete.map((entry, index) =>
			index === nativeIndex ? { ...entry, status: 'not ok' } : entry
		),
		1
	],
	['zero-tests', [], 1],
	[
		'independent-regression',
		[...complete, { name: 'e2e[native-edit] independent Unicode regression', status: 'ok' }],
		0
	]
];
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-e2e-manifest-'));
try {
	for (const [name, entries, expected] of cases) {
		const source = transcript(entries);
		assert.equal(validateAhkE2eManifest(source).complete, expected === 0, name);
		const receipt = path.join(root, name + '.tap');
		fs.writeFileSync(receipt, source, 'utf8');
		const result = spawnSync(
			process.execPath,
			[path.join(__dirname, 'validate-ahk-e2e-manifest.cjs'), '--input', receipt],
			{ encoding: 'utf8', windowsHide: true, timeout: 5000 }
		);
		assert.ifError(result.error);
		assert.equal(result.status, expected, name + ': ' + result.stderr);
	}
	for (const vectors of [[], [{ id: '' }], [{ id: 'same' }, { id: 'same' }]])
		assert.equal(validateAhkE2eManifest(transcript(complete), vectors).complete, false);
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}

// The change planner's isolated consumers ship only the legacy validator inputs.
// Native replay support must not acquire a CI dependency until explicitly used.
const isolatedRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-e2e-legacy-'));
try {
	const repository = path.resolve(__dirname, '../..');
	for (const relative of [
		'tools/test/validate-ahk-e2e-manifest.cjs',
		'tools/test/validate-ahk-suite-manifest.cjs',
		'static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json'
	]) {
		const destination = path.join(isolatedRoot, relative);
		fs.mkdirSync(path.dirname(destination), { recursive: true });
		fs.copyFileSync(path.join(repository, relative), destination);
	}
	assert.equal(fs.existsSync(path.join(isolatedRoot, 'tools/ci')), false);
	const isolatedValidator = path.join(isolatedRoot, 'tools/test/validate-ahk-e2e-manifest.cjs');
	const isolated = createRequire(isolatedValidator)(isolatedValidator);
	assert.equal(isolated.validateAhkE2eManifest(transcript(complete)).complete, true);
	assert.equal(
		isolated.validateAhkE2eManifest(transcript(complete.slice(0, nativeIndex))).complete,
		false
	);
	const receipt = path.join(isolatedRoot, 'legacy.tap');
	fs.writeFileSync(receipt, transcript(complete));
	const result = spawnSync(process.execPath, [isolatedValidator, '--input', receipt], {
		encoding: 'utf8',
		windowsHide: true,
		timeout: 5000
	});
	assert.ifError(result.error);
	assert.equal(result.status, 0, result.stderr);
} finally {
	fs.rmSync(isolatedRoot, { recursive: true, force: true });
}

const gateFile = path.join(__dirname, 'verify-change.cjs');
const originalRequire = createRequire(gateFile);
let current = transcript(complete);
let nativeStatus = 0;
const calls = [];
const context = vm.createContext({
	module: { exports: {} },
	__dirname,
	process,
	console: { log() {}, error() {} },
	require(name) {
		if (name === 'node:fs')
			return { ...fs, existsSync: () => true, readFileSync: () => current, rmSync() {} };
		if (name === 'node:child_process')
			return {
				spawnSync(command, args, options) {
					calls.push({ command, args, options });
					return { status: nativeStatus };
				}
			};
		return originalRequire(name);
	}
});
vm.runInContext(fs.readFileSync(gateFile, 'utf8'), context, { filename: gateFile });
for (const [name, entries, expected] of cases) {
	current = transcript(entries);
	assert.equal(context.runGate('ahk-e2e').status, expected, 'production runGate: ' + name);
	assert.ok(
		calls.at(-1).options.env.ERGOPTI_AHK_RESULTS_FILE,
		'the native runner must publish an explicit fresh receipt'
	);
}
nativeStatus = 2;
current = transcript(complete);
assert.equal(
	context.runGate('ahk-e2e').status,
	2,
	'a native failure must override a complete receipt'
);

/** Requires the actual Windows CI job to enforce corpus-aware admission. */
function checkAdmission(body) {
	const step = pipeline.step(body, 'Validate complete native E2E corpus execution');
	assert.equal(pipeline.stepField(step, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(step, 'if'), null);
	assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	const script = pipeline.runOf(step).join('\n');
	assert.match(script, /node tools\/test\/validate-ahk-e2e-manifest\.cjs --input/);
	assert.match(script, /windows\/tests\/e2e\/test_results\.txt/);
	assert.match(script, /if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}/);
}
const body = pipeline.job('e2e-ahk');
checkAdmission(body);
for (const [from, to] of [
	['node tools/test/validate-ahk-e2e-manifest.cjs --input', 'echo skipped'],
	['- name: Validate complete native E2E corpus execution', '- name: Missing admission'],
	[
		'- name: Validate complete native E2E corpus execution',
		'- name: Validate complete native E2E corpus execution\n        if: false'
	],
	[
		'- name: Validate complete native E2E corpus execution',
		'- name: Validate complete native E2E corpus execution\n        continue-on-error: true'
	],
	[
		'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }',
		'if ($LASTEXITCODE -ne 0) { Write-Host ignored }'
	]
])
	assert.throws(() => checkAdmission(body.replaceAll(from, to)), from);

console.log(
	'AHK E2E admission rejects missing, duplicate, failed and empty native corpus observations.'
);

// A complete old corpus must not qualify a larger freshly discovered runner.
const unicode = ['pure', 'native-edit'].map((tier) => ({
	name: `e2e[${tier}] supplementary trigger and completion preserve native edits (unicode-erase)`,
	status: 'ok'
}));
const oldMinimum = [...complete, ...unicode];
const fresh = [
	...oldMinimum,
	...Array.from({ length: 7 }, (_, index) => ({
		name: `additional native regression ${index}`,
		status: 'ok'
	}))
];
const planOf = (entries) =>
	entries.map((entry) => `e2e\ttests/e2e/actual.ahk\t${entry.name}`).join('\n') + '\n';
const discoveryOf = (entries) => `1..${entries.length}\n# dry-run - skipping execution.\n`;
const timed = (entries) =>
	transcript(entries).replace(
		/^(ok|not ok) (\d+) - (.+)$/gm,
		(line, status, ordinal) => `${line}\n# duration_ms ${ordinal} 0.125`
	);
const discovery = validateAhkE2eDiscovery(planOf(fresh), discoveryOf(fresh));
assert.equal(discovery.complete, true, discovery.errors.join('\n'));
assert.equal(discovery.expected_count, fresh.length);
assert.equal(validateAhkE2eManifest(timed(oldMinimum)).complete, true);
assert.equal(validateAhkE2ePlanExecution(timed(oldMinimum), discovery).complete, false);
assert.equal(validateAhkE2ePlanExecution(timed(fresh), discovery).complete, true);
for (const [plan, tap] of [
	['', discoveryOf(fresh)],
	['malformed', discoveryOf(fresh)],
	[planOf([...fresh, fresh[0]]), discoveryOf([...fresh, fresh[0]])],
	[planOf(complete), discoveryOf(complete)],
	[planOf(fresh), discoveryOf(oldMinimum)],
	[planOf(fresh), discoveryOf(fresh).replace('# dry-run - skipping execution.', '')],
	[planOf(fresh), discoveryOf(fresh) + 'ok 1 - forged\n'],
	[planOf(fresh), discoveryOf(fresh) + '# DEFERRED qualification\n'],
	[planOf(fresh), discoveryOf(fresh) + '# skip: French layout unavailable\n'],
	[planOf(fresh), discoveryOf(fresh) + '# DeFeRrEd qualification\n'],
	[planOf(fresh), discoveryOf(fresh) + '# excluded (requires --interactive): x\n']
])
	assert.equal(validateAhkE2eDiscovery(plan, tap).complete, false);
for (const source of [
	timed([...fresh].reverse()),
	timed(fresh.slice(0, -1)),
	timed(
		fresh.map((entry, index) =>
			index === fresh.length - 1 ? { ...entry, name: 'substitute' } : entry
		)
	),
	transcript(fresh),
	timed(fresh).replace('# duration_ms 1 0.125\n', ''),
	timed(fresh).replace(/^ok 1 /m, 'not ok 1 '),
	timed(fresh) + '# SKIP x\n',
	timed(fresh) + '# skip: French layout unavailable\n',
	timed(fresh) + '# SkIp: unavailable\n',
	timed(fresh) + '# dry-run - skipping execution.\n'
])
	assert.equal(validateAhkE2ePlanExecution(source, discovery).complete, false);
const chunks = [
	...timed(fresh).matchAll(/RUNNING [^\n]+\n(?:not )?ok [^\n]+\n# duration_ms [^\n]+\n/g)
].map((match) => match[0]);
const physicallyReversed = `1..${fresh.length}\n${chunks.reverse().join('')}# ${fresh.length} passed, 0 failed.\n`;
assert.equal(validateAhkE2eManifest(physicallyReversed).complete, true);
assert.equal(validateAhkE2ePlanExecution(physicallyReversed, discovery).complete, false);
assert.equal(
	validateAhkE2ePlanExecution(timed(fresh).replaceAll('\n', '\r\n'), discovery).complete,
	true
);
const future = [...fresh, { name: 'future independent native case', status: 'ok' }];
assert.equal(
	validateAhkE2ePlanExecution(
		timed(future),
		validateAhkE2eDiscovery(planOf(future), discoveryOf(future))
	).complete,
	true
);
const cliRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-e2e-discovery-'));
try {
	const files = Object.fromEntries(
		['plan', 'discovery', 'input', 'json'].map((key) => [key, path.join(cliRoot, key)])
	);
	fs.writeFileSync(files.plan, planOf(fresh));
	fs.writeFileSync(files.discovery, discoveryOf(fresh));
	fs.writeFileSync(files.input, timed(fresh));
	const invoke = (args) =>
		spawnSync(process.execPath, [path.join(__dirname, 'validate-ahk-e2e-manifest.cjs'), ...args], {
			encoding: 'utf8',
			timeout: 5000,
			windowsHide: true
		});
	const base = ['--plan', files.plan, '--discovery', files.discovery, '--json', files.json];
	for (const args of [base, ['--input', files.input, ...base]]) {
		const result = invoke(args);
		assert.ifError(result.error);
		assert.equal(result.status, 0, result.stderr);
		assert.equal(JSON.parse(fs.readFileSync(files.json)).expected_count, fresh.length);
	}
	fs.writeFileSync(files.input, timed(oldMinimum));
	assert.equal(invoke(['--input', files.input, ...base]).status, 1);
	assert.equal(JSON.parse(fs.readFileSync(files.json)).complete, false);
	for (const args of [
		[],
		['--plan', files.plan],
		['--discovery', files.discovery],
		['--unknown', files.input],
		['--input'],
		['--input', files.input, '--input', files.input]
	])
		assert.equal(invoke(args).status, 1);
} finally {
	fs.rmSync(cliRoot, { recursive: true, force: true });
}
const replaySource = fs.readFileSync(
	path.join(__dirname, '../../.github/workflows/windows-test-replay.yml'),
	'utf8'
);
const replayStep = pipeline.step(replaySource, 'Run the complete native Windows E2E corpus');
assert.equal(pipeline.stepField(replayStep, 'timeout-minutes'), '5');
const replayScript = pipeline.runOf(replayStep).join('\n');
assert.match(replayScript, /foreach \(\$phase in @\('discovery', 'execution'\)\)/);
assert.match(replayScript, /--dry-run .*--dump-plan=\$plan/);
assert.match(replayScript, /Remove-Item -LiteralPath \$plan, \$tap, \$discoveryTap/);
assert.match(replayScript, /Test-Path -LiteralPath \$phaseTap/);
assert.match(replayScript, /Test-Path -LiteralPath \$plan/);
assert.match(replayScript, /A prior E2E artifact could not be retired/);
assert.match(
	replayScript,
	/--input \$tap --plan \$plan --discovery \$discoveryTap --json \$manifest/
);
assert.match(replayScript, /ElapsedMilliseconds -gt 180000/);
assert.doesNotMatch(replayScript, /2 \* \$corpus|expected_count = 77|continue-on-error/);
console.log(
	'Fresh native E2E discovery requires every exact ordered result and timing, beyond the mandatory corpus.'
);
