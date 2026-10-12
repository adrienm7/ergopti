// tools/ci/publication-plan.cjs

/** Persists the validation plan across failed-job reruns without reusable outputs. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { selectLanes, verifyManualJobs } = require('./manual-ci-lanes.cjs');
const { loadChannels } = require('../build/release-channel.cjs');

// A scalar plan carries no logs or assets; bound its complete retained image.
const MAX_PLAN_BYTES = 64 * 1024;

const FIELDS = Object.freeze([
	'release',
	'version',
	'tag',
	'title',
	'prerelease',
	'channel',
	'linux_bundle',
	'native_qualification_profile',
	'lane_windows',
	'lane_macos',
	'lane_linux'
]);
const CONTEXT = Object.freeze([
	'repository',
	'source_sha',
	'run_id',
	'producer_attempt',
	'event',
	'ref',
	'selection'
]);

/** Requires a closed JSON object before trusting any of its fields. */
function exactKeys(value, keys) {
	assert.ok(value && typeof value === 'object' && !Array.isArray(value));
	assert.deepEqual(Object.keys(value).sort(), [...keys].sort(), 'Publication plan shape changed.');
}

/** Reads only non-secret scheduler identity and the original manual selection. */
function context(env) {
	const result = {
		repository: env.GITHUB_REPOSITORY,
		source_sha: env.GITHUB_SHA,
		run_id: env.GITHUB_RUN_ID,
		producer_attempt: env.GITHUB_RUN_ATTEMPT,
		event: env.GITHUB_EVENT_NAME,
		ref: env.GITHUB_REF,
		selection: env.CI_OS_SELECTION || 'all'
	};
	for (const key of CONTEXT)
		assert.ok(
			typeof result[key] === 'string' &&
				result[key].length <= 4096 &&
				!/[\r\n\0]/.test(result[key]),
			`Invalid publication context: ${key}`
		);
	assert.match(result.repository, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/);
	assert.match(result.source_sha, /^[a-f0-9]{40}$/);
	for (const key of ['run_id', 'producer_attempt']) assert.match(result[key], /^[1-9][0-9]*$/);
	assert.ok(['push', 'pull_request', 'workflow_dispatch'].includes(result.event));
	assert.ok(
		typeof result.ref === 'string' && result.ref.startsWith('refs/') && !/[\r\n\0]/.test(result.ref)
	);
	selectLanes(result.event, result.selection);
	return result;
}

/** Validates the original plan, retaining its approved qualification selection. */
function validate(record) {
	exactKeys(record, ['schema_version', 'context', 'plan']);
	assert.equal(record.schema_version, 1);
	exactKeys(record.context, CONTEXT);
	exactKeys(record.plan, FIELDS);
	const c = record.context;
	context({
		GITHUB_REPOSITORY: c.repository,
		GITHUB_SHA: c.source_sha,
		GITHUB_RUN_ID: c.run_id,
		GITHUB_RUN_ATTEMPT: c.producer_attempt,
		GITHUB_EVENT_NAME: c.event,
		GITHUB_REF: c.ref,
		CI_OS_SELECTION: c.selection
	});
	const p = record.plan;
	for (const key of FIELDS)
		assert.ok(
			typeof p[key] === 'string' && p[key].length <= 4096 && !/[\r\n\0]/.test(p[key]),
			`Invalid publication field: ${key}`
		);
	assert.ok(['true', 'false'].includes(p.release));
	assert.match(p.linux_bundle, /^[A-Za-z0-9._+-]+\.tar\.gz$/);
	assert.match(p.native_qualification_profile, /^[A-Za-z0-9_.-]*$/);
	const lanes = selectLanes(c.event, c.selection);
	for (const [os, enabled] of Object.entries(lanes)) assert.equal(p[`lane_${os}`], String(enabled));
	if (p.release === 'true') {
		assert.equal(c.event, 'push');
		assert.ok(['refs/heads/main', 'refs/heads/dev'].includes(c.ref));
		assert.equal(p.tag, 'v' + p.version);
		assert.match(p.version, /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-dev\.[1-9]\d*)?$/);
		assert.equal(p.title, 'Ergopti ' + p.tag);
		assert.equal(p.channel, loadChannels().channelForTag(p.tag));
		assert.equal(p.channel, c.ref === 'refs/heads/dev' ? 'dev' : 'main');
		assert.match(
			p.tag,
			c.ref === 'refs/heads/dev'
				? /^v0\.0\.0-dev\.[1-9]\d*$/
				: /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/
		);
		assert.equal(p.prerelease, c.ref === 'refs/heads/dev' ? 'true' : 'false');
	} else {
		for (const key of ['version', 'tag', 'title', 'prerelease']) assert.equal(p[key], '');
		assert.equal(p.channel, 'dev');
	}
	return record;
}

/** Builds a create-only record from the final validation step's exact outputs. */
function create(env) {
	return validate({
		schema_version: 1,
		context: context(env),
		plan: Object.fromEntries(FIELDS.map((key) => [key, env['CI_PLAN_' + key.toUpperCase()] || '']))
	});
}

/** Accepts retained earlier-attempt plans only within the same source and run. */
function receive(record, env, jobs) {
	validate(record);
	const current = context(env);
	for (const key of CONTEXT.filter((key) => key !== 'producer_attempt'))
		assert.equal(record.context[key], current[key], `Publication identity differs: ${key}`);
	assert.ok(
		BigInt(record.context.producer_attempt) <= BigInt(current.producer_attempt),
		'Publication plan comes from a future attempt.'
	);
	exactKeys(jobs, ['core', 'windows', 'macos', 'linux']);
	if (current.event === 'workflow_dispatch') {
		const outputs = Object.fromEntries(
			['windows', 'macos', 'linux'].map((os) => ['lane_' + os, record.plan['lane_' + os]])
		);
		// Common can succeed only after the validation producer succeeded. Its
		// scheduler result and the persisted plan retain the old five-job verdict.
		verifyManualJobs(current.event, current.selection, {
			...jobs,
			validate: { result: 'success', outputs }
		});
	} else {
		for (const job of Object.values(jobs))
			assert.equal(job?.result, 'success', 'A publication lane did not succeed.');
	}
	return record.plan;
}

/** Reads the exact create-owned JSON image through one bounded regular handle. */
function read(file) {
	const before = fs.lstatSync(file, { bigint: true });
	assert.ok(before.isFile() && !before.isSymbolicLink(), 'Publication plan is not a regular file.');
	assert.ok(
		before.size > 0n && before.size <= BigInt(MAX_PLAN_BYTES),
		'Publication plan size is invalid.'
	);
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
			'Publication plan changed before acquisition.'
		);
		const bytes = Buffer.alloc(Number(acquired.size) + 1);
		assert.equal(
			fs.readSync(fd, bytes, 0, bytes.length, 0),
			Number(acquired.size),
			'Publication plan read is incomplete or grew.'
		);
		const after = fs.lstatSync(file, { bigint: true });
		assert.ok(
			after.isFile() &&
				!after.isSymbolicLink() &&
				same(acquired, fs.fstatSync(fd, { bigint: true })) &&
				same(acquired, after),
			'Publication plan changed during reading.'
		);
		const raw = bytes.subarray(0, Number(acquired.size));
		const parsed = JSON.parse(raw.toString('utf8'));
		assert.ok(
			raw.equals(Buffer.from(JSON.stringify(parsed) + '\n', 'utf8')),
			'Publication plan bytes are not canonical.'
		);
		return parsed;
	} finally {
		fs.closeSync(fd);
	}
}

/** Uses a create-only artifact and refuses missing or malformed receiving data. */
function main(argv, env) {
	assert.ok(
		argv.length === 2 && ['create', 'receive'].includes(argv[0]),
		'Publication plan mode/path required.'
	);
	if (argv[0] === 'create') {
		const image = JSON.stringify(create(env)) + '\n';
		assert.ok(
			Buffer.byteLength(image, 'utf8') <= MAX_PLAN_BYTES,
			'Publication plan size is invalid.'
		);
		fs.writeFileSync(argv[1], image, { encoding: 'utf8', flag: 'wx' });
	} else {
		const plan = receive(read(argv[1]), env, JSON.parse(env.CI_JOB_RESULTS));
		assert.ok(env.GITHUB_OUTPUT, 'Publication output port is missing.');
		fs.appendFileSync(
			env.GITHUB_OUTPUT,
			FIELDS.map((key) => `${key}=${plan[key]}\n`).join(''),
			'utf8'
		);
	}
}

if (require.main === module) {
	try {
		main(process.argv.slice(2), process.env);
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}

module.exports = { FIELDS, create, receive, validate, read, main };
