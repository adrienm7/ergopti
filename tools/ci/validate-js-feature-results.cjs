// tools/ci/validate-js-feature-results.cjs

/** Admit downloaded Common feature journals without replacing native qualification. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { validateFeatureJournals } = require('../test/lib/js-feature-results.cjs');
const { stageOf } = require('./js-feature-matrix.cjs');

// The rendered name of each Common stage's matrix job and the step that writes
// its feature journal: a lot runs in exactly one of them.
const STAGE_JOBS = Object.freeze({
	unit: { prefix: 'YAML, shared code & web / Unit tests', writer: 'Run shared validation suite' },
	integration: {
		prefix: 'YAML, shared code & web / Integration tests',
		writer: 'Run shared integration suite'
	}
});
const WRITERS = Object.values(STAGE_JOBS).map((stage) => stage.writer);
// A completed lot's writer step record lags its job by seconds; six reads 10 s
// apart cover that lag and still refuse a writer that never completes.
const WRITER_LAG_READS = 6;
const WRITER_LAG_INTERVAL_MS = 10000;
const WRITER_LAG_PAUSE = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function collectJournals(directory) {
	const result = [];
	function visit(current) {
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const target = path.join(current, entry.name);
			if (entry.isSymbolicLink()) throw new Error(`Refusing linked feature evidence: ${target}`);
			if (entry.isDirectory()) visit(target);
			else if (entry.isFile() && entry.name === 'timings.ndjson') {
				const text = fs.readFileSync(target, 'utf8');
				if (!text.endsWith('\n')) throw new Error(`Truncated feature evidence: ${target}`);
				result.push(
					text
						.trimEnd()
						.split('\n')
						.map((line) => JSON.parse(line))
				);
			}
		}
	}
	visit(directory);
	return result;
}

/** Bind every actual Unit and Integration lot to its unique highest successful execution. */
/**
 * Whether a job the API still reports in progress has in fact finished and
 * succeeded. Run 39836200270 read a lot as "in_progress" for half an hour after
 * every step, its runner's "Complete job" included, had completed with success
 * and its dependants had started: the job record is never refreshed, so a
 * re-read cannot help. The step records are the proof instead.
 * @param {object} job One API job.
 * @returns {boolean}
 */
function finishedBySteps(job) {
	if (job.status !== 'in_progress' || job.conclusion !== null || !Array.isArray(job.steps))
		return false;
	const steps = job.steps;
	if (steps.length === 0) return false;
	const last = steps.reduce((a, b) => (Number(b.number) > Number(a.number) ? b : a));
	// A skipped conditional step is part of a successful job; the writer step
	// itself is still required to succeed by the check that follows.
	return (
		last.name === 'Complete job' &&
		last.status === 'completed' &&
		last.conclusion === 'success' &&
		steps.every(
			(step) => step.status === 'completed' && ['success', 'skipped'].includes(step.conclusion)
		)
	);
}

function selectUnitJobs(plan, jobs, identity) {
	const fail = (ok, message) => {
		if (!ok) throw new Error('Common Unit admission refused: ' + message);
	};
	const positive = (value) =>
		Number.isSafeInteger(Number(value)) && /^[1-9][0-9]*$/.test(String(value));
	fail(
		identity &&
			/^[0-9a-f]{40}$/.test(identity.head_sha) &&
			positive(identity.run_id) &&
			positive(identity.run_attempt),
		'invalid API identity'
	);
	fail(Array.isArray(jobs) && jobs.length <= 1000, 'invalid job census');
	const expected = new Map(
		Object.entries(plan.metadata).map(([lot, row]) => [
			STAGE_JOBS[stageOf(row)].prefix + ' (' + lot + ')',
			row
		])
	);
	const ids = new Set();
	for (const job of jobs) {
		fail(positive(job.id) && !ids.has(String(job.id)), 'duplicate or invalid job ID');
		ids.add(String(job.id));
		const carriesWriter =
			Array.isArray(job.steps) && job.steps.some((step) => WRITERS.includes(step.name));
		const named =
			typeof job.name === 'string' &&
			Object.values(STAGE_JOBS).some((stage) => job.name.startsWith(stage.prefix));
		if (named || carriesWriter) fail(expected.has(job.name), 'foreign Unit name or writer');
	}
	const selected = {};
	for (const [name, row] of expected) {
		const found = jobs.filter((job) => job.name === name);
		fail(found.length > 0, 'missing Unit lot ' + name);
		for (const job of found)
			fail(
				String(job.run_id) === String(identity.run_id) &&
					job.head_sha === identity.head_sha &&
					positive(job.run_attempt) &&
					Number(job.run_attempt) <= Number(identity.run_attempt),
				'foreign or future Unit execution'
			);
		const latest = Math.max(...found.map((job) => Number(job.run_attempt)));
		const newest = found.filter((job) => Number(job.run_attempt) === latest);
		fail(newest.length === 1, 'ambiguous latest Unit execution');
		const job = newest[0];
		fail(
			(job.status === 'completed' && job.conclusion === 'success') || finishedBySteps(job),
			'latest Unit lot did not succeed: ' +
				JSON.stringify({
					lot: name,
					feature: row.feature,
					suite: row.suite,
					job_id: String(job.id),
					run_attempt: String(latest),
					status: typeof job.status === 'string' ? job.status.slice(0, 64) : null,
					conclusion: typeof job.conclusion === 'string' ? job.conclusion.slice(0, 64) : null
				})
		);
		const writer = STAGE_JOBS[stageOf(row)].writer;
		const writers = Array.isArray(job.steps)
			? job.steps.filter((step) => WRITERS.includes(step.name))
			: [];
		fail(
			writers.every((step) => step.name === writer),
			'Unit writer of another stage: ' + JSON.stringify({ lot: name, feature: row.feature })
		);
		// The API publishes a job's success before its step records: run 39785389458
		// read a completed successful lot whose writer step was still "pending". The
		// refusal is marked so the caller re-reads it; every other writer state refuses.
		const writerLags =
			writers.length === 1 && ['pending', 'queued', 'in_progress'].includes(writers[0].status);
		try {
			fail(
				writers.length === 1 &&
					writers[0].status === 'completed' &&
					writers[0].conclusion === 'success',
				'missing or failed Unit writer: ' +
					JSON.stringify({
						lot: name,
						feature: row.feature,
						suite: row.suite,
						job_id: String(job.id),
						run_attempt: String(latest),
						writer_count: writers.length,
						writers_truncated: writers.length > 3,
						writers: writers.slice(0, 3).map((step) => ({
							number: Number.isSafeInteger(step.number) ? step.number : null,
							status: typeof step.status === 'string' ? step.status.slice(0, 64) : null,
							conclusion: typeof step.conclusion === 'string' ? step.conclusion.slice(0, 64) : null
						}))
					})
			);
		} catch (error) {
			if (writerLags) error.writerStepLag = true;
			throw error;
		}
		selected[row.feature] = {
			suite: row.suite,
			job_id: String(job.id),
			run_attempt: String(latest)
		};
	}
	return selected;
}

/** Admit the current run before reading journals; a failed matrix cannot become a skip. */
async function receiveUnit(inventory, env, readApi, readJournals, pause = WRITER_LAG_PAUSE) {
	if (env.COMMON_PREDECESSOR_RESULT !== 'success')
		throw new Error('Common Unit matrix did not succeed');
	const { admitPlan } = require('./js-feature-matrix.cjs');
	const { collect, readCurrentRun } = require('./site-deploy-admission.cjs');
	const plan = admitPlan(
		inventory,
		{ source: env.GITHUB_SHA, ref: env.GITHUB_REF },
		env.COMMON_PLAN
	);
	const first = await readCurrentRun(env, readApi);
	let selected = null;
	for (let read = 1; selected === null; read++) {
		const jobs = await collect(
			readApi,
			'/repos/' + env.GITHUB_REPOSITORY + '/actions/runs/' + first.run_id + '/jobs?filter=all',
			'jobs'
		);
		try {
			selected = selectUnitJobs(plan, jobs, first);
		} catch (error) {
			if (!error.writerStepLag || read >= WRITER_LAG_READS) throw error;
			await pause(WRITER_LAG_INTERVAL_MS);
		}
	}
	let result = null;
	if (readJournals) {
		result = validateFeatureJournals(inventory, readJournals(), {
			platform: 'linux',
			source: env.GITHUB_SHA,
			run_id: env.GITHUB_RUN_ID,
			run_attempt: env.GITHUB_RUN_ATTEMPT
		});
		for (const feature of result.features)
			if (feature.producer_run_attempt !== selected[feature.feature].run_attempt)
				throw new Error(
					'Common feature evidence differs from its highest actual Unit writer attempt'
				);
	}
	if (JSON.stringify(await readCurrentRun(env, readApi)) !== JSON.stringify(first))
		throw new Error('Common Unit run identity changed while receiving evidence');
	return { selected, result };
}

async function main() {
	if (process.argv.length !== 3)
		throw new Error(
			'Usage: node tools/ci/validate-js-feature-results.cjs <downloaded-artifacts-directory>|--admit-jobs'
		);
	const { loadInventory } = require('../test/lib/js-feature-inventory.cjs');
	const { execFileSync } = require('node:child_process');
	const inventory = loadInventory(path.resolve(__dirname, '..', '..'));
	const received = await receiveUnit(
		inventory,
		process.env,
		(endpoint) =>
			JSON.parse(
				execFileSync('gh', ['api', endpoint], {
					encoding: 'utf8',
					maxBuffer: 4 * 1024 * 1024,
					stdio: ['ignore', 'pipe', 'pipe']
				})
			),
		process.argv[2] === '--admit-jobs' ? null : () => collectJournals(process.argv[2])
	);
	console.log(JSON.stringify(received, null, 2));
	if (received.result)
		console.log(`Common feature union: ${received.result.checks} checks passed exactly once.`);
	else console.log('Common Unit jobs received; deferred JavaScript remains unqualified.');
}

if (require.main === module)
	main().catch((error) => {
		console.error(error.message);
		process.exitCode = 1;
	});
module.exports = { collectJournals, selectUnitJobs, receiveUnit };
