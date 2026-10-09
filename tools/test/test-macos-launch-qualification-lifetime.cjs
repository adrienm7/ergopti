// tools/test/test-macos-launch-qualification-lifetime.cjs
'use strict';

/** Calls the actual model module with owned filesystem and synchronous inert child ports. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const sourcePath = path.join(__dirname, 'test-macos-launch-qualification.cjs');
const load = createRequire(sourcePath);
const code = fs.readFileSync(sourcePath, 'utf8');
const outer = fs.readFileSync(path.join(__dirname, 'test-dev-release-qualification.cjs'), 'utf8');
const registration = "require('./test-macos-launch-qualification.cjs');";
assert.equal(
	outer.includes(registration),
	false,
	'the asynchronous suite must not import this model'
);
assert.equal(code.includes("require('./test-macos-launch-qualification-lifetime.cjs');"), false);
const runner = fs.readFileSync(path.join(__dirname, 'run-js-suite.cjs'), 'utf8');
for (const file of [
	'test-macos-launch-qualification.cjs',
	'test-macos-launch-qualification-lifetime.cjs'
]) {
	const entry = "args: ['tools/test/" + file + "']";
	assert.equal(
		runner.split(entry).length,
		2,
		'each model needs exactly one independent runner entry'
	);
}
let controls = 0;
function exercise(source, assigned, refuseBody) {
	const inherited = ['GITHUB_SHA', 'MATRIX_RUNNER'].map((name) => [name, process.env[name]]);
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-mac-lifetime-control-'));
	const owned = [];
	try {
		for (const name of ['GITHUB_SHA', 'MATRIX_RUNNER']) {
			if (assigned) process.env[name] = 'inherited-model-value';
			else delete process.env[name];
		}
		const expected = ['GITHUB_SHA', 'MATRIX_RUNNER'].map((name) => [name, process.env[name]]);
		const filesystem = Object.create(fs);
		filesystem.mkdtempSync = (prefix) => {
			const directory = fs.mkdtempSync(path.join(root, path.basename(prefix)));
			owned.push(directory);
			return directory;
		};
		const desktop = load('./desktop-ci-evidence.cjs');
		const modelRequire = (name) => {
			if (name === 'node:fs') return filesystem;
			if (name === 'node:os') return { ...os, tmpdir: () => root };
			if (name === 'node:child_process')
				return {
					spawnSync: (command) => {
						assert.equal(command, process.platform === 'win32' ? 'python' : 'python3');
						return { status: 0, stdout: '{"controls":11,"native_calls":0}', stderr: '' };
					}
				};
			if (name === './desktop-ci-evidence.cjs')
				return {
					...desktop,
					recordMac(...args) {
						if (refuseBody && args.length === 4) throw Error('injected-model-body-refusal');
						return desktop.recordMac(...args);
					}
				};
			if (name === './test-macos-launch-qualification-lifetime.cjs') return {};
			return load(name);
		};
		let failure = null;
		try {
			const body = vm.runInThisContext(
				'(function(require, module, __dirname, process, console) {\n' + source + '\n})'
			);
			body(modelRequire, { exports: {} }, __dirname, process, { log() {}, error() {} });
		} catch (error) {
			failure = error;
		}
		if (refuseBody) assert.equal(failure && failure.message, 'injected-model-body-refusal');
		else assert.equal(failure, null);
		assert.deepEqual(
			['GITHUB_SHA', 'MATRIX_RUNNER'].map((name) => [name, process.env[name]]),
			expected
		);
		assert.equal(owned.length, 1, 'the actual module acquires exactly one model namespace');
		assert(
			owned.every((directory) => !fs.existsSync(directory)),
			'each actual model namespace must retire'
		);
		controls++;
	} finally {
		for (const [name, value] of inherited) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
		assert(path.resolve(root).startsWith(path.resolve(os.tmpdir()) + path.sep));
		assert(path.basename(root).startsWith('ergopti-mac-lifetime-control-'));
		fs.rmSync(root, { recursive: true, force: false });
	}
}
for (const assigned of [false, true])
	for (const refuseBody of [false, true]) exercise(code, assigned, refuseBody);
const restore =
	'\tfor (const [name, value] of previousEnvironment) {\n' +
	'\t\tif (value === undefined) delete process.env[name];\n' +
	'\t\telse process.env[name] = value;\n\t}\n';
const retire = '\tfs.rmSync(owner, { recursive: true, force: false });\n';
assert.equal(code.split(restore).length, 2);
assert.equal(code.split(retire).length, 2);
assert.throws(
	() => exercise(code.replace(restore, ''), true, false),
	'omitting environment restore must fail'
);
assert.throws(
	() => exercise(code.replace(retire, ''), true, false),
	/namespace must retire|namespaces must retire/
);
if (process.env.ERGOPTI_PROPOSAL_LIFETIME_BEFORE) {
	const before = fs.readFileSync(process.env.ERGOPTI_PROPOSAL_LIFETIME_BEFORE, 'utf8');
	assert.throws(
		() => exercise(before, true, false),
		'the predecessor leaked the assigned environment and namespace'
	);
	console.log('Actual predecessor model lifetime RED preserved; controlled cleanup completed.');
}
console.log(
	JSON.stringify({
		lifetime_controls: controls,
		independent_guard_reversals: 2,
		native_calls: 0,
		environment_restored: true,
		model_namespaces_retired: true,
		child_port: 'synchronous inert result'
	})
);
