// tools/ci/macos-stage-roles.cjs
'use strict';

/** Keeps the five visible Mac stages complete without cross-stage dependency edges. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { parseClosedJson } = require('./dev-release-qualification.cjs');
const STAGES = ['unit', 'e2e', 'build', 'testbuild'];
const JOBS = ['test-hs', 'e2e-hs', 'package-macos', 'launch'];
const fields = (value, names) =>
	assert.deepEqual(
		Object.keys(value).sort(),
		[...names].sort(),
		'Closed stage receipt fields required'
	);

function validateContext(value) {
	fields(value, ['source_sha', 'run_id', 'event_name', 'release', 'scenarios']);
	assert.match(value.source_sha, /^[a-f0-9]{40}$/);
	assert.match(value.run_id, /^[1-9][0-9]*$/);
	assert.ok(['push', 'pull_request', 'workflow_dispatch'].includes(value.event_name));
	assert.equal(typeof value.release, 'boolean');
	assert.ok(Array.isArray(value.scenarios) && value.scenarios.length > 0);
	assert.ok(
		value.scenarios.every((name) => typeof name === 'string' && /^[a-z][a-z0-9_]*$/.test(name))
	);
	assert.equal(new Set(value.scenarios).size, value.scenarios.length);
	return value;
}

function cell(role, runner, architecture, timeout, scenario = '') {
	return { role, runner, architecture, timeout_minutes: timeout, scenario };
}

/** Authored roles retain the original operating systems, architectures and job bounds. */
function plan(stage, context) {
	validateContext(context);
	if (stage === 'unit') return [cell('lua-unit-meta', 'ubuntu-latest', 'stubbed', 360)];
	if (stage === 'e2e') {
		const rows = [
			cell('e2e-hs', 'ubuntu-latest', 'stubbed', 360),
			cell('tooltip-canvas', 'macos-15', 'arm64', 10),
			cell('managed-ollama-native', 'macos-15', 'arm64', 60),
			cell('managed-ollama-native', 'macos-15-intel', 'amd64', 60)
		];
		if (context.event_name === 'workflow_dispatch' && !context.release)
			rows.push(
				cell('item36-native', 'macos-latest', 'host', 25),
				cell('lease-silence-native', 'macos-15', 'arm64', 20),
				cell('lease-silence-native', 'macos-15-intel', 'amd64', 20)
			);
		return rows;
	}
	if (stage === 'build') return [cell('package-macos', 'macos-latest', 'host', 45)];
	assert.equal(stage, 'testbuild');
	return [
		...(context.release ? ['macos-15', 'macos-15-intel'] : ['macos-15']).flatMap((runner) =>
			context.scenarios.map((scenario) =>
				cell('launch', runner, runner === 'macos-15' ? 'arm64' : 'amd64', 12, scenario)
			)
		),
		cell('cold-bootstrap-native', 'macos-15', 'arm64', 90)
	];
}

function identity(value) {
	return [value.role, value.runner, value.scenario].join('/');
}

function validateHost(host, selected) {
	fields(host, ['os', 'architecture']);
	assert.equal(
		host.os,
		selected.runner === 'ubuntu-latest' ? 'linux' : 'darwin',
		'Wrong OS for stage role'
	);
	const expected = { arm64: 'arm64', amd64: 'x64' }[selected.architecture];
	if (expected) assert.equal(host.architecture, expected, 'Wrong architecture for stage role');
	else assert.ok(['arm64', 'x64'].includes(host.architecture), 'Unsupported host architecture');
}

function validateCells(stage, rows, context) {
	const expected = plan(stage, context),
		byIdentity = new Map();
	assert.equal(rows.length, expected.length, 'Missing or extra stage role receipt');
	for (const row of rows) {
		fields(row, ['cell', 'host', 'result', 'attempt']);
		const key = identity(row.cell);
		assert.ok(!byIdentity.has(key), 'Duplicate stage role receipt');
		const wanted = expected.find((candidate) => identity(candidate) === key);
		assert.ok(wanted, 'Unexpected stage role receipt');
		assert.deepEqual(row.cell, wanted, 'Changed role, runtime, runner or bound');
		validateHost(row.host, wanted);
		assert.equal(row.result, 'success', 'Stage role did not succeed');
		assert.ok(Number.isSafeInteger(row.attempt) && row.attempt > 0, 'Invalid producer attempt');
		byIdentity.set(key, row);
	}
	return expected.map((wanted) => byIdentity.get(identity(wanted)));
}

function validateChain(chain, beforeStage, context) {
	assert.ok(Array.isArray(chain));
	const expected = STAGES.slice(0, STAGES.indexOf(beforeStage));
	assert.deepEqual(
		chain.map((row) => row.stage),
		expected,
		'Missing, repeated or reordered prior stage'
	);
	let priorAttempt = 0;
	for (const row of chain) {
		fields(row, ['stage', 'cells']);
		assert.deepEqual(row.cells, validateCells(row.stage, row.cells, context));
		assert.ok(
			row.cells.every((cell) => cell.attempt >= priorAttempt),
			'Backward predecessor attempt lineage'
		);
		priorAttempt = Math.max(...row.cells.map((cell) => cell.attempt));
	}
	return chain;
}

/** The direct GitHub matrix aggregate is admitted before any receipt is consumed. */
function aggregate(needs, stage) {
	const index = STAGES.indexOf(stage);
	assert.ok(index >= 0);
	fields(needs, [JOBS[index]]);
	assert.equal(
		needs[JOBS[index]].result,
		'success',
		'Direct predecessor aggregate did not succeed'
	);
	return needs[JOBS[index]].result;
}

function union(stage, receipts, result, context, currentAttempt) {
	assert.equal(result, 'success', 'Direct predecessor aggregate did not succeed');
	assert.ok(
		Number.isSafeInteger(currentAttempt) && currentAttempt > 0,
		'Invalid receiving attempt'
	);
	validateContext(context);
	assert.ok(STAGES.includes(stage));
	assert.ok(Array.isArray(receipts));
	let prior,
		priorWitnessAttempt = Infinity;
	const rows = receipts.map((receipt) => {
		fields(receipt, ['schema', 'context', 'stage', 'cell', 'host', 'result', 'attempt', 'prior']);
		assert.equal(receipt.schema, 1);
		assert.deepEqual(receipt.context, context, 'Foreign source, run or expected role context');
		assert.equal(receipt.stage, stage, 'Foreign stage receipt');
		validateChain(receipt.prior, stage, context);
		assert.ok(receipt.attempt <= currentAttempt, 'Future producer attempt');
		for (const previous of receipt.prior)
			for (const row of previous.cells)
				assert.ok(row.attempt <= receipt.attempt, 'Predecessor from a future attempt');
		if (prior === undefined) prior = receipt.prior;
		else {
			// Attempt metadata can differ after a legitimate partial rerun of the same source/run.
			const meaning = (chain) =>
				chain.map((row) => ({
					stage: row.stage,
					cells: row.cells.map(({ attempt, ...value }) => value)
				}));
			assert.deepEqual(
				meaning(receipt.prior),
				meaning(prior),
				'Conflicting predecessor receipt chain'
			);
		}
		// Preserve a real admitted earlier chain when successful cells survive partial reruns.
		if (receipt.attempt < priorWitnessAttempt) {
			prior = receipt.prior;
			priorWitnessAttempt = receipt.attempt;
		}
		return {
			cell: receipt.cell,
			host: receipt.host,
			result: receipt.result,
			attempt: receipt.attempt
		};
	});
	const cells = validateCells(stage, rows, context);
	return { context, chain: [...prior, { stage, cells }] };
}

/** Successful earlier attempts may be retained by GitHub's rerun-failed-jobs behavior. */
function record(stage, selected, result, prior, context, host, attempt) {
	assert.ok(STAGES.includes(stage));
	validateContext(context);
	fields(prior, ['context', 'chain']);
	assert.deepEqual(prior.context, context);
	validateChain(prior.chain, stage, context);
	assert.ok(['success', 'failure', 'cancelled'].includes(result));
	const wanted = plan(stage, context).find((row) => identity(row) === identity(selected));
	assert.ok(wanted, 'Unplanned role cannot publish a receipt');
	assert.deepEqual(selected, wanted);
	validateHost(host, wanted);
	assert.ok(Number.isSafeInteger(attempt) && attempt > 0);
	for (const previous of prior.chain)
		for (const row of previous.cells)
			assert.ok(row.attempt <= attempt, 'Predecessor from a future attempt');
	return { schema: 1, context, stage, cell: selected, host, result, attempt, prior: prior.chain };
}

function legacyNeeds(proof, context) {
	fields(proof, ['context', 'chain']);
	assert.deepEqual(proof.context, context);
	assert.deepEqual(
		proof.chain.map((row) => row.stage),
		STAGES
	);
	for (const row of proof.chain) {
		fields(row, ['stage', 'cells']);
		assert.deepEqual(row.cells, validateCells(row.stage, row.cells, context));
	}
	return Object.fromEntries(
		[
			'test-hs',
			'e2e-hs',
			'package-macos',
			'launch',
			'tooltip-canvas',
			'managed-ollama-native',
			'cold-bootstrap-native'
		].map((id) => [id, { result: 'success' }])
	);
}

/** Uses publication-plan's bounded handle admission with this producer's pretty JSON image. */
function read(file) {
	const before = fs.lstatSync(file, { bigint: true });
	assert.ok(before.isFile() && !before.isSymbolicLink(), 'Stage receipt is not a regular file');
	assert.ok(before.size > 0n && before.size <= 65536n, 'Stage receipt size is invalid');
	const fd = fs.openSync(
		file,
		fs.constants.O_RDONLY | fs.constants.O_NONBLOCK | (fs.constants.O_NOFOLLOW || 0)
	);
	try {
		const acquired = fs.fstatSync(fd, { bigint: true });
		const same = (a, b) =>
			['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].every((key) => a[key] === b[key]);
		assert.ok(
			acquired.isFile() && same(before, acquired),
			'Stage receipt changed before acquisition'
		);
		const bytes = Buffer.alloc(Number(acquired.size) + 1);
		assert.equal(
			fs.readSync(fd, bytes, 0, bytes.length, 0),
			Number(acquired.size),
			'Stage receipt read is incomplete or grew'
		);
		const after = fs.lstatSync(file, { bigint: true });
		assert.ok(
			after.isFile() &&
				!after.isSymbolicLink() &&
				same(acquired, fs.fstatSync(fd, { bigint: true })) &&
				same(acquired, after),
			'Stage receipt changed during reading'
		);
		const raw = bytes.subarray(0, Number(acquired.size));
		const value = parseClosedJson(raw.toString('utf8'));
		assert.ok(
			raw.equals(Buffer.from(JSON.stringify(value, null, 2) + '\n', 'utf8')),
			'Stage receipt bytes are not canonical'
		);
		return value;
	} finally {
		fs.closeSync(fd);
	}
}

function readReceipts(directory, depth = 0) {
	assert.ok(depth <= 1, 'Nested artifact directory is unexpected');
	const metadata = fs.lstatSync(directory);
	assert.ok(
		metadata.isDirectory() && !metadata.isSymbolicLink(),
		'A regular stage artifact directory is required'
	);
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		assert.ok(!entry.isSymbolicLink(), 'Linked stage artifact refused');
		const file = path.join(directory, entry.name);
		if (entry.isDirectory()) return readReceipts(file, depth + 1);
		assert.ok(entry.isFile() && entry.name === 'receipt.json', 'Foreign stage artifact member');
		return [read(file)];
	});
}

function environmentContext() {
	const release = process.env.ERGOPTI_DEV_RELEASE_RELEASE;
	assert.ok(['true', 'false'].includes(release));
	const profile = release === 'true' ? 'release' : 'ci';
	const raw = execFileSync(
		'python3',
		['tools/diagnostics/macos_launch_gate.py', '--print-matrix', profile],
		{ encoding: 'utf8', timeout: 30000 }
	);
	assert.match(raw.trim(), /^scenarios=/);
	return validateContext({
		source_sha: process.env.GITHUB_SHA,
		run_id: process.env.GITHUB_RUN_ID,
		event_name: process.env.GITHUB_EVENT_NAME,
		release: release === 'true',
		scenarios: JSON.parse(raw.trim().slice('scenarios='.length))
	});
}

function save(file, value) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', { flag: 'wx' });
}

function main(args) {
	const [command, stage, input, output] = args;
	const context = environmentContext();
	if (command === 'plan') {
		assert.equal(args.length, 2);
		assert.ok(['e2e', 'testbuild'].includes(stage));
		if (stage === 'testbuild')
			assert.deepEqual(
				JSON.parse(process.env.MACOS_LAUNCH_SCENARIOS),
				context.scenarios,
				'Build scenario output differs from canonical owner'
			);
		fs.appendFileSync(
			process.env.GITHUB_OUTPUT,
			stage + '_matrix=' + JSON.stringify(plan(stage, context)) + '\n'
		);
	} else if (command === 'admit') {
		assert.equal(args.length, 4);
		const result = aggregate(parseClosedJson(process.env.MACOS_STAGE_NEEDS), stage);
		save(
			output,
			union(stage, readReceipts(input), result, context, Number(process.env.GITHUB_RUN_ATTEMPT))
		);
	} else if (command === 'record') {
		assert.equal(args.length, 4);
		const prior = input === '-' ? { context, chain: [] } : read(input);
		save(
			output,
			record(
				stage,
				parseClosedJson(process.env.MACOS_STAGE_CELL),
				process.env.MACOS_STAGE_RESULT,
				prior,
				context,
				{ os: process.platform, architecture: process.arch },
				Number(process.env.GITHUB_RUN_ATTEMPT)
			)
		);
	} else {
		assert.equal(command, 'verdict');
		assert.equal(args.length, 2);
		const result = aggregate(parseClosedJson(process.env.MACOS_STAGE_NEEDS), 'testbuild');
		const proof = union(
			'testbuild',
			readReceipts(stage),
			result,
			context,
			Number(process.env.GITHUB_RUN_ATTEMPT)
		);
		fs.appendFileSync(
			process.env.GITHUB_OUTPUT,
			'needs=' + JSON.stringify(legacyNeeds(proof, context)) + '\n'
		);
	}
}

module.exports = {
	STAGES,
	JOBS,
	plan,
	record,
	aggregate,
	union,
	legacyNeeds,
	readReceipts,
	validateContext
};
if (require.main === module) main(process.argv.slice(2));
