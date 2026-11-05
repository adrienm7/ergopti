// tools/test/test-linux-nix-native.cjs
/** Independent receipt/config/registration controls; these are not native credit. */
'use strict';
const assert = require('node:assert/strict');
const LinuxE2E = require('./fixtures/linux-e2e-shards.cjs');
const fs = require('node:fs');
const path = require('node:path');
const {
	receipt,
	runtimeReceipt,
	cleanEnvironment,
	lockReceipt,
	outputReceipt,
	helpReceipt,
	SUMMARY,
	nativeExecutableHash,
	gitInventory,
	gitInventoryReceipt,
	readGitInventory
} = require('./run-linux-nix-native.cjs');
const root = path.resolve(__dirname, '../..');
const head = '0123456789abcdef0123456789abcdef01234567';
const passed = `Nix native source: ${head}\nPASS native Nix installed runtime: 7 checks; 0 failed; 0 skipped; source and physical closure admitted.\n`;
let checks = 0;
function check(name, run) {
	run();
	checks++;
}
check('large genuine ELF does not inherit the source input budget (nix-large-elf)', () => {
	const executable = fs.realpathSync(process.execPath);
	assert.ok(
		fs.statSync(executable).size > 8 * 1024 * 1024,
		'pinned Node must reproduce the large ELF boundary'
	);
	const expected = require('node:crypto')
		.createHash('sha256')
		.update(fs.readFileSync(executable))
		.digest('hex');
	assert.equal(nativeExecutableHash(executable), expected);
});
/** Model read races on real owned files, retaining actual descriptor cleanup. */
function executableControl(mode) {
	const directory = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'ergopti-nix-elf-'));
	const file = path.join(directory, 'image'),
		previous = path.join(directory, 'previous');
	const content = Buffer.concat([Buffer.from([127, 69, 76, 70]), Buffer.alloc(131072, 42)]);
	fs.writeFileSync(file, content);
	const original = Object.fromEntries(
		['openSync', 'readSync', 'fstatSync', 'closeSync'].map((name) => [name, fs[name]])
	);
	let owned,
		reads = 0,
		closes = 0,
		stats = 0;
	fs.openSync = (...args) => {
		if (mode === 'open-error') throw new Error('controlled open refusal');
		owned = original.openSync(...args);
		return owned;
	};
	fs.readSync = (fd, buffer, offset, length, position) => {
		assert.equal(fd, owned);
		assert.ok(length <= 64 * 1024, 'native hashing must use bounded chunks');
		reads++;
		if (mode === 'read-error') throw new Error('controlled read refusal');
		if (mode === 'premature-eof') return 0;
		const count = original.readSync(
			fd,
			buffer,
			offset,
			mode === 'partial' ? Math.min(length, 3) : length,
			position
		);
		if (reads === 1 && mode === 'truncate') fs.writeFileSync(file, content.subarray(0, 16));
		if (reads === 1 && mode === 'mutation') {
			const changed = Buffer.from(content);
			changed[changed.length - 1] = 43;
			fs.writeFileSync(file, changed);
		}
		if (reads === 1 && (mode === 'replacement' || mode === 'symlink-race')) {
			fs.renameSync(file, previous);
			if (mode === 'replacement') fs.writeFileSync(file, content);
			else fs.symlinkSync(previous, file);
		}
		return count;
	};
	fs.fstatSync = (...args) => {
		stats++;
		if (mode === 'stat-error' && stats === 2) throw new Error('controlled stat refusal');
		return original.fstatSync(...args);
	};
	fs.closeSync = (fd) => {
		assert.equal(fd, owned);
		closes++;
		original.closeSync(fd);
		if (mode === 'close-error') throw new Error('controlled close refusal');
	};
	try {
		if (mode === 'symlink') {
			fs.renameSync(file, previous);
			fs.symlinkSync(previous, file);
		}
		if (mode === 'not-elf') fs.writeFileSync(file, 'ordinary text');
		if (mode === 'partial') {
			const expected = require('node:crypto').createHash('sha256').update(content).digest('hex');
			assert.equal(nativeExecutableHash(file), expected);
			assert.ok(reads > 2, 'positive short reads must finish the entire image');
		} else assert.throws(() => nativeExecutableHash(file));
		assert.equal(
			closes,
			owned === undefined ? 0 : 1,
			'every admitted descriptor must close exactly once'
		);
		if (owned !== undefined) assert.throws(() => original.fstatSync(owned), { code: 'EBADF' });
	} finally {
		Object.assign(fs, original);
		fs.rmSync(directory, { recursive: true });
	}
}
for (const mode of [
	'partial',
	'premature-eof',
	'read-error',
	'open-error',
	'stat-error',
	'close-error',
	'mutation',
	'truncate',
	'replacement',
	'symlink',
	'symlink-race',
	'not-elf'
]) {
	check('pinned ELF read and cleanup: ' + mode, () => executableControl(mode));
}
check('native hashing leaves bounded source inputs unchanged', () => {
	const directory = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'ergopti-nix-source-'));
	const file = path.join(directory, 'oversized-source');
	const descriptor = fs.openSync(file, 'wx');
	try {
		fs.ftruncateSync(descriptor, 8 * 1024 * 1024 + 1);
	} finally {
		fs.closeSync(descriptor);
	}
	try {
		assert.throws(() =>
			cleanEnvironment({ SSL_CERT_FILE: file }, '/owned/home', '/owned/config', '/owned/tmp')
		);
	} finally {
		fs.rmSync(directory, { recursive: true });
	}
});
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
			GITHUB_TOKEN: 'dummy-token',
			USER: 'foreign-account',
			LOGNAME: 'foreign-account'
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
			'USER',
			'XDG_CACHE_HOME',
			'XDG_CONFIG_HOME'
		].sort()
	);
	assert.equal(env.USER, 'ergopti-nix-native');
	assert.equal(env.HOME, '/owned/home');
	assert.equal(env.LOGNAME, undefined);
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
check('Nix metrics commands belong to the installed executable closure (nix-metrics-cli)', () => {
	const flake = fs.readFileSync(path.join(root, 'tools/build/nix/flake.nix'), 'utf8');
	const wrapper = flake.match(
		/--prefix PATH : \$\{nixpkgs\.lib\.makeBinPath \(with pkgs; \[([\s\S]*?)\]\)\}/
	);
	assert.ok(wrapper, 'The actual installed launcher must declare its executable closure.');
	const packages = wrapper[1]
		.replace(/#[^\n]*/g, '')
		.trim()
		.split(/\s+/);
	for (const [provider, operation] of [
		['openssl', 'derive the configured at-rest key'],
		['sqlite', 'persist and read the metrics database'],
		['coreutils', 'create the private metrics data directory']
	]) {
		assert.equal(
			packages.filter((name) => name === provider).length,
			1,
			`The installed launcher must provide ${provider} to ${operation}, without borrowing host PATH.`
		);
	}
});
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
	assert.ok(
		step.includes(
			'if: ' + LinuxE2E.condition('Qualify genuine Nix installed runtime', '${{ !cancelled() }}')
		)
	);
	assert.ok(step.includes('test:linux:nix-native'));
	// The signed-APT Nix tool installs in its own step, just before, in the same row.
	const installMarker =
		'      - name: Install prerequisites for Qualify genuine Nix installed runtime\n';
	assert.equal(ci.split(installMarker).length, 2);
	const install = ci.split(installMarker)[1].split('\n      - name:')[0];
	assert.ok(ci.indexOf(installMarker) < ci.indexOf(marker));
	assert.equal(
		ci.slice(ci.indexOf(installMarker), ci.indexOf(marker)).split('\n      - name:').length,
		1
	);
	assert.ok(
		install.includes(
			'if: ' +
				LinuxE2E.condition(
					'Install prerequisites for Qualify genuine Nix installed runtime',
					'${{ !cancelled() }}'
				)
		)
	);
	assert.ok(install.includes('ubuntu_apt.py" -y --no-install-recommends nix-bin'));
	assert.ok(!step.includes('nix-bin'));
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
	assert.ok(source.includes("const GIT_INVENTORY = 'tools/test/run-linux-nix-git-inventory.py'"));
	assert.ok(
		/PROBE,\s*GIT_INVENTORY\s*\]/.test(source),
		'helper belongs to the actual input hash fences'
	);
	assert.ok(source.includes('unchanged(source, inspectSource(root, tracked))'));
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

// Independent literals exercise the actual passive projection, never Nix.
const closedBuild = (stderr) => ({
	checkpoint: 'native-build',
	boundary: 'result_or_physical_debt_gate',
	result: { status: 1, signal: null, error: null, stderr }
});
function receiveBuild(observation, expected, retained = false, code = diagnostic) {
	const observed = projection(observation, retained, code);
	const hint = 'NIX_NATIVE_BUILD_ERROR_KINDS kinds=' + expected;
	assert.deepEqual(observed.slice(2), [
		hint,
		'::error title=Nix native build classification::' + hint
	]);
}
for (const [name, text, expected] of [
	['missing attribute', "       error: attribute 'luv' missing\n", 'evaluation'],
	['undefined evaluator name', "error: undefined variable 'fixture'\n", 'evaluation'],
	['evaluator type refusal', 'error: cannot coerce a list to a string\n', 'evaluation'],
	[
		'Nixpkgs implementation prerequisite',
		'       This version of Nixpkgs requires an implementation of Nix with the following features:\n',
		'nixpkgs-requirements'
	],
	[
		'closed transfer refusal',
		"error: unable to download 'https://private.invalid/?token=opaque': HTTP error 403\n",
		'fetch'
	],
	[
		'builder exit',
		"error: builder for '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-private.drv' failed with exit code 1;\n",
		'builder'
	],
	[
		'failed dependency',
		"error: 1 dependencies of derivation '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-private.drv' failed to build\n",
		'dependency'
	],
	[
		'disk refusal',
		"error: writing to file '/private/fixture': No space left on device\n",
		'disk-space'
	],
	[
		'combined independent hints',
		"error: unable to download 'https://private.invalid/opaque': HTTP error 403\nerror: 2 dependencies of derivation '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-private.drv' failed to build\n",
		'fetch,dependency'
	],
	['unrecognized private failure', 'private token=opaque\n::error::private-suffix\n', 'unknown'],
	['empty stderr invents no cause', '', 'unknown'],
	['stdout-style lookalike is not an error', "echo error: attribute 'luv' missing\n", 'unknown'],
	[
		'oversized attribute is not selected',
		"error: attribute '" + 'a'.repeat(129) + "' missing\n",
		'unknown'
	],
	['over-capture bound is unavailable', 'a'.repeat(1024 * 1024 + 1), 'unavailable'],
	['NUL capture refused', "error: attribute 'luv' missing\n\0", 'unavailable'],
	['ANSI capture refused', "error: attribute 'luv' missing\n\x1b[0m", 'unavailable'],
	['replacement decoding refused', "error: attribute 'luv' missing\n\ufffd", 'unavailable'],
	['CR capture refused', "error: attribute 'luv' missing\r\n", 'unavailable']
])
	check('native build lexical hint: ' + name, () => receiveBuild(closedBuild(text), expected));
check('non-ASCII private capture emits only the finite literal label', () => {
	const text =
		'é😀'.repeat(200000) +
		"\nerror: attribute 'luv' missing\n/private/秘密 ::error::opaque-suffix\n";
	receiveBuild(closedBuild(text), 'evaluation');
	assert.ok(projection(closedBuild(text)).every((line) => !/é|😀|秘密|opaque|private/.test(line)));
});
check('private suffix, URLs, paths and workflow commands never reach the build hint', () => {
	const text =
		"error: unable to download 'https://dummy-user:dummy-pass@private.invalid/?token=opaque%0A': HTTP error 403\n::error::private-suffix\n/private/config HOME=secret\n";
	const observation = closedBuild(text);
	receiveBuild(observation, 'fetch');
	assert.equal(observation.result.stderr, text);
	assert.ok(
		projection(observation).every((line) => !/opaque|secret|private|dummy|https|HOME=/.test(line))
	);
});
check('stderr accessors never run', () => {
	const observation = closedBuild('');
	let reads = 0;
	Object.defineProperty(observation.result, 'stderr', {
		get() {
			reads++;
			throw new Error('private');
		}
	});
	receiveBuild(observation, 'unavailable');
	assert.equal(reads, 0);
});
check('inherited stderr cannot fabricate a build hint', () => {
	const observation = closedBuild('');
	delete observation.result.stderr;
	Object.setPrototypeOf(observation.result, { stderr: "error: attribute 'luv' missing\n" });
	receiveBuild(observation, 'unavailable');
});
for (const [name, mutate, retained] of [
	[
		'wrong phase',
		(o) => {
			o.checkpoint = 'pinned-source-metadata';
		},
		false
	],
	[
		'source fence failure',
		(o) => {
			o.boundary = 'execution_source_fence';
		},
		false
	],
	[
		'successful build',
		(o) => {
			o.result.status = 0;
		},
		false
	],
	[
		'invalid status',
		(o) => {
			o.result.status = 256;
		},
		false
	],
	[
		'signalled build',
		(o) => {
			o.result.signal = 'SIGTERM';
		},
		false
	],
	[
		'owner error',
		(o) => {
			o.result.error = 'deadline';
		},
		false
	],
	['retained physical debt', () => {}, true]
])
	check('unqualified build has no lexical hint: ' + name, () => {
		const observation = closedBuild("error: attribute 'luv' missing\n");
		mutate(observation);
		assert.equal(projection(observation, retained).length, 2);
	});
check('removing the build annotation fails independent receiving', () => {
	const inverse = diagnostic.replace(
		/\n\s*error\(['"]::error title=Nix native build classification::['"] \+ buildHint\);/,
		''
	);
	assert.notEqual(inverse, diagnostic);
	assert.throws(
		() =>
			receiveBuild(closedBuild("error: attribute 'luv' missing\n"), 'evaluation', false, inverse),
		assert.AssertionError
	);
});
check('reflecting stderr fails independent fixed privacy receipt', () => {
	const inverse = diagnostic.replace(
		"'NIX_NATIVE_BUILD_ERROR_KINDS kinds=' + kinds",
		"'NIX_NATIVE_BUILD_ERROR_KINDS kinds=' + stderr"
	);
	assert.notEqual(inverse, diagnostic);
	assert.throws(
		() =>
			receiveBuild(
				closedBuild("error: attribute 'luv' missing\n::error::private-suffix"),
				'evaluation',
				false,
				inverse
			),
		assert.AssertionError
	);
});

/** Build only creator identity; the real reader must observe all later bytes. */
function inventoryIdentity(filename) {
	const fact = fs.lstatSync(filename, { bigint: true });
	return {
		schema: 1,
		dev: String(fact.dev),
		ino: String(fact.ino),
		uid: String(fact.uid),
		mode: 0o600,
		nlink: 1
	};
}
function inventoryResult(identity, replacements = {}) {
	return {
		status: 0,
		signal: null,
		error: null,
		stdout: JSON.stringify(identity) + '\n',
		stderr: '',
		...replacements
	};
}
/** Exercise exact completed-file admission with real files and read-race ports. */
function inventoryReadControls() {
	const directory = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'ergopti-nix-index-'));
	fs.chmodSync(directory, 0o700);
	const filename = path.join(directory, 'inventory');
	function replace(raw) {
		if (fs.existsSync(filename)) fs.unlinkSync(filename);
		fs.writeFileSync(filename, raw, { flag: 'wx', mode: 0o600 });
		return inventoryIdentity(filename);
	}
	const current = () => {};
	try {
		const valid = Buffer.from('audit/outside-static\0directory/name with\nnewline\0');
		let identity = replace(valid);
		check('Git inventory keeps every path byte and creates a closed identity receipt', () => {
			assert.deepEqual(gitInventoryReceipt(inventoryResult(identity)), identity);
			assert.deepEqual(readGitInventory(filename, identity, current), [
				'audit/outside-static',
				'directory/name with\nnewline'
			]);
		});
		for (const [name, raw] of [
			['empty output', Buffer.alloc(0)],
			['missing final NUL', Buffer.from('file')],
			['empty path', Buffer.from('file\0\0')],
			['duplicate path', Buffer.from('file\0file\0')],
			['absolute path', Buffer.from('/file\0')],
			['parent component', Buffer.from('dir/../file\0')],
			['dot component', Buffer.from('./file\0')],
			['empty component', Buffer.from('dir//file\0')],
			['invalid UTF-8', Buffer.from([0xff, 0])]
		]) {
			identity = replace(raw);
			check('Git inventory refuses ' + name, () =>
				assert.throws(() => readGitInventory(filename, identity, current))
			);
		}
		identity = replace(valid);
		for (const [name, replacements] of [
			['nonzero Git', { status: 128 }],
			['signalled Git', { signal: 'SIGTERM' }],
			['physical owner refusal', { error: 'native_closure_unknown' }],
			['stderr output', { stderr: 'unexpected' }],
			['extra stdout', { stdout: JSON.stringify(identity) + '\nextra' }],
			['missing receipt', { stdout: '' }],
			['receipt over capture allowance', { stdout: 'x'.repeat(1025) }],
			['unknown receipt field', { stdout: JSON.stringify({ ...identity, extra: true }) + '\n' }],
			['noncanonical receipt', { stdout: JSON.stringify(identity, null, 1) + '\n' }],
			['wrong receipt mode', { stdout: JSON.stringify({ ...identity, mode: 0o644 }) + '\n' }],
			['wrong receipt links', { stdout: JSON.stringify({ ...identity, nlink: 2 }) + '\n' }],
			['wrong receipt UID', { stdout: JSON.stringify({ ...identity, uid: '-1' }) + '\n' }]
		])
			check('Git inventory refuses ' + name, () =>
				assert.throws(() => gitInventoryReceipt(inventoryResult(identity, replacements)))
			);
		for (const mode of [
			'partial-read',
			'read-error',
			'premature-eof',
			'mutation',
			'equal-byte-successor',
			'symlink',
			'mode',
			'hardlink',
			'forged-identity',
			'close-error',
			'close-successor',
			'currentness'
		]) {
			identity = replace(valid);
			const saved = Object.fromEntries(
				['openSync', 'readSync', 'closeSync'].map((name) => [name, fs[name]])
			);
			let descriptor,
				reads = 0,
				closes = 0,
				fences = 0;
			const previous = path.join(directory, 'previous-' + mode);
			const write = (raw) => {
				const fd = saved.openSync(filename, 'w', 0o600);
				try {
					assert.equal(fs.writeSync(fd, raw), raw.length);
				} finally {
					saved.closeSync(fd);
				}
			};
			if (mode === 'symlink') {
				fs.renameSync(filename, previous);
				fs.symlinkSync(previous, filename);
			} else if (mode === 'mode') fs.chmodSync(filename, 0o644);
			else if (mode === 'hardlink') fs.linkSync(filename, previous);
			else if (mode === 'forged-identity') identity = { ...identity, ino: '0' };
			fs.openSync = (...args) => {
				descriptor = saved.openSync(...args);
				return descriptor;
			};
			fs.readSync = (fd, buffer, offset, length, position) => {
				assert.equal(fd, descriptor);
				assert.ok(length <= 64 * 1024);
				reads++;
				if (mode === 'read-error') throw new Error('controlled inventory read refusal');
				if (mode === 'premature-eof') return 0;
				const count = saved.readSync(
					fd,
					buffer,
					offset,
					mode === 'partial-read' ? Math.min(length, 3) : length,
					position
				);
				if (reads === 1 && mode === 'mutation') write(Buffer.alloc(valid.length));
				if (reads === 1 && mode === 'equal-byte-successor') {
					fs.renameSync(filename, previous);
					write(valid);
				}
				return count;
			};
			fs.closeSync = (fd) => {
				assert.equal(fd, descriptor);
				closes++;
				saved.closeSync(fd);
				if (mode === 'close-error') throw new Error('controlled inventory close refusal');
				if (mode === 'close-successor') {
					fs.renameSync(filename, previous);
					write(valid);
				}
			};
			try {
				check('Git inventory exact read/cleanup: ' + mode, () => {
					const read = () =>
						readGitInventory(filename, identity, () => {
							if (++fences === 2 && mode === 'currentness') throw new Error('source revoked');
						});
					if (mode === 'partial-read') assert.equal(read().length, 2);
					else assert.throws(read);
					assert.equal(closes, descriptor === undefined ? 0 : 1, 'exact acquired reader is closed');
				});
			} finally {
				Object.assign(fs, saved);
			}
		}
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
}

/** Run real Git above the unchanged capture ceiling under the actual owner. */
async function inventoryPhaseControls() {
	const { spawnSync } = require('node:child_process');
	const crypto = require('node:crypto');
	const { ownPhase, hasRetainedPhases } = require('./run-linux-managed-http-native.cjs');
	const directory = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'ergopti-nix-git-'));
	fs.chmodSync(directory, 0o700);
	const repository = path.join(directory, 'repository'),
		execution = path.join(directory, 'execution');
	for (const name of [repository, execution]) fs.mkdirSync(name, { mode: 0o700 });
	const inputs = [
		'tools/test/run-linux-nix-git-inventory.py',
		'tools/test/run-linux-managed-http-phase.py',
		'tools/build/stage-linux-network-runtime.py',
		'tools/lib/git_bash.py',
		'tools/__init__.py'
	];
	const hashes = {};
	for (const name of inputs) {
		const raw = fs.readFileSync(path.join(root, name)),
			copy = path.join(execution, name);
		hashes[name] = crypto.createHash('sha256').update(raw).digest('hex');
		fs.mkdirSync(path.dirname(copy), { recursive: true, mode: 0o700 });
		fs.writeFileSync(copy, raw, { flag: 'wx', mode: 0o600 });
	}
	const current = () => {
		for (const name of inputs)
			for (const location of [root, execution])
				assert.equal(
					crypto
						.createHash('sha256')
						.update(fs.readFileSync(path.join(location, name)))
						.digest('hex'),
					hashes[name]
				);
	};
	const env = {
		PATH: '/usr/bin:/bin',
		HOME: directory,
		GIT_CONFIG_NOSYSTEM: '1',
		GIT_OPTIONAL_LOCKS: '0',
		PYTHONDONTWRITEBYTECODE: '1'
	};
	function setup(args, input) {
		const result = spawnSync('/usr/bin/git', ['-C', repository, ...args], {
			env,
			input,
			encoding: 'utf8'
		});
		assert.equal(result.status, 0, 'private Git index setup must succeed');
		assert.equal(result.error, undefined);
		return result.stdout;
	}
	let serial = 0,
		expired = false,
		lastResult;
	const phase = async (command, args, extra) => {
		current();
		const label = 'inventory-' + ++serial;
		const result = await ownPhase({
			command,
			args,
			env: { ...env, ...extra },
			cwd: directory,
			work: directory,
			label,
			worker: path.join(execution, inputs[1]),
			owner: path.join(execution, inputs[2]),
			ownerSha: hashes[inputs[2]],
			kind: 'command',
			budgetMs: 10000,
			gateDeadline: process.hrtime.bigint() + (expired ? -1n : 15000000000n)
		});
		current();
		assert.equal(
			hasRetainedPhases(),
			false,
			'actual phase must physically close, even after capture refusal'
		);
		if (!expired) {
			const closed = JSON.parse(
				fs.readFileSync(path.join(directory, label + '.owner', 'closed.json'))
			);
			assert.equal(closed.state, 'closed');
			assert.equal(closed.phase, 'command');
			assert.equal(closed.status, result.status);
			assert.ok(Number.isSafeInteger(closed.pid) && closed.pid > 0);
		}
		lastResult = result;
		return result;
	};
	async function refusesBeforeRead(target, operation) {
		const open = fs.openSync;
		let reads = 0;
		fs.openSync = (filename, ...args) => {
			if (filename === target) reads++;
			return open(filename, ...args);
		};
		try {
			await assert.rejects(operation());
			assert.equal(reads, 0, 'failed phase must not acquire the spool reader');
		} finally {
			fs.openSync = open;
		}
	}
	try {
		setup(['init', '--quiet']);
		const blob = setup(['hash-object', '-w', '--stdin'], 'synthetic tracked bytes\n').trim();
		const expected = Array.from(
			{ length: 6000 },
			(_, index) => 'audit/' + String(index).padStart(6, '0') + '-' + 'p'.repeat(200) + '.json'
		);
		expected.push('zz-last-tracked-sentinel');
		assert.ok(Buffer.byteLength(expected.join('\0') + '\0') > 1024 * 1024);
		setup(
			['update-index', '-z', '--index-info'],
			expected.map((name) => `100644 ${blob}\t${name}\0`).join('')
		);
		const old = await phase('/usr/bin/git', ['-C', repository, 'ls-files', '-z']);
		assert.ok(
			['capture_bound', 'closure_receipt_refused'].includes(old.error),
			'original capture must refuse the real oversized inventory'
		);
		checks++;
		const helper = path.join(execution, inputs[0]);
		const filename = path.join(directory, 'tracked.nul');
		const actual = await gitInventory(phase, repository, helper, filename, current);
		assert.deepEqual(actual, expected);
		assert.equal(actual.at(-1), 'zz-last-tracked-sentinel');
		assert.ok(fs.statSync(filename).size > 1024 * 1024);
		checks++;
		const preserved = fs.readFileSync(filename);
		await refusesBeforeRead(filename, () =>
			gitInventory(phase, repository, helper, filename, current)
		);
		assert.equal(lastResult.status, 1);
		assert.deepEqual(
			fs.readFileSync(filename),
			preserved,
			'exclusive helper cannot truncate an incumbent spool'
		);
		checks++;
		const notRepository = path.join(directory, 'not-repo.nul');
		await refusesBeforeRead(notRepository, () =>
			gitInventory(phase, directory, helper, notRepository, current)
		);
		assert.equal(lastResult.status, 1);
		checks++;
		expired = true;
		const late = path.join(directory, 'expired.nul');
		await refusesBeforeRead(late, () => gitInventory(phase, repository, helper, late, current));
		assert.equal(lastResult.error, 'acquisition_refused');
		assert.equal(
			fs.existsSync(late),
			false,
			'expired original deadline must not start Git or parse a spool'
		);
		checks++;
		assert.equal(hasRetainedPhases(), false);
		process.stdout.write(
			'PASS real oversized Git inventory: old capture refused; complete spool and original physical closure admitted.\n'
		);
	} finally {
		if (!hasRetainedPhases()) fs.rmSync(directory, { recursive: true, force: true });
	}
}
async function finish() {
	inventoryReadControls();
	if (process.platform === 'linux') await inventoryPhaseControls();
	process.stdout.write(
		`PASS Nix source/receipt/registration controls: ${checks}; native Nix execution unqualified.\n`
	);
}
finish().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
