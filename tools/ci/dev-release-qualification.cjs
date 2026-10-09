// tools/ci/dev-release-qualification.cjs
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const POLICY_PATH = path.resolve(
	__dirname,
	'../../.github/ci/dev_release_qualification_exceptions.json'
);
const STABLE_POLICY_PATH = path.resolve(
	__dirname,
	'../../.github/ci/stable_release_qualification_exception.json'
);
const STABLE_PROFILE_ID = 'stable-v1-20261009-macos-native-deferred';
const SCOPE_IDS = Object.freeze([
	'windows-pac-full-url',
	'linux-window-receipts',
	'macos-brew-archive',
	'macos-shortcuts-discovery',
	'macos-launch-appleevents'
]);
const STABLE_EXTRA_SCOPES = Object.freeze({
	'core-js-suite': { path: '.github/workflows/ci.yml', args: ['core', 'npm run test:js'] },
	'macos-native-model-receiving': {
		path: '.github/workflows/ci-macos.yml',
		args: [
			'managed-ollama-native',
			'Receive actual native model create, pull, inference and retirement'
		]
	},
	'linux-unit-suite': {
		path: '.github/workflows/ci-linux.yml',
		args: ['test-linux', 'Run the driver unit test suite']
	},
	'linux-e2e-suite': {
		path: '.github/workflows/ci-linux.yml',
		args: ['e2e-linux', 'Linux E2E test suite bodies including live fixture chain']
	},
	'macos-native-pac': {
		path: '.github/workflows/ci-macos.yml',
		args: ['managed-ollama-native', 'Qualify actual native PAC and WPAD XCTest controls']
	},
	'macos-native-http': {
		path: '.github/workflows/ci-macos.yml',
		args: ['managed-ollama-native', 'Receive actual independent managed HTTP native clients']
	},
	'macos-stubbed-unit': {
		path: '.github/workflows/ci-macos.yml',
		args: ['test-hs', 'Run unit + meta tests']
	},
	'macos-stubbed-e2e': {
		path: '.github/workflows/ci-macos.yml',
		args: ['e2e-hs', 'Run virtual-keyboard harness (stubbed hs.* — no real Hammerspoon)']
	},
	'windows-native-desktop': {
		path: '.github/workflows/ci-windows.yml',
		args: ['test-ahk', 'Run native desktop AHK cohorts']
	},
	'linux-simultaneous-native': {
		path: 'static/ergopti_plus/linux/tests/hardware/run_daemon_live.sh',
		args: [
			'python3',
			'tests/hardware/run_native_subreaper.py',
			'luajit',
			'tests/hardware/run_simultaneous_configuration_real.lua'
		]
	}
});
const STABLE_SCOPE_IDS = Object.freeze([
	...SCOPE_IDS.slice(2),
	...Object.keys(STABLE_EXTRA_SCOPES)
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
	const stable = value && value.id === STABLE_PROFILE_ID;
	if (
		stable &&
		(value.repository !== 'adrienm7/ergopti' ||
			value.expires_at !== '2026-10-09T22:00:00Z' ||
			value.tag !== 'v1.0.0' ||
			value.version !== '1.0.0')
	)
		refuse('Invalid one-candidate stable boundary.');
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
		value.prerelease !== (stable ? 'false' : 'true') ||
		value.channel !== (stable ? 'main' : 'dev') ||
		value.event_name !== 'push' ||
		value.ref !== (stable ? 'refs/heads/main' : 'refs/heads/dev') ||
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
		!(stable ? /^1\.0\.0$/ : /^\d+\.\d+\.\d+-dev\.\d+$/).test(value.version) ||
		value.tag !== 'v' + value.version
	)
		refuse('Invalid qualification release boundary.');
	const policyScopes = stable ? STABLE_SCOPE_IDS : SCOPE_IDS;
	keys(value.scopes, policyScopes);
	const kinds = ['ahk_test', 'linux_fixture', 'swift_test_file', 'command', 'macos_launch'];
	const names = new Set();
	for (const scope of policyScopes) {
		const i = SCOPE_IDS.indexOf(scope);
		const row = value.scopes[scope];
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
			i < 0 &&
			(row.path !== STABLE_EXTRA_SCOPES[scope].path ||
				JSON.stringify(row.args) !== JSON.stringify(STABLE_EXTRA_SCOPES[scope].args))
		)
			refuse('Invalid closed stable command scope.');
		if (
			i === 4 &&
			(JSON.stringify(row.scenarios) !== '["clean","karabiner_config"]' ||
				JSON.stringify(row.runners) !== '["macos-15","macos-15-intel"]')
		)
			refuse('Invalid closed Mac launch qualification matrix.');
		if (
			row.kind !== (i < 0 ? 'command' : kinds[i]) ||
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
const STABLE_POLICY = freeze(
	validatePolicy(parseClosedJson(fs.readFileSync(STABLE_POLICY_PATH, 'utf8')))
);
function eligible(context, now, policy = POLICY) {
	keys(context, CONTEXT_KEYS);
	const stamp = now instanceof Date ? now.getTime() : Date.parse(now);
	if (!Number.isFinite(stamp)) refuse('Invalid qualification clock.');
	return (
		context.github_actions === 'true' &&
		CONTEXT_KEYS.filter((k) => k !== 'github_actions').every((k) => context[k] === policy[k]) &&
		stamp < Date.parse(policy.expires_at)
	);
}
/** Automatic mismatch, expiry and later tags retain full default execution. */
function resolveQualificationProfile(context, now = new Date(), scope = null) {
	if ((scope === null || SCOPE_IDS.includes(scope)) && eligible(context, now)) return POLICY;
	return STABLE_SCOPE_IDS.includes(scope) && eligible(context, now, STABLE_POLICY)
		? STABLE_POLICY
		: null;
}
/** An explicit profile request refuses every unknown or ineligible context. */
function authorizeQualificationProfile(id, context, now = new Date()) {
	const policy = id === POLICY.id ? POLICY : id === STABLE_POLICY.id ? STABLE_POLICY : null;
	if (!policy || !eligible(context, now, policy))
		refuse('Qualification profile is not authorized for this context.');
	return policy;
}
function deferredScopes(profile) {
	if (profile === null) return [];
	if (profile !== POLICY && profile !== STABLE_POLICY) refuse('Unknown qualification profile.');
	return Object.keys(profile.scopes);
}
function sourceSha(value) {
	if (typeof value !== 'string' || !/^[0-9a-f]{40}$/.test(value))
		refuse('Qualification source SHA is unavailable.');
	return value;
}
/** Closed missing-proof metadata never conveys native lease or feature authority. */
function qualificationReceipt(profile, scope, details) {
	if ((profile !== POLICY && profile !== STABLE_POLICY) || !deferredScopes(profile).includes(scope))
		refuse('Unknown qualification receipt scope.');
	keys(details, ['source_sha']);
	return {
		schema: 1,
		profile_id: profile.id,
		scope,
		tag: profile.tag,
		version: profile.version,
		expires_at: profile.expires_at,
		status: 'deferred',
		qualified: false,
		reason: profile.scopes[scope].reason,
		artifact: profile.scopes[scope],
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
	const row = (profile || POLICY).scopes[scope];
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
		resolveQualificationProfile(context, now, 'macos-launch-appleevents'),
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
/** Selects only this one proposed stable publication; existing callers remain full. */
function stablePublicationProfile(context, now = new Date()) {
	const selected = resolveQualificationProfile(context, now, 'macos-brew-archive');
	return selected === STABLE_POLICY ? selected : null;
}
/** Fresh admission precedes every publication side effect; missing proof stays explicit. */
function stablePublicationNotice(id, context, sha, now = new Date()) {
	if (id === '') return '';
	if (id !== STABLE_POLICY.id) refuse('Unknown stable publication selection.');
	const profile = authorizeQualificationProfile(id, context, now);
	return (
		'NATIVE AND HARNESS QUALIFICATION DEFERRED / qualified:false (source ' +
		sourceSha(sha) +
		'): ' +
		deferredScopes(profile)
			.map((scope) => scope + ': ' + profile.scopes[scope].reason)
			.join(' ') +
		' ' +
		'Compilation, packaging, macOS signing, source and asset integrity, installation and all other tests remain required. Windows signature evidence is disclosed separately. ' +
		'[Qualification records](https://github.com/adrienm7/ergopti/releases/tag/v1.0.0) retain the exact source-bound deferred scopes. Packaging does not prove native feature acceptance. This exception applies only to v1.0.0 before 2026-10-09T22:00:00Z.' +
		' Known macOS reports remain under investigation: Karabiner lease failures (including watchdog exit 73 and PONG/READY timeouts), and an active Homebrew upgrade leaving Hammerspoon running without ErgoptiPlus. This release does not claim those reports repaired.'
	);
}
/** Validates existing source-bound scope receipts before a command can be deferred. */
function scopeDisposition(receipt, scope, sha, context, now = new Date()) {
	if (receipt && receipt.status === 'deferred') {
		validateQualificationReceipt(receipt, scope, sha, context, now);
		return 'deferred';
	}
	const expected = {
		schema: 1,
		profile_id: null,
		scope,
		status: 'full',
		qualified: false,
		source_sha: sourceSha(sha)
	};
	if (
		JSON.stringify(receipt) !== JSON.stringify(expected) ||
		resolveQualificationProfile(context, now, scope) !== null
	)
		refuse('Invalid full command qualification receipt.');
	return 'full';
}
/** Requires every actually emitted command scope receipt before public disclosure. */
function admitCommandReceipts(directory, context, sha, now = new Date()) {
	const expected = {
		'macos-native-pac': ['arm64', 'amd64'],
		'macos-native-http': ['arm64', 'amd64'],
		'macos-stubbed-unit': [''],
		'macos-stubbed-e2e': [''],
		'windows-native-desktop': [''],
		'linux-simultaneous-native': [''],
		'linux-unit-suite': [''],
		'linux-e2e-suite': [''],
		'core-js-suite': [''],
		'macos-native-model-receiving': ['arm64', 'amd64']
	};
	for (const [scope, suffixes] of Object.entries(expected)) {
		for (const suffix of suffixes) {
			const file = path.join(directory, 'stable-' + scope + (suffix ? '-' + suffix : '') + '.json');
			const record = parseClosedJson(fs.readFileSync(file, 'utf8'));
			if (scopeDisposition(record, scope, sha, context, now) !== 'deferred')
				refuse('Missing approved deferred command receipt.');
		}
	}
}
function main(argv) {
	if (argv.length === 1 && argv[0] === '--publication-select') {
		const profile = stablePublicationProfile(environmentContext());
		console.log('native_qualification_profile=' + (profile ? profile.id : ''));
		return;
	}
	if (argv.length === 1 && argv[0] === '--publication-admit') {
		const notice = stablePublicationNotice(
			process.env.ERGOPTI_NATIVE_QUALIFICATION_PROFILE || '',
			environmentContext(),
			process.env.GITHUB_SHA
		);
		if (notice)
			admitCommandReceipts(
				path.resolve(__dirname, '../../release-assets'),
				environmentContext(),
				process.env.GITHUB_SHA
			);
		console.log('ERGOPTI_NATIVE_QUALIFICATION_NOTE=' + notice);
		return;
	}
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
				'--validate-scope-receipt',
				'--validate-launch-receipt'
			].includes(argv[i]) ||
			!argv[i + 1] ||
			options[argv[i]]
		)
			refuse('Invalid qualification command arguments.');
		options[argv[i]] = argv[i + 1];
	}
	const scope = options['--scope'];
	if (![...SCOPE_IDS, ...STABLE_SCOPE_IDS].includes(scope)) refuse('Unknown qualification scope.');
	const context = environmentContext(),
		profile = resolveQualificationProfile(context, new Date(), scope);
	if (options['--validate-scope-receipt']) {
		if (!Object.hasOwn(STABLE_EXTRA_SCOPES, scope)) refuse('Unknown command qualification scope.');
		console.log(
			scopeDisposition(
				parseClosedJson(fs.readFileSync(options['--validate-scope-receipt'], 'utf8')),
				scope,
				process.env.GITHUB_SHA,
				context
			)
		);
		return;
	}
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
	admitCommandReceipts,
	scopeDisposition,
	stablePublicationProfile,
	stablePublicationNotice,
	POLICY_PATH,
	STABLE_POLICY_PATH,
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
