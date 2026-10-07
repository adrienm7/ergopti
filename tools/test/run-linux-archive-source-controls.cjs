// tools/test/run-linux-archive-source-controls.cjs

/** Owns twelve unchanged source controls through the existing physical phase owner. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { bashExecutable } = require('../lib/git-bash.cjs');
const {
	ownPhase,
	requestActiveCancellation,
	hasRetainedPhases
} = require('./run-linux-managed-http-native.cjs');
const ROOT = path.resolve(__dirname, '../..');
const LABELS = {
	crypto: [
		'missing descriptor refuses',
		'invalid descriptor refuses',
		'implicit transitive crypto is insufficient',
		'relative metadata library path refuses',
		'wrong native SONAME refuses',
		'absent SONAME refuses',
		'ambiguous SONAME refuses',
		'explicit actual-metadata root is retained independently of curl'
	],
	parents: [
		'checkout source bin symlink',
		'release payload bin symlink',
		'installed bin symlink',
		'ordinary recovery'
	],
	snapshot: [],
	connect: []
};
const END = {
	crypto: '8 PASS, 0 FAIL, 0 SKIP; controlled metadata only',
	parents: '4 PASS, 0 FAIL, 0 SKIP; filesystem guard only',
	snapshot: 'Archive snapshot controls: 5 passed; 0 skipped.',
	connect: 'CONNECT terminal protocol controls: 5 passed; 0 skipped; modeled socket/select only.'
};
function receipt(kind, result) {
	if (
		!Object.hasOwn(LABELS, kind) ||
		!result ||
		result.error ||
		result.status !== 0 ||
		result.signal != null ||
		typeof result.stdout !== 'string' ||
		result.stderr !== ''
	)
		return false;
	const expected = [...LABELS[kind].map((label) => 'PASS ' + label), END[kind], ''].join('\n');
	return result.stdout === expected;
}
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
function regular(filename) {
	const fact = fs.lstatSync(filename);
	if (!fact.isFile() || fact.isSymbolicLink() || fact.size > 8 * 1024 * 1024)
		throw new Error('Source refused');
	return fs.readFileSync(filename);
}
function admittedCanonicalBash() {
	const filename = bashExecutable();
	if (!path.isAbsolute(filename)) throw new Error('Absolute canonical Bash required');
	const bytes = regular(filename);
	fs.accessSync(filename, fs.constants.X_OK);
	if (!bytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70])))
		throw new Error('Canonical Bash ELF refused');
	return { filename, bytes };
}
async function run({
	root = ROOT,
	environment = process.env,
	log = console.log,
	error = console.error
} = {}) {
	if (process.platform !== 'linux') {
		log('[DEFERRED] Archive source controls require Linux.');
		return 0;
	}
	let cancelled = false;
	const deadline = process.hrtime.bigint() + 90000000000n;
	const current = () => {
		if (cancelled || process.hrtime.bigint() >= deadline) throw new Error('Admission refused');
	};
	const cancel = () => {
		cancelled = true;
		requestActiveCancellation();
	};
	process.on('SIGTERM', cancel);
	process.on('SIGINT', cancel);
	try {
		current();
		const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-archive-source-controls-'));
		fs.chmodSync(work, 0o700);
		const snapshot = path.join(work, 'source');
		const inputs = [
			'tools/build/stage-linux-network-runtime.py',
			'tools/lib/git_bash.py',
			'tools/__init__.py',
			'tools/test/run-linux-managed-http-phase.py',
			'tools/test/fixtures/linux-explicit-crypto-staging.py',
			'tools/test/fixtures/linux-native-bin-parents.py',
			'static/ergopti_plus/linux/install.sh',
			'tools/test/test-linux-updater-archive-snapshot.py',
			'tools/test/prepare-linux-updater-archive-snapshot.py',
			'tools/test/fixtures/linux-connect-terminal-protocol.py',
			'static/ergopti_plus/linux/tests/hardware/run_managed_http_native.py'
		];
		const identities = new Map();
		for (const relative of inputs) {
			current();
			const bytes = regular(path.join(root, relative));
			const target = path.join(snapshot, relative);
			fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
			fs.writeFileSync(target, bytes, { flag: 'wx', mode: 0o600 });
			identities.set(relative, digest(bytes));
			if (digest(regular(path.join(root, relative))) !== identities.get(relative))
				throw new Error('Source changed');
		}
		// The fixture receives this exact common-resolver ELF and its original hash.
		// It does not select an alternate PATH shell.
		const bash = admittedCanonicalBash();
		const bashSha = digest(bash.bytes);
		const bin = path.join(work, 'bin');
		fs.mkdirSync(bin, { mode: 0o700 });
		fs.writeFileSync(path.join(bin, 'bash'), bash.bytes, { flag: 'wx', mode: 0o700 });
		const env = { ...environment, PYTHONDONTWRITEBYTECODE: '1', LC_ALL: 'C.UTF-8' };
		const worker = path.join(snapshot, 'tools/test/run-linux-managed-http-phase.py');
		const owner = path.join(snapshot, 'tools/build/stage-linux-network-runtime.py');
		const phases = [
			[
				'crypto',
				'tools/test/fixtures/linux-explicit-crypto-staging.py',
				'tools/build/stage-linux-network-runtime.py'
			],
			[
				'parents',
				'tools/test/fixtures/linux-native-bin-parents.py',
				'static/ergopti_plus/linux/install.sh'
			],
			[
				'snapshot',
				'tools/test/test-linux-updater-archive-snapshot.py',
				'tools/test/prepare-linux-updater-archive-snapshot.py'
			],
			[
				'connect',
				'tools/test/fixtures/linux-connect-terminal-protocol.py',
				'static/ergopti_plus/linux/tests/hardware/run_managed_http_native.py'
			]
		];
		for (const [kind, control, source] of phases) {
			current();
			let args = ['-B', path.join(snapshot, control), path.join(snapshot, source)];
			if (kind === 'parents') args.push(path.join(bin, 'bash'), bashSha);
			if (
				kind === 'snapshot' &&
				identities.get(source) !==
					'347375967b5425d22a95aab8c8264a746029479bd450d0220b6984d3a20fbfae'
			)
				throw new Error('Snapshot helper identity refused');
			if (kind === 'snapshot') args.push(identities.get(source));
			if (kind === 'connect') {
				if (
					identities.get(source) !==
					'452ba937f6ac7d995f23c4cb3b49d7d96939dc0ac3c23460bf6c83df42e8db77'
				)
					throw new Error('CONNECT fixture identity refused');
				args = [
					'-B',
					path.join(snapshot, control),
					'--fixture',
					path.join(snapshot, source),
					'--expected-fixture-sha256',
					identities.get(source)
				];
			}
			const result = await ownPhase({
				command: 'python3',
				args,
				env,
				cwd: snapshot,
				work,
				label: kind,
				worker,
				owner,
				ownerSha: identities.get('tools/build/stage-linux-network-runtime.py'),
				kind: 'command',
				budgetMs: kind === 'snapshot' ? 60000 : 30000,
				gateDeadline: deadline
			});
			current();
			if (!receipt(kind, result)) throw new Error('Control or physical closure refused');
		}
		for (const [relative, expected] of identities) {
			current();
			if (
				digest(regular(path.join(root, relative))) !== expected ||
				digest(regular(path.join(snapshot, relative))) !== expected
			)
				throw new Error('Source changed');
		}
		if (
			digest(regular(bash.filename)) !== bashSha ||
			digest(regular(path.join(bin, 'bash'))) !== bashSha
		)
			throw new Error('Canonical Bash changed');
		if (hasRetainedPhases()) throw new Error('Physical phase debt remains');
		current();
		log(
			'[OK] Linux archive source crypto: 8 controls passed; 0 skipped; controlled metadata only.'
		);
		log(
			'[OK] Linux archive source bin parents: 4 controls passed; 0 skipped; filesystem guards only.'
		);
		log(
			'[OK] Linux archive snapshot: 5 controls passed; 0 skipped; actual private Git snapshots only.'
		);
		log(
			'[OK] Linux CONNECT terminal protocol: 5 controls passed; 0 skipped; modeled socket/select only.'
		);
		return 0;
	} catch {
		error('[FAIL] Archive source controls refused; private source/phase evidence retained.');
		return 1;
	} finally {
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
module.exports = { run, receipt };
