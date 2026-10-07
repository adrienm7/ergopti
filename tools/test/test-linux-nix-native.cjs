// tools/test/test-linux-nix-native.cjs
/** Independent receipt/config/registration controls; these are not native credit. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
	receipt,
	runtimeReceipt,
	cleanEnvironment,
	lockReceipt,
	outputReceipt,
	helpReceipt,
	SUMMARY
} = require('./run-linux-nix-native.cjs');
const root = path.resolve(__dirname, '../..');
const head = '0123456789abcdef0123456789abcdef01234567';
const passed = `Nix native source: ${head}\nPASS native Nix installed runtime: 7 checks; 0 failed; 0 skipped; source and physical closure admitted.\n`;
let checks = 0;
function check(name, run) {
	run();
	checks++;
}
check('exact actual source-bound native receipt', () => assert.equal(receipt(passed, head), true));
for (const [name, text, sha] of [
	['missing summary', `Nix native source: ${head}\n`, head],
	['missing source', SUMMARY + '\n', head],
	['wrong source', passed, '1123456789abcdef0123456789abcdef01234567'],
	['six credit', passed.replace('7 checks', '6 checks'), head],
	['skip credit', passed.replace('0 skipped', '1 skipped'), head],
	['failed credit', passed.replace('0 failed', '1 failed'), head],
	['deferred credit', '[DEFERRED] Nix unavailable\n', head],
	['duplicate summary', passed + SUMMARY + '\n', head],
	['unexpected diagnostic', passed + 'unexpected warning\n', head],
	['invalid source type', passed, 'main']
])
	check(name, () => assert.equal(receipt(text, sha), false));
const runtime =
	'PASS installed shared root\nPASS packaged LuaJIT and luv\nPASS installed C backend ABI\nPASS native GIO backend and compiled schema\nPASS native OpenSSL NIST SHA256\n';
check('exact five installed claims', () => assert.equal(runtimeReceipt(runtime), true));
check('absent GIO never earns credit', () =>
	assert.equal(
		runtimeReceipt(runtime.replace('PASS native GIO backend and compiled schema\n', '')),
		false
	)
);
check('duplicate runtime claim rejected', () =>
	assert.equal(runtimeReceipt(runtime + 'PASS native OpenSSL NIST SHA256\n'), false)
);
check('ambient host routes and loader/config discarded', () => {
	const env = cleanEnvironment(
		{
			LUA_PATH: '/host/?.lua',
			LUA_CPATH: '/host/?.so',
			LUA_INIT: '@secret',
			LD_LIBRARY_PATH: '/host',
			NIX_CONFIG: 'require-sigs=false',
			NIX_REMOTE: 'daemon',
			NIX_PATH: 'foreign',
			PKG_CONFIG_PATH: '/host',
			HTTP_PROXY: 'http://dummy-user:dummy-pass@proxy.invalid',
			GITHUB_TOKEN: 'dummy-token'
		},
		'/owned/home',
		'/owned/config',
		'/owned/tmp'
	);
	assert.deepEqual(
		Object.keys(env).sort(),
		[
			'HOME',
			'LC_ALL',
			'NIX_CONF_DIR',
			'PATH',
			'PYTHONDONTWRITEBYTECODE',
			'TMPDIR',
			'XDG_CACHE_HOME',
			'XDG_CONFIG_HOME'
		].sort()
	);
	assert.equal(env.NIX_CONF_DIR, '/owned/config');
	assert.equal(env.TMPDIR, '/owned/tmp');
});
const locked = {
	locked: {
		type: 'github',
		owner: 'NixOS',
		repo: 'nixpkgs',
		rev: head,
		narHash: 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
	}
};
check('actual locked revision and NAR bound together', () =>
	assert.deepEqual(lockReceipt(locked), { revision: head, narHash: locked.locked.narHash })
);
for (const [name, replacement] of [
	['floating revision', { rev: 'nixos-unstable' }],
	['missing NAR', { narHash: undefined }],
	['wrong repository', { repo: 'foreign' }]
])
	check(name, () =>
		assert.throws(() => lockReceipt({ locked: { ...locked.locked, ...replacement } }))
	);
const out = '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ergopti-plus-dev';
check('one native store output', () =>
	assert.equal(outputReceipt([{ drvPath: out + '.drv', outputs: { out } }]), out)
);
for (const value of [
	[],
	[{ drvPath: out + '.drv', outputs: { out: '/workspace/fake-ergopti' } }],
	[{ drvPath: out + '.drv', outputs: { out, other: out } }]
])
	check('malformed or non-store output refusal', () => assert.throws(() => outputReceipt(value)));
check('physical owner is reused and no alternate process supervisor', () => {
	const source = fs.readFileSync(path.join(root, 'tools/test/run-linux-nix-native.cjs'), 'utf8');
	assert.ok(source.includes("require('./run-linux-managed-http-native.cjs')"));
	assert.ok(source.includes("kind: 'command'"));
	assert.ok(source.includes('if (!success(result) || hasRetainedPhases()) refuse();'));
	assert.ok(!/require\(['"]node:child_process/.test(source));
	assert.ok(!/curl[^\n]*\|[^\n]*sh/.test(source));
	assert.ok(source.includes('sandbox = false\\n')); // Actual single-user build, no claim of Nix sandbox execution.
});
check('hosted registration is mandatory and additive', () => {
	const ci = fs.readFileSync(path.join(root, '.github/workflows/ci-linux.yml'), 'utf8');
	const marker = '      - name: Qualify genuine Nix installed runtime\n';
	assert.equal(ci.split(marker).length, 2);
	const step = ci.split(marker)[1].split('\n      - name:')[0];
	assert.ok(step.includes('if: ${{ !cancelled() }}'));
	assert.ok(step.includes('test:linux:nix-native'));
	assert.ok(step.includes('nix-bin'));
	assert.ok(!step.includes('curl |'));
	assert.ok(ci.includes('--subject "nix-installed-runtime=$nix_runtime_assertions"'));
	const coverage = JSON.parse(
		fs.readFileSync(path.join(root, '.github/linux-ci-coverage.json'), 'utf8')
	);
	assert.equal(coverage.jobs['e2e-linux'].subjects['nix-installed-runtime'], 7);
	assert.equal(coverage.jobs['e2e-linux'].subjects['managed-network-runtime'], 4);
	assert.equal(coverage.jobs['e2e-linux'].subjects['managed-http-output'], 18);
	assert.equal(coverage.jobs['e2e-linux'].subjects['managed-http-public'], 30);
});
// Independent literal help tail from the retained real AppImage --help receipt.
const retainedHelp =
	'Usage: luajit ergopti_hotstrings.lua [OPTIONS]\n\n  --config <path>     TOML file or directory of definitions.\n                      Default: ~/.config/ergopti/hotstrings/\n  --device <path>     evdev device (e.g. /dev/input/event3).\n                      Default: auto-detected.\n  --layout <name>     Keyboard layout: qwerty | azerty.\n                      Default: $XKBLAYOUT, else qwerty.\n  --tray              Enable the system tray icon.\n  --no-grab           Do NOT take an exclusive grab on the device.\n                      Physical keys then reach the application while an\n                      expansion is being typed, which can scramble it.\n                      Use only if the grab misbehaves on your hardware.\n  --dry-run           Log matches without injecting.\n  --verbose           Log at debug level for this run.\n  --help              Show this message.\n';
const normalHelp = { status: 0, signal: null, error: null, stdout: retainedHelp, stderr: '' };
check('real unchanged driver help tail', () => assert.equal(helpReceipt(normalHelp), true));
check('benign pre-Usage startup logs retained', () =>
	assert.equal(
		helpReceipt({
			...normalHelp,
			stdout: '2026-10-06 17:39:48:000 [DEBUG] [module] Benign startup.\n' + retainedHelp
		}),
		true
	)
);
for (const [name, result] of [
	['duplicate exact Usage header', { ...normalHelp, stdout: retainedHelp + retainedHelp }],
	[
		'missing exact help option',
		{
			...normalHelp,
			stdout: retainedHelp.replace('  --help              Show this message.\n', '')
		}
	],
	[
		'changed exact help option',
		{ ...normalHelp, stdout: retainedHelp.replace('Show this message.', 'Different text.') }
	],
	['lookalike Usage header', { ...normalHelp, stdout: 'Fake ' + retainedHelp }],
	['runtime stderr', { ...normalHelp, stderr: 'warning' }],
	['nonzero native help', { ...normalHelp, status: 1 }],
	['physical closure refusal', { ...normalHelp, error: 'native_closure_unknown' }]
])
	check(name, () => assert.equal(helpReceipt(result), false));
check('Git index observation does not refresh original locks', () => {
	const source = fs.readFileSync(path.join(root, 'tools/test/run-linux-nix-native.cjs'), 'utf8');
	assert.ok(
		source.includes("phase('/usr/bin/git', ['-C', root, ...args], { GIT_OPTIONAL_LOCKS: '0' })")
	);
	assert.ok(
		source.includes("worker: path.join(snapshot, 'tools/test/run-linux-managed-http-phase.py')")
	);
	assert.ok(
		source.includes("owner: path.join(snapshot, 'tools/build/stage-linux-network-runtime.py')")
	);
	assert.ok(source.includes("LUA_INIT: '@' + path.join(snapshot, PROBE)"));
});

// Execute only the actual fixed projection in isolation: no Nix or phase owner.
const vm = require('node:vm');
const diagnosticSource = fs.readFileSync(
	path.join(root, 'tools/test/run-linux-nix-native.cjs'),
	'utf8'
);
const diagnosticStart = diagnosticSource.indexOf('\tfunction emitPhaseObservation() {');
const diagnosticEnd = diagnosticSource.indexOf('\n\ttry {\n\t\tcurrent();', diagnosticStart);
assert.ok(
	diagnosticStart >= 0 && diagnosticEnd > diagnosticStart,
	'actual diagnostic function required'
);
const diagnostic = diagnosticSource.slice(diagnosticStart, diagnosticEnd).trim();
function projection(phaseObservation, retained = false, code = diagnostic) {
	const lines = [];
	vm.runInNewContext(
		'(' + code + ')()',
		{
			phaseObservation,
			hasRetainedPhases: () => retained,
			error: (line) => lines.push(line)
		},
		{ timeout: 1000 }
	);
	return lines;
}
function receiveProjection(lines, suffix) {
	const original =
		'NIX_OWNED_PHASE_OBSERVATION checkpoint=pinned-source-metadata boundary=result_or_physical_debt_gate ' +
		suffix;
	assert.deepEqual(lines, [original, '::error title=Nix native owned phase::' + original]);
}
function phase(result) {
	return { checkpoint: 'pinned-source-metadata', boundary: 'result_or_physical_debt_gate', result };
}
check('missing Nix phase has no invented observation', () =>
	assert.deepEqual(projection(undefined), [])
);
check('closed nonzero Nix status reaches both original log and annotation', () => {
	const result = Object.freeze({
		status: 1,
		signal: null,
		error: null,
		stderr: 'Private arbitrary cause'
	});
	receiveProjection(
		projection(phase(result)),
		'status=1 signal=none owner_error=none retained=false'
	);
	assert.equal(result.stderr, 'Private arbitrary cause');
});
check('unreturned Nix phase fields remain unknown', () =>
	receiveProjection(
		projection(phase(undefined)),
		'status=unknown signal=unknown owner_error=unknown retained=false'
	)
);
check('retained native cancellation remains distinct from closed child exit', () =>
	receiveProjection(
		projection(phase({ status: null, signal: 'SIGTERM', error: 'owned_cleanup_pending' }), true),
		'status=unknown signal=SIGTERM owner_error=owned_cleanup_pending retained=true'
	)
);
check('native upper status bound and accepted enum remain fixed', () =>
	receiveProjection(
		projection(phase({ status: 255, signal: 'SIGSEGV', error: 'deadline' })),
		'status=255 signal=SIGSEGV owner_error=deadline retained=false'
	)
);
for (const status of [-1, 256, 1.5, NaN, Infinity]) {
	check('unsafe native status is never printed (' + String(status) + ')', () =>
		receiveProjection(
			projection(phase({ status, signal: null, error: null })),
			'status=unknown signal=none owner_error=none retained=false'
		)
	);
}
check('inherited phase values cannot manufacture native facts', () =>
	receiveProjection(
		projection(phase(Object.create({ status: 1, signal: 'SIGTERM', error: 'deadline' }))),
		'status=unknown signal=unknown owner_error=unknown retained=false'
	)
);
check('phase getters are never invoked', () => {
	let reads = 0;
	const result = {};
	for (const name of ['status', 'signal', 'error']) {
		Object.defineProperty(result, name, {
			get() {
				reads++;
				throw new Error('Synthetic private field');
			}
		});
	}
	receiveProjection(
		projection(phase(result)),
		'status=unknown signal=unknown owner_error=unknown retained=false'
	);
	assert.equal(reads, 0);
});
check('private URLs, workflow commands and exceptions cannot escape enum projection', () => {
	const privateValue = 'https://private.invalid/?token=opaque%0A\n::error::private-suffix';
	const result = {
		status: privateValue,
		signal: privateValue,
		error: privateValue,
		stderr: privateValue,
		stdout: privateValue,
		exception: privateValue
	};
	receiveProjection(
		projection(phase(result)),
		'status=unknown signal=other owner_error=other retained=false'
	);
});
check('removing the public annotation fails the same independent receipt', () => {
	const inverse = diagnostic.replace(
		/\n\s*error\(["']::error title=Nix native owned phase::["'] \+ observation\);/,
		''
	);
	assert.notEqual(inverse, diagnostic, 'actual annotation addition required');
	assert.throws(
		() =>
			receiveProjection(
				projection(phase({ status: 1, signal: null, error: null }), false, inverse),
				'status=1 signal=none owner_error=none retained=false'
			),
		assert.AssertionError
	);
});
process.stdout.write(
	`PASS Nix source/receipt/registration controls: ${checks}; native execution unqualified.\n`
);
