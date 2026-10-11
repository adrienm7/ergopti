'use strict';

// Independent calibration consistency. Official receiving and kernel executable
// identity require separate evidence; no process or trust command runs here.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const baseSource = require('../diagnostics/native_pac_source_evidence.cjs');
const MAC = 'static/ergopti_plus/macos/';
const SWIFT = Object.freeze([
	...[
		'ManagedHTTPWorker.swift',
		'ManagedPACSource.swift',
		'ManagedCertificateAuthorities.swift',
		'ManagedBootstrapPolicy.generated.swift'
	].map((name) => MAC + 'launcher/Sources/ErgoptiPlus/' + name),
	MAC + 'tests/support/native_http_fixture_main.swift'
]);
const HEADERS = Object.freeze(
	[
		'CPOSIXCompatibility.h',
		'OwnedProgramCompatibility.h',
		'LoopbackListenerCompatibility.h',
		'OwnedImageAliasCompatibility.h',
		'OwnedSuspendedImageCompatibility.h',
		'OwnedListenerEventCompatibility.h'
	].map((name) => MAC + 'launcher/Sources/CPOSIXCompatibility/include/' + name)
);
const RUNTIME = Object.freeze([
	MAC + 'platform/network/native_http.py',
	MAC + 'platform/network/managed_http.py',
	'static/ergopti_plus/_shared/python/network_proxy_policy.py',
	'static/ergopti_plus/_shared/modules/network/proxy_policy.json'
]);
const OWNERS = Object.freeze([
	MAC + 'tests/support/native_http_fixture_builder.py',
	MAC + 'tests/support/native_http_wire_fixture.py',
	'tools/diagnostics/macos_owned_process.py'
]);
const RECEIVER = MAC + 'tests/support/native_http_wire_client_receiving.py';
const INPUTS = Object.freeze([...SWIFT, ...HEADERS, ...RUNTIME, ...OWNERS, RECEIVER]);
const LOADERS = Object.freeze([
	'.github/workflows/ci.yml',
	'.github/workflows/ci-macos.yml',
	'tools/ci/native_http_clock_evidence.cjs',
	'tools/ci/dev-release-qualification.cjs',
	'.github/ci/dev_release_qualification_exceptions.json',
	'.github/ci/stable_release_qualification_exception.json',
	'tools/test/export-macos-managed-http-test-deps.py',
	MAC + 'uv.lock'
]);
const MODULE_MAP = Buffer.from(
	'module CPOSIXCompatibility {\n  umbrella header "CPOSIXCompatibility.h"\n  export *\n}\n'
);
const PAYLOAD = Object.freeze([
	'compile.json',
	'sign.json',
	'strict_verify.json',
	'clock.json',
	'clock-frame.bin',
	'image.bin',
	'source-receipt.json',
	'clock-receipt.json',
	'python-loader.json'
]);
function requireFact(condition, reason) {
	if (!condition) throw new Error(reason);
}
function sha(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}
function canonical(value) {
	if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
	if (value !== null && typeof value === 'object')
		return (
			'{' +
			Object.keys(value)
				.sort()
				.map((key) => JSON.stringify(key) + ':' + canonical(value[key]))
				.join(',') +
			'}'
		);
	return JSON.stringify(value);
}
function exact(actual, expected, reason) {
	requireFact(canonical(actual) === canonical(expected), reason);
}
function plain(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function keys(value, names, reason) {
	requireFact(plain(value), reason);
	exact(Object.keys(value).sort(), [...names].sort(), reason);
}
function regularBytes(file, maximum = 8388608) {
	const absolute = path.resolve(file);
	for (let parent = path.dirname(absolute); ; parent = path.dirname(parent)) {
		requireFact(
			fs.lstatSync(parent).isDirectory() && !fs.lstatSync(parent).isSymbolicLink(),
			'Directory alias refused'
		);
		if (path.dirname(parent) === parent) break;
	}
	const named = fs.lstatSync(absolute, { bigint: true });
	requireFact(
		named.isFile() && named.nlink === 1n && named.size <= BigInt(maximum),
		'Regular single-name input refused'
	);
	const fd = fs.openSync(
		absolute,
		fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK
	);
	try {
		const before = fs.fstatSync(fd, { bigint: true });
		requireFact(
			before.isFile() &&
				before.nlink === 1n &&
				before.dev === named.dev &&
				before.ino === named.ino &&
				before.size <= BigInt(maximum),
			'Input acquisition changed'
		);
		const bytes = Buffer.alloc(Number(before.size) + 1);
		let count = 0;
		while (count < bytes.length) {
			const n = fs.readSync(fd, bytes, count, bytes.length - count, null);
			if (!n) break;
			count += n;
		}
		const after = fs.fstatSync(fd, { bigint: true }),
			final = fs.lstatSync(absolute, { bigint: true });
		requireFact(
			after.isFile() &&
				final.isFile() &&
				after.nlink === 1n &&
				final.nlink === 1n &&
				count === Number(before.size),
			'Input type/size changed'
		);
		for (const field of ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'])
			requireFact(
				before[field] === after[field] && after[field] === final[field],
				'Input changed while reading'
			);
		return bytes.subarray(0, count);
	} finally {
		fs.closeSync(fd);
	}
}
// Validate the JSON token tree independently before JSON.parse. Duplicate keys
// (including escaped aliases) and malformed/nonfinite JSON never get last-wins.
const numericTokens = new WeakMap();
function integerToken(root, ...route) {
	return numericTokens.get(root)?.has(JSON.stringify(route)) === true;
}
function uniqueJSON(bytes, maximum = 1048576) {
	requireFact(Buffer.isBuffer(bytes) && bytes.length <= maximum, 'JSON bound refused');
	const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
	let cursor = 0;
	const integers = new Set();
	function space() {
		while (/\s/.test(text[cursor] || '') && /[\x20\x09\x0a\x0d]/.test(text[cursor])) cursor++;
	}
	function string() {
		const start = cursor++;
		while (cursor < text.length) {
			const code = text.charCodeAt(cursor++);
			if (code === 34) return JSON.parse(text.slice(start, cursor));
			requireFact(code >= 32, 'JSON control refused');
			if (code === 92) {
				requireFact(cursor < text.length, 'JSON escape refused');
				cursor++;
			}
		}
		throw new Error('JSON string incomplete');
	}
	function value(depth, route = []) {
		requireFact(depth <= 32, 'JSON depth refused');
		space();
		const token = text[cursor];
		if (token === '"') {
			string();
			return;
		}
		if (token === '{' || token === '[') {
			cursor++;
			space();
			const end = token === '{' ? '}' : ']';
			const seen = new Set();
			if (text[cursor] === end) {
				cursor++;
				return;
			}
			let index = 0;
			for (;;) {
				let member = index;
				if (token === '{') {
					requireFact(text[cursor] === '"', 'JSON key refused');
					const key = string();
					member = key;
					requireFact(!seen.has(key), 'JSON duplicate field refused');
					seen.add(key);
					space();
					requireFact(text[cursor++] === ':', 'JSON separator refused');
				}
				value(depth + 1, [...route, member]);
				index++;
				space();
				if (text[cursor] === end) {
					cursor++;
					return;
				}
				requireFact(text[cursor++] === ',', 'JSON collection refused');
				space();
			}
		}
		const match = /^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/.exec(
			text.slice(cursor)
		);
		requireFact(match, 'JSON token refused');
		if (/^-?(?:0|[1-9][0-9]*)$/.test(match[0])) integers.add(JSON.stringify(route));
		cursor += match[0].length;
	}
	value(0);
	space();
	requireFact(cursor === text.length, 'JSON trailing input refused');
	const result = JSON.parse(text);
	function finite(value) {
		if (typeof value === 'number') requireFact(Number.isFinite(value), 'JSON nonfinite refused');
		if (value !== null && typeof value === 'object')
			for (const nested of Object.values(value)) finite(nested);
	}
	finite(result);
	if (result !== null && typeof result === 'object') numericTokens.set(result, integers);
	return result;
}
function sourceReceipt(repository, epoch) {
	const admitted = baseSource.context(
		epoch.candidate,
		epoch.run_id,
		epoch.run_attempt,
		epoch.architecture
	);
	const original = baseSource.sourceReceipt(repository, admitted);
	const implicitCache = {};
	const implicit = execFileSync(
		'git',
		[
			'ls-files',
			'--others',
			'-z',
			'--',
			MAC + 'tests/support',
			'tools/diagnostics',
			MAC + 'platform/network',
			'static/ergopti_plus/_shared/python'
		],
		{ cwd: repository, stdio: 'pipe' }
	)
		.toString()
		.split('\0')
		.filter(Boolean);
	for (const relative of implicit) {
		const match =
			/^(.*)\/__pycache__\/([A-Za-z0-9_]+)\.cpython-[0-9]{2,3}(?:\.opt-[12])?\.pyc$/.exec(relative);
		requireFact(match, 'Unbound Python shadow input refused');
		execFileSync('git', ['ls-files', '--error-unmatch', '--', match[1] + '/' + match[2] + '.py'], {
			cwd: repository,
			stdio: 'pipe'
		});
		implicitCache[relative] = sha(regularBytes(path.join(repository, relative)));
	}

	const sources = {},
		loaders = {};
	for (const [inputs, output] of [
		[Object.keys(original.sources), {}],
		[INPUTS, sources],
		[LOADERS, loaders]
	])
		for (const relative of inputs) {
			execFileSync('git', ['ls-files', '--error-unmatch', '--', relative], {
				cwd: repository,
				stdio: 'pipe'
			});
			const actual = regularBytes(path.join(repository, relative));
			const committed = execFileSync('git', ['show', admitted.candidate + ':' + relative], {
				cwd: repository,
				stdio: 'pipe',
				maxBuffer: 8388608
			});
			requireFact(actual.equals(committed), 'Candidate source bytes diverged');
			output[relative] = sha(actual);
			if (Object.hasOwn(original.sources, relative))
				requireFact(
					output[relative] === original.sources[relative],
					'Original source bytes changed'
				);
		}
	// Recheck HEAD, whole tracked cleanliness and original independent inventories
	// after acquiring every additional input. The historical 402-input procedure
	// and independent inventories are unchanged; candidate counts are received.
	exact(
		baseSource.sourceReceipt(repository, admitted),
		original,
		'Original source acquisition changed'
	);
	return {
		schema: 1,
		scope: 'native-http-clock-inputs',
		...admitted,
		original_source: original,
		sources,
		loaders,
		identified_unused_default_cache: implicitCache
	};
}
function frame(raw, before, after) {
	requireFact(
		Buffer.isBuffer(raw) &&
			raw.length >= 1 &&
			raw.length <= 4096 &&
			raw.at(-1) === 10 &&
			[...raw].filter((value) => value === 10).length === 1 &&
			[...raw].every((value) => value <= 127),
		'Clock raw frame refused'
	);
	requireFact(
		typeof before === 'number' &&
			Number.isFinite(before) &&
			typeof after === 'number' &&
			Number.isFinite(after) &&
			0 < before &&
			before <= after &&
			after - before <= 15,
		'Clock bracket refused'
	);
	const parsed = uniqueJSON(raw, 4096);
	keys(parsed, ['version', 'system_uptime'], 'Clock grammar refused');
	requireFact(
		integerToken(parsed, 'version') &&
			parsed.version === 1 &&
			Array.isArray(parsed.system_uptime) &&
			parsed.system_uptime.length === 16,
		'Exact sixteen samples refused'
	);
	parsed.system_uptime.forEach((sample, index) =>
		requireFact(
			typeof sample === 'number' &&
				Number.isFinite(sample) &&
				before <= sample &&
				sample <= after &&
				(!index || sample >= parsed.system_uptime[index - 1]),
			'Clock sample epoch/order refused'
		)
	);
	return parsed.system_uptime;
}
function commandFact(fact) {
	keys(
		fact,
		[
			'version',
			'command',
			'exit_status',
			'original_failed',
			'literal_true_settlement',
			'stdin_closed',
			'stderr_closed',
			'stdout_closed',
			'command_group_debt',
			'command_file_debt',
			'owner'
		],
		'Command observation shape refused'
	);
	exact(fact.command, { phase: 'complete', status: 0 }, 'Original command failed');
	requireFact(
		integerToken(fact, 'version') &&
			integerToken(fact, 'command', 'status') &&
			integerToken(fact, 'exit_status') &&
			fact.version === 1 &&
			fact.exit_status === 0 &&
			fact.original_failed === false &&
			fact.literal_true_settlement === true &&
			fact.stdin_closed === true &&
			fact.stderr_closed === true &&
			fact.stdout_closed === true &&
			fact.command_group_debt === false &&
			fact.command_file_debt === false,
		'Command retirement/capture facts refused'
	);
	keys(
		fact.owner,
		[
			'worker_pid',
			'group_id',
			'closed',
			'reservation_lost',
			'signals',
			'live_group_members',
			'escaped_sessions_managed'
		],
		'Original owner receipt shape refused'
	);
	const owner = fact.owner;
	requireFact(
		integerToken(fact, 'owner', 'worker_pid') &&
			integerToken(fact, 'owner', 'group_id') &&
			Number.isSafeInteger(owner.worker_pid) &&
			owner.worker_pid > 0 &&
			owner.group_id === owner.worker_pid &&
			owner.closed === true &&
			owner.reservation_lost === false &&
			owner.escaped_sessions_managed === false &&
			Array.isArray(owner.signals) &&
			owner.signals.length <= 2 &&
			owner.signals.every(
				(value, index) =>
					integerToken(fact, 'owner', 'signals', index) && (value === 15 || value === 9)
			),
		'Original owner receipt refused'
	);
	exact(owner.live_group_members, [], 'Original owner group remains live');
	return fact;
}
function privateCache(directory) {
	const file = path.resolve(directory);
	requireFact(fs.realpathSync(file) === file, 'Private cache directory alias refused');
	const before = fs.lstatSync(file),
		contents = fs.readdirSync(file),
		after = fs.lstatSync(file);
	requireFact(
		before.isDirectory() &&
			(before.mode & 0o777) === 0o700 &&
			contents.length === 0 &&
			after.isDirectory() &&
			before.dev === after.dev &&
			before.ino === after.ino,
		'Private cache admission refused'
	);
	requireFact(
		Number.isSafeInteger(before.dev) && Number.isSafeInteger(before.ino),
		'Private cache identity range refused'
	);
	return { device: before.dev, inode: before.ino, empty: true };
}
function pythonLoader(fact, cache) {
	keys(
		fact,
		[
			'version',
			'isolated',
			'ignore_environment',
			'no_user_site',
			'dont_write_bytecode',
			'safe_path',
			'cache_empty',
			'cache_device',
			'cache_inode'
		],
		'Python loader observation refused'
	);
	for (const field of [
		'version',
		'isolated',
		'ignore_environment',
		'no_user_site',
		'cache_device',
		'cache_inode'
	])
		requireFact(integerToken(fact, field), 'Python loader integer-token refused');
	requireFact(
		fact.version === 1 &&
			fact.isolated === 1 &&
			fact.ignore_environment === 1 &&
			fact.no_user_site === 1 &&
			fact.dont_write_bytecode === true &&
			fact.safe_path === true &&
			fact.cache_empty === true &&
			cache?.empty === true &&
			fact.cache_device === cache.device &&
			fact.cache_inode === cache.inode,
		'Python private loader context changed'
	);
	return fact;
}
function payloadReceipt(directory, source) {
	const entries = fs.readdirSync(directory).sort();
	exact(entries, [...PAYLOAD].sort(), 'Payload inventory refused');
	const bytes = Object.fromEntries(
		PAYLOAD.map((name) => [name, regularBytes(path.join(directory, name))])
	);
	const loader = pythonLoader(uniqueJSON(bytes['python-loader.json']), source.private_cache);
	const commands = Object.fromEntries(
		['compile', 'sign', 'strict_verify', 'clock'].map((role) => [
			role,
			commandFact(uniqueJSON(bytes[role + '.json']))
		])
	);
	const original = uniqueJSON(bytes['source-receipt.json']),
		clock = uniqueJSON(bytes['clock-receipt.json']);
	keys(
		original,
		['version', 'source_hashes', 'staged_hashes', 'binary_sha256', 'device', 'inode'],
		'Original build receipt shape refused'
	);
	requireFact(
		integerToken(original, 'version') &&
			integerToken(original, 'device') &&
			integerToken(original, 'inode') &&
			original.version === 1 &&
			Number.isSafeInteger(original.device) &&
			original.device >= 0 &&
			Number.isSafeInteger(original.inode) &&
			original.inode > 0,
		'Original image identity refused'
	);
	const recipe = Object.fromEntries(
		[...SWIFT, ...HEADERS, ...RUNTIME, ...OWNERS].map((relative) => [
			relative,
			source.sources[relative]
		])
	);
	exact(original.source_hashes, recipe, 'Original eighteen source recipe refused');
	const staged = Object.fromEntries([
		...SWIFT.map((relative) => [path.posix.basename(relative), recipe[relative]]),
		...HEADERS.map((relative) => [
			'CPOSIXCompatibility/' + path.posix.basename(relative),
			recipe[relative]
		]),
		...RUNTIME.map((relative) => [
			'OwnedNativeHTTPFixture.app/Contents/Resources/' + relative,
			recipe[relative]
		]),
		['CPOSIXCompatibility/module.modulemap', sha(MODULE_MAP)]
	]);
	exact(original.staged_hashes, staged, 'Original staged sixteen mapping refused');
	const image = bytes['image.bin'],
		cpu = source.architecture === 'arm64' ? 0x0100000c : 0x01000007;
	requireFact(
		image.length >= 32 &&
			image.readUInt32LE(0) === 0xfeedfacf &&
			image.readUInt32LE(4) === cpu &&
			sha(image) === original.binary_sha256,
		'Original image hash/architecture refused'
	);
	keys(
		clock,
		[
			'version',
			'state',
			'native_acceptance',
			'git_head',
			'tracked_clean_sources',
			'epoch',
			'context_bound',
			'python_before',
			'python_after',
			'system_uptime',
			'source_receipt_sha256',
			'source_hashes',
			'staged_hashes',
			'receiver_sha256',
			'binary_sha256',
			'device',
			'inode',
			'architecture',
			'signature'
		],
		'Clock receipt shape refused'
	);
	requireFact(
		integerToken(clock, 'version') &&
			integerToken(clock, 'device') &&
			integerToken(clock, 'inode') &&
			clock.version === 1 &&
			clock.state === 'observed' &&
			clock.context_bound === true &&
			clock.native_acceptance === 'UNQUALIFIED_GIT_HEAD_CLEANLINESS_NOT_RECEIVED' &&
			clock.git_head === null &&
			clock.tracked_clean_sources === null,
		'Clock receipt provenance refused'
	);
	exact(
		clock.epoch,
		{
			candidate: source.candidate,
			run_id: source.run_id,
			run_attempt: source.run_attempt,
			architecture: source.architecture,
			provenance: 'github_environment'
		},
		'Clock original run epoch refused'
	);
	exact(
		clock.system_uptime,
		frame(bytes['clock-frame.bin'], clock.python_before, clock.python_after),
		'Clock original samples changed'
	);
	for (const field of ['source_hashes', 'staged_hashes', 'binary_sha256', 'device', 'inode'])
		exact(clock[field], original[field], 'Original clock/build identity diverged');
	requireFact(
		clock.source_receipt_sha256 === sha(bytes['source-receipt.json']) &&
			clock.receiver_sha256 === source.sources[RECEIVER] &&
			clock.architecture === source.architecture &&
			clock.signature === 'existing_build_codesign_strict_verified_same_image',
		'Clock original source/image receipt diverged'
	);
	return {
		schema: 1,
		scope: 'native-http-clock-consistency',
		source_consistent: true,
		original_source_input_count: Object.keys(source.original_source?.sources || {}).length,
		calibration_samples_observed: 16,
		source,
		command_observations: commands,
		python_loader_observation: loader,
		python_interpreter_identity: 'UNKNOWN_EXTERNAL_INTERPRETER_NOT_ATTESTED',
		default_cache_execution:
			'NOT_ESTABLISHED_BY_IDENTIFIED_DEFAULT_CACHE_HASHES; PRIVATE_PREFIX_OBSERVATIONS_RECEIVED',
		payload_sha256: Object.fromEntries(PAYLOAD.map((name) => [name, sha(bytes[name])])),
		original_image: {
			sha256: original.binary_sha256,
			device: original.device,
			inode: original.inode,
			architecture: source.architecture
		},
		signature_evidence: 'SOURCE_PINNED_SIGN_AND_STRICT_VERIFY_COMMAND_STATUS_OBSERVATIONS',
		compiler_identity: 'UNKNOWN_EXTERNAL_TOOLCHAIN_NOT_ATTESTED',
		native_acceptance: 'PENDING_AUTHENTICATED_OFFICIAL_RUN_ARTIFACT_RECEIVING',
		kernel_executable_identity: 'UNKNOWN_NOT_ESTABLISHED_BY_PATH_HASH_OR_PROCESS_RECEIPT',
		swift_factory_activation: 'HELD'
	};
}
function officialConsistency(verdict, run, artifact, job, archive, receiving) {
	requireFact(
		verdict.source_consistent === true && verdict.scope === 'native-http-clock-consistency',
		'Clock verdict unavailable'
	);
	const epoch = verdict.source,
		candidate = epoch.candidate;
	requireFact(
		run.id !== undefined &&
			String(run.id) === epoch.run_id &&
			String(run.run_attempt) === epoch.run_attempt &&
			run.head_sha === candidate &&
			run.event === 'workflow_dispatch' &&
			run.path === '.github/workflows/ci.yml' &&
			run.head_branch === 'codex/ci-validation' &&
			run.repository?.full_name === 'adrienm7/ergopti' &&
			run.status === 'completed',
		'Official run consistency refused'
	);
	requireFact(
		String(artifact.workflow_run?.id) === epoch.run_id &&
			artifact.workflow_run?.head_sha === candidate &&
			artifact.name ===
				`native-http-clock-${epoch.architecture}-${epoch.run_id}-${epoch.run_attempt}` &&
			artifact.expired === false &&
			artifact.digest === 'sha256:' + sha(archive),
		'Official artifact consistency refused'
	);
	requireFact(
		String(job.run_id) === epoch.run_id &&
			job.head_sha === candidate &&
			job.status === 'completed' &&
			job.name === `Managed Ollama native · ${epoch.architecture}` &&
			job.conclusion !== 'skipped' &&
			job.conclusion !== 'cancelled',
		'Official job consistency refused'
	);
	requireFact(
		receiving?.job_api_path ===
			`/repos/adrienm7/ergopti/actions/runs/${epoch.run_id}/attempts/${epoch.run_attempt}/jobs`,
		'Attempt-scoped job receiving path refused'
	);
	// Pure data comparison is never authenticated API receiving. The parent must
	// retain actual HTTPS API responses, redirect/download hashes and safe extraction.
	return {
		schema: 1,
		official_metadata_consistent: true,
		candidate,
		run_id: epoch.run_id,
		run_attempt: epoch.run_attempt,
		architecture: epoch.architecture,
		artifact_sha256: sha(archive),
		authentication: 'NOT_ESTABLISHED_BY_CALLER_SUPPLIED_JSON',
		kernel_executable_identity: verdict.kernel_executable_identity,
		swift_factory_activation: 'HELD'
	};
}
function writeExclusive(file, fact) {
	fs.writeFileSync(file, JSON.stringify(fact, null, 2) + '\n', {
		flag: 'wx',
		mode: 0o600
	});
}
function nativeStatuses(bytes) {
	const fact = uniqueJSON(bytes, 4096);
	keys(
		fact,
		['schema', 'owned_process', 'public_native', 'independent_client'],
		'Native roster statuses refused'
	);
	requireFact(integerToken(fact, 'schema') && fact.schema === 1, 'Native status schema refused');
	for (const role of ['owned_process', 'public_native', 'independent_client']) {
		keys(fact[role], ['command', 'capture'], 'Native command capture statuses refused');
		requireFact(
			integerToken(fact, role, 'command') &&
				Number.isSafeInteger(fact[role].command) &&
				fact[role].command >= 0 &&
				fact[role].command <= 255 &&
				integerToken(fact, role, 'capture') &&
				fact[role].capture === 0,
			'Native command capture failed'
		);
	}
	return fact;
}
function main(args, repository = path.resolve(__dirname, '../..')) {
	try {
		if (args.length === 6 && args[0] === 'begin') {
			const epoch = baseSource.context(args[1], args[2], args[3], args[4]);
			const before = sourceReceipt(repository, epoch);
			before.private_cache = privateCache(
				path.join(path.dirname(path.resolve(args[5])), 'private-cache')
			);
			writeExclusive(args[5], before);
			return 0;
		}
		if (args.length === 9 && args[0] === 'judge') {
			const epoch = baseSource.context(args[4], args[5], args[6], args[7]);
			const outputRoot = path.dirname(path.resolve(args[8]));
			function snapshot(name) {
				try {
					const actual = sourceReceipt(repository, epoch);
					actual.private_cache = privateCache(
						path.join(path.dirname(path.resolve(args[1])), 'private-cache')
					);
					writeExclusive(path.join(outputRoot, name + '.json'), actual);
					return actual;
				} catch (refused) {
					writeExclusive(path.join(outputRoot, name + '-not-received.json'), {
						schema: 1,
						state: 'NOT_RECEIVED',
						candidate: epoch.candidate,
						run_id: epoch.run_id,
						run_attempt: epoch.run_attempt,
						architecture: epoch.architecture
					});
					throw refused;
				}
			}
			const after = snapshot('source-after');
			let result;
			try {
				const before = uniqueJSON(regularBytes(args[1], 1048576));
				exact(before, after, 'Clock before/after source epoch changed');
				result = payloadReceipt(args[2], after);
				result.native_control_results = nativeStatuses(regularBytes(args[3], 4096));
				result.native_controls_all_passed = [
					'owned_process',
					'public_native',
					'independent_client'
				].every((role) => result.native_control_results[role].command === 0);
			} finally {
				exact(snapshot('source-final'), after, 'Clock source changed during payload receiving');
			}
			writeExclusive(args[8], result);
			console.log('NATIVE_HTTP_CLOCK consistency=true official=pending factory=held');
			return 0;
		}
		throw new Error('Clock evidence arguments refused');
	} catch {
		console.error('NATIVE_HTTP_CLOCK refused; native acceptance and factory remain unqualified.');
		return 1;
	}
}
module.exports = {
	INPUTS,
	LOADERS,
	SWIFT,
	HEADERS,
	RUNTIME,
	OWNERS,
	RECEIVER,
	PAYLOAD,
	MODULE_MAP,
	sourceReceipt,
	regularBytes,
	uniqueJSON,
	nativeStatuses,
	privateCache,
	pythonLoader,
	frame,
	commandFact,
	payloadReceipt,
	officialConsistency,
	main
};
if (require.main === module) process.exitCode = main(process.argv.slice(2));
