// tools/ci/run-timing.cjs

/**
 * ==============================================================================
 * MODULE: CI Run Timing
 * DESCRIPTION:
 * Reads the jobs of one finished GitHub Actions run and prints where its time
 * went: the wall clock of each lane, the slowest jobs with their queue time and
 * the slowest steps. It answers "what is on the critical path" without opening
 * hundreds of job pages, and it is the evidence the CI duration target in
 * docs/memory/workflow-and-verification.md is measured against.
 *
 * ROOT CAUSE ENCODED:
 * A partial rerun lists the jobs it did not execute again as copies under the new
 * attempt with the original times (see producingAttempt in
 * site-deploy-admission.cjs). Summing them would count a lane's time twice, so
 * a row sharing its name, start and completion with an earlier attempt is dropped.
 * Steps that never ran carry no times and are skipped, never read as zero.
 *
 * USAGE:
 *   node tools/ci/run-timing.cjs <run-id> [--top N]
 * Needs an authenticated `gh`. Pages are 30 jobs: a larger page makes the API
 * answer 502 on runs with several hundred jobs.
 * ==============================================================================
 */

'use strict';

const { execFileSync } = require('node:child_process');

const REPOSITORY = 'adrienm7/ergopti';
const PAGE_SIZE = 30;
const DEFAULT_TOP = 15;

/**
 * Milliseconds between two ISO instants, or null when either is missing.
 * @param {string|null} from Start.
 * @param {string|null} to End.
 * @returns {number|null}
 */
function span(from, to) {
	if (typeof from !== 'string' || typeof to !== 'string') return null;
	const value = Date.parse(to) - Date.parse(from);
	return Number.isFinite(value) && value >= 0 ? value : null;
}

/**
 * Drops the copies a partial rerun lists under a later attempt.
 * @param {Array<object>} jobs Every job row of the run, all attempts.
 * @returns {Array<object>} Each executed job once.
 */
function executedJobs(jobs) {
	const first = new Map();
	for (const job of jobs) {
		const key = [job.name, job.started_at, job.completed_at].join('\u0000');
		const seen = first.get(key);
		if (seen === undefined || Number(job.run_attempt) < Number(seen.run_attempt))
			first.set(key, job);
	}
	return [...first.values()].filter((job) => span(job.started_at, job.completed_at) !== null);
}

/**
 * Builds the timing summary of a run.
 * @param {Array<object>} jobs Every job row of the run.
 * @param {number} top How many jobs and steps to keep.
 * @returns {{wall_ms: number, lanes: Array<object>, jobs: Array<object>, steps: Array<object>}}
 */
function summarize(jobs, top = DEFAULT_TOP) {
	const executed = executedJobs(jobs);
	if (executed.length === 0) throw new Error('The run has no job with start and completion times.');
	const starts = executed.map((job) => Date.parse(job.started_at));
	const ends = executed.map((job) => Date.parse(job.completed_at));
	const lanes = new Map();
	for (const job of executed) {
		const lane = job.name.includes(' / ') ? job.name.split(' / ')[0] : job.name;
		const row = lanes.get(lane) || { lane, jobs: 0, start: Infinity, end: -Infinity };
		row.jobs++;
		row.start = Math.min(row.start, Date.parse(job.started_at));
		row.end = Math.max(row.end, Date.parse(job.completed_at));
		lanes.set(lane, row);
	}
	const steps = executed.flatMap((job) =>
		(job.steps || [])
			.map((step) => ({
				job: job.name,
				step: step.name,
				conclusion: step.conclusion,
				elapsed_ms: span(step.started_at, step.completed_at)
			}))
			.filter((step) => step.elapsed_ms !== null)
	);
	return {
		wall_ms: Math.max(...ends) - Math.min(...starts),
		lanes: [...lanes.values()]
			.map((row) => ({ lane: row.lane, jobs: row.jobs, wall_ms: row.end - row.start }))
			.sort((a, b) => b.wall_ms - a.wall_ms),
		jobs: executed
			.map((job) => ({
				job: job.name,
				conclusion: job.conclusion,
				elapsed_ms: span(job.started_at, job.completed_at),
				queued_ms: span(job.created_at, job.started_at)
			}))
			.sort((a, b) => b.elapsed_ms - a.elapsed_ms)
			.slice(0, top),
		steps: steps.sort((a, b) => b.elapsed_ms - a.elapsed_ms).slice(0, top)
	};
}

/**
 * Formats a duration for people.
 * @param {number|null} ms Milliseconds.
 * @returns {string} "12m 03s", or "-" when unknown.
 */
function clock(ms) {
	if (ms === null || ms === undefined) return '-';
	const seconds = Math.round(ms / 1000);
	return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`;
}

/**
 * Renders the summary as text.
 * @param {ReturnType<typeof summarize>} summary Timing summary.
 * @returns {string}
 */
function render(summary) {
	const lines = [
		`Run wall clock: ${clock(summary.wall_ms)}`,
		'',
		'Lanes (first start to last end):'
	];
	for (const row of summary.lanes)
		lines.push(`  ${clock(row.wall_ms).padStart(8)}  ${row.lane} (${row.jobs} job(s))`);
	lines.push('', 'Slowest jobs (elapsed, queued before start):');
	for (const row of summary.jobs)
		lines.push(
			`  ${clock(row.elapsed_ms).padStart(8)}  +${clock(row.queued_ms)} queued  ${row.job}`
		);
	lines.push('', 'Slowest steps:');
	for (const row of summary.steps)
		lines.push(`  ${clock(row.elapsed_ms).padStart(8)}  ${row.step}  [${row.job}]`);
	return lines.join('\n') + '\n';
}

/**
 * Reads every job row of a run through `gh`, page by page.
 * @param {string} runId Numeric run id.
 * @param {(endpoint: string) => object} readApi Returns the parsed API answer.
 * @returns {Array<object>}
 */
function readJobs(runId, readApi) {
	const jobs = [];
	for (let page = 1; ; page++) {
		const answer = readApi(
			`repos/${REPOSITORY}/actions/runs/${runId}/jobs?filter=all&per_page=${PAGE_SIZE}&page=${page}`
		);
		if (!Array.isArray(answer.jobs)) throw new Error('The jobs answer has no job list.');
		jobs.push(...answer.jobs);
		if (jobs.length >= answer.total_count || answer.jobs.length === 0) return jobs;
	}
}

function main(argv = process.argv.slice(2)) {
	const runId = argv[0];
	const topAt = argv.indexOf('--top');
	const top = topAt >= 0 ? Number(argv[topAt + 1]) : DEFAULT_TOP;
	if (!/^[1-9][0-9]*$/.test(runId || '') || !Number.isSafeInteger(top) || top < 1)
		throw new Error('usage: run-timing.cjs <run-id> [--top N]');
	const readApi = (endpoint) =>
		JSON.parse(
			execFileSync('gh', ['api', endpoint], {
				encoding: 'utf8',
				maxBuffer: 16 * 1024 * 1024,
				stdio: ['ignore', 'pipe', 'pipe']
			})
		);
	process.stdout.write(render(summarize(readJobs(runId, readApi), top)));
}

if (require.main === module) {
	try {
		main();
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}
module.exports = { summarize, executedJobs, readJobs, render, clock };
