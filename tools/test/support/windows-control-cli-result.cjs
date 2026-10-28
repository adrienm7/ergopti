// tools/test/support/windows-control-cli-result.cjs

/** Executes the actual public receiver AST against private JSON files. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');

function runResult({ root, source, spec, invoke, runtimeVersion, receiptPath }) {
	const hash = () => createHash('sha256').update(fs.readFileSync(source)).digest('hex');
	const sourceHash = hash();
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-control-result-'));
	const receiver = path.join(scratch, "actual receiver O'Brien é [1].ps1");
	const requestId = 'ps-0123456789abcdef';
	const future = Math.floor(Date.now() / 1000) + spec.pending_ttl_seconds;
	const baseline = {
		schema: spec.schema,
		request_id: requestId,
		state: 'completed',
		driver_pid: 4004,
		successor_pid: 4004
	};
	const cases = [
		{ name: 'completed', exit: 0, state: 'completed' },
		{ name: 'schema-float', numeric: '1.0', exit: 0, state: 'completed' },
		{ name: 'schema-exponent', numeric: '1e0', exit: 0, state: 'completed' },
		{ name: 'integral-pid-float', pidFloat: true, exit: 0, state: 'completed' },
		{
			name: 'refused',
			change: { state: 'refused', reason: 'busy' },
			drop: ['successor_pid'],
			exit: 1,
			state: 'refused'
		},
		{
			name: 'timeout',
			change: { state: 'timeout', reason: spec.timeout_reason },
			drop: ['successor_pid'],
			exit: 2,
			state: 'timeout'
		},
		{
			name: 'requested-known',
			change: { state: 'requested', driver_pid: 4000 },
			exit: 2,
			state: 'requested'
		},
		{
			name: 'requested-unknown',
			change: { state: 'requested', driver_pid: 4000, successor_pid: null, deadline: future },
			exit: 2,
			state: 'requested'
		},
		{ name: 'claimed', change: { state: 'claimed', deadline: future }, exit: 2, state: 'claimed' },
		{
			name: 'foreign-request',
			change: { request_id: 'ps-fedcba9876543210' },
			exit: 2,
			state: 'unknown'
		},
		{
			name: 'request-uppercase',
			change: { request_id: requestId.toUpperCase() },
			exit: 2,
			state: 'unknown'
		},
		{ name: 'state-array', change: { state: ['completed'] } },
		{ name: 'state-uppercase', change: { state: 'COMPLETED' } },
		{ name: 'state-mixedcase', change: { state: 'Completed' } },
		{ name: 'schema-true', change: { schema: true } },
		{ name: 'schema-false', change: { schema: false } },
		{ name: 'schema-string', change: { schema: '1' } },
		{ name: 'schema-array', change: { schema: [1] } },
		{ name: 'schema-empty-array', change: { schema: [] } },
		{ name: 'missing-schema', drop: ['schema'] },
		{ name: 'request-array', change: { request_id: [requestId] } },
		{ name: 'request-final-LF', change: { request_id: requestId + '\n' } },
		{ name: 'driver-pid-true', change: { driver_pid: true } },
		{ name: 'driver-pid-string', change: { driver_pid: '4004' } },
		{ name: 'driver-pid-fraction', change: { driver_pid: 4004.5 } },
		{ name: 'missing-driver-pid', drop: ['driver_pid'] },
		{ name: 'successor-true', change: { successor_pid: true } },
		{ name: 'successor-string', change: { successor_pid: '4004' } },
		{ name: 'successor-fraction', change: { successor_pid: 4004.5 } },
		{ name: 'root-array', arrayRoot: true },
		{ name: 'schema-key-uppercase', rename: ['schema', 'SCHEMA'] },
		{ name: 'state-key-uppercase', rename: ['state', 'STATE'] },
		{ name: 'request-key-uppercase', rename: ['request_id', 'REQUEST_ID'] },
		{ name: 'unknown-field', change: { foreign: true } },
		{
			name: 'requested-boolean-deadline',
			change: { state: 'requested', successor_pid: null, deadline: true }
		},
		{
			name: 'requested-string-deadline',
			change: { state: 'requested', successor_pid: null, deadline: '1' }
		},
		{ name: 'completed-with-deadline', change: { deadline: future } },
		{ name: 'completed-with-reason', change: { reason: 'busy' } },
		{ name: 'malformed-json', raw: '{' }
	];
	assert.equal(cases.length, 39, 'all authored public receiver controls must execute');
	const controls = [],
		failures = [];
	const plain = (text) => text.replace(/\x1b\[[0-9;]*m/g, '').replace(/\s+/g, ' ');
	const replace = (text, from, to) => {
		assert.equal(
			text.split(from).length,
			2,
			'numeric fixture replacement must name exactly one token'
		);
		return text.replace(from, to);
	};
	try {
		const prepared = invoke([
			'-File',
			path.join(root, 'tools/test/support/windows_control_cli_poll.ps1'),
			'-Source',
			source,
			'-Destination',
			receiver
		]);
		assert.equal(prepared.exit, 0, `the real poll AST must load: ${JSON.stringify(prepared)}`);
		for (const fixture of cases) {
			const folder = path.join(scratch, fixture.name + " O'Brien é [1]");
			fs.mkdirSync(folder);
			const record = { ...baseline, ...fixture.change };
			for (const key of fixture.drop || []) delete record[key];
			if (fixture.rename) {
				record[fixture.rename[1]] = record[fixture.rename[0]];
				delete record[fixture.rename[0]];
			}
			let text = fixture.raw || JSON.stringify(fixture.arrayRoot ? [record] : record);
			if (fixture.numeric) text = replace(text, '"schema":1,', '"schema":' + fixture.numeric + ',');
			if (fixture.pidFloat) {
				text = replace(text, '"driver_pid":4004,', '"driver_pid":4004.0,');
				text = replace(text, '"successor_pid":4004}', '"successor_pid":4004.0}');
			}
			fs.writeFileSync(path.join(folder, spec.files.result), text + '\n', 'utf8');
			const actual = invoke([
				'-File',
				receiver,
				'-Folder',
				folder,
				'-SpecPath',
				path.join(root, 'static/ergopti_plus/_shared/modules/control/driver_control.json'),
				'-RequestId',
				requestId,
				'-DriverPid',
				'4000',
				'-TimeoutMs',
				'1000'
			]);
			let passed = false;
			if (fixture.state) {
				try {
					passed =
						actual.exit === fixture.exit &&
						JSON.parse(actual.stdout.trim()).state === fixture.state;
				} catch {
					passed = false;
				}
			} else {
				passed =
					actual.exit === 1 && plain(actual.stderr).includes('The driver result is malformed.');
			}
			controls.push({
				name: fixture.name,
				expected_exit: fixture.state ? fixture.exit : 1,
				expected_state: fixture.state || 'malformed-result',
				passed,
				...actual
			});
			if (!passed)
				failures.push(`${fixture.name}: exit=${actual.exit}, out=${actual.stdout.trim()}`);
		}
		assert.equal(
			hash(),
			sourceHash,
			'the actual public poll owner must stay unchanged during all controls'
		);
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
		if (receiptPath)
			fs.writeFileSync(
				receiptPath,
				JSON.stringify(
					{
						phase: 'result',
						runtime: runtimeVersion,
						source_sha256: sourceHash,
						qualification:
							'Actual public receiver AST and private files; no Windows endpoint or live reload receiving.',
						controls
					},
					null,
					2
				) + '\n'
			);
	}
	assert.equal(
		controls.length,
		cases.length,
		'every receiver case must produce a real child receipt'
	);
	assert.deepEqual(failures, [], failures.join('\n'));
	console.log('[OK] Windows control CLI result admission controls passed.');
	console.log(`PowerShell ${runtimeVersion}; Windows message and live reload receiving UNRUN.`);
}
module.exports = { runResult };
