// tools/test/run-linux-nix-native.cjs
/** Genuine Nix package admission through the existing physical command owner. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const ROOT = path.resolve(__dirname, '../..');
const PROBE = 'tools/test/fixtures/linux-nix-installed-runtime.lua';
const LABELS = Object.freeze([
	'installed shared root',
	'packaged LuaJIT and luv',
	'installed C backend ABI',
	'native GIO backend and compiled schema',
	'native OpenSSL NIST SHA256'
]);
const SUMMARY =
	'PASS native Nix installed runtime: 7 checks; 0 failed; 0 skipped; source and physical closure admitted.';
const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
function refuse() {
	throw new Error('Nix native admission refused');
}
function bytes(filename, limit = 8 * 1024 * 1024) {
	const fact = fs.lstatSync(filename);
	if (!fact.isFile() || fact.isSymbolicLink() || fact.size > limit) refuse();
	return fs.readFileSync(filename);
}
const NODE_OWNER = 'tools/test/run-linux-managed-http-native.cjs';
const capturedNodeOwner = sha(bytes(path.join(ROOT, NODE_OWNER)));
const {
	ownPhase,
	requestActiveCancellation,
	hasRetainedPhases
} = require('./run-linux-managed-http-native.cjs');
if (sha(bytes(path.join(ROOT, NODE_OWNER))) !== capturedNodeOwner) refuse();
const HELP =
	'Usage: luajit ergopti_hotstrings.lua [OPTIONS]\n\n' +
	'  --config <path>     TOML file or directory of definitions.\n' +
	'                      Default: ~/.config/ergopti/hotstrings/\n' +
	'  --device <path>     evdev device (e.g. /dev/input/event3).\n' +
	'                      Default: auto-detected.\n' +
	'  --layout <name>     Keyboard layout: qwerty | azerty.\n' +
	'                      Default: $XKBLAYOUT, else qwerty.\n' +
	'  --tray              Enable the system tray icon.\n' +
	'  --no-grab           Do NOT take an exclusive grab on the device.\n' +
	'                      Physical keys then reach the application while an\n' +
	'                      expansion is being typed, which can scramble it.\n' +
	'                      Use only if the grab misbehaves on your hardware.\n' +
	'  --dry-run           Log matches without injecting.\n' +
	'  --verbose           Log at debug level for this run.\n' +
	'  --help              Show this message.\n';
function helpReceipt(result) {
	if (!success(result) || result.stderr !== '' || typeof result.stdout !== 'string') return false;
	const header = 'Usage: luajit ergopti_hotstrings.lua [OPTIONS]';
	const lines = result.stdout.split('\n');
	if (lines.filter((line) => line === header).length !== 1) return false;
	const offset = lines.indexOf(header);
	return lines.slice(offset).join('\n') === HELP;
}
function success(result) {
	return !!result && result.status === 0 && result.signal == null && !result.error;
}
function receipt(text, head) {
	return /^[0-9a-f]{40}$/.test(head) && text === `Nix native source: ${head}\n${SUMMARY}\n`;
}
function runtimeReceipt(text) {
	return text === LABELS.map((x) => `PASS ${x}\n`).join('');
}
function cleanEnvironment(original, home, config, tmp) {
	const env = {
		PATH: '/usr/bin:/bin',
		HOME: home,
		XDG_CONFIG_HOME: path.join(home, '.config'),
		XDG_CACHE_HOME: path.join(home, '.cache'),
		NIX_CONF_DIR: config,
		TMPDIR: tmp,
		LC_ALL: 'C.UTF-8',
		PYTHONDONTWRITEBYTECODE: '1'
	};
	// No proxy credentials, ambient Nix config, host Lua/LD or PKG_CONFIG fallbacks.
	if (original.SSL_CERT_FILE) {
		if (!path.isAbsolute(original.SSL_CERT_FILE)) refuse();
		bytes(original.SSL_CERT_FILE);
		env.SSL_CERT_FILE = original.SSL_CERT_FILE;
	}
	return env;
}
function inspectSource(root, paths) {
	const result = {};
	for (const relative of paths) {
		if (
			!relative ||
			path.isAbsolute(relative) ||
			relative.split('/').some((x) => x === '..' || x === '.')
		)
			refuse();
		const filename = path.join(root, relative),
			fact = fs.lstatSync(filename);
		if (fact.isSymbolicLink())
			result[relative] = { kind: 'link', target: fs.readlinkSync(filename) };
		else if (fact.isFile())
			result[relative] = {
				kind: 'file',
				sha256: sha(fs.readFileSync(filename)),
				mode: fact.mode & 511
			};
		else refuse();
	}
	return result;
}
function unchanged(before, after) {
	if (JSON.stringify(before) !== JSON.stringify(after)) refuse();
}
function lockReceipt(value) {
	const lock = value && value.locked;
	if (
		!lock ||
		lock.type !== 'github' ||
		lock.owner !== 'NixOS' ||
		lock.repo !== 'nixpkgs' ||
		!/^[0-9a-f]{40}$/.test(lock.rev) ||
		!/^sha256-[A-Za-z0-9+/]{43}=$/.test(lock.narHash)
	)
		refuse();
	return { revision: lock.rev, narHash: lock.narHash };
}
function outputReceipt(value) {
	if (
		!Array.isArray(value) ||
		value.length !== 1 ||
		typeof value[0].drvPath !== 'string' ||
		!/^\/nix\/store\/[a-z0-9]{32}-[^/]+\.drv$/.test(value[0].drvPath)
	)
		refuse();
	const outputs = value[0].outputs;
	if (
		!outputs ||
		Object.keys(outputs).join(',') !== 'out' ||
		typeof outputs.out !== 'string' ||
		!/^\/nix\/store\/[a-z0-9]{32}-[^/]*ergopti[^/]*$/.test(outputs.out)
	)
		refuse();
	return outputs.out;
}
async function run({
	root = ROOT,
	environment = process.env,
	log = console.log,
	error = console.error
} = {}) {
	if (process.platform !== 'linux') {
		error('[FAIL] Genuine Nix native admission requires Linux; no credit.');
		return 1;
	}
	let cancelled = false;
	const cancel = () => {
		cancelled = true;
		requestActiveCancellation();
	};
	process.on('SIGTERM', cancel);
	process.on('SIGINT', cancel);
	const deadline = process.hrtime.bigint() + 1800000000000n;
	const current = () => {
		if (cancelled || process.hrtime.bigint() >= deadline) refuse();
	};
	let work;
	// Public diagnostics use only lexical checkpoint literals; no private input.
	let checkpoint = 'source-admission';
	try {
		current();
		const head = environment.ERGOPTI_NIX_EXPECTED_HEAD || environment.GITHUB_SHA;
		if (!/^[0-9a-f]{40}$/.test(head || '')) refuse();
		checkpoint = 'workspace';
		const temp = environment.TMPDIR || os.tmpdir();
		if (!path.isAbsolute(temp)) refuse();
		work = fs.mkdtempSync(path.join(temp, 'ergopti-nix-native-'));
		fs.chmodSync(work, 0o700);
		const home = path.join(work, 'home'),
			config = path.join(work, 'config'),
			tmp = path.join(work, 'tmp');
		for (const directory of [home, config, tmp]) fs.mkdirSync(directory, { mode: 0o700 });
		fs.writeFileSync(
			path.join(config, 'nix.conf'),
			'experimental-features = nix-command flakes\nbuild-users-group =\nsandbox = false\nrequire-sigs = true\naccept-flake-config = false\n',
			{ flag: 'wx', mode: 0o600 }
		);
		checkpoint = 'local-store';
		// CI prepares a standard single-user LOCAL store; this runner never adopts a daemon.
		for (const directory of ['/nix/store', '/nix/var/nix']) {
			const fact = fs.lstatSync(directory);
			if (
				!fact.isDirectory() ||
				fact.isSymbolicLink() ||
				fact.uid !== process.getuid() ||
				fact.mode & 2
			)
				refuse();
			fs.accessSync(directory, fs.constants.W_OK | fs.constants.X_OK);
		}
		checkpoint = 'native-cli';
		const nix = fs.realpathSync('/usr/bin/nix'),
			nixBytes = bytes(nix);
		fs.accessSync(nix, fs.constants.X_OK);
		if (!nixBytes.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) refuse();
		if (
			path.resolve(root) !== ROOT ||
			sha(bytes(path.join(root, NODE_OWNER))) !== capturedNodeOwner
		)
			refuse();
		checkpoint = 'execution-source';
		const snapshot = path.join(work, 'execution-source');
		fs.mkdirSync(snapshot, { mode: 0o700 });
		const inputs = [
			'tools/test/run-linux-managed-http-phase.py',
			'tools/build/stage-linux-network-runtime.py',
			'tools/lib/git_bash.py',
			'tools/__init__.py',
			PROBE
		];
		const inputHashes = {};
		for (const relative of inputs) {
			const raw = bytes(path.join(root, relative)),
				copied = path.join(snapshot, relative);
			inputHashes[relative] = sha(raw);
			fs.mkdirSync(path.dirname(copied), { recursive: true, mode: 0o700 });
			fs.writeFileSync(copied, raw, { flag: 'wx', mode: 0o600 });
			if (
				sha(bytes(copied)) !== inputHashes[relative] ||
				sha(bytes(path.join(root, relative))) !== inputHashes[relative]
			)
				refuse();
		}
		function executionCurrent() {
			current();
			if (sha(bytes(path.join(root, NODE_OWNER))) !== capturedNodeOwner) refuse();
			for (const relative of inputs) {
				if (
					sha(bytes(path.join(root, relative))) !== inputHashes[relative] ||
					sha(bytes(path.join(snapshot, relative))) !== inputHashes[relative]
				)
					refuse();
			}
		}
		const identities = {
			nix: sha(nixBytes),
			worker: inputHashes[inputs[0]],
			owner: inputHashes[inputs[1]],
			probe: inputHashes[PROBE]
		};
		const env = cleanEnvironment(environment, home, config, tmp);
		let serial = 0;
		async function phase(command, args, extra = {}, budgetMs = 60000) {
			executionCurrent();
			const result = await ownPhase({
				command,
				args,
				env: { ...env, ...extra },
				cwd: work,
				work,
				label: String(++serial).padStart(2, '0'),
				worker: path.join(snapshot, 'tools/test/run-linux-managed-http-phase.py'),
				owner: path.join(snapshot, 'tools/build/stage-linux-network-runtime.py'),
				ownerSha: identities.owner,
				kind: 'command',
				budgetMs,
				gateDeadline: deadline
			});
			executionCurrent();
			if (!success(result) || hasRetainedPhases()) refuse();
			if (
				sha(bytes(nix)) !== identities.nix ||
				sha(bytes(path.join(root, 'tools/test/run-linux-managed-http-phase.py'))) !==
					identities.worker ||
				sha(bytes(path.join(root, 'tools/build/stage-linux-network-runtime.py'))) !==
					identities.owner
			)
				refuse();
			return result;
		}
		async function git(args) {
			return (await phase('/usr/bin/git', ['-C', root, ...args], { GIT_OPTIONAL_LOCKS: '0' }))
				.stdout;
		}
		checkpoint = 'checkout';
		if (
			(await git(['rev-parse', 'HEAD'])) !== head + '\n' ||
			(await git(['status', '--porcelain=v1', '--untracked-files=all'])) !== ''
		)
			refuse();
		const tracked = (await git(['ls-files', '-z'])).split('\0');
		if (
			tracked.pop() !== '' ||
			new Set(tracked).size !== tracked.length ||
			!tracked.includes(PROBE)
		)
			refuse();
		const source = inspectSource(root, tracked);
		if (!source[NODE_OWNER] || source[NODE_OWNER].sha256 !== capturedNodeOwner) refuse();
		for (const relative of inputs)
			if (!source[relative] || source[relative].sha256 !== inputHashes[relative]) refuse();
		fs.writeFileSync(path.join(work, 'SOURCE.json'), JSON.stringify({ head, files: source }), {
			flag: 'wx',
			mode: 0o600
		});
		checkpoint = 'cli-version';
		const version = await phase(nix, ['--version']);
		if (
			version.stderr !== '' ||
			!/^nix \(Nix\) (2\.(?:[4-9]|[1-9][0-9]+)|[3-9]\.\d+)(?:\.[0-9]+)?\n$/.test(version.stdout)
		)
			refuse();
		const prefix = ['--store', 'local'];
		checkpoint = 'nixpkgs-metadata';
		const metadata = await phase(
			nix,
			[
				...prefix,
				'flake',
				'metadata',
				'github:NixOS/nixpkgs/nixos-unstable',
				'--json',
				'--no-write-lock-file'
			],
			{},
			180000
		);
		const pinned = lockReceipt(JSON.parse(metadata.stdout));
		const flake = `git+file://${root}?dir=tools/build/nix&rev=${head}`;
		const override = [
			'--override-input',
			'nixpkgs',
			`github:NixOS/nixpkgs/${pinned.revision}`,
			'--no-write-lock-file'
		];
		checkpoint = 'pinned-source-metadata';
		const pinnedMetadata = await phase(
			nix,
			[...prefix, 'flake', 'metadata', flake, ...override, '--json'],
			{},
			180000
		);
		checkpoint = 'pinned-source-json';
		const resolved = JSON.parse(pinnedMetadata.stdout);
		checkpoint = 'pinned-source-routing';
		const nodes = resolved.locks && resolved.locks.nodes,
			rootNode = nodes && nodes[resolved.locks.root];
		const reference = rootNode && rootNode.inputs && rootNode.inputs.nixpkgs;
		if (typeof reference !== 'string' || !nodes[reference]) refuse();
		checkpoint = 'pinned-source-input-lock';
		const actual = lockReceipt({ locked: nodes[reference].locked });
		checkpoint = 'pinned-source-pin-agreement';
		if (
			actual.revision !== pinned.revision ||
			actual.narHash !== pinned.narHash ||
			!resolved.locked ||
			resolved.locked.rev !== head
		)
			refuse();
		checkpoint = 'native-build';
		const build = await phase(
			nix,
			[
				...prefix,
				'build',
				`${flake}#packages.x86_64-linux.ergopti`,
				...override,
				'--json',
				'--out-link',
				path.join(work, 'result')
			],
			{},
			1200000
		);
		const out = outputReceipt(JSON.parse(build.stdout)),
			wrapper = path.join(out, 'bin/ergopti-hotstrings');
		const wrapperHash = sha(bytes(wrapper));
		fs.accessSync(wrapper, fs.constants.X_OK);
		checkpoint = 'installed-help';
		const help = await phase(wrapper, ['--help']);
		if (!helpReceipt(help)) refuse();
		// Read-only qualification startup runs under the unchanged generated wrapper.
		checkpoint = 'installed-runtime';
		const probe = await phase(wrapper, ['--help'], {
			LUA_INIT: '@' + path.join(snapshot, PROBE),
			ERGOPTI_NIX_PACKAGE_ROOT: out
		});
		if (probe.stderr !== '' || !runtimeReceipt(probe.stdout)) refuse();
		checkpoint = 'final-source-and-closure';
		unchanged(source, inspectSource(root, tracked));
		if (
			(await git(['status', '--porcelain=v1', '--untracked-files=all'])) !== '' ||
			(await git(['rev-parse', 'HEAD'])) !== head + '\n' ||
			sha(bytes(wrapper)) !== wrapperHash ||
			sha(bytes(path.join(root, PROBE))) !== identities.probe
		)
			refuse();
		if (hasRetainedPhases()) refuse();
		current();
		checkpoint = 'receipt-publication';
		fs.writeFileSync(
			path.join(work, 'ADMISSION.json'),
			JSON.stringify({
				schema: 1,
				head,
				nix_sha256: identities.nix,
				nix_version: version.stdout.trim(),
				nixpkgs: pinned,
				out,
				wrapper_sha256: wrapperHash,
				probe_sha256: identities.probe,
				checks: 7,
				skipped: 0,
				physical_closed: true
			}) + '\n',
			{ flag: 'wx', mode: 0o600 }
		);
		executionCurrent();
		if (hasRetainedPhases()) refuse();
		log(`Nix native source: ${head}`);
		log(SUMMARY);
		return 0;
	} catch {
		error(
			'[FAIL] Nix native source/build/runtime or physical closure refused; private inputs retained.'
		);
		// The fixed GitHub annotation is readable even when private phase logs
		// are unavailable. It cannot publish raw stderr, paths or environment.
		error(`::error::Nix native admission failed at checkpoint=${checkpoint}; no native credit.`);
		return 1;
	} finally {
		if (!hasRetainedPhases()) {
			process.removeListener('SIGTERM', cancel);
			process.removeListener('SIGINT', cancel);
		}
	}
}
if (require.main === module) {
	if (process.argv[2] === '--evidence' && process.argv.length === 5) {
		try {
			if (!receipt(bytes(process.argv[3], 4096).toString('utf8'), process.argv[4])) refuse();
			process.stdout.write('7\n');
		} catch {
			process.stderr.write('[FAIL] Nix native evidence refused.\n');
			process.exitCode = 1;
		}
	} else if (process.argv.length !== 2) {
		process.stderr.write('[FAIL] Nix native arguments refused.\n');
		process.exitCode = 1;
	} else
		run().then((status) => {
			process.exitCode = status;
		});
}
module.exports = {
	run,
	receipt,
	runtimeReceipt,
	cleanEnvironment,
	lockReceipt,
	outputReceipt,
	inspectSource,
	unchanged,
	helpReceipt,
	HELP,
	LABELS,
	SUMMARY
};
