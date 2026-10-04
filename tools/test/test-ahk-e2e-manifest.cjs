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
const { validateAhkE2eManifest } = require('./validate-ahk-e2e-manifest.cjs');
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
