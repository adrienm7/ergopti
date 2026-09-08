// tools/test/test-ahk-runner-scan-streaming.cjs

/**
 * Preserve runner-reference semantics while preventing whole-corpus retention.
 * Instrument actual text inspection rather than asserting a particular loop.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const subjectPath = path.join(__dirname, 'test-ahk-runners-are-invoked.cjs');
const source = fs.readFileSync(subjectPath, 'utf8');
const root = path.resolve(path.dirname(subjectPath), '../..');
const prefix = 'static/ergopti_plus/windows/tests/';

function run(runners, files, { tracked = Object.keys(files), streaming = false } = {}) {
	const trace = [];
	const output = [];
	let pending = null;
	const exit = {};
	let code = 0;
	const relative = (file) => path.relative(root, file).replace(/\\/g, '/');
	const fakeFs = {
		readdirSync(dir) {
			const parent = relative(dir) + '/';
			const entries = new Map();
			for (const runner of runners) {
				if (!runner.startsWith(parent)) continue;
				const tail = runner.slice(parent.length);
				const name = tail.split('/')[0];
				entries.set(name, { name, isDirectory: () => tail.includes('/') });
			}
			return [...entries.values()];
		},
		existsSync(file) {
			return Object.hasOwn(files, relative(file));
		},
		readFileSync(file) {
			const name = relative(file);
			if (streaming && pending !== null) {
				assert.ok(
					trace.includes('inspect:' + pending),
					'must inspect ' + pending + ' before reading ' + name
				);
			}
			trace.push('read:' + name);
			pending = name;
			const value = files[name];
			if (value instanceof Error) throw value;
			return {
				includes(needle) {
					trace.push('inspect:' + name);
					return value.includes(needle);
				}
			};
		}
	};
	try {
		vm.runInNewContext(
			source,
			{
				__dirname: path.dirname(subjectPath),
				require(name) {
					if (name === 'fs') return fakeFs;
					if (name === 'path') return path;
					if (name === 'child_process') return { execSync: () => tracked.join('\n') };
					throw new Error('Unexpected dependency: ' + name);
				},
				console: {
					log: (...args) => output.push(args.join(' ')),
					error: (...args) => output.push(args.join(' '))
				},
				process: {
					exit(status) {
						code = status;
						throw exit;
					}
				}
			},
			{ filename: subjectPath }
		);
	} catch (error) {
		if (error !== exit) throw error;
	}
	return { code, output: output.join('\n'), trace };
}

const alpha = prefix + 'run_alpha.ahk';
const beta = prefix + 'nested/bench_beta.ahk';
assert.equal(
	run([alpha], { [alpha]: 'run_alpha.ahk' }).code,
	1,
	'self reference must not cover a runner'
);
assert.equal(run([alpha], { 'docs/audits/report.md': 'run_alpha.ahk' }).code, 0);
assert.equal(
	run([alpha], { 'docs/report.md': 'RUN_ALPHA.ahk' }).code,
	1,
	'matching remains case sensitive'
);
assert.equal(
	run([alpha], { 'docs/report.md': 'prefix-run_alpha.ahk-suffix' }).code,
	0,
	'historical substring mentions count'
);
assert.equal(
	run([alpha], { 'untracked.md': 'run_alpha.ahk' }, { tracked: ['deleted.md'] }).code,
	1
);
assert.equal(
	run([alpha], { 'ignored.bin': 'run_alpha.ahk' }).code,
	1,
	'unsupported extensions do not cover runners'
);
const twin = prefix + 'nested/run_alpha.ahk';
const duplicate = run([alpha, twin], { [alpha]: 'run_alpha.ahk' });
assert.equal(duplicate.code, 1);
assert.ok(duplicate.output.includes('    ' + alpha));
assert.ok(
	!duplicate.output.includes('    ' + twin),
	'another runner with the same basename may reference the nested one'
);
assert.equal(run([alpha, twin], { [alpha]: 'run_alpha.ahk', [twin]: 'run_alpha.ahk' }).code, 0);
const missing = run([alpha, beta], {});
assert.equal(missing.code, 1);
assert.ok(
	missing.output.indexOf('    ' + alpha) < missing.output.indexOf('    ' + beta),
	'orphan order follows discovery'
);
const empty = run([], {});
assert.equal(empty.code, 1);
assert.ok(empty.output.includes('no run_*/bench_* file found under windows/tests'));
const failure = new Error('injected read failure');
assert.throws(
	() => run([alpha], { 'docs/a.md': 'run_alpha.ahk', 'docs/b.md': failure }),
	(error) => error === failure
);
console.log('orphan guard semantic scenarios: ok');

const streamed = run(
	[alpha, beta],
	{ 'docs/a.md': 'unrelated', 'docs/b.md': 'run_alpha.ahk bench_beta.ahk' },
	{ streaming: true }
);
assert.equal(streamed.code, 0);
assert.ok(streamed.trace.includes('inspect:docs/b.md'), 'the final file must also be inspected');
console.log('orphan guard streaming resource regression: ok');
