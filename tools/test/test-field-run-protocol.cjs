// tools/test/test-field-run-protocol.cjs

/**
 * ==============================================================================
 * MODULE: Field Run Protocol Tests
 * DESCRIPTION:
 * Pins static/ergopti_plus/_shared/data/field_run_protocol.json, the request
 * and result files every driver and field report collector shares:
 * 1. the declaration is well formed: closed names, patterns that compile,
 *    one document key list per file, a steps file and a folder per driver;
 * 2. the macOS field run (macos/data/field_run.json, the first implementation)
 *    keeps every protocol key equal to the shared one, and its folder is the
 *    clone folder;
 * 3. every driver steps file that exists declares steps the protocol accepts:
 *    unique ids, declared kinds, positive integer deadlines, a check name for
 *    a field check and one sentence of what its pass proves.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const PROTOCOL = 'static/ergopti_plus/_shared/data/field_run_protocol.json';
const MACOS = 'static/ergopti_plus/macos/data/field_run.json';
// The keys the macOS declaration carries for the protocol, beside its steps.
const SHARED_KEYS = [
	'schema',
	'files',
	'max_request_bytes',
	'request_id_pattern',
	'log_window_max_lines',
	'verdicts',
	'reasons'
];

const read = (relative) => JSON.parse(fs.readFileSync(path.join(ROOT, relative), 'utf8'));
const protocol = read(PROTOCOL);
let checks = 0;

/** Runs one named check. */
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

check('the shared declaration is well formed', () => {
	assert.equal(protocol.schema, 1);
	for (const key of [
		'request_id_pattern',
		'step_id_pattern',
		'code_pattern',
		'result_file_pattern'
	])
		assert.doesNotThrow(() => new RegExp(protocol[key]), key);
	assert.deepEqual(
		Object.keys(protocol.documents).sort(),
		[
			...Object.keys(protocol.files).filter((name) => !['results', 'resume'].includes(name)),
			'result'
		].sort()
	);
	for (const [name, keys] of Object.entries(protocol.documents)) {
		assert(keys.includes('schema'), `${name} carries the schema`);
		assert.equal(new Set(keys).size, keys.length, `${name} lists a key twice`);
	}
	assert.equal(new Set(protocol.verdicts).size, protocol.verdicts.length);
	assert.equal(new Set(protocol.reasons).size, protocol.reasons.length);
	assert.deepEqual(Object.keys(protocol.steps_file).sort(), [...protocol.drivers].sort());
	for (const os of protocol.drivers.filter((name) => name !== 'macos')) {
		const folder = protocol.folder[os];
		assert(folder && /^[A-Z_]+$/.test(folder.base) && folder.segments.length > 0, `${os} folder`);
	}
	assert(!path.isAbsolute(protocol.folder.clone), 'the clone folder is relative to the clone root');
	assert.match('mac-2026-10-30_191337', new RegExp(protocol.request_id_pattern));
	assert.match('03_field_network.json', new RegExp(protocol.result_file_pattern));
	assert.doesNotMatch('../x.json', new RegExp(protocol.result_file_pattern));
});

check('the macOS field run keeps every protocol key of the shared declaration', () => {
	const macos = read(MACOS);
	for (const key of SHARED_KEYS)
		assert.deepEqual(macos[key], protocol[key], `${MACOS} ${key} differs from ${PROTOCOL}`);
	assert.equal(macos.folder, protocol.folder.clone);
	assert.equal(protocol.steps_file.macos, MACOS);
});

check('every driver steps file declares steps the protocol accepts', () => {
	const stepId = new RegExp(protocol.step_id_pattern);
	let found = 0;
	for (const [os, relative] of Object.entries(protocol.steps_file)) {
		if (!fs.existsSync(path.join(ROOT, relative))) continue;
		found++;
		const steps = read(relative).steps;
		assert(Array.isArray(steps) && steps.length > 0, `${relative} declares no step`);
		const ids = new Set();
		for (const step of steps) {
			const label = `${os} step ${step.id}`;
			assert.match(step.id, stepId, label);
			assert.notEqual(step.id, protocol.all_steps, label);
			assert(!ids.has(step.id), `${label} is declared twice`);
			ids.add(step.id);
			assert(
				protocol.step_kinds.includes(step.kind),
				`${label} has an undeclared kind ${step.kind}`
			);
			assert(
				Number.isInteger(step.deadline_seconds) && step.deadline_seconds > 0,
				`${label} deadline`
			);
			if (step.kind === 'field_check') assert.match(step.check, stepId, `${label} names no check`);
			assert(
				typeof step.proves === 'string' && step.proves.endsWith('.'),
				`${label} proves nothing`
			);
		}
	}
	assert(found >= 1, 'no driver steps file exists');
});

console.log(`[OK] field run protocol (${checks} checks).`);
