// tools/test/run-linux-updater-temp-native.cjs

/** Genuine original temporary updater fixtures in one privately compiled source cohort. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {
	ownPhase,
	requestActiveCancellation,
	hasRetainedPhases
} = require('./run-linux-managed-http-native.cjs');
const { payloadInventory } = require('./run-linux-updater-archive-native.cjs');
const ROOT = path.resolve(__dirname, '../..');
const NATIVE_TEMP_PARENT = '/var/tmp/ergopti-cloud-validation';
const ABIS = ['luajit', 'lua5.4'];
const NAMESPACE = 'tests/hardware/run_native_artifact_cleanup_retry.py';
const CAPTURE = 'tests/hardware/run_native_artifact_capture_completion.c';
const CRYPTO = 'tests/hardware/run_openssl_byte_input_native.lua';
const FIXTURES = {
	ownership: 'run_updater_temp_ownership_receipts.py',
	allocation: 'run_updater_temp_allocation_receipts.py'
};
const LABELS = {
	ownership: [
		'checksum-http preserves regular ownership',
		'checksum-http preserves hardlink ownership',
		'checksum-http preserves symlink ownership',
		'checksum-http preserves dangling ownership',
		'publication-collision preserves regular ownership',
		'publication-collision preserves hardlink ownership',
		'publication-collision preserves symlink ownership',
		'publication-collision preserves dangling ownership',
		'invalid-checksum preserves regular ownership',
		'digest-mismatch preserves regular ownership',
		'archive-http preserves regular ownership',
		'healthy preserves regular ownership'
	],
	allocation: [
		'update-limit-0-callback-True',
		'update-limit-0-callback-False',
		'update-limit-3-callback-True',
		'update-limit-3-callback-False',
		'update-limit-None-callback-True',
		'update-limit-None-callback-False',
		'release-limit-0-callback-True',
		'release-limit-0-callback-False',
		'release-limit-3-callback-True',
		'release-limit-3-callback-False',
		'release-limit-None-callback-True',
		'release-limit-None-callback-False'
	]
};
const SUMMARY = {
	ownership: 'Native updater temporary ownership receipts: 12 checks, 0 failures',
	allocation: 'Native updater temporary allocation receipts: 12 checks, 0 failures'
};
function refused() {
	throw new Error('Temporary updater native admission or physical closure refused.');
}
// An explicit work root is supplied and owned by the caller; never create it.
function temporaryWorkRoot(environment) {
	const configured = Object.hasOwn(environment, 'ERGOPTI_UPDATER_TEMP_NATIVE_WORK_ROOT');
	let temporaryParent = NATIVE_TEMP_PARENT;
	if (configured) {
		const selected = environment.ERGOPTI_UPDATER_TEMP_NATIVE_WORK_ROOT;
		if (typeof selected !== 'string' || !path.isAbsolute(selected) || selected.includes('\0'))
			refused();
		temporaryParent = path.resolve(selected);
		if (fs.realpathSync(temporaryParent) !== temporaryParent) refused();
	} else if (!fs.existsSync(temporaryParent)) fs.mkdirSync(temporaryParent, { mode: 0o700 });
	const temporaryFact = fs.lstatSync(temporaryParent);
	if (
		!temporaryFact.isDirectory() ||
		temporaryFact.isSymbolicLink() ||
		temporaryFact.uid !== process.getuid() ||
		(temporaryFact.mode & 0o077) !== 0 ||
		(configured && (temporaryFact.mode & 0o7777) !== 0o700)
	)
		refused();
	return temporaryParent;
}
// The opt-in moves cloned/build inputs only; native fixture policy stays canonical.
function nativeFixtureEnvironment(environment) {
	return {
		...environment,
		TMPDIR: NATIVE_TEMP_PARENT,
		PYTHONDONTWRITEBYTECODE: '1',
		LC_ALL: 'C.UTF-8'
	};
}
function hash(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}
function ordinary(filename) {
	const fact = fs.lstatSync(filename);
	if (!fact.isFile() || fact.isSymbolicLink()) refused();
	return fact;
}
function closed(result) {
	return result && !result.error && result.signal == null && Number.isInteger(result.status);
}
function complete(result) {
	return closed(result) && result.status === 0;
}
function fixtureReceipt(family, result) {
	if (
		!Object.hasOwn(FIXTURES, family) ||
		!complete(result) ||
		result.stderr !== '' ||
		typeof result.stdout !== 'string'
	)
		return false;
	const expected =
		[...LABELS[family].map((label) => 'PASS native ' + label), SUMMARY[family]].join('\n') + '\n';
	return result.stdout === expected;
}
function nativeLine(family, head) {
	if (
		!(Object.hasOwn(FIXTURES, family) || family === 'namespace') ||
		!/^[0-9a-f]{40}$/.test(head || '')
	)
		refused();
	if (family === 'namespace')
		return (
			'[OK] Linux updater namespace cleanup: SHA=' +
			head +
			'; 5 actual checks; 0 skipped; closure complete.\n'
		);
	return (
		'[OK] Linux updater temporary ' +
		family +
		': SHA=' +
		head +
		'; 24 actual checks; 0 skipped; closure complete.\n'
	);
}
function evidenceCount(family, text, head) {
	if (family === 'namespace') {
		if (text !== nativeLine('namespace', head) + nativeLine('ownership', head)) refused();
		return 5;
	}
	if (text !== nativeLine('namespace', head) + nativeLine(family, head)) refused();
	return 24;
}
function cryptoReceipt(result) {
	const expected =
		[
			'PASS actual native SHA256 abc',
			'PASS actual native SHA256 one zero byte',
			'PASS actual native SHA256 empty',
			'SUMMARY 3 passed, 0 failed, 0 skipped'
		].join('\n') + '\n';
	return complete(result) && result.stderr === '' && result.stdout === expected;
}
function captureReceipt(result) {
	const expected =
		[
			'PASS invalid literal component refuses before any native owner acquisition',
			'PASS missing component retains then closes exact acquired descriptors',
			'PASS non-directory component retains then closes exact acquired descriptors',
			'PASS completed reserve still refuses actual foreign namespace noise',
			'Native capture completion: 4 passed; 0 skipped; exact native retirement complete.'
		].join('\n') + '\n';
	return complete(result) && result.stderr === '' && result.stdout === expected;
}
function namespaceReceipt(result) {
	if (
		!complete(result) ||
		result.stderr !== '' ||
		typeof result.stdout !== 'string' ||
		!result.stdout.endsWith('\n') ||
		result.stdout.indexOf('\n') !== result.stdout.length - 1
	)
		return false;
	let row;
	try {
		row = JSON.parse(result.stdout);
	} catch {
		return false;
	}
	if (
		row === null ||
		typeof row !== 'object' ||
		Array.isArray(row) ||
		Object.keys(row).sort().join(',') !==
			'cases,failed,fixture_debt,native_owner_debt,passed,schema_version,skipped,state' ||
		row.schema_version !== 1 ||
		row.state !== 'native_namespace_conflicts_passed' ||
		row.passed !== 5 ||
		row.failed !== 0 ||
		row.skipped !== 0 ||
		row.fixture_debt !== 0 ||
		row.native_owner_debt !== 0 ||
		!Array.isArray(row.cases) ||
		row.cases.length !== 5
	)
		return false;
	const names = ['regular', 'hardlink', 'symlink', 'dangling', 'unexpected-basename'];
	return row.cases.every(
		(item, index) =>
			item !== null &&
			typeof item === 'object' &&
			!Array.isArray(item) &&
			Object.keys(item).sort().join(',') ===
				'case,conflicts,fixture_competitor_removed,fixture_debt,native_descriptors_closed,native_disposed_once,passed,same_owner,sentinel_preserved' &&
			item.case === names[index] &&
			item.passed === true &&
			item.same_owner === true &&
			item.conflicts === 2 &&
			item.fixture_competitor_removed === true &&
			item.native_descriptors_closed === true &&
			item.native_disposed_once === true &&
			item.sentinel_preserved === true &&
			item.fixture_debt === 0
	);
}
function executable(name, env) {
	if (typeof name !== 'string' || name === '' || /[\0\r\n]/.test(name)) refused();
	const choices = path.isAbsolute(name)
		? [name]
		: (env.PATH || '/usr/bin:/bin')
				.split(path.delimiter)
				.filter((directory) => path.isAbsolute(directory))
				.map((directory) => path.join(directory, name));
	for (const filename of choices) {
		try {
			const actual = fs.realpathSync(filename);
			ordinary(actual);
			fs.accessSync(actual, fs.constants.X_OK);
			if (
				fs
					.readFileSync(actual)
					.subarray(0, 4)
					.equals(Buffer.from([127, 69, 76, 70]))
			)
				return actual;
		} catch {}
	}
	refused();
}
async function run({
	root = ROOT,
	environment = process.env,
	family,
	log = console.log,
	error = console.error
} = {}) {
	if (process.platform !== 'linux') {
		log('[DEFERRED] Temporary updater native qualification requires Linux; no native receipt.');
		return 0;
	}
	let phase = 'source-admission',
		cancelled = false;
	const deadline = process.hrtime.bigint() + 1200000n * 1000000n;
	const current = () => {
		if (cancelled || process.hrtime.bigint() >= deadline) refused();
	};
	const cancel = () => {
		cancelled = true;
		requestActiveCancellation();
	};
	process.on('SIGINT', cancel);
	process.on('SIGTERM', cancel);
	try {
		current();
		if (family !== undefined && !Object.hasOwn(FIXTURES, family)) refused();
		const families = family === undefined ? Object.keys(FIXTURES) : [family];
		const head = environment.ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD;
		if (!/^[0-9a-f]{40}$/.test(head || '') || !path.isAbsolute(root)) refused();
		const rootFact = fs.lstatSync(root);
		if (!rootFact.isDirectory() || rootFact.isSymbolicLink()) refused();
		const temporaryParent = temporaryWorkRoot(environment);
		if (temporaryParent !== NATIVE_TEMP_PARENT) temporaryWorkRoot({});
		current();
		const work = fs.mkdtempSync(path.join(temporaryParent, 'ergopti-updater-temp-native-'));
		fs.chmodSync(work, 0o700);
		const env = nativeFixtureEnvironment(environment);
		for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
		env.GIT_CONFIG_GLOBAL = '/dev/null';
		env.GIT_CONFIG_NOSYSTEM = '1';
		env.GIT_OPTIONAL_LOCKS = '0';
		delete env.LUA_PATH;
		delete env.LUA_CPATH;

		const inputs = [
			'tools/build/stage-linux-network-runtime.py',
			'tools/lib/git_bash.py',
			'tools/test/run-linux-managed-http-phase.py',
			'tools/__init__.py',
			'tools/test/prepare-linux-updater-archive-snapshot.py',
			'tools/lib/git-bash.cjs',
			'tools/build/build-linux-native-output.sh',
			'tools/test/run-linux-managed-http-native.cjs',
			'tools/test/run-linux-updater-archive-native.cjs',
			'tools/test/run-linux-updater-temp-native.cjs',
			'static/ergopti_plus/linux/native/archive_output/archive_publication.c',
			'static/ergopti_plus/linux/native/archive_output/archive_publication.h',
			'static/ergopti_plus/linux/' + NAMESPACE,
			'static/ergopti_plus/linux/' + CAPTURE,
			'static/ergopti_plus/linux/' + CRYPTO,
			'static/ergopti_plus/linux/infra/openssl_digest.lua',
			'tools/test/prepare-linux-lua54-native-provider.cjs',
			'tools/test/fixtures/lua54-provider-entry.c',
			...Object.values(FIXTURES).map((file) => 'static/ergopti_plus/linux/tests/hardware/' + file)
		];
		const ownerRoot = path.join(work, 'owner'),
			identities = {};
		for (const relative of inputs) {
			ordinary(path.join(root, relative));
			const bytes = fs.readFileSync(path.join(root, relative));
			const target = path.join(ownerRoot, relative);
			fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
			fs.writeFileSync(target, bytes, { flag: 'wx', mode: 0o600 });
			identities[relative] = hash(bytes);
			if (hash(fs.readFileSync(path.join(root, relative))) !== identities[relative]) refused();
		}
		function sourceCurrent() {
			current();
			for (const relative of inputs) {
				ordinary(path.join(root, relative));
				if (hash(fs.readFileSync(path.join(root, relative))) !== identities[relative]) refused();
			}
		}
		let serial = 0;
		async function child(
			command,
			args,
			childEnv = env,
			cwd = work,
			budgetMs = 120000,
			allowFailure = false
		) {
			sourceCurrent();
			const result = await ownPhase({
				command,
				args,
				env: childEnv,
				cwd,
				work,
				label: String(++serial).padStart(2, '0'),
				worker: path.join(ownerRoot, inputs[2]),
				owner: path.join(ownerRoot, inputs[0]),
				ownerSha: identities[inputs[0]],
				kind: 'command',
				budgetMs,
				gateDeadline: deadline
			});
			sourceCurrent();
			if (!closed(result) || (!allowFailure && !complete(result))) refused();
			return result;
		}
		const actualHead = await child('git', ['-C', root, 'rev-parse', 'HEAD']);
		if (actualHead.stdout !== head + '\n' || actualHead.stderr !== '') refused();
		const clone = path.join(work, 'repository');
		await child('git', ['clone', '--no-local', '--no-hardlinks', '--no-checkout', root, clone]);
		await child('git', ['-C', clone, 'checkout', '--detach', head]);
		phase = 'working-tree-snapshot';
		const snapshot = path.join(work, 'snapshot');
		await child(
			'python3',
			[
				'-B',
				path.join(ownerRoot, 'tools/test/prepare-linux-updater-archive-snapshot.py'),
				'--repository',
				root,
				'--clone',
				clone,
				'--output',
				snapshot,
				'--expected-head',
				head
			],
			env,
			work,
			180000
		);
		const admission = JSON.parse(fs.readFileSync(path.join(snapshot, 'ADMISSION.json'), 'utf8'));
		if (
			admission.phase !== 'working-tree-snapshot' ||
			admission.source_head !== head ||
			!/^[0-9a-f]{64}$/.test(admission.inventory_sha256 || '')
		)
			refused();
		for (const relative of inputs) {
			ordinary(path.join(clone, relative));
			if (hash(fs.readFileSync(path.join(clone, relative))) !== identities[relative]) refused();
		}
		const resolver = path.join(root, 'tools/lib/git-bash.cjs');
		if (require.resolve('../lib/git-bash.cjs') !== resolver) refused();
		sourceCurrent();
		const { bashExecutable } = require('../lib/git-bash.cjs');
		const bash = bashExecutable();
		sourceCurrent();
		if (typeof bash !== 'string' || !path.isAbsolute(bash)) refused();
		ordinary(bash);
		fs.accessSync(bash, fs.constants.X_OK);
		const bashBytes = fs.readFileSync(bash);
		if (!bashBytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) refused();
		const bashSha = hash(bashBytes);
		const compiler = executable(env.CC || 'cc', env),
			compilerSha = hash(fs.readFileSync(compiler));
		const interpreters = Object.fromEntries(
			ABIS.map((abi) => {
				const filename = executable(abi, env);
				return [abi, { filename, sha256: hash(fs.readFileSync(filename)) }];
			})
		);
		function binariesCurrent() {
			for (const [filename, expected] of [
				[bash, bashSha],
				[compiler, compilerSha],
				...ABIS.map((abi) => [interpreters[abi].filename, interpreters[abi].sha256])
			]) {
				ordinary(filename);
				fs.accessSync(filename, fs.constants.X_OK);
				if (hash(fs.readFileSync(filename)) !== expected) refused();
			}
			sourceCurrent();
		}
		const driver = path.join(clone, 'static/ergopti_plus/linux');
		const shared = path.join(clone, 'static/ergopti_plus/_shared');
		const sourceDirectory = path.join(driver, 'native/archive_output');
		const outputDirectory = path.join(driver, 'bin');
		const generated = path.join(outputDirectory, 'libergopti_archive_publication.so');
		if (fs.existsSync(generated)) refused();
		phase = 'canonical-native-build';
		binariesCurrent();
		await child(
			bash,
			[
				path.join(clone, 'tools/build/build-linux-native-output.sh'),
				'--source-directory',
				sourceDirectory,
				'--output-directory',
				outputDirectory
			],
			{ ...env, CC: compiler },
			clone,
			120000
		);
		binariesCurrent();
		ordinary(generated);
		const nativeBytes = fs.readFileSync(generated);
		if (!nativeBytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) refused();
		const nativeSha = hash(nativeBytes);
		const driverInventory = payloadInventory(driver, current),
			sharedInventory = payloadInventory(shared, current);
		let lua54Provider, captureExecutable;
		function cohortCurrent() {
			binariesCurrent();
			if (lua54Provider) lua54Provider.current();
			if (captureExecutable) {
				ordinary(captureExecutable.filename);
				if (hash(fs.readFileSync(captureExecutable.filename)) !== captureExecutable.sha256)
					refused();
				current();
			}
			ordinary(generated);
			if (
				hash(fs.readFileSync(generated)) !== nativeSha ||
				payloadInventory(driver, current) !== driverInventory ||
				payloadInventory(shared, current) !== sharedInventory
			)
				refused();
		}
		phase = 'genuine-lua54-provider-preparation';
		cohortCurrent();
		const providerHelper = path.join(root, 'tools/test/prepare-linux-lua54-native-provider.cjs');
		if (require.resolve('./prepare-linux-lua54-native-provider.cjs') !== providerHelper) refused();
		const { prepareLua54Provider } = require('./prepare-linux-lua54-native-provider.cjs');
		cohortCurrent();
		lua54Provider = await prepareLua54Provider({
			child,
			current: cohortCurrent,
			env,
			work,
			lua54: interpreters['lua5.4'].filename,
			compiler,
			sourceRoot: clone
		});
		cohortCurrent();
		phase = 'native-capture-completion-build';
		cohortCurrent();
		const captureBinary = path.join(work, 'native-capture-completion');
		await child(
			compiler,
			[
				'-std=c11',
				'-I',
				sourceDirectory,
				path.join(driver, CAPTURE),
				generated,
				'-Wl,-rpath,' + outputDirectory,
				'-o',
				captureBinary
			],
			{ ...env, CC: compiler },
			work,
			120000
		);
		cohortCurrent();
		ordinary(captureBinary);
		fs.accessSync(captureBinary, fs.constants.X_OK);
		const captureBytes = fs.readFileSync(captureBinary);
		if (!captureBytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) refused();
		captureExecutable = { filename: captureBinary, sha256: hash(captureBytes) };
		phase = 'actual-native-capture-completion';
		cohortCurrent();
		const captureEnvironment = { ...env, LD_LIBRARY_PATH: outputDirectory };
		delete captureEnvironment.LD_PRELOAD;
		delete captureEnvironment.LD_AUDIT;
		const capture = await child(captureBinary, [work], captureEnvironment, work, 10000, true);
		cohortCurrent();
		if (!captureReceipt(capture)) refused();
		phase = 'actual-native-namespace-cleanup';
		cohortCurrent();
		const namespace = await child(
			'python3',
			[
				'-B',
				path.join(driver, NAMESPACE),
				'--library',
				generated,
				'--library-sha256',
				nativeSha,
				'--source-root',
				clone
			],
			env,
			driver,
			120000,
			true
		);
		cohortCurrent();
		if (!namespaceReceipt(namespace)) refused();
		const successReceipts = [nativeLine('namespace', head).trimEnd()];
		const phases = [
			{
				fixture: 'namespace',
				abi: 'native-C',
				status: 'passed',
				exit: namespace.status,
				signal: namespace.signal,
				admitted_checks: 5,
				skipped: 0,
				physical_phase_closed: true
			}
		];
		phases.unshift({
			fixture: 'capture-completion',
			abi: 'native-C',
			status: 'passed',
			exit: capture.status,
			signal: capture.signal,
			source_sha256: identities['static/ergopti_plus/linux/' + CAPTURE],
			library_sha256: nativeSha,
			executable_sha256: captureExecutable.sha256,
			admitted_checks: 4,
			skipped: 0,
			physical_phase_closed: true
		});
		for (const abi of ABIS) {
			phase = 'actual-native-openssl-byte-input-' + abi;
			cohortCurrent();
			const runtime = interpreters[abi];
			const cryptoEnvironment = { ...env };
			if (abi === 'luajit' && environment.ERGOPTI_NATIVE_LUA_CPATH) {
				const nativePath = environment.ERGOPTI_NATIVE_LUA_CPATH;
				if (typeof nativePath !== 'string' || /[\0\r\n]/.test(nativePath)) refused();
				cryptoEnvironment.LUA_CPATH = nativePath;
			}
			if (abi === 'lua5.4') {
				cryptoEnvironment.LUA_CPATH = lua54Provider.cpath;
				cryptoEnvironment.LUA_CPATH_5_4 = lua54Provider.cpath;
			}
			const crypto = await child(
				runtime.filename,
				[path.join(driver, CRYPTO), path.join(driver, 'infra/openssl_digest.lua')],
				cryptoEnvironment,
				driver,
				10000,
				true
			);
			cohortCurrent();
			if (!cryptoReceipt(crypto)) refused();
			phases.push({
				fixture: 'openssl-byte-input',
				abi,
				status: 'passed',
				exit: crypto.status,
				signal: crypto.signal,
				source_sha256: identities['static/ergopti_plus/linux/' + CRYPTO],
				module_sha256: identities['static/ergopti_plus/linux/infra/openssl_digest.lua'],
				interpreter_sha256: runtime.sha256,
				admitted_checks: 3,
				skipped: 0,
				physical_phase_closed: true
			});
		}
		let failed = false;
		for (const selected of families) {
			let familyPassed = true;
			for (const abi of ABIS) {
				phase = 'actual-' + selected + '-' + abi;
				cohortCurrent();
				const runtime = interpreters[abi];
				const version = await child(runtime.filename, ['-v']);
				const observed = version.stdout + version.stderr;
				if (!(abi === 'luajit' ? /^LuaJIT / : /^Lua 5\.4\./).test(observed)) refused();
				const fixture = path.join(driver, 'tests/hardware', FIXTURES[selected]);
				const fixtureEnvironment = { ...env, ERGOPTI_HTTP_TEST_LUA: runtime.filename };
				// The existing optional native Cpath belongs to LuaJIT's real provider ABI.
				// Lua5.4 alone receives the admitted private native provider plus genuine defaults.
				if (abi === 'luajit' && environment.ERGOPTI_NATIVE_LUA_CPATH) {
					const nativePath = environment.ERGOPTI_NATIVE_LUA_CPATH;
					if (typeof nativePath !== 'string' || /[\0\r\n]/.test(nativePath)) refused();
					fixtureEnvironment.LUA_CPATH = nativePath;
				}
				if (abi === 'lua5.4') fixtureEnvironment.LUA_CPATH = lua54Provider.cpath;
				if (abi === 'lua5.4') fixtureEnvironment.LUA_CPATH_5_4 = lua54Provider.cpath;
				const result = await child(
					'python3',
					['-B', fixture],
					fixtureEnvironment,
					driver,
					selected === 'ownership' ? 200000 : 120000,
					true
				);
				cohortCurrent();
				const passed = fixtureReceipt(selected, result);
				phases.push({
					fixture: selected,
					abi,
					status: passed ? 'passed' : 'failed',
					exit: result.status,
					signal: result.signal,
					source_sha256: hash(fs.readFileSync(fixture)),
					interpreter_sha256: runtime.sha256,
					admitted_checks: passed ? 12 : 0,
					skipped: 0,
					physical_phase_closed: true
				});
				if (!passed) {
					failed = true;
					familyPassed = false;
					error(
						'[FAIL] Linux updater temporary ' +
							selected +
							' ' +
							abi +
							': native prerequisites or original assertions failed; private evidence retained.'
					);
				}
			}
			if (familyPassed) successReceipts.push(nativeLine(selected, head).trimEnd());
		}
		cohortCurrent();
		current();
		fs.writeFileSync(
			path.join(work, 'QUALIFICATION.json'),
			JSON.stringify(
				{
					schema: 1,
					component_status: failed ? 'failed' : 'passed',
					gate_publication: 'requires_final_original_deadline_admission',
					source_head: head,
					source_phase: admission.phase,
					source_inventory_sha256: admission.inventory_sha256,
					identities,
					native_sha256: nativeSha,
					lua54_provider: {
						commit: lua54Provider.commit,
						tree: lua54Provider.tree,
						sha256: lua54Provider.sha256,
						vendor: lua54Provider.vendor,
						product_skip_credit: 0
					},
					driver_inventory_sha256: driverInventory,
					shared_inventory_sha256: sharedInventory,
					phases,
					skipped: 0,
					physical_phase_closed: true
				},
				null,
				2
			) + '\n',
			{ flag: 'wx', mode: 0o600 }
		);
		// A slow result write is not permission to publish after the original budget.
		current();
		for (const receipt of successReceipts) {
			current();
			log(receipt);
			current();
		}
		current();
		return failed ? 1 : 0;
	} catch {
		error(
			'[FAIL] Linux updater temporary native ' +
				phase +
				': admission or physical closure refused; private evidence retained.'
		);
		return 1;
	} finally {
		// Only the existing phase owner may retire native children/descriptors.
		// Never erase failed fixture roots, private compiler/source inputs or logs.
		if (!hasRetainedPhases()) {
			process.removeListener('SIGINT', cancel);
			process.removeListener('SIGTERM', cancel);
		}
	}
}
function readEvidence(filename) {
	const before = fs.lstatSync(filename, { bigint: true });
	if (!before.isFile() || before.isSymbolicLink() || before.size > 4096n) refused();
	const bytes = fs.readFileSync(filename);
	const after = fs.lstatSync(filename, { bigint: true });
	if (
		!after.isFile() ||
		after.dev !== before.dev ||
		after.ino !== before.ino ||
		after.size !== before.size ||
		after.mode !== before.mode ||
		after.uid !== before.uid ||
		after.nlink !== before.nlink ||
		BigInt(bytes.length) !== before.size
	)
		refused();
	return bytes.toString('utf8');
}
if (require.main === module) {
	const args = process.argv.slice(2);
	if (args[0] === '--evidence') {
		try {
			const [, family, filename, head, ...extra] = args;
			if (extra.length) refused();
			process.stdout.write(String(evidenceCount(family, readEvidence(filename), head)) + '\n');
		} catch {
			console.error('[FAIL] Temporary updater evidence refused.');
			process.exitCode = 1;
		}
	} else {
		const family = args.length === 2 && args[0] === '--fixture' ? args[1] : undefined;
		if (args.length && family === undefined) {
			console.error('[FAIL] Temporary updater native arguments refused.');
			process.exitCode = 1;
		} else
			run({ family }).then((status) => {
				process.exitCode = status;
			});
	}
}
module.exports = {
	run,
	temporaryWorkRoot,
	nativeFixtureEnvironment,
	fixtureReceipt,
	namespaceReceipt,
	evidenceCount,
	captureReceipt,
	cryptoReceipt
};
