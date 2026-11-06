// Exercise the actual CJS guard through a private read port; never edit data/source.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(process.argv[2]);
const dataPath = path.join(root, 'static/ergopti_plus/_shared/tap_hold/one_shot_shift.json');
const scriptPath = path.join(root, 'tools/test/test-tap-hold-one-shot-results-single-source.cjs');
const source = fs.readFileSync(scriptPath, 'utf8');
const actual = JSON.parse(fs.readFileSync(dataPath, 'utf8'));
function run(name, mutate) {
	const candidate = structuredClone(actual);
	mutate(candidate);
	const messages = [];
	let status = 0;
	const readPort = Object.create(fs);
	readPort.readFileSync = (file, ...args) =>
		path.resolve(file) === dataPath ? JSON.stringify(candidate) : fs.readFileSync(file, ...args);
	try {
		vm.runInNewContext(
			source,
			{
				__dirname: path.dirname(scriptPath),
				require: (id) => (id === 'fs' ? readPort : require(id)),
				console: {
					log: (...args) => messages.push(args.join(' ')),
					error: (...args) => messages.push(args.join(' '))
				},
				process: {
					exit: (code) => {
						throw { auditExit: code };
					}
				}
			},
			{ filename: scriptPath }
		);
	} catch (error) {
		if (!error || !Object.hasOwn(error, 'auditExit')) throw error;
		status = error.auditExit;
	}
	return { name, status, messages };
}
const rows = [
	run('shipped-positive', () => {}),
	run('duplicate-character-narrow-source-guard-passes', (data) =>
		data.results.push({ ...data.results[0] })
	),
	run('multi-scalar-character-rejected', (data) => (data.results[0].char = 'ab')),
	run('empty-result-rejected', (data) => (data.results[0].result = '')),
	run('missing-magic-rejected', (data) => delete data.magic_key_result)
];
assert.equal(rows[0].status, 0);
assert.equal(rows[1].status, 0);
for (const row of rows.slice(2)) assert.equal(row.status, 1);
console.log(
	JSON.stringify({
		qualification:
			'Actual CJS source over data-read port. The duplicate case is NOT an overall false-green claim: actual Mac Owner.new rejects it, and its registered real-data unit covers that load.',
		rows
	})
);
