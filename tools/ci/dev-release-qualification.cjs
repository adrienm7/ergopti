// tools/ci/dev-release-qualification.cjs
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const POLICY_PATH = path.resolve(
	__dirname,
	'../../.github/ci/dev_release_qualification_exceptions.json'
);
const SCOPE_IDS = Object.freeze([
	'windows-pac-full-url',
	'linux-window-receipts',
	'macos-brew-archive',
	'macos-shortcuts-discovery',
	'macos-launch-appleevents'
]);
const CONTEXT_KEYS = [
	'github_actions',
	'repository',
	'event_name',
	'ref',
	'release',
	'prerelease',
	'channel',
	'tag',
	'version'
];
function refuse(message) {
	throw new Error(message);
}
function keys(value, expected) {
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		Object.keys(value).sort().join('|') !== [...expected].sort().join('|')
	)
		refuse('Invalid closed qualification fields.');
}
function parseClosedJson(raw) {
	const value = JSON.parse(raw),
		stack = [];
	for (let i = 0; i < raw.length; i++) {
		if (raw[i] === '{') stack.push(new Set());
		else if (raw[i] === '}') stack.pop();
		else if (raw[i] === '"') {
			const start = i++;
			for (; i < raw.length; i++) {
				if (raw.charCodeAt(i) === 92) i++;
				else if (raw[i] === '"') break;
			}
			const text = JSON.parse(raw.slice(start, i + 1));
			let next = i + 1;
			while (/\s/.test(raw[next] || '') && next < raw.length) next++;
			if (raw[next] === ':') {
				const fields = stack[stack.length - 1];
				if (!fields || fields.has(text)) refuse('Duplicate qualification JSON field.');
				fields.add(text);
			}
		}
	}
	return value;
}
function validatePolicy(value) {
	keys(value, [
		'schema',
		'id',
		'expires_at',
		'repository',
		'event_name',
		'ref',
		'release',
		'prerelease',
		'channel',
		'tag',
		'version',
		'authorization_note',
		'scopes'
	]);
	if (
		value.schema !== 1 ||
		typeof value.id !== 'string' ||
		!/^[a-z0-9-]+$/.test(value.id) ||
		value.release !== true ||
		value.prerelease !== 'true' ||
		value.channel !== 'dev' ||
		value.event_name !== 'push' ||
		value.ref !== 'refs/heads/dev' ||
		typeof value.repository !== 'string' ||
		!/^\w[\w-]*\/[\w.-]+$/.test(value.repository) ||
		typeof value.authorization_note !== 'string' ||
		!value.authorization_note
	)
		refuse('Invalid qualification policy.');
	if (
		typeof value.expires_at !== 'string' ||
		!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value.expires_at) ||
		!Number.isFinite(Date.parse(value.expires_at)) ||
		typeof value.version !== 'string' ||
		!/^\d+\.\d+\.\d+-dev\.\d+$/.test(value.version) ||
		value.tag !== 'v' + value.version
	)
		refuse('Invalid qualification release boundary.');
	keys(value.scopes, SCOPE_IDS);
	const kinds = ['ahk_test', 'linux_fixture', 'swift_test_file', 'command', 'macos_launch'];
	const names = new Set();
	for (let i = 0; i < SCOPE_IDS.length; i++) {
		const row = value.scopes[SCOPE_IDS[i]];
		const expected =
			i === 0
				? ['kind', 'name', 'reason']
				: i === 2
					? ['kind', 'path', 'name', 'reason']
					: i === 4
						? ['kind', 'path', 'scenarios', 'runners', 'reason']
						: ['kind', 'path', 'args', 'reason'];
		keys(row, expected);
		if (
			i === 4 &&
			(JSON.stringify(row.scenarios) !== '["clean","karabiner_config"]' ||
				JSON.stringify(row.runners) !== '["macos-15","macos-15-intel"]')
		)
			refuse('Invalid closed Mac launch qualification matrix.');
		if (
			row.kind !== kinds[i] ||
			typeof row.reason !== 'string' ||
			!row.reason ||
			/[\r\n]/.test(row.reason)
		)
			refuse('Invalid qualification scope.');
		if (
			row.name !== undefined &&
			(typeof row.name !== 'string' || !row.name || /[\r\n]/.test(row.name) || names.has(row.name))
		)
			refuse('Duplicate or invalid qualification test name.');
		if (row.name) names.add(row.name);
		if (
			row.path !== undefined &&
			(typeof row.path !== 'string' ||
				!row.path ||
				row.path.startsWith('/') ||
				row.path.includes('..') ||
				/[\r\n]/.test(row.path) ||
				row.path.includes(String.fromCharCode(92)))
		)
			refuse('Invalid qualification artifact path.');
		if (
			row.args !== undefined &&
			(!Array.isArray(row.args) ||
				row.args.some((x) => typeof x !== 'string' || /[\r\n]/.test(x)) ||
				new Set(row.args).size !== row.args.length)
		)
			refuse('Invalid qualification arguments.');
	}
	return value;
}
function freeze(value) {
	if (value && typeof value === 'object') {
		for (const child of Object.values(value)) freeze(child);
		Object.freeze(value);
	}
	return value;
}
const POLICY = freeze(validatePolicy(parseClosedJson(fs.readFileSync(POLICY_PATH, 'utf8'))));
function eligible(context, now) {
	keys(context, CONTEXT_KEYS);
	const stamp = now instanceof Date ? now.getTime() : Date.parse(now);
	if (!Number.isFinite(stamp)) refuse('Invalid qualification clock.');
	return (
		context.github_actions === 'true' &&
		CONTEXT_KEYS.filter((k) => k !== 'github_actions').every((k) => context[k] === POLICY[k]) &&
		stamp < Date.parse(POLICY.expires_at)
	);
}
/** Automatic mismatch, expiry and later tags retain full default execution. */
function resolveQualificationProfile(context, now = new Date()) {
	return eligible(context, now) ? POLICY : null;
}
/** An explicit profile request refuses every unknown or ineligible context. */
function authorizeQualificationProfile(id, context, now = new Date()) {
	if (id !== POLICY.id || !eligible(context, now))
		refuse('Qualification profile is not authorized for this context.');
	return POLICY;
}
function deferredScopes(profile) {
	if (profile === null) return [];
	if (profile !== POLICY) refuse('Unknown qualification profile.');
	return SCOPE_IDS.slice();
}
function sourceSha(value) {
	if (typeof value !== 'string' || !/^[0-9a-f]{40}$/.test(value))
		refuse('Qualification source SHA is unavailable.');
	return value;
}
/** Closed missing-proof metadata never conveys native lease or feature authority. */
function qualificationReceipt(profile, scope, details) {
	if (profile !== POLICY || !SCOPE_IDS.includes(scope))
		refuse('Unknown qualification receipt scope.');
	keys(details, ['source_sha']);
	return {
		schema: 1,
		profile_id: POLICY.id,
		scope,
		tag: POLICY.tag,
		version: POLICY.version,
		expires_at: POLICY.expires_at,
		status: 'deferred',
		qualified: false,
		reason: POLICY.scopes[scope].reason,
		artifact: POLICY.scopes[scope],
		source_sha: sourceSha(details.source_sha)
	};
}
function validateQualificationReceipt(receipt, scope, sha, context, now = new Date()) {
	const profile = authorizeQualificationProfile(receipt && receipt.profile_id, context, now);
	const expected = qualificationReceipt(profile, scope, { source_sha: sha });
	if (JSON.stringify(receipt) !== JSON.stringify(expected))
		refuse('Qualification receipt is not the exact closed source-bound record.');
	return receipt;
}
/** Binds missing native proof to one retained lifecycle matrix row. */
function launchQualificationReceipt(profile, scenario, runner, details) {
	const scope = 'macos-launch-appleevents';
	const row = POLICY.scopes[scope];
	keys(details, ['source_sha']);
	if (
		typeof scenario !== 'string' ||
		!scenario ||
		/[\r\n]/.test(scenario) ||
		!row.runners.includes(runner)
	)
		refuse('Invalid Mac launch qualification row.');
	if (profile !== null) deferredScopes(profile);
	if (profile && row.scenarios.includes(scenario))
		return { ...qualificationReceipt(profile, scope, details), scenario, runner };
	return {
		schema: 1,
		profile_id: null,
		scope,
		status: 'full',
		qualified: false,
		source_sha: sourceSha(details.source_sha),
		scenario,
		runner
	};
}
/** Rechecks current policy, source and exact row before any omission or publication. */
function validateLaunchQualificationReceipt(
	receipt,
	scenario,
	runner,
	sha,
	context,
	now = new Date()
) {
	const expected = launchQualificationReceipt(
		resolveQualificationProfile(context, now),
		scenario,
		runner,
		{ source_sha: sha }
	);
	if (JSON.stringify(receipt) !== JSON.stringify(expected))
		refuse('Mac launch qualification is not the exact closed source-bound record.');
	return receipt.status === 'deferred' ? receipt : null;
}
function environmentContext(env = process.env) {
	return {
		github_actions: env.GITHUB_ACTIONS || '',
		repository: env.GITHUB_REPOSITORY || '',
		event_name: env.GITHUB_EVENT_NAME || '',
		ref: env.GITHUB_REF || '',
		release: env.ERGOPTI_DEV_RELEASE_RELEASE === 'true',
		prerelease: env.ERGOPTI_DEV_RELEASE_PRERELEASE || '',
		channel: env.ERGOPTI_DEV_RELEASE_CHANNEL || '',
		tag: env.ERGOPTI_DEV_RELEASE_TAG || '',
		version: env.ERGOPTI_DEV_RELEASE_VERSION || ''
	};
}
function selectRegistry(registry, profile, scope) {
	if (
		!Array.isArray(registry) ||
		registry.some((x) => !x || typeof x.name !== 'string' || typeof x.callback !== 'function')
	)
		refuse('Invalid complete qualification registry.');
	if (profile === null) return { selected: registry.slice(), deferred: [] };
	deferredScopes(profile);
	if (scope !== 'windows-pac-full-url') refuse('Invalid AHK qualification scope.');
	const name = POLICY.scopes[scope].name,
		matches = registry.filter((x) => x.name === name);
	if (matches.length !== 1)
		refuse('Qualification test must match the complete registry exactly once.');
	return { selected: registry.filter((x) => x.name !== name), deferred: matches };
}
function ahkQualificationManifest(tap, execution, profile, sha) {
	const eligible = [],
		deferred = [];
	for (const line of tap.split(/\r?\n/)) {
		let match = /^# QUALIFICATION_ELIGIBLE (\d+) - (.+)$/.exec(line);
		if (match) eligible.push({ index: Number(match[1]), name: match[2] });
		match = /^# DEFERRED qualification - (.+)$/.exec(line);
		if (match) deferred.push(match[1]);
	}
	if (
		!execution.complete ||
		profile !== POLICY ||
		deferred.length !== 1 ||
		deferred[0] !== POLICY.scopes['windows-pac-full-url'].name ||
		eligible.length !== execution.planned + deferred.length
	)
		refuse('Incomplete full AHK qualification registry.');
	const entries = [];
	let observed = 0,
		postponed = 0;
	for (let i = 0; i < eligible.length; i++) {
		if (eligible[i].index !== i + 1) refuse('Malformed qualification registry ordinal.');
		if (eligible[i].name === deferred[0]) {
			postponed++;
			entries.push({ ...eligible[i], status: 'deferred', duration_ms: null });
		} else {
			const actual = execution.executed[observed++];
			if (!actual || actual.name !== eligible[i].name)
				refuse('Qualification selection lost a registered test.');
			entries.push({ ...eligible[i], status: actual.status, duration_ms: actual.duration_ms });
		}
	}
	if (postponed !== 1 || observed !== execution.executed_count)
		refuse('Qualification accounting is incomplete.');
	return {
		...qualificationReceipt(profile, 'windows-pac-full-url', { source_sha: sha }),
		registry_complete: true,
		eligible_count: eligible.length,
		executed_count: observed,
		deferred_count: 1,
		passed: execution.passed,
		failed: execution.failed,
		entries
	};
}
function main(argv) {
	const options = {};
	for (let i = 0; i < argv.length; i += 2) {
		if (
			![
				'--scope',
				'--github-env',
				'--receipt',
				'--ahk-tap',
				'--execution-manifest',
				'--scenario',
				'--runner',
				'--validate-launch-receipt'
			].includes(argv[i]) ||
			!argv[i + 1] ||
			options[argv[i]]
		)
			refuse('Invalid qualification command arguments.');
		options[argv[i]] = argv[i + 1];
	}
	const scope = options['--scope'];
	if (!SCOPE_IDS.includes(scope)) refuse('Unknown qualification scope.');
	const context = environmentContext(),
		profile = resolveQualificationProfile(context);
	if (scope === 'macos-launch-appleevents') {
		const receipt = options['--validate-launch-receipt']
			? parseClosedJson(fs.readFileSync(options['--validate-launch-receipt'], 'utf8'))
			: launchQualificationReceipt(profile, options['--scenario'], options['--runner'], {
					source_sha: process.env.GITHUB_SHA
				});
		const deferred = validateLaunchQualificationReceipt(
			receipt,
			options['--scenario'],
			options['--runner'],
			process.env.GITHUB_SHA,
			context
		);
		if (options['--validate-launch-receipt']) {
			console.log(JSON.stringify(deferred));
			return;
		}
		if (!options['--receipt'] || options['--ahk-tap'] || options['--execution-manifest'])
			refuse('Mac launch qualification needs its exact receipt destination.');
		fs.writeFileSync(options['--receipt'], JSON.stringify(receipt, null, 2) + '\n');
		console.log(
			deferred
				? '[DEFERRED] ' +
						scope +
						': ' +
						receipt.scenario +
						'/' +
						receipt.runner +
						' native/feature qualified=false.'
				: 'Qualification profile inactive for this row; full execution is required.'
		);
		return;
	}
	if (options['--scenario'] || options['--runner'] || options['--validate-launch-receipt'])
		refuse('Unexpected launch qualification arguments.');
	if (options['--github-env'])
		fs.appendFileSync(
			options['--github-env'],
			'ERGOPTI_DEV_QUALIFICATION_PROFILE=' + (profile ? profile.id : '') + '\n'
		);
	if (profile) {
		let receipt = qualificationReceipt(profile, scope, { source_sha: process.env.GITHUB_SHA });
		if (options['--ahk-tap'])
			receipt = ahkQualificationManifest(
				fs.readFileSync(options['--ahk-tap'], 'utf8'),
				JSON.parse(fs.readFileSync(options['--execution-manifest'], 'utf8')),
				profile,
				process.env.GITHUB_SHA
			);
		if (options['--receipt'])
			fs.writeFileSync(options['--receipt'], JSON.stringify(receipt, null, 2) + '\n');
		console.log(
			'[DEFERRED] ' +
				scope +
				': ' +
				profile.scopes[scope].reason +
				' Native/feature qualified=false.'
		);
	} else {
		if (
			options['--ahk-tap'] &&
			fs.readFileSync(options['--ahk-tap'], 'utf8').includes('# DEFERRED qualification - ')
		)
			refuse('Expired or unauthorized AHK qualification deferral.');
		if (options['--receipt'])
			fs.writeFileSync(
				options['--receipt'],
				JSON.stringify(
					{
						schema: 1,
						profile_id: null,
						scope,
						status: 'full',
						qualified: false,
						source_sha: process.env.GITHUB_SHA || null
					},
					null,
					2
				) + '\n'
			);
		console.log('Qualification profile inactive; full execution is required.');
	}
}
module.exports = {
	POLICY_PATH,
	resolveQualificationProfile,
	authorizeQualificationProfile,
	deferredScopes,
	qualificationReceipt,
	validateQualificationReceipt,
	launchQualificationReceipt,
	validateLaunchQualificationReceipt,
	environmentContext,
	selectRegistry,
	ahkQualificationManifest,
	validatePolicy,
	parseClosedJson
};
if (require.main === module) {
	try {
		main(process.argv.slice(2));
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}
