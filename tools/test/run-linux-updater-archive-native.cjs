// tools/test/run-linux-updater-archive-native.cjs

/**
 * MODULE: Source-Admitted Native Updater Archive Chain
 * Builds the genuine HEAD plus index-listed working snapshot and delegates every child
 * to the existing retained phase owner. Native transcripts never reach console.
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {
	ownPhase,
	requestActiveCancellation,
	hasRetainedPhases
} = require('./run-linux-managed-http-native.cjs');
const ROOT = path.resolve(__dirname, '../..');
const MODES = ['happy', 'wrong_digest', 'smoke_rollback'];
const COMMON = [
	'actual source resolves genuine standalone installation',
	'selected checksum dispatch has actual owned admission',
	'one actual archive receipt waits retained physical owners',
	'actual loop and exact namespace descriptor owners physically drain'
];
function refused() {
	throw new Error('Native archive admission or physical closure refused.');
}
function hash(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}
function ordinary(filename) {
	const fact = fs.lstatSync(filename);
	if (!fact.isFile() || fact.isSymbolicLink()) refused();
	return fact;
}
function complete(result) {
	return result && !result.error && result.status === 0 && result.signal == null;
}
function pipelineReceipt(result) {
	if (!complete(result) || result.stderr !== '' || !result.stdout.endsWith('\n')) return false;
	const lines = result.stdout.split(/\r?\n/).filter(Boolean);
	const observed = lines.filter((line) => line.startsWith('PIPELINE_PASS '));
	const expected = MODES.flatMap((mode) =>
		[
			...COMMON.slice(0, 3),
			mode === 'happy' || mode === 'smoke_rollback'
				? 'actual verified brand enters native tar installation'
				: 'wrong digest exposes zero verified installation authority',
			COMMON[3]
		].map((name) => 'PIPELINE_PASS ' + mode + ' ' + name)
	);
	if (
		observed.length !== 15 ||
		new Set(observed).size !== 15 ||
		observed.some((line, index) => line !== expected[index])
	)
		return false;
	const terminal = lines.filter((line) => line.startsWith('PIPELINE_RESULT '));
	if (
		terminal.length !== 3 ||
		terminal.some(
			(line, index) => line !== 'PIPELINE_RESULT ' + MODES[index] + ' passed=5 failed=0 skipped=0'
		)
	)
		return false;
	const final = 'PIPELINE_NATIVE_RESULT cases=3 checks=15 failed=0 skipped=0 closure=complete';
	if (lines.filter((line) => line === final).length !== 1 || lines.at(-1) !== final) return false;
	if (
		lines.some(
			(line) =>
				line.startsWith('PIPELINE_') &&
				!expected.includes(line) &&
				!terminal.includes(line) &&
				line !== final
		)
	)
		return false;
	const summaries = lines.filter((line) => /^Native subreaper: /.test(line));
	const closures = lines.filter((line) => /^Native subreaper closure: /.test(line));
	if (summaries.length !== 6 || closures.length !== 6) return false;
	try {
		for (let index = 0; index < 6; index++) {
			const match = /^Native subreaper: (\d+) adopted descendants physically reaped$/.exec(
				summaries[index]
			);
			if (!match) return false;
			const row = JSON.parse(closures[index].slice('Native subreaper closure: '.length));
			if (
				Object.keys(row).sort().join(',') !== 'adopted,pending,rescue' ||
				!Number.isSafeInteger(row.adopted) ||
				row.adopted < 0 ||
				row.adopted !== Number(match[1]) ||
				row.pending !== 0 ||
				row.rescue !== 0
			)
				return false;
		}
	} catch {
		return false;
	}
	return true;
}
function payloadInventory(root, current) {
	const rows = [];
	let bytes = 0;
	function visit(directory) {
		current();
		for (const name of fs.readdirSync(directory).sort()) {
			const filename = path.join(directory, name);
			const fact = fs.lstatSync(filename);
			if (fact.isSymbolicLink()) refused();
			if (fact.isDirectory()) visit(filename);
			else {
				if (!fact.isFile() || fact.size > 32 * 1024 * 1024) refused();
				bytes += fact.size;
				if (bytes > 256 * 1024 * 1024 || rows.length >= 20000) refused();
				rows.push([
					path.relative(root, filename).split(path.sep).join('/'),
					fact.mode & 511,
					hash(fs.readFileSync(filename))
				]);
			}
			current();
		}
	}
	if (!fs.lstatSync(root).isDirectory() || fs.lstatSync(root).isSymbolicLink()) refused();
	visit(root);
	rows.sort((a, b) => Buffer.compare(Buffer.from(a[0]), Buffer.from(b[0])));
	return hash(
		Buffer.from(
			JSON.stringify(rows).replace(
				/[\u007f-\uffff]/g,
				(character) => '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0')
			)
		)
	);
}
function executable(name, environment) {
	for (const directory of (environment.PATH || '/usr/bin:/bin').split(path.delimiter)) {
		if (!path.isAbsolute(directory)) continue;
		const actual = path.join(directory, name);
		try {
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
	log = console.log,
	error = console.error
} = {}) {
	if (process.platform !== 'linux') {
		log('[DEFERRED] Updater archive native qualification requires Linux.');
		return 0;
	}
	let phase = 'prerequisites',
		cancelled = false;
	const deadline = process.hrtime.bigint() + 1800000n * 1000000n;
	const current = () => {
		if (cancelled || process.hrtime.bigint() >= deadline) refused();
	};
	const cancel = () => {
		cancelled = true;
		requestActiveCancellation();
	};
	process.on('SIGTERM', cancel);
	process.on('SIGINT', cancel);
	try {
		current();
		if (
			!path.isAbsolute(root) ||
			!fs.lstatSync(root).isDirectory() ||
			fs.lstatSync(root).isSymbolicLink()
		)
			refused();
		const head = environment.ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD;
		if (!/^[0-9a-f]{40}$/.test(head || '')) refused();
		const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-updater-archive-native-'));
		fs.chmodSync(work, 0o700);
		const env = { ...environment, PYTHONDONTWRITEBYTECODE: '1', LC_ALL: 'C.UTF-8' };
		// A private Git command must never inherit another repository/index target.
		for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
		env.GIT_CONFIG_GLOBAL = '/dev/null';
		env.GIT_CONFIG_NOSYSTEM = '1';
		env.GIT_OPTIONAL_LOCKS = '0'; // Read-only original status cannot refresh its index.
		delete env.LUA_PATH;
		if (environment.ERGOPTI_NATIVE_LUA_CPATH) env.LUA_CPATH = environment.ERGOPTI_NATIVE_LUA_CPATH;
		const ownerRoot = path.join(work, 'owner');
		const inputs = [
			'tools/build/stage-linux-network-runtime.py',
			'tools/lib/git_bash.py',
			'tools/test/run-linux-managed-http-phase.py',
			'tools/__init__.py',
			'tools/test/prepare-linux-updater-archive-snapshot.py',
			'tools/lib/git-bash.cjs',
			'package.json',
			'tools/build/write_build_stamp.sh'
		];
		const identities = {};
		for (const relative of inputs) {
			ordinary(path.join(root, relative));
			const bytes = fs.readFileSync(path.join(root, relative));
			const target = path.join(ownerRoot, relative);
			fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
			fs.writeFileSync(target, bytes, { flag: 'wx', mode: 0o600 });
			identities[relative] = hash(bytes);
			if (hash(fs.readFileSync(path.join(root, relative))) !== hash(bytes)) refused();
		}
		let serial = 0;
		const worker = path.join(ownerRoot, inputs[2]);
		const owner = path.join(ownerRoot, inputs[0]);
		async function child(
			command,
			args,
			childEnv = env,
			cwd = work,
			kind = 'command',
			budgetMs = 120000
		) {
			current();
			const result = await ownPhase({
				command,
				args,
				env: childEnv,
				cwd,
				work,
				label: String(++serial).padStart(2, '0'),
				worker,
				owner,
				ownerSha: identities[inputs[0]],
				kind,
				fixtureSha: kind === 'archive' ? hash(fs.readFileSync(args[1])) : undefined,
				budgetMs,
				gateDeadline: deadline
			});
			current();
			if (!complete(result)) refused();
			return result;
		}
		const observedHead = await child('git', ['-C', root, 'rev-parse', 'HEAD']);
		if (observedHead.stdout !== head + '\n' || observedHead.stderr !== '') refused();
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
			'command',
			180000
		);
		const snapshotReceipt = JSON.parse(
			fs.readFileSync(path.join(snapshot, 'ADMISSION.json'), 'utf8')
		);
		if (
			snapshotReceipt.phase !== 'working-tree-snapshot' ||
			snapshotReceipt.source_head !== head ||
			!/^[0-9a-f]{64}$/.test(snapshotReceipt.inventory_sha256 || '')
		)
			refused();
		for (const relative of inputs) {
			ordinary(path.join(clone, relative));
			if (hash(fs.readFileSync(path.join(clone, relative))) !== identities[relative]) refused();
		}
		const resolver = path.join(root, 'tools/lib/git-bash.cjs');
		// The canonical resolver is the only Bash selector; refuse an unqualified bare fallback.
		if (require.resolve('../lib/git-bash.cjs') !== resolver) refused();
		const resolverCurrent = () => {
			ordinary(resolver);
			if (hash(fs.readFileSync(resolver)) !== identities['tools/lib/git-bash.cjs']) refused();
			current();
		};
		resolverCurrent();
		const { bashExecutable } = require('../lib/git-bash.cjs');
		resolverCurrent();
		const bash = bashExecutable();
		resolverCurrent();
		if (typeof bash !== 'string' || !path.isAbsolute(bash)) refused();
		ordinary(bash);
		fs.accessSync(bash, fs.constants.X_OK);
		const bashBytes = fs.readFileSync(bash);
		if (!bashBytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) refused();
		const bashSha = hash(bashBytes);
		phase = 'actual-curl';
		const modern = environment.ERGOPTI_MANAGED_NATIVE_MODERN_CURL;
		const modernSha = environment.ERGOPTI_MANAGED_NATIVE_MODERN_SHA256;
		if (
			!path.isAbsolute(modern || '') ||
			path.basename(modern) !== 'curl' ||
			!/^[0-9a-f]{64}$/.test(modernSha || '')
		)
			refused();
		ordinary(modern);
		fs.accessSync(modern, fs.constants.X_OK);
		const curlBytes = fs.readFileSync(modern);
		if (
			!curlBytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70])) ||
			hash(curlBytes) !== modernSha
		)
			refused();
		const bin = path.join(work, 'bin');
		fs.mkdirSync(bin, { mode: 0o700 });
		const curl = path.join(bin, 'curl');
		fs.writeFileSync(curl, curlBytes, { flag: 'wx', mode: 0o700 });
		env.PATH = bin + path.delimiter + (environment.PATH || '/usr/bin:/bin');
		const curlVersion = await child(curl, ['--version']);
		const first = curlVersion.stdout.split(/\r?\n/)[0];
		if (
			!/^curl 8\.14\.1(?: |$)/.test(first) ||
			!first.split(/\s+/).includes('libcurl/8.14.1') ||
			curlVersion.stderr !== ''
		)
			refused();
		if (hash(fs.readFileSync(modern)) !== modernSha || hash(fs.readFileSync(curl)) !== modernSha)
			refused();
		phase = 'canonical-build';
		const buildEnv = { ...env };
		// A private source-validation build uses actual admitted repository metadata,
		// never a fabricated release or handwritten stamp. Explicit CI release input wins.
		const versionInputs = ['package.json', 'tools/build/write_build_stamp.sh'];
		const versionCurrent = () => {
			for (const relative of versionInputs) {
				for (const base of [root, ownerRoot, clone]) {
					const filename = path.join(base, relative);
					ordinary(filename);
					if (hash(fs.readFileSync(filename)) !== identities[relative]) refused();
					current();
				}
			}
		};
		versionCurrent();
		const packageBytes = fs.readFileSync(path.join(ownerRoot, 'package.json'));
		if (packageBytes.length > 1048576) refused();
		const providedVersion = environment.ERGOPTI_BUILD_VERSION;
		const fromPackage = providedVersion === undefined || providedVersion === '';
		const version = fromPackage
			? JSON.parse(packageBytes.toString('utf8')).version
			: providedVersion;
		if (
			typeof version !== 'string' ||
			version.length > 128 ||
			/[\0\r\n]/.test(version) ||
			!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(version)
		)
			refused();
		const versionSource = fromPackage ? 'admitted_package_json' : 'explicit_build_input';
		versionCurrent();
		buildEnv.ERGOPTI_BUILD_VERSION = version;
		buildEnv.ERGOPTI_BUILD_COMMIT = head;
		const sdk = environment.ERGOPTI_MANAGED_NATIVE_GIO_SYSROOT;
		if (sdk) {
			if (
				!path.isAbsolute(sdk) ||
				/[\0\r\n]/.test(sdk) ||
				!fs.lstatSync(sdk).isDirectory() ||
				fs.lstatSync(sdk).isSymbolicLink()
			)
				refused();
			buildEnv.PKG_CONFIG_SYSROOT_DIR = sdk;
		}
		// Fresh Git clone supplies exact tracked inputs and genuine original stamp;
		// ignored .so/build outputs never enter it, and only its build/ is mutated.
		resolverCurrent();
		versionCurrent();
		const built = await child(
			bash,
			[path.join(clone, 'tools/build/build-linux-driver.sh')],
			buildEnv,
			clone,
			'command',
			600000
		);
		const payload = path.join(clone, 'build/linux');
		const stampPath = path.join(payload, '_shared/build_stamp.txt');
		ordinary(stampPath);
		if (fs.readFileSync(stampPath, 'utf8') !== 'commit=' + head + '\nversion=' + version + '\n')
			refused();
		versionCurrent();
		const inventory = payloadInventory(payload, current);
		const backend = path.join(payload, 'linux/bin/libergopti_archive_publication.so');
		ordinary(backend);
		if (
			!fs
				.readFileSync(backend)
				.subarray(0, 4)
				.equals(Buffer.from([127, 69, 76, 70]))
		)
			refused();
		fs.writeFileSync(
			path.join(work, 'BUILD-ADMISSION.json'),
			JSON.stringify(
				{
					schema: 1,
					source_head: head,
					source_phase: snapshotReceipt.phase,
					source_inventory_sha256: snapshotReceipt.inventory_sha256,
					build_purpose: 'source_validation',
					build_version: version,
					version_source: versionSource,
					bash_sha256: bashSha,
					builder_sha256: hash(
						fs.readFileSync(path.join(clone, 'tools/build/build-linux-driver.sh'))
					),
					backend_sha256: hash(fs.readFileSync(backend)),
					payload_inventory_sha256: inventory,
					physical_build_closed: complete(built)
				},
				null,
				2
			) + '\n',
			{ flag: 'wx', mode: 0o600 }
		);
		phase = 'certificate';
		const certificate = path.join(work, 'certificate.pem');
		const key = path.join(work, 'key.pem');
		await child('openssl', [
			'req',
			'-x509',
			'-newkey',
			'rsa:2048',
			'-nodes',
			'-keyout',
			key,
			'-out',
			certificate,
			'-days',
			'2',
			'-subj',
			'/CN=127.0.0.1',
			'-addext',
			'subjectAltName=IP:127.0.0.1'
		]);
		ordinary(certificate);
		ordinary(key);
		fs.chmodSync(key, 0o600);
		phase = 'archive';
		const hardware = path.join(clone, 'static/ergopti_plus/linux/tests/hardware');
		const fixture = path.join(hardware, 'run_updater_archive_pipeline.py');
		ordinary(fixture);
		const lua = path.join(hardware, 'run_updater_archive_pipeline.lua');
		ordinary(lua);
		const guardian = path.join(hardware, 'run_native_subreaper.py');
		ordinary(guardian);
		const args = [
			'-B',
			fixture,
			'--payload',
			payload,
			'--expected-payload-inventory',
			inventory,
			'--work',
			path.join(work, 'cases'),
			'--luajit',
			executable('luajit', env),
			'--bash',
			bash,
			'--expected-bash-sha256',
			bashSha,
			'--lua-fixture',
			lua,
			'--expected-lua-sha256',
			hash(fs.readFileSync(lua)),
			'--guardian',
			guardian,
			'--expected-guardian-sha256',
			hash(fs.readFileSync(guardian)),
			'--certificate',
			certificate,
			'--key',
			key
		];
		resolverCurrent();
		versionCurrent();
		const result = await child('python3', args, env, work, 'archive', 600000);
		if (!pipelineReceipt(result) || payloadInventory(payload, current) !== inventory) refused();
		current();
		fs.writeFileSync(
			path.join(work, 'QUALIFICATION.json'),
			JSON.stringify(
				{
					status: 'passed',
					source_head: head,
					source_phase: snapshotReceipt.phase,
					source_inventory_sha256: snapshotReceipt.inventory_sha256,
					build_purpose: 'source_validation',
					build_version: version,
					version_source: versionSource,
					payload_inventory_sha256: inventory,
					source_identities: identities,
					fixture_sha256: hash(fs.readFileSync(fixture)),
					lua_sha256: hash(fs.readFileSync(lua)),
					native_cases: 3,
					native_checks: 15,
					skipped: 0,
					physical_phase_closed: true
				},
				null,
				2
			) + '\n',
			{ flag: 'wx', mode: 0o600 }
		);
		current();
		resolverCurrent();
		versionCurrent();
		log(
			'[OK] Linux updater archive pipeline: 3 actual native cases; 15 checks; 0 skipped; closure complete.'
		);
		return 0;
	} catch {
		error(
			'[FAIL] Linux updater archive native ' +
				phase +
				': admission or physical closure refused; private evidence retained.'
		);
		return 1;
	} finally {
		// Cancelled/retained children remain referenced by the original owner.
		// Never unlink source/payload/key evidence or guess native cleanup.
		if (!hasRetainedPhases()) {
			process.removeListener('SIGTERM', cancel);
			process.removeListener('SIGINT', cancel);
		}
	}
}
if (require.main === module)
	run().then((status) => {
		process.exitCode = status;
	});
module.exports = { run, pipelineReceipt, payloadInventory };
