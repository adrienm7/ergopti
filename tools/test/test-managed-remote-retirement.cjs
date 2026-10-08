// tools/test/test-managed-remote-retirement.cjs

/** Exercise the actual managed fixture accept/retirement bodies on owned TCP. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Execute the actual C#-assembled PAC expressions without networking or certificates.
const vm = require('node:vm');
const fixtureSource = fs.readFileSync(
	path.join(
		__dirname,
		'../../static/ergopti_plus/windows/tests/fixtures/managed_remote_transport.ps1'
	),
	'utf8'
);
function fixturePacExpression(name) {
	const matches = [
		...fixtureSource.matchAll(
			new RegExp(`string ${name} = ([\\s\\S]*?);\\s*\\n\\s*Reply\\(stream,`, 'g')
		)
	];
	assert.equal(matches.length, 1, 'The real fixture PAC assembly must be unique and present.');
	return matches[0][1];
}
const fixturePorts = {
	TlsPort: 45123,
	ProxyPort: 45124,
	SecondProxyPort: 45125,
	RefusalProxyPort: 45126
};
const fixtureAuthorities = {
	owned: `https://managed-fixture.invalid:${fixturePorts.TlsPort}`,
	origin: `https://managed-fixture.invalid:${fixturePorts.TlsPort}`,
	redirected: `https://updater-redirect.managed-fixture.invalid:${fixturePorts.TlsPort}`,
	refused: `https://updater-refusal.managed-fixture.invalid:${fixturePorts.TlsPort}`
};
for (const [name, rows] of [
	[
		'updaterScript',
		[
			['managed-fixture.invalid', fixtureAuthorities.owned, '/updater/start', 45124],
			[
				'updater-redirect.managed-fixture.invalid',
				fixtureAuthorities.redirected,
				'/updater/good?marker=staging-fixture',
				45125
			],
			['updater-refusal.managed-fixture.invalid', fixtureAuthorities.refused, '/updater/407', 45126]
		]
	],
	[
		'script',
		[
			[
				'managed-fixture.invalid',
				fixtureAuthorities.origin,
				'/v1/chat/completions?marker=managed-network-fixture',
				45124
			]
		]
	]
]) {
	const emitted = vm.runInNewContext(
		fixturePacExpression(name),
		{
			...fixturePorts,
			...fixtureAuthorities
		},
		{ timeout: 100 }
	);
	assert.equal(typeof emitted, 'string');
	const context = vm.createContext({});
	vm.runInContext(emitted, context, { timeout: 100 });
	for (const [host, authority, suffix, port] of rows) {
		for (const url of [authority + '/', authority, authority + suffix]) {
			context.requestUrl = url;
			context.requestHost = host;
			assert.equal(
				vm.runInContext('FindProxyForURL(requestUrl, requestHost)', context, { timeout: 100 }),
				`PROXY 127.0.0.1:${port}`,
				`${name}: exact owned HTTPS authority must select its relay without a path`
			);
		}
		for (const [url, requestHost] of [
			[authority + suffix, 'foreign.invalid'],
			[authority.replace(':45123', ':45122') + suffix, host],
			[authority.replace('https:', 'http:') + suffix, host],
			[authority.replace('https://', 'https://user@') + suffix, host],
			[authority + '.foreign.invalid/', host],
			[`https://${host}.foreign.invalid:45123/`, host]
		]) {
			context.requestUrl = url;
			context.requestHost = requestHost;
			assert.equal(
				vm.runInContext('FindProxyForURL(requestUrl, requestHost)', context, { timeout: 100 }),
				'PROXY refused.invalid:9',
				`${name}: foreign authority cannot acquire an owned relay`
			);
		}
	}
}
const updaterSource = fs.readFileSync(
	path.join(
		__dirname,
		'../../static/ergopti_plus/windows/tests/unit/test_updater_managed_transport.ahk'
	),
	'utf8'
);
assert.ok(
	updaterSource.includes(
		'this.Path == "/updater/407" ? "updater-refusal.managed-fixture.invalid" : "managed-fixture.invalid"'
	)
);
for (const host of [
	'updater-redirect.managed-fixture.invalid',
	'updater-refusal.managed-fixture.invalid'
]) {
	assert.ok(
		fixtureSource.includes(`Encoding.ASCII.GetBytes("${host}")`),
		'Every updater authority has an exact certificate SAN.'
	);
}
assert.ok(fixtureSource.includes('Location: https://updater-redirect.managed-fixture.invalid:'));
assert.ok(fixtureSource.includes('CONNECT updater-redirect.managed-fixture.invalid:'));
assert.ok(fixtureSource.includes('CONNECT updater-refusal.managed-fixture.invalid:'));
assert.ok(fixtureSource.includes('first == "GET /updater/good?marker=staging-fixture HTTP/1.1"'));
assert.ok(fixtureSource.includes('first == "GET /updater/slow HTTP/1.1"'));
console.log(
	'PASS: real fixture PAC assemblies retain bounded HTTPS authorities and foreign refusal.'
);

if (process.platform !== 'win32') {
	console.log('SKIP: managed fixture retirement requires Windows PowerShell and owned loopback.');
	process.exit(0);
}

const powershell = path.join(
	process.env.SystemRoot,
	'System32/WindowsPowerShell/v1.0/powershell.exe'
);
assert.ok(fs.existsSync(powershell), 'The real Windows PowerShell runtime is required.');
// The staging sidecar is exercised with actual generated source and explicit
// observation functions only; this does not qualify HTTP, TLS or certificate stores.
const os = require('node:os');
/** Retire only the exact fixture namespace after a known synchronous terminal. */
function retireStagingObservation(directory, terminal, files = fs) {
	if (
		!terminal ||
		terminal.error ||
		terminal.signal != null ||
		!Number.isInteger(terminal.status)
	) {
		return 'retained_unknown_terminal';
	}
	try {
		const directoryStat = files.lstatSync(directory);
		if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink())
			return 'retained_unexpected_type';
		const entries = files.readdirSync(directory);
		if (entries.length > 1 || (entries.length === 1 && entries[0] !== 'pure-fact.json')) {
			return 'retained_unexpected_entries';
		}
		const fact = path.join(directory, 'pure-fact.json');
		if (entries.length === 1) {
			const factStat = files.lstatSync(fact);
			if (!factStat.isFile() || factStat.isSymbolicLink()) return 'retained_unexpected_type';
			files.unlinkSync(fact);
		}
		files.rmdirSync(directory);
		return 'closed';
	} catch {
		return 'retained_cleanup_refused';
	}
}

/** A cleanup/report failure never replaces the exact original test failure. */
function finishStagingObservation(
	directory,
	terminal,
	assertions,
	report = console.error,
	files = fs
) {
	let failed = false;
	let primary;
	try {
		assertions();
	} catch (error) {
		failed = true;
		primary = error;
	}
	const cleanup = retireStagingObservation(directory, terminal, files);
	finishStagingObservation.lastCleanupStatus = cleanup;
	finishStagingObservation.lastReportStatus = 'not_required';
	if (cleanup !== 'closed') {
		try {
			report('STAGING_OBSERVATION_CLEANUP status=' + cleanup);
			finishStagingObservation.lastReportStatus = 'reported';
		} catch (reportFailure) {
			finishStagingObservation.lastReportStatus = 'unavailable';
			if (!failed) throw reportFailure;
		}
		if (!failed) throw new Error('Staging observation cleanup refused: ' + cleanup);
	}
	if (failed) throw primary;
}

const stagingOwned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-staging-observation-'));
const stagingResult = spawnSync(
	powershell,
	[
		'-NoProfile',
		'-NonInteractive',
		'-ExecutionPolicy',
		'Bypass',
		'-File',
		path.join(__dirname, 'test_updater_staging_observation.ps1'),
		'-WorkerSourcePath',
		path.join(__dirname, '../../static/ergopti_plus/windows/modules/updater/self_update.ahk'),
		'-HelperPath',
		path.join(
			__dirname,
			'../../static/ergopti_plus/windows/tests/fixtures/updater_staging_diagnostic.ps1'
		),
		'-OwnedDirectory',
		stagingOwned
	],
	{ encoding: 'utf8', windowsHide: true, maxBuffer: 65536 }
);
finishStagingObservation(stagingOwned, stagingResult, () => {
	assert.ifError(stagingResult.error);
	assert.equal(stagingResult.status, 0, stagingResult.stdout + stagingResult.stderr);
	assert.equal(stagingResult.stderr, '');
	assert.equal(
		stagingResult.stdout.trim(),
		'PASS: staging observation checks=5 native_watch=0 network=0 certificate=0'
	);
});

const script = path.join(__dirname, 'test_managed_remote_retirement.ps1');
const result = spawnSync(
	powershell,
	['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script],
	{ encoding: 'utf8', windowsHide: true }
);
assert.ifError(result.error);
assert.equal(result.status, 0, result.stdout + result.stderr);
assert.equal(result.stderr, '', 'The real fixture body compilation and execution must be quiet.');
assert.deepEqual(result.stdout.trim().split(/\r?\n/), [
	'PASS admitted-client exact close and retirement',
	'PASS late-client admission refusal and retirement'
]);
console.log(
	'PASS: actual fixture bodies retire admitted clients and reject late accepted clients.'
);
