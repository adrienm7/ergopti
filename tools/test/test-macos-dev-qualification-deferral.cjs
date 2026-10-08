// tools/test/test-macos-dev-qualification-deferral.cjs
'use strict';

/** Source and typed-receipt controls; these do not execute Swift or native Mac APIs. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ROOT = path.resolve(__dirname, '../..');
const policy = require('../ci/dev-release-qualification.cjs');
const configuration = JSON.parse(fs.readFileSync(policy.POLICY_PATH, 'utf8'));
const workflow = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-macos.yml'), 'utf8');
const caller = fs.readFileSync(path.join(ROOT, '.github/workflows/ci.yml'), 'utf8');
const packageSource = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/macos/launcher/Package.swift'),
	'utf8'
);
const brew = configuration.scopes['macos-brew-archive'];
const brewSource = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/macos/launcher', brew.path),
	'utf8'
);
const clock = new Date('2026-10-08T20:00:00Z');
const sha = '0123456789abcdef0123456789abcdef01234567';
const context = {
	github_actions: 'true',
	repository: configuration.repository,
	event_name: configuration.event_name,
	ref: configuration.ref,
	release: configuration.release,
	prerelease: configuration.prerelease,
	channel: configuration.channel,
	tag: configuration.tag,
	version: configuration.version
};
const environment = {
	GITHUB_ACTIONS: 'true',
	GITHUB_REPOSITORY: context.repository,
	GITHUB_EVENT_NAME: context.event_name,
	GITHUB_REF: context.ref,
	GITHUB_SHA: sha,
	ERGOPTI_DEV_RELEASE_RELEASE: 'true',
	ERGOPTI_DEV_RELEASE_PRERELEASE: context.prerelease,
	ERGOPTI_DEV_RELEASE_CHANNEL: context.channel,
	ERGOPTI_DEV_RELEASE_TAG: context.tag,
	ERGOPTI_DEV_RELEASE_VERSION: context.version
};
let passed = 0;
function check(name, callback) {
	callback();
	passed++;
}
function sourceProblems(pkg, mac, rootCaller) {
	const errors = [];
	const requireText = (value, token, name) => {
		if (!value.includes(token)) errors.push(name);
	};
	requireText(
		pkg,
		'guard let selected = environment["ERGOPTI_DEV_QUALIFICATION_PROFILE"], !selected.isEmpty else {\n\t\treturn []',
		'full-default'
	);
	requireText(pkg, '.github/ci/dev_release_qualification_exceptions.json', 'canonical-policy');
	requireText(pkg, 'profile == selected', 'profile-identity');
	requireText(pkg, 'Date() < expiry', 'expiry');
	requireText(
		pkg,
		'CFGetTypeID(release) == CFBooleanGetTypeID(), release.boolValue',
		'typed-release'
	);
	requireText(pkg, 'environment["GITHUB_ACTIONS"] == "true"', 'github-actions');
	requireText(pkg, 'environment["ERGOPTI_DEV_RELEASE_RELEASE"] == "true"', 'release-context');
	for (const key of [
		'GITHUB_REPOSITORY',
		'GITHUB_EVENT_NAME',
		'GITHUB_REF',
		'ERGOPTI_DEV_RELEASE_PRERELEASE',
		'ERGOPTI_DEV_RELEASE_CHANNEL',
		'ERGOPTI_DEV_RELEASE_TAG',
		'ERGOPTI_DEV_RELEASE_VERSION'
	])
		requireText(pkg, `("${key}",`, 'context-' + key);
	requireText(pkg, 'environment[variable] == expected', 'context-comparison');
	requireText(pkg, 'scopes["macos-brew-archive"]', 'brew-only-scope');
	requireText(pkg, 'brew["kind"] as? String == "swift_test_file"', 'test-file-kind');
	requireText(
		pkg,
		'testSource.components(separatedBy: "\\n\\tfunc test").count == 2',
		'single-test-file'
	);
	requireText(pkg, 'exclude: deferredDevReleaseTestFiles()', 'conditional-exclusion');
	if ((pkg.match(/exclude:/g) || []).length !== 1 || /--skip|--filter|XCTSkip/.test(mac + pkg))
		errors.push('no-other-exclusion');
	for (const value of [
		configuration.id,
		configuration.expires_at,
		brew.path,
		configuration.tag,
		configuration.version
	])
		if (pkg.includes(value)) errors.push('duplicated-policy');
	requireText(
		mac,
		'python3 -m unittest discover -s tools/diagnostics -p macos_brew_archive_acceptance_test.py -v',
		'portable-brew'
	);
	requireText(
		mac,
		'python3 -m unittest discover -s tools/diagnostics/apple_shortcuts_probe -p test_probe.py -v',
		'portable-shortcuts'
	);
	requireText(mac, 'node tools/diagnostics/apple_shortcuts_probe/test_probe.cjs', 'portable-jxa');
	requireText(
		mac,
		'if [ "$shortcuts_mode" = full ]; then\n            python3 tools/diagnostics/apple_shortcuts_probe/run_probe.py',
		'full-native-command'
	);
	requireText(
		mac,
		"policy.validateQualificationReceipt(receipt, 'macos-shortcuts-discovery', process.env.GITHUB_SHA, context)",
		'fresh-typed-receipt'
	);
	requireText(mac, 'receipt.qualified !== false', 'unqualified-receipt');
	requireText(mac, 'macos-brew-archive.json', 'brew-artifact');
	requireText(mac, 'macos-shortcuts-discovery.json', 'shortcuts-artifact');
	requireText(mac, 'script -q /dev/null swift test --package-path', 'swift-unfiltered');
	requireText(mac, "Test Suite 'All tests' passed", 'strict-all-tests');
	requireText(mac, 'node tools/test/desktop-ci-evidence.cjs verify macos', 'desktop-verdict');
	for (const name of [
		'Install Sparkle signing tool',
		'Build ErgoptiPlus.app',
		'Smoke test built ErgoptiPlus.app',
		'Sign declared archives with Sparkle EdDSA key',
		'Generate Sparkle appcast',
		'Install the package the way a user does',
		'Launch over the user state and judge it'
	])
		requireText(mac, name, 'preserved-' + name);
	const callerStart = rootCaller.indexOf('    uses: ./.github/workflows/ci-macos.yml\n');
	const callerEnd = rootCaller.indexOf('    secrets:\n', callerStart);
	const macCaller =
		callerStart >= 0 && callerEnd > callerStart ? rootCaller.slice(callerStart, callerEnd) : '';
	requireText(
		macCaller,
		'      tag: ${{ needs.validate.outputs.tag }}\n      prerelease: ${{ needs.validate.outputs.prerelease }}\n      channel:',
		'exact-plan-forwarding'
	);
	for (const field of ['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION'])
		requireText(
			mac,
			`ERGOPTI_DEV_RELEASE_${field}: \${{ inputs.${field.toLowerCase()} }}`,
			'plan-env-' + field
		);
	requireText(rootCaller, 'needs: [validate, core, macos, windows, linux]', 'release-needs');
	return errors;
}
check('complete-source-guard', () =>
	assert.deepEqual(sourceProblems(packageSource, workflow, caller), [])
);
for (const [name, token, replacement, target] of [
	['default-must-be-full', 'return []', 'return ["other.swift"]', 'package'],
	['expired-profile-refuses', 'Date() < expiry', 'Date() >= expiry', 'package'],
	['github-context-required', 'environment["GITHUB_ACTIONS"] == "true"', 'true', 'package'],
	['only-brew-file-selected', 'exclude: deferredDevReleaseTestFiles()', 'exclude: []', 'package'],
	[
		'portable-shortcuts-remains',
		'node tools/diagnostics/apple_shortcuts_probe/test_probe.cjs',
		'echo disabled',
		'workflow'
	],
	['native-full-remains', 'if [ "$shortcuts_mode" = full ]; then', 'if false; then', 'workflow'],
	[
		'typed-receipt-required',
		"policy.validateQualificationReceipt(receipt, 'macos-shortcuts-discovery', process.env.GITHUB_SHA, context)",
		'void receipt',
		'workflow'
	],
	[
		'strict-xctest-collector-remains',
		"Test Suite 'All tests' passed",
		'Selected tests',
		'workflow'
	],
	[
		'release-needs-remain',
		'needs: [validate, core, macos, windows, linux]',
		'needs: [validate, core]',
		'caller'
	]
]) {
	check(name, () => {
		const text = target === 'package' ? packageSource : target === 'workflow' ? workflow : caller;
		assert.ok(text.includes(token));
		const changed = text.replace(token, replacement);
		assert.ok(
			sourceProblems(
				target === 'package' ? changed : packageSource,
				target === 'workflow' ? changed : workflow,
				target === 'caller' ? changed : caller
			).length > 0
		);
	});
}
check('canonical-file-contains-only-declared-method', () => {
	assert.equal(brewSource.split('func ' + brew.name + '() throws').length - 1, 1);
	assert.equal((brewSource.match(/\n\tfunc test/g) || []).length, 1);
});
check('actual-helper-rejects-main-pr-version-clock', () => {
	for (const changed of [
		{ ...context, ref: 'refs/heads/main' },
		{ ...context, event_name: 'pull_request' },
		{ ...context, version: '0.0.0-dev.157' }
	])
		assert.equal(policy.resolveQualificationProfile(changed, clock), null);
	assert.equal(
		policy.resolveQualificationProfile(context, new Date(configuration.expires_at)),
		null
	);
	assert.throws(() => policy.authorizeQualificationProfile('unknown', context, clock));
});
const readerStart = workflow.indexOf(
	"          const fs = require('node:fs');\n          const policy = require('./tools/ci/dev-release-qualification.cjs');"
);
const readerEnd = workflow.indexOf('\n          NODE', readerStart);
assert.ok(readerStart > 0 && readerEnd > readerStart);
const reader = workflow
	.slice(readerStart, readerEnd)
	.split('\n')
	.map((line) => line.slice(10))
	.join('\n');
function receive(receipt, env) {
	let output = '';
	const actualClockPort = {
		environmentContext: () => policy.environmentContext(env),
		resolveQualificationProfile: (c) => policy.resolveQualificationProfile(c, clock),
		validateQualificationReceipt: (r, s, h, c) =>
			policy.validateQualificationReceipt(r, s, h, c, clock)
	};
	vm.runInNewContext(reader, {
		require: (name) =>
			name === 'node:fs' ? { readFileSync: () => JSON.stringify(receipt) } : actualClockPort,
		process: {
			argv: ['node', '-', 'owned-receipt.json'],
			env,
			stdout: {
				write: (value) => {
					output += value;
				}
			}
		}
	});
	return output;
}
const profile = policy.resolveQualificationProfile(context, clock);
const deferred = policy.qualificationReceipt(profile, 'macos-shortcuts-discovery', {
	source_sha: sha
});
check('actual-receipt-reader-deferred-without-feature-claim', () => {
	assert.equal(receive(deferred, environment), 'deferred');
	assert.equal(deferred.qualified, false);
	assert.ok(!('ownership' in deferred) && !('passed' in deferred));
});
const full = {
	schema: 1,
	profile_id: null,
	scope: 'macos-shortcuts-discovery',
	status: 'full',
	qualified: false,
	source_sha: sha
};
check('actual-receipt-reader-full-outside-profile', () =>
	assert.equal(receive(full, { ...environment, GITHUB_REF: 'refs/heads/main' }), 'full')
);
check('full-cannot-bypass-active-policy', () => assert.throws(() => receive(full, environment)));
check('deferred-cannot-bypass-context-or-foreign-sha', () => {
	assert.throws(() => receive(deferred, { ...environment, GITHUB_EVENT_NAME: 'pull_request' }));
	assert.throws(() => receive({ ...deferred, source_sha: 'f'.repeat(40) }, environment));
});
check('unknown-fields-and-status-never-hide-native-work', () => {
	for (const changed of [
		{ ...deferred, passed: 0 },
		{ ...deferred, status: 'PASS' },
		{ ...deferred, qualified: true },
		{ ...full, ownership: { closed: true } }
	])
		assert.throws(() =>
			receive(
				changed,
				changed.profile_id === null
					? { ...environment, GITHUB_REF: 'refs/heads/main' }
					: environment
			)
		);
});
/** Validate actual SwiftPM output using its documented target-relative semantics. */
function validateSwiftExclusionDump(dump, selectedProfile) {
	policy.deferredScopes(selectedProfile);
	assert.ok(dump && Array.isArray(dump.targets), 'Actual Swift target dump is required.');
	const targets = dump.targets.filter((target) => target.name === 'ErgoptiPlusTests');
	assert.equal(targets.length, 1, 'The exact test target must occur once.');
	const target = targets[0];
	assert.equal(typeof target.path, 'string');
	assert.ok(Array.isArray(target.exclude));
	assert.ok(target.exclude.every((value) => typeof value === 'string'));
	if (selectedProfile === null) {
		assert.deepEqual(target.exclude, [], 'Inactive policy must retain every test source.');
		return 'full';
	}
	assert.equal(target.exclude.length, 1, 'Only the declared Brew file may be excluded.');
	const produced = target.exclude[0];
	assert.ok(
		produced && !produced.includes('/') && !produced.includes('\\'),
		'Swift exclusion must be one target-relative filename.'
	);
	assert.equal(
		path.posix.join(target.path, produced),
		brew.path,
		'Swift target join must identify the canonical declared Brew file.'
	);
	return 'deferred';
}
check('source-produced-target-relative-exclusion', () => {
	const target = /let launcherTestTargetPath = "([^"\n]+)"/.exec(packageSource);
	assert.ok(target, 'The actual shared target path must be present.');
	assert.ok(packageSource.includes('path: launcherTestTargetPath,'));
	assert.ok(packageSource.includes('let targetPrefix = launcherTestTargetPath + "/"'));
	assert.ok(packageSource.includes('guard path.hasPrefix(targetPrefix)'));
	assert.ok(packageSource.includes('let exclusion = String(path.dropFirst(targetPrefix.count))'));
	assert.ok(packageSource.includes('return [exclusion]'));
	assert.ok(!packageSource.includes('return [path]'));
	const producedRelative = brew.path.slice((target[1] + '/').length);
	assert.equal(path.posix.join(target[1], producedRelative), brew.path);
	assert.ok(workflow.includes('swift package dump-package --package-path'));
	assert.ok(
		workflow.includes('--package-dump "$RUNNER_TEMP/dev-release-qualification/swift-package.json"')
	);
});
const targetPath = path.posix.dirname(brew.path);
const relativeFile = path.posix.basename(brew.path);
check('produced-relative-dump-binds-canonical-file', () => {
	assert.equal(
		validateSwiftExclusionDump(
			{ targets: [{ name: 'ErgoptiPlusTests', path: targetPath, exclude: [relativeFile] }] },
			profile
		),
		'deferred'
	);
});
check('old-fullpath-dump-is-red', () => {
	assert.throws(
		() =>
			validateSwiftExclusionDump(
				{ targets: [{ name: 'ErgoptiPlusTests', path: targetPath, exclude: [brew.path] }] },
				profile
			),
		/target-relative filename/
	);
});
check('inactive-dump-full-and-foreign-target-refusal', () => {
	assert.equal(
		validateSwiftExclusionDump(
			{ targets: [{ name: 'ErgoptiPlusTests', path: targetPath, exclude: [] }] },
			null
		),
		'full'
	);
	assert.throws(() =>
		validateSwiftExclusionDump(
			{ targets: [{ name: 'ErgoptiPlusTests', path: targetPath, exclude: [relativeFile] }] },
			null
		)
	);
	assert.throws(() =>
		validateSwiftExclusionDump(
			{ targets: [{ name: 'ErgoptiPlusTests', path: 'Tests/Foreign', exclude: [relativeFile] }] },
			profile
		)
	);
});
if (process.argv[2] === '--package-dump') {
	assert.equal(process.argv.length, 4, 'One actual Swift manifest dump is required.');
	const selected = process.env.ERGOPTI_DEV_QUALIFICATION_PROFILE
		? policy.authorizeQualificationProfile(
				process.env.ERGOPTI_DEV_QUALIFICATION_PROFILE,
				policy.environmentContext()
			)
		: null;
	const mode = validateSwiftExclusionDump(
		JSON.parse(fs.readFileSync(process.argv[3], 'utf8')),
		selected
	);
	console.log(
		'SwiftPM target exclusion binding verified: ' + mode + '; native/feature qualified=false.'
	);
}
assert.equal(passed, 21);
console.log(
	'PASS: Mac qualification deferral source/typed-receipt controls=21; Swift/native execution unqualified.'
);
