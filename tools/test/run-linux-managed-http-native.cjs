// tools/test/run-linux-managed-http-native.cjs

/**
 * ==============================================================================
 * MODULE: Source-Admitted Native Managed HTTP Qualification
 * DESCRIPTION:
 * Captures the current driver/shared cohort once, then serially runs the retained
 * output and public GIO/curl fixtures. Native streams stay in private file sinks.
 * Prerequisite refusal, failed controls or unknown closure cannot earn credit.
 * ==============================================================================
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const MAX_RECEIPT_BYTES = 1024 * 1024;
const PUBLIC_CASES = [
	'test_actual_gnome_proxy_reaches_public_get_owned',
	'test_actual_public_post_and_stream_reach_desktop_proxy',
	'test_actual_public_download_uses_system_proxy_and_owned_destination',
	'test_actual_origin403_remains_http_unknown_source',
	'test_actual_connect407_and403_have_distinct_native_receipts',
	'test_actual_loopback_fast_path_bypasses_pac',
	'test_actual_valid_pac_direct_remains_usable',
	'test_actual_pac_ordered_relay_waits_and_reaches_second_proxy',
	'test_actual_cancellation_fences_slow_native_pac_and_retires_owned_children',
	'test_actual_dummy_capability_does_not_disable_plain_network',
	'test_actual_dummy_proxy_credentials_remain_outside_native_argv_and_reports',
	'test_actual_environment_http_proxy_precedes_system_with_no_lookup',
	'test_actual_explicit_direct_disables_inherited_proxy',
	'test_actual_selected_system_proxy_preserves_no_proxy',
	'test_actual_native_supported_gio_error_refuses_without_network_fallback',
	'test_actual_parent_budget_spans_native_lookup_and_physical_retirement',
	'test_actual_older_native_curl_does_not_request_or_publish_new_metric',
	'test_actual_metric_positive_requires_supported_paired_native_receipt',
	'test_actual_same_origin_relative_path_query_selects_new_proxy',
	'test_actual_cross_origin_strips_all_canonical_credentials',
	'test_actual_query_only_location_changes_native_pac_choice',
	'test_actual_forged_body_footer_remains_exact_final_body',
	'test_actual_trusted_https_downgrade_refuses_before_second_lookup',
	'test_actual_untrusted_https_retains_certificate_failure',
	'test_actual_cycle_refuses_before_repeated_native_lookup',
	'test_actual_hop_limit_refuses_before_fiftysecond_acquisition',
	'test_actual_official_older_curl_follows_fresh_pac_without_new_metric',
	'test_actual_second_pac_uses_remaining_original_deadline',
	'test_actual_cancel_at_second_lookup_suppresses_terminal_and_retires',
	'test_actual_redirect_url_and_credentials_stay_outside_native_argv'
];

const OUTPUT_CASES = [
	'actual HTTP output has exactly one retained anonymous regular inode',
	'retained writable output is CLOEXEC before curl dispatch',
	'actual owned curl pipeline dispatches without pathname output',
	'actual curl group and all native handles acknowledge physical settlement',
	'actual local HTTP status publishes one successful bounded result',
	'one truthful native terminal waits filesystem acknowledgements',
	'multiple real parent filesystem writes enforce one outstanding bounded chunk',
	'actual EOF and owned child retirement retain every body byte',
	'actual retained file equals independent NUL-bearing HTTP corpus',
	'delivered actual bytes refuse relay truncation',
	'actual output and original deadline close acknowledgements retire parent lease',
	'actual owned output descriptor was physically removed',
	'actual loopback/core/writer resources drain their loop',
	'cleanup has no unacknowledged native filesystem write',
	'cleanup retains no owned curl/group/handle debt',
	'cleanup acknowledges exact parent output/deadline retirement',
	'cleanup independently observes exact descriptor removal',
	'native anonymous output leaves no directory debt: nil'
];

function refuse() {
	throw new Error('Native source admission or completed receipt refused.');
}
function hash(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}
function regular(filename) {
	const fact = fs.lstatSync(filename);
	if (!fact.isFile() || fact.isSymbolicLink()) refuse();
	return fact;
}
function bounded(filename) {
	if (regular(filename).size > MAX_RECEIPT_BYTES) refuse();
	return fs.readFileSync(filename, 'utf8');
}
function completed(result) {
	return !result.error && result.signal == null && result.status === 0;
}
function publicReceipt(result) {
	if (!completed(result) || result.stdout !== '') return false;
	const lines = result.stderr.split(/\r?\n/);
	if (
		lines.filter((line) => /^Ran 30 tests in [0-9.]+s$/.test(line)).length !== 1 ||
		lines.filter((line) => line === 'OK').length !== 1
	)
		return false;
	const observed = [];
	for (const line of lines) {
		if (!line) continue;
		// Python 3.10 omits the method suffix; newer Python includes it.
		// Either observed suffix must name the same independent case.
		const witness =
			/^(test_[a-z0-9_]+) \(__main__\.(NativePublicControls|PerHopControls)(?:\.\1)?\) \.\.\. ok$/.exec(
				line
			);
		if (witness) {
			const position = PUBLIC_CASES.indexOf(witness[1]);
			if (
				position < 0 ||
				witness[2] !== (position < 18 ? 'NativePublicControls' : 'PerHopControls')
			)
				return false;
			observed.push(witness[1]);
		} else if (!/^Ran 30 tests in [0-9.]+s$/.test(line) && line !== 'OK' && !/^-+$/.test(line))
			return false;
	}
	return (
		observed.length === 30 &&
		new Set(observed).size === 30 &&
		PUBLIC_CASES.every((name) => observed.includes(name))
	);
}
function outputReceipt(result) {
	if (!completed(result) || result.stderr !== '') return false;
	const lines = result.stdout.trimEnd().split(/\r?\n/);
	if (
		lines.filter((line) => line === 'native HTTP parent output: 18 passed, 0 failures, 18 checks')
			.length !== 1 ||
		lines.filter((line) => /^PASS /.test(line)).length !== 18 ||
		lines.filter((line) =>
			/^Native subreaper: \d+ adopted descendants physically reaped$/.test(line)
		).length !== 1
	)
		return false;
	const cases = lines.filter((line) => line.startsWith('PASS ')).map((line) => line.slice(5));
	if (
		cases.length !== OUTPUT_CASES.length ||
		new Set(cases).size !== OUTPUT_CASES.length ||
		OUTPUT_CASES.some((name, position) => cases[position] !== name)
	)
		return false;
	const closure = lines.filter((line) => line.startsWith('Native subreaper closure: '));
	if (closure.length !== 1 || lines.length !== 21) return false;
	try {
		const value = JSON.parse(closure[0].slice('Native subreaper closure: '.length));
		const summary = lines.find((line) =>
			/^Native subreaper: \d+ adopted descendants physically reaped$/.test(line)
		);
		const adopted = Number(summary.match(/^Native subreaper: (\d+)/)[1]);
		return (
			Object.keys(value).sort().join(',') === 'adopted,pending,rescue' &&
			value.pending === 0 &&
			value.rescue === 0 &&
			Number.isSafeInteger(value.adopted) &&
			value.adopted >= 0 &&
			value.adopted === adopted
		);
	} catch {
		return false;
	}
}
function curlVersion(result) {
	if (!completed(result) || result.stderr !== '') refuse();
	const match = /^curl (\d+)\.(\d+)\.(\d+)[^\n]*\blibcurl\/(\d+)\.(\d+)\.(\d+)/.exec(result.stdout);
	if (!match) refuse();
	return { cli: match.slice(1, 4).map(Number), library: match.slice(4, 7).map(Number) };
}
function atLeast(version, major, minor) {
	return version[0] > major || (version[0] === major && version[1] >= minor);
}
function admittedElf(filename, expected) {
	if (
		!path.isAbsolute(filename || '') ||
		path.basename(filename) !== 'curl' ||
		!/^[0-9a-f]{64}$/.test(expected || '') ||
		/[\0\r\n]/.test(filename)
	)
		refuse();
	regular(filename);
	const bytes = fs.readFileSync(filename);
	if (!bytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70])) || hash(bytes) !== expected)
		refuse();
	fs.accessSync(filename, fs.constants.X_OK);
	return bytes;
}

const activeChildren = new Map(); // Retain exact child and uncertain FD owners.
const PHASE_GRACE_MS = 15000;
const TOTAL_GATE_MS = 1800000;
function phaseReceipt(value, pid, kind, status) {
	return (
		value &&
		typeof value === 'object' &&
		Object.keys(value).sort().join(',') === 'cancelled,phase,pid,schema,state,status' &&
		value.schema === 1 &&
		value.phase === kind &&
		value.pid === pid &&
		Number.isSafeInteger(pid) &&
		pid > 0 &&
		value.state === 'closed' &&
		typeof value.cancelled === 'boolean' &&
		Number.isSafeInteger(value.status) &&
		(value.status === 0 || value.status === 1) &&
		value.status === status &&
		(value.status !== 0 || value.cancelled === false)
	);
}

/** TERM requests original cleanup; grace refusal retains child/sinks and cannot pass. */
async function ownPhase({
	command,
	args,
	env,
	cwd,
	work,
	label,
	worker,
	owner,
	ownerSha,
	kind,
	fixtureSha,
	budgetMs,
	gateDeadline,
	spawnChild = spawn,
	clock = () => process.hrtime.bigint(),
	graceMs = PHASE_GRACE_MS
}) {
	const stdout = path.join(work, label + '.stdout');
	const stderr = path.join(work, label + '.stderr');
	const receipt = path.join(work, label + '.owner');
	fs.mkdirSync(receipt, { mode: 0o700 });
	const held = {
		child: null,
		pid: null,
		nativeClosed: false,
		childClosed: false,
		descriptors: [],
		reason: null,
		requested: false,
		returned: false,
		started: clock()
	};
	activeChildren.set(receipt, held);
	const deadline = held.started + BigInt(budgetMs) * 1000000n;
	const expires = deadline < gateDeadline ? deadline : gateDeadline;
	let watcher, grace;
	return await new Promise((resolve) => {
		function answer(value) {
			if (held.returned) return;
			held.returned = true;
			resolve(value);
		}
		function retain() {
			// The actual child/FD references and a referenced watcher remain alive.
			// Returning failure is not a native cleanup acknowledgement.
			answer({
				status: null,
				signal: null,
				error: 'owned_cleanup_pending',
				stdout: '',
				stderr: ''
			});
		}
		function request(reason) {
			held.reason ||= reason;
			if (!grace) grace = setTimeout(retain, graceMs);
			if (
				held.requested ||
				!held.child ||
				!held.pid ||
				held.childClosed ||
				held.child.exitCode !== null ||
				held.child.signalCode !== null
			)
				return;
			held.requested = true; // Only one exact ChildProcess TERM; never PGID/PID rescue.
			try {
				if (!held.child.kill('SIGTERM')) held.reason ||= 'cancel_refused';
			} catch {
				held.reason ||= 'cancel_refused';
			}
		}
		held.cancel = () => request('caller_cancelled');
		function closeSinks() {
			let closed = true;
			for (const record of held.descriptors) {
				if (record.state !== 'open') {
					closed = false;
					continue;
				}
				record.state = 'closing';
				try {
					fs.closeSync(record.fd);
					record.state = 'closed';
				} catch {
					record.state = 'uncertain-close';
					closed = false;
				}
			}
			return closed;
		}
		function finish(status, signal) {
			if (held.childClosed) return;
			held.childClosed = true;
			// Completion must check the original monotonic deadline itself, so
			// a late close cannot beat the monitor's next tick.
			if (clock() >= expires) held.reason ||= 'deadline';
			const sinksClosed = closeSinks();
			let result = { status, signal, error: held.reason, stdout: '', stderr: '' };
			try {
				const closedFile = path.join(receipt, 'closed.json');
				const fact = fs.lstatSync(closedFile, { bigint: true });
				if (
					!fact.isFile() ||
					fact.isSymbolicLink() ||
					fact.size > 1024n ||
					fact.uid !== BigInt(process.getuid()) ||
					(fact.mode & 511n) !== 384n ||
					fact.nlink !== 1n
				)
					refuse();
				held.nativeClosed = phaseReceipt(JSON.parse(bounded(closedFile)), held.pid, kind, status);
				result.stdout = bounded(stdout);
				result.stderr = bounded(stderr);
			} catch {
				held.reason ||= 'closure_receipt_refused';
				result.error = held.reason;
			}
			if (!held.nativeClosed) result.error ||= 'native_closure_unknown';
			if (!sinksClosed) result.error ||= 'sink_closure_unknown';
			if (sinksClosed) {
				// The Python owner has exited. Unknown native receipt still fails;
				// Node holds its original record and never signals a reused PID.
				clearInterval(watcher);
				clearTimeout(grace);
				activeChildren.delete(receipt);
			}
			answer(result);
		}
		// Retention exists before Popen/listener acquisition can partially fail.
		watcher = setInterval(() => {
			if (held.childClosed) return;
			if (clock() >= expires) request('deadline');
			for (const record of held.descriptors) {
				if (record.state !== 'open') continue; // Never inspect a possibly reused closed integer.
				try {
					if (fs.fstatSync(record.fd).size > MAX_RECEIPT_BYTES) request('capture_bound');
				} catch {
					request('capture_observation_refused');
				}
			}
		}, 25);
		try {
			for (const filename of [stdout, stderr]) {
				const fd = fs.openSync(filename, 'wx', 0o600);
				held.descriptors.push({ fd, state: 'open' });
			}
			const remaining = Number(expires - clock()) / 1000000000;
			if (!(remaining > 0)) refuse();
			const vector = [
				'-B',
				worker,
				'--owner',
				owner,
				'--owner-sha256',
				ownerSha,
				'--kind',
				kind,
				'--receipt',
				receipt,
				'--budget',
				String(Math.min(remaining, 1800))
			];
			if (fixtureSha) vector.push('--fixture-sha256', fixtureSha);
			vector.push('--', command, ...args);
			held.child = spawnChild('python3', vector, {
				cwd,
				env,
				stdio: ['ignore', held.descriptors[0].fd, held.descriptors[1].fd]
			});
			held.child.once('spawn', () => {
				held.pid = held.child.pid;
				if (held.reason) request(held.reason);
			});
			held.child.once('error', () => {
				held.reason ||= 'spawn_refused';
			});
			held.child.once('close', finish);
		} catch {
			held.reason ||= 'acquisition_refused';
			if (held.child) {
				request(held.reason);
				return;
			}
			const closed = closeSinks();
			if (closed) {
				activeChildren.delete(receipt);
				clearInterval(watcher);
			}
			// An existing referenced watcher retains uncertain FD debt.
			answer({ status: null, signal: null, error: held.reason, stdout: '', stderr: '' });
		}
	});
}

/** No native transcript is returned to the console, including on refusal. */
async function run({
	root = ROOT,
	environment = process.env,
	log = console.log,
	error = console.error
} = {}) {
	if (process.platform !== 'linux') {
		log('[DEFERRED] Managed HTTP native qualification requires its Linux lane.');
		return 0;
	}
	let work,
		phase = 'prerequisites',
		gateCancelled = false;
	const gateDeadline = process.hrtime.bigint() + BigInt(TOTAL_GATE_MS) * 1000000n;
	const cancel = () => {
		gateCancelled = true;
		for (const held of activeChildren.values()) if (held.cancel) held.cancel();
	};
	process.on('SIGTERM', cancel);
	process.on('SIGINT', cancel);
	try {
		const modern = environment.ERGOPTI_MANAGED_NATIVE_MODERN_CURL;
		const legacy = environment.ERGOPTI_MANAGED_NATIVE_LEGACY_CURL;
		const modernBytes = admittedElf(modern, environment.ERGOPTI_MANAGED_NATIVE_MODERN_SHA256);
		admittedElf(legacy, environment.ERGOPTI_MANAGED_NATIVE_LEGACY_SHA256);
		const expectedHead = environment.ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD;
		if (!/^[0-9a-f]{40}$/.test(expectedHead || '')) refuse();
		work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-managed-native-'));
		fs.chmodSync(work, 0o700);
		let serial = 0;
		const baseEnv = { ...environment, PYTHONDONTWRITEBYTECODE: '1', LC_ALL: 'C.UTF-8' };
		delete baseEnv.LUA_PATH;
		if (environment.ERGOPTI_NATIVE_LUA_CPATH)
			baseEnv.LUA_CPATH = environment.ERGOPTI_NATIVE_LUA_CPATH;
		const ownerRoot = path.join(work, 'build-owner');
		const ownerInputs = [
			'tools/build/stage-linux-network-runtime.py',
			'tools/lib/git_bash.py',
			'tools/test/run-linux-managed-http-phase.py',
			'tools/__init__.py'
		];
		for (const relative of ownerInputs) {
			const actual = path.join(root, relative);
			regular(actual);
			const bytes = fs.readFileSync(actual);
			const target = path.join(ownerRoot, relative);
			fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
			fs.writeFileSync(target, bytes, { flag: 'wx', mode: 0o600 });
			if (hash(fs.readFileSync(actual)) !== hash(bytes)) refuse();
		}
		const owner = path.join(ownerRoot, ownerInputs[0]);
		const ownerSha = hash(fs.readFileSync(owner));
		const bashHelperSha = hash(fs.readFileSync(path.join(ownerRoot, ownerInputs[1])));
		const worker = path.join(ownerRoot, ownerInputs[2]);
		const workerSha = hash(fs.readFileSync(worker));
		async function child(
			command,
			args,
			env = baseEnv,
			cwd = work,
			kind = 'command',
			budgetMs = 30000
		) {
			if (gateCancelled || process.hrtime.bigint() >= gateDeadline) refuse();
			const label = String(++serial).padStart(2, '0');
			const fixtureSha = kind === 'command' ? undefined : hash(fs.readFileSync(args[1]));
			return await ownPhase({
				command,
				args,
				env,
				cwd,
				work,
				label,
				worker,
				owner,
				ownerSha,
				kind,
				fixtureSha,
				budgetMs,
				gateDeadline
			});
		}
		const bin = path.join(work, 'bin');
		fs.mkdirSync(bin, { mode: 0o700 });
		const privateModern = path.join(bin, 'curl');
		fs.writeFileSync(privateModern, modernBytes, { flag: 'wx', mode: 0o700 });
		admittedElf(modern, environment.ERGOPTI_MANAGED_NATIVE_MODERN_SHA256);
		admittedElf(privateModern, environment.ERGOPTI_MANAGED_NATIVE_MODERN_SHA256);
		baseEnv.PATH = bin + path.delimiter + (environment.PATH || '/usr/bin:/bin');
		const modernVersion = curlVersion(await child(privateModern, ['--version']));
		const legacyEnv = { ...baseEnv };
		const oldLibraries = environment.ERGOPTI_MANAGED_NATIVE_LEGACY_LIBRARY_PATH;
		if (oldLibraries) {
			if (
				!path.isAbsolute(oldLibraries) ||
				/[\0\r\n:]/.test(oldLibraries) ||
				!fs.lstatSync(oldLibraries).isDirectory()
			)
				refuse();
			legacyEnv.LD_LIBRARY_PATH =
				oldLibraries +
				(environment.LD_LIBRARY_PATH ? path.delimiter + environment.LD_LIBRARY_PATH : '');
		}
		const oldVersion = curlVersion(await child(legacy, ['--version'], legacyEnv));
		if (
			!atLeast(modernVersion.cli, 8, 7) ||
			!atLeast(modernVersion.library, 8, 7) ||
			!atLeast(oldVersion.cli, 7, 76) ||
			!atLeast(oldVersion.library, 7, 76) ||
			atLeast(oldVersion.cli, 8, 7) ||
			atLeast(oldVersion.library, 8, 7)
		)
			refuse();
		phase = 'source-snapshot';
		const snapshot = path.join(work, 'snapshot');
		const captured = await child(
			'python3',
			[
				'-B',
				path.join(root, 'tools/test/prepare-linux-managed-http-snapshot.py'),
				'--repository',
				root,
				'--output',
				snapshot,
				'--expected-head',
				expectedHead
			],
			baseEnv,
			work,
			'command',
			150000
		);
		if (!completed(captured) || captured.stderr !== '') refuse();
		const admission = JSON.parse(bounded(path.join(snapshot, 'ADMISSION.json')));
		for (const key of [
			'expected_manifest',
			'expected_inventory_sha256',
			'expected_native_sha256'
		]) {
			if (!/^[0-9a-f]{64}$/.test(admission[key] || '')) refuse();
		}
		if (
			admission.expected_dependency_commit !== expectedHead ||
			admission.expected_dependency_phase !== 'working-tree-snapshot'
		)
			refuse();
		const dependency = path.join(snapshot, 'dependencies');
		const driver = path.join(dependency, 'static/ergopti_plus/linux');
		const hardware = path.join(driver, 'tests/hardware');
		const env = {
			...baseEnv,
			LUA_PATH:
				driver +
				'/?.lua;' +
				driver +
				'/?/init.lua;' +
				path.join(driver, '../_shared/lua/?.lua') +
				';' +
				path.join(driver, '../_shared/lua/?/init.lua')
		};
		phase = 'gio-native-build';
		const compileEnv = { ...env };
		const gioSysroot = environment.ERGOPTI_MANAGED_NATIVE_GIO_SYSROOT;
		if (gioSysroot !== undefined && gioSysroot !== '') {
			if (
				typeof gioSysroot !== 'string' ||
				!path.isAbsolute(gioSysroot) ||
				/[\0\r\n]/.test(gioSysroot) ||
				!fs.lstatSync(gioSysroot).isDirectory()
			)
				refuse();
			compileEnv.PKG_CONFIG_SYSROOT_DIR = gioSysroot;
		}
		const flags = await child(
			'pkg-config',
			['--cflags', '--libs', 'gio-2.0', 'gmodule-2.0'],
			compileEnv
		);
		if (!completed(flags) || flags.stderr !== '') refuse();
		const argv = flags.stdout.trim().split(/\s+/);
		if (!argv.length || argv.some((value) => !/^[a-zA-Z0-9_./:+,=~@%+-]+$/.test(value))) refuse();
		const modules = path.join(work, 'modules');
		fs.mkdirSync(modules, { mode: 0o700 });
		const built = await child(
			'cc',
			[
				'-fPIC',
				'-shared',
				'-Wall',
				'-Wextra',
				'-Werror',
				path.join(hardware, 'managed_http_gio_error.c'),
				'-o',
				path.join(modules, 'libergopti-native-error.so'),
				...argv
			],
			compileEnv
		);
		if (!completed(built) || built.stdout !== '' || built.stderr !== '') refuse();
		regular(path.join(modules, 'libergopti-native-error.so'));
		phase = 'output18';
		const outputEnv = { ...env };
		for (const key of Object.keys(outputEnv)) {
			if (key.toLowerCase().endsWith('_proxy')) delete outputEnv[key];
		}
		// Explicit test-owned local transport. Public30 configures its own real
		// environment/system routes independently; no parent environment changes.
		outputEnv.NO_PROXY = '*';
		outputEnv.no_proxy = '*';
		const output = await child(
			'python3',
			[
				'-B',
				path.join(hardware, 'run_native_subreaper.py'),
				'luajit',
				path.join(hardware, 'run_http_output_target_native_entry.lua'),
				driver
			],
			outputEnv,
			work,
			'output18',
			60000
		);
		if (!outputReceipt(output)) refuse();
		log('[OK] Linux managed HTTP retained output: 18 actual native controls passed; 0 skipped.');
		phase = 'public30';
		const args = [
			'-B',
			path.join(hardware, 'run_managed_http_native.py'),
			'--composition',
			snapshot,
			'--repository',
			dependency,
			'--dependency-inventory',
			path.join(snapshot, 'DEPENDENCY-FILES.json'),
			'--expected-manifest',
			admission.expected_manifest,
			'--expected-inventory-sha256',
			admission.expected_inventory_sha256,
			'--expected-native-sha256',
			admission.expected_native_sha256,
			'--expected-dependency-commit',
			expectedHead,
			'--expected-dependency-phase',
			'working-tree-snapshot',
			'--control',
			path.join(hardware, 'run_managed_http_native.lua'),
			'--error-module',
			modules,
			'--legacy-curl-path',
			legacy,
			'-f',
			'-v'
		];
		if (oldLibraries) args.push('--legacy-curl-library-path', oldLibraries);
		// Python is the direct owner of public30 and its native token guardians.
		// Never insert a competing subreaper or group-kill wrapper in this path.
		const publicResult = await child('python3', args, env, work, 'public30', 900000);
		if (!publicReceipt(publicResult)) refuse();
		log('[OK] Linux managed HTTP public transport: 30 actual native controls passed; 0 skipped.');
		if (gateCancelled || process.hrtime.bigint() >= gateDeadline) refuse();
		fs.writeFileSync(
			path.join(work, 'QUALIFICATION.json'),
			JSON.stringify(
				{
					status: 'passed',
					output_native: 18,
					public_native: 30,
					skipped: 0,
					owner_kernel_sha256: ownerSha,
					phase_worker_sha256: workerSha,
					bash_helper_sha256: bashHelperSha,
					dependency_commit: expectedHead,
					inventory_sha256: admission.expected_inventory_sha256,
					manifest_sha256: admission.expected_manifest,
					native_sha256: admission.expected_native_sha256
				},
				null,
				2
			) + '\n',
			{ flag: 'wx', mode: 0o600 }
		);
		log(
			'Linux managed HTTP source: ' +
				expectedHead +
				'; inventory ' +
				admission.expected_inventory_sha256 +
				'; native ' +
				admission.expected_native_sha256 +
				'.'
		);
		return 0;
	} catch {
		error(
			'[FAIL] Linux managed HTTP native ' +
				phase +
				': admission or completed cleanup receipt refused.'
		);
		return 1;
	} finally {
		if (!activeChildren.size) {
			process.removeListener('SIGTERM', cancel);
			process.removeListener('SIGINT', cancel);
		}
	}
	// Completed and refused private snapshots/sinks stay with their owner.
	// This runner never guesses process/descriptor cleanup or recursively
	// removes evidence. Explicit later artifact retention belongs to the caller.
}

// Reuse only each already-retained exact phase's original cancellation admission.
function requestActiveCancellation() {
	for (const held of [...activeChildren.values()]) if (held.cancel) held.cancel();
}

// Read-only presence keeps the original retained-debt signal handler installed.
function hasRetainedPhases() {
	return activeChildren.size !== 0;
}

if (require.main === module)
	run().then((status) => {
		process.exitCode = status;
	});
module.exports = {
	run,
	publicReceipt,
	outputReceipt,
	phaseReceipt,
	ownPhase,
	requestActiveCancellation,
	hasRetainedPhases
};
