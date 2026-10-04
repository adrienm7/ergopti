// tools/ci/manual-ci-lanes.cjs

/**
 * ==============================================================================
 * MODULE: Manual CI Lane Selection
 * DESCRIPTION:
 * Resolves one strict manual OS choice and verifies the selected native jobs.
 * Push and pull-request runs always select every OS. Shared checks remain
 * mandatory for every manual subset, and this owner never authorizes releases.
 *
 * FEATURES & RATIONALE:
 * 1. Exact choices admit singles, pairs or all without shell interpolation.
 * 2. Selected jobs require success; unselected jobs must be intentionally skipped.
 * 3. One built-in-only CLI serves both the plan and its final manual verdict.
 * ==============================================================================
 */

'use strict';

const CHOICES = Object.freeze({
	all: ['windows', 'macos', 'linux'],
	windows: ['windows'],
	macos: ['macos'],
	linux: ['linux'],
	'windows+macos': ['windows', 'macos'],
	'windows+linux': ['windows', 'linux'],
	'macos+linux': ['macos', 'linux']
});

/** Returns the selected OS booleans; automatic runs ignore manual input. */
function selectLanes(event, selection = 'all') {
	const choice = event === 'workflow_dispatch' ? selection : 'all';
	if (typeof choice !== 'string' || !Object.hasOwn(CHOICES, choice)) {
		throw new Error('Invalid manual CI OS selection');
	}
	const selected = CHOICES[choice];
	return Object.fromEntries(['windows', 'macos', 'linux'].map((os) => [os, selected.includes(os)]));
}

/** Rejects missing, failed or unexpectedly skipped selected work. */
function verifyManualJobs(event, selection, jobs) {
	if (event !== 'workflow_dispatch') throw new Error('Manual CI verdict requires dispatch');
	const lanes = selectLanes(event, selection);
	const expected = ['validate', 'core', 'windows', 'macos', 'linux'];
	if (
		!jobs ||
		typeof jobs !== 'object' ||
		Array.isArray(jobs) ||
		Object.keys(jobs).sort().join(',') !== [...expected].sort().join(',')
	) {
		throw new Error('Manual CI verdict requires every job result');
	}
	const outputs = jobs.validate && jobs.validate.outputs;
	if (
		!outputs ||
		typeof outputs !== 'object' ||
		Array.isArray(outputs) ||
		Object.keys(outputs)
			.filter((key) => key.startsWith('lane_'))
			.sort()
			.join(',') !== 'lane_linux,lane_macos,lane_windows'
	) {
		throw new Error('Manual CI verdict requires the selected lane outputs');
	}
	for (const [os, selected] of Object.entries(lanes)) {
		if (outputs[`lane_${os}`] !== String(selected)) {
			throw new Error('Manual CI lane output does not match the requested choice');
		}
	}
	for (const job of expected) {
		const wanted = job === 'validate' || job === 'core' || lanes[job] ? 'success' : 'skipped';
		if (!jobs[job] || jobs[job].result !== wanted) {
			throw new Error(`Manual CI job did not reach its required result: ${job}`);
		}
	}
	return true;
}

/** Executes the workflow port without reading packages or emitting input data. */
function main(argv, env, output) {
	if (argv.length !== 1) throw new Error('Manual CI lane command requires one mode');
	if (argv[0] === 'select') {
		const lanes = selectLanes(env.CI_EVENT, env.CI_OS_SELECTION);
		for (const [os, selected] of Object.entries(lanes)) output(`lane_${os}=${selected}\n`);
	} else if (argv[0] === 'verdict') {
		let jobs;
		try {
			jobs = JSON.parse(env.CI_JOB_RESULTS);
		} catch {
			throw new Error('Manual CI job results are not valid JSON');
		}
		verifyManualJobs(env.CI_EVENT, env.CI_OS_SELECTION, jobs);
		output('[OK] Shared checks and selected native OS lanes passed.\n');
	} else {
		throw new Error('Invalid manual CI lane command');
	}
}

if (require.main === module) {
	try {
		main(process.argv.slice(2), process.env, (text) => process.stdout.write(text));
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}

module.exports = { selectLanes, verifyManualJobs, main };
