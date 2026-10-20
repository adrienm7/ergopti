// tools/ci/macos-stage-roles.cjs
'use strict';

/** Keeps the five visible Mac stages complete through exact source-bound stage receipts. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { parseClosedJson } = require('./dev-release-qualification.cjs');
const STAGES = ['unit', 'e2e', 'build', 'testbuild'];
const JOBS = ['test-hs', 'e2e-hs', 'package-macos', 'launch'];
/**
 * The stages each stage admits directly. Build packages after Unit, beside
 * E2E, and the test build admits both, so every receipt chain still names
 * each earlier stage exactly once, in STAGES order, and the verdict proof
 * covers all four stages.
 */
const PREDECESSORS = Object.freeze({
	unit: Object.freeze([]),
	e2e: Object.freeze(['unit']),
	build: Object.freeze(['unit']),
	testbuild: Object.freeze(['e2e', 'build'])
});

/** The stages a receipt of one stage carries before itself: its transitive predecessors, in STAGES order. */
function priorStages(stage) {
	assert.ok(STAGES.includes(stage), 'Unknown stage');
	const found = new Set();
	const visit = (name) => {
		for (const predecessor of PREDECESSORS[name]) {
			found.add(predecessor);
			visit(predecessor);
		}
	};
	visit(stage);
	return STAGES.filter((name) => found.has(name));
}

/** A chain row without its attempts, which may differ after a legitimate partial rerun. */
function meaning(row) {
	return { stage: row.stage, cells: row.cells.map(({ attempt, ...value }) => value) };
}

/** The newest producer attempt of one chain row. */
function newestAttempt(row) {
	return Math.max(...row.cells.map((cell) => cell.attempt));
}
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

const MODULE_GROUPS = path.resolve(
	__dirname,
	'../../static/ergopti_plus/macos/tests/support/module_groups.lua'
);
let unitGroupNames;

/**
 * The Lua runner's domain groups, in order, read from their one owner
 * (run.lua --module=<group>). Each names one Unit cell; the groups partition
 * the suite, so the Unit cells together run every test module once.
 */
function unitGroups() {
	if (unitGroupNames) return unitGroupNames.slice();
	const source = fs.readFileSync(MODULE_GROUPS, 'utf8').replace(/\r\n/g, '\n');
	const table = /^M\.GROUPS = \{\n([\s\S]*?)\n\}\n/m.exec(source);
	assert.ok(table, 'module_groups.lua must declare M.GROUPS');
	const entries = table[1].split('\n').filter((line) => /^\t\{ name = /.test(line));
	const names = entries.map(
		(line) => /^\t\{ name = "([a-z][a-z0-9_]*)", prefixes = /.exec(line)?.[1]
	);
	assert.ok(names.length > 0, 'module_groups.lua declares no group');
	assert.ok(names.every(Boolean), 'Every module group needs a one-line literal name');
	assert.equal(new Set(names).size, names.length, 'Duplicate module group');
	assert.match(
		entries[entries.length - 1],
		/prefixes = \{\} \},?$/,
		'The last group must be the catch-all'
	);
	unitGroupNames = names;
	return names.slice();
}

/** Authored roles retain the original operating systems, architectures and job bounds. */
function plan(stage, context) {
	validateContext(context);
	if (stage === 'unit')
		return unitGroups().map((group) =>
			cell('lua-unit-meta', 'ubuntu-latest', 'stubbed', 360, group)
		);
	// Each managed-ollama-build cell runs the clean native source build of the
	// managed-ollama-native cell of its architecture, beside it; the sealed bytes
	// travel through tools/ci/managed-ollama-handoff.cjs.
	if (stage === 'e2e') {
		const rows = [
			cell('e2e-hs', 'ubuntu-latest', 'stubbed', 360),
			cell('tooltip-canvas', 'macos-15', 'arm64', 10),
			cell('managed-ollama-native', 'macos-15', 'arm64', 60),
			cell('managed-ollama-native', 'macos-15-intel', 'amd64', 60),
			cell('managed-ollama-build', 'macos-15', 'arm64', 60),
			cell('managed-ollama-build', 'macos-15-intel', 'amd64', 60)
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

/** Gives an admitted cell one human label without changing its runtime identity. */
function humanLot(stage, selected) {
	fields(selected, ['role', 'runner', 'architecture', 'timeout_minutes', 'scenario']);
	return roleLot(stage, selected.role, selected.architecture, selected.scenario);
}

/** Names an existing role without asserting a runtime cell or constructing a CI context. */
function roleLot(stage, role, architecture, scenario) {
	for (const [name, value] of Object.entries({ stage, role, architecture, scenario }))
		assert.equal(typeof value, 'string', 'Invalid human lot ' + name);
	const native = () => {
		assert.ok(['arm64', 'amd64'].includes(architecture), 'Unknown human lot architecture');
		return architecture === 'arm64' ? 'Apple silicon' : 'Intel';
	};
	if (stage === 'unit' && role === 'lua-unit-meta') {
		assert.equal(architecture, 'stubbed');
		assert.ok(unitGroups().includes(scenario), 'Unknown Unit module group');
		return scenario;
	}
	if (stage === 'testbuild' && role === 'launch') {
		assert.match(scenario, /^[a-z][a-z0-9_]*$/);
		return 'Installed app: ' + scenario.replace(/_/g, ' ') + ' (' + native() + ')';
	}
	assert.equal(scenario, '', 'Unexpected scenario for this human lot');
	switch (stage + '/' + role) {
		case 'e2e/e2e-hs':
			assert.equal(architecture, 'stubbed');
			return 'Virtual-keyboard replay (stubbed)';
		case 'e2e/tooltip-canvas':
			assert.equal(architecture, 'arm64');
			return 'Tooltip canvas (Apple silicon)';
		case 'e2e/managed-ollama-native':
			return 'Managed Ollama (' + native() + ')';
		case 'e2e/managed-ollama-build':
			return 'Managed Ollama build (' + native() + ')';
		case 'e2e/item36-native':
			assert.equal(architecture, 'host');
			return 'Archive update controls';
		case 'e2e/lease-silence-native':
			return 'Lease silence (' + native() + ')';
		case 'testbuild/cold-bootstrap-native':
			assert.equal(architecture, 'arm64');
			return 'Cold native bootstrap (Apple silicon)';
		default:
			throw new Error('Unknown human lot stage or role');
	}
}

/** Separates the only matrix axis from the complete canonical cell metadata. */
function displayPlan(stage, context) {
	assert.ok(['unit', 'e2e', 'testbuild'].includes(stage), 'Stage has no human lot matrix');
	const rows = plan(stage, context);
	const lots = rows.map((selected) => humanLot(stage, selected));
	assert.equal(new Set(lots).size, rows.length, 'Duplicate human lot label');
	return {
		matrix: { lot: lots },
		metadata: Object.fromEntries(lots.map((lot, index) => [lot, rows[index]]))
	};
}

/** Refuses a partial or altered map before returning the unchanged canonical cell. */
function selectLot(stage, lot, metadata, context) {
	const expected = displayPlan(stage, context);
	assert.deepEqual(metadata, expected.metadata, 'Complete human lot metadata map differs');
	assert.ok(
		typeof lot === 'string' && Object.hasOwn(expected.metadata, lot),
		'Missing or foreign human lot'
	);
	return expected.metadata[lot];
}

/** Unit lots are the module groups and need no predecessor to produce their metadata map. */
function selectUnitLot(lot, context) {
	return selectLot('unit', lot, displayPlan('unit', context).metadata, context);
}

/**
 * Validate the receiver's complete lot map, then every direct predecessor
 * aggregate, before reading prior receipts. Each predecessor stage is admitted
 * whole; a receipt of any other stage, a missing stage or two different
 * histories of a shared earlier stage refuse.
 */
function admit(receiver, lot, metadata, needs, context, currentAttempt, receive) {
	assert.ok(['e2e', 'build', 'testbuild'].includes(receiver), 'Unknown receiving stage');
	if (receiver !== 'build') selectLot(receiver, lot, metadata, context);
	const predecessors = PREDECESSORS[receiver];
	const result = aggregate(needs, predecessors);
	assert.equal(typeof receive, 'function', 'Missing prior receipt reader');
	const receipts = receive();
	assert.ok(Array.isArray(receipts), 'Prior stage receipts must be a list');
	for (const receipt of receipts)
		assert.ok(
			receipt !== null && typeof receipt === 'object' && predecessors.includes(receipt.stage),
			'Foreign stage receipt'
		);
	const proofs = predecessors.map((stage) =>
		union(
			stage,
			receipts.filter((receipt) => receipt.stage === stage),
			result,
			context,
			currentAttempt
		)
	);
	return join(receiver, proofs, context);
}

/** Joins admitted predecessor proofs into the receiver's exact prior chain. */
function join(receiver, proofs, context) {
	const byStage = new Map();
	for (const proof of proofs) {
		fields(proof, ['context', 'chain']);
		assert.deepEqual(proof.context, context, 'Foreign source, run or expected role context');
		for (const row of proof.chain) {
			const known = byStage.get(row.stage);
			if (known === undefined) {
				byStage.set(row.stage, row);
				continue;
			}
			assert.deepEqual(meaning(row), meaning(known), 'Conflicting predecessor receipt chain');
			// Keep the earliest successful witness, as union does inside one stage.
			if (newestAttempt(row) < newestAttempt(known)) byStage.set(row.stage, row);
		}
	}
	const chain = priorStages(receiver).map((stage) => byStage.get(stage));
	assert.ok(
		chain.every(Boolean) && byStage.size === chain.length,
		'Missing, repeated or reordered prior stage'
	);
	validateChain(chain, receiver, context);
	return { context, chain };
}

/** Bind the visible lot to the original receipt cell without extending the receipt schema. */
function recordLot(stage, selected, result, prior, context, host, attempt, lot, metadata) {
	if (stage !== 'build') {
		const expected =
			stage === 'unit' ? selectUnitLot(lot, context) : selectLot(stage, lot, metadata, context);
		assert.deepEqual(selected, expected, 'Selected human lot and receipt cell differ');
		assert.equal(humanLot(stage, selected), lot, 'Receipt human lot differs');
	}
	return record(stage, selected, result, prior, context, host, attempt);
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
	assert.deepEqual(
		chain.map((row) => row?.stage),
		priorStages(beforeStage),
		'Missing, repeated or reordered prior stage'
	);
	const newest = new Map();
	for (const row of chain) {
		fields(row, ['stage', 'cells']);
		assert.deepEqual(row.cells, validateCells(row.stage, row.cells, context));
		// A stage runs after its own predecessors, not after a parallel sibling.
		const priorAttempt = Math.max(
			0,
			...PREDECESSORS[row.stage].map((stage) => newest.get(stage) ?? 0)
		);
		assert.ok(
			row.cells.every((cell) => cell.attempt >= priorAttempt),
			'Backward predecessor attempt lineage'
		);
		newest.set(row.stage, newestAttempt(row));
	}
	return chain;
}

/** The direct GitHub matrix aggregates are admitted before any receipt is consumed. */
function aggregate(needs, stages) {
	const names = typeof stages === 'string' ? [stages] : stages;
	assert.ok(
		Array.isArray(names) && names.length > 0 && names.every((stage) => STAGES.includes(stage)),
		'Unknown predecessor stage'
	);
	const jobs = names.map((stage) => JOBS[STAGES.indexOf(stage)]);
	fields(needs, jobs);
	for (const job of jobs)
		assert.equal(needs[job].result, 'success', 'Direct predecessor aggregate did not succeed');
	return 'success';
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
			assert.deepEqual(
				receipt.prior.map(meaning),
				prior.map(meaning),
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
		const displayed = displayPlan(stage, context);
		fs.appendFileSync(
			process.env.GITHUB_OUTPUT,
			stage +
				'_matrix=' +
				JSON.stringify(displayed.matrix) +
				'\n' +
				stage +
				'_metadata=' +
				JSON.stringify(displayed.metadata) +
				'\n'
		);
	} else if (command === 'select') {
		assert.equal(args.length, 2);
		assert.equal(stage, 'unit');
		const selected = selectUnitLot(process.env.MACOS_STAGE_LOT, context);
		fs.appendFileSync(process.env.GITHUB_OUTPUT, 'cell=' + JSON.stringify(selected) + '\n');
	} else if (command === 'admit') {
		assert.equal(args.length, 4);
		save(
			output,
			admit(
				stage,
				process.env.MACOS_STAGE_LOT,
				stage === 'build' ? undefined : parseClosedJson(process.env.MACOS_STAGE_METADATA),
				parseClosedJson(process.env.MACOS_STAGE_NEEDS),
				context,
				Number(process.env.GITHUB_RUN_ATTEMPT),
				() => readReceipts(input)
			)
		);
	} else if (command === 'record') {
		assert.equal(args.length, 4);
		const prior = input === '-' ? { context, chain: [] } : read(input);
		save(
			output,
			recordLot(
				stage,
				parseClosedJson(process.env.MACOS_STAGE_CELL),
				process.env.MACOS_STAGE_RESULT,
				prior,
				context,
				{ os: process.platform, architecture: process.arch },
				Number(process.env.GITHUB_RUN_ATTEMPT),
				process.env.MACOS_STAGE_LOT,
				['e2e', 'testbuild'].includes(stage)
					? parseClosedJson(process.env.MACOS_STAGE_METADATA)
					: undefined
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
	unitGroups,
	STAGES,
	JOBS,
	PREDECESSORS,
	priorStages,
	plan,
	humanLot,
	roleLot,
	displayPlan,
	selectLot,
	selectUnitLot,
	admit,
	recordLot,
	record,
	aggregate,
	union,
	validateChain,
	legacyNeeds,
	readReceipts,
	validateContext
};
if (require.main === module) main(process.argv.slice(2));
