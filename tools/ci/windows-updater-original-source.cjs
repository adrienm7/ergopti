// G6 original updater Source-only receiving; import does not collect a Source receipt or start native children.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const inputs = require('./windows-updater-original-diagnostic-cohort-inputs.json');
const root = path.resolve(__dirname, '../..');
const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const demand = (ok, message) => {
	if (!ok) throw new Error(message);
};

const ORACLE_PATH = 'tools/ci/windows-updater-original-label-oracle.json';
const ORACLE_SHA256 = '2b00c32567273c9e671b3460fe54b52059032b0188f10103076523d58b59eb01';
const ALL_AHK_INPUTS = 'all tracked repository paths ending in .ahk (case-insensitive)';
const SOURCE_ROOTS = Object.freeze([
	'static/ergopti_plus/windows',
	'static/ergopti_plus/_shared',
	'tools/build',
	'tools/native',
	'tools/ci/run-windows-updater-original-diagnostic-cohort.cjs',
	'tools/ci/windows-updater-original-diagnostic-cohort-inputs.json',
	'tools/ci/windows-updater-original-source.cjs',
	ORACLE_PATH,
	'tools/test/validate-ahk-suite-manifest.cjs',
	'tools/ci/manual-ci-lanes.cjs',
	'tools/ci/dev-release-qualification.cjs',
	'.github/ci/dev_release_qualification_exceptions.json',
	'.github/ci/stable_release_qualification_exception.json',
	'.github/workflows/ci.yml',
	'.github/workflows/ci-windows.yml',
	'.node-version',
	'package.json',
	'package-lock.json'
]);
function readSourceFile(file, maximum = 33554432) {
	const named = fs.lstatSync(file, { bigint: true });
	demand(
		named.isFile() && !named.isSymbolicLink() && named.nlink === 1n,
		'Regular unaliased source/image required.'
	);
	const fd = fs.openSync(
		file,
		fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0)
	);
	let receivingFailed = false,
		receivingFailure;
	try {
		const acquired = fs.fstatSync(fd, { bigint: true });
		demand(
			acquired.isFile() &&
				acquired.nlink === 1n &&
				acquired.size <= BigInt(maximum) &&
				acquired.dev === named.dev &&
				acquired.ino === named.ino,
			'Source/image acquisition refused.'
		);
		const storage = Buffer.alloc(Number(acquired.size) + 1);
		let length = 0;
		while (length < storage.length) {
			const count = fs.readSync(fd, storage, length, storage.length - length, null);
			if (!count) break;
			length += count;
		}
		const bytes = storage.subarray(0, length);
		const final = fs.fstatSync(fd, { bigint: true });
		const finalNamed = fs.lstatSync(file, { bigint: true });
		demand(
			final.isFile() &&
				finalNamed.isFile() &&
				!finalNamed.isSymbolicLink() &&
				final.nlink === 1n &&
				finalNamed.nlink === 1n &&
				final.dev === acquired.dev &&
				final.ino === acquired.ino &&
				finalNamed.dev === acquired.dev &&
				finalNamed.ino === acquired.ino &&
				final.size === acquired.size &&
				BigInt(bytes.length) === acquired.size &&
				final.mtimeNs === acquired.mtimeNs &&
				final.ctimeNs === acquired.ctimeNs,
			'Source/image changed during receiving.'
		);
		return {
			bytes,
			sha256: sha(bytes),
			identity: {
				dev: String(acquired.dev),
				ino: String(acquired.ino),
				size: String(acquired.size)
			}
		};
	} catch (error) {
		receivingFailed = true;
		receivingFailure = error;
		throw error;
	} finally {
		try {
			fs.closeSync(fd);
		} catch (closureFailure) {
			if (receivingFailed)
				throw new AggregateError(
					[receivingFailure, closureFailure],
					'Source/image receiving and closure refused.',
					{ cause: receivingFailure }
				);
			throw closureFailure;
		}
	}
}
function candidateSourceReceipt(epoch) {
	const git = (args) =>
		execFileSync('git', args, {
			cwd: root,
			env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
			encoding: 'utf8',
			maxBuffer: 32 * 1024 * 1024
		});
	demand(git(['rev-parse', 'HEAD']).trim() === epoch.candidate, 'Source HEAD changed.');
	git(['diff', '--exit-code', 'HEAD', '--']); // staged AND unstaged tracked source
	const untrackedAhk = git(['ls-files', '--others', '-z'])
		.split('\0')
		.filter((name) => /\.ahk$/i.test(name));
	demand(untrackedAhk.length === 0, 'Unbound AHK input refused.');
	// ls-tree has no glob-magic dependency: select the finite native input
	// superset from its ordinary full recursive Git tree listing.
	const entries = git(['ls-tree', '-rz', '--full-tree', epoch.candidate])
		.split('\0')
		.filter(Boolean)
		.filter((row) => {
			const relative = row.slice(row.indexOf('\t') + 1);
			return (
				/\.ahk$/i.test(relative) ||
				SOURCE_ROOTS.some((scope) => relative === scope || relative.startsWith(`${scope}/`))
			);
		});
	const sources = {},
		caseNames = new Set();
	for (const row of entries) {
		const match = /^(100644|100755) blob ([0-9a-f]{40})\t([^\0]+)$/.exec(row);
		demand(match, 'Tracked regular source entry refused.');
		const [, mode, blob, relative] = match;
		demand(
			!relative.includes('\\') &&
				!relative.split('/').includes('..') &&
				!caseNames.has(relative.toLowerCase()),
			'Ambiguous source pathname refused.'
		);
		caseNames.add(relative.toLowerCase());
		const absolute = path.join(root, relative);
		for (
			let directory = path.dirname(absolute);
			directory !== root;
			directory = path.dirname(directory)
		) {
			const owner = fs.lstatSync(directory);
			demand(owner.isDirectory() && !owner.isSymbolicLink(), 'Source directory alias refused.');
		}
		const observed = readSourceFile(absolute);
		const actualBlob = crypto
			.createHash('sha1')
			.update(Buffer.from(`blob ${observed.bytes.length}\0`))
			.update(observed.bytes)
			.digest('hex');
		demand(actualBlob === blob, 'Actual source differs from current Git blob.');
		sources[relative] = {
			mode,
			git_blob: blob,
			sha256: observed.sha256,
			bytes: observed.bytes.length
		};
	}
	for (const required of SOURCE_ROOTS.filter((name) => path.extname(name)))
		demand(Object.hasOwn(sources, required), 'Source loader/receiver unavailable.');
	for (const [relative, expected] of Object.entries(inputs.source_sha256))
		demand(sources[relative]?.sha256 === expected, 'Candidate runtime/fixture source pin changed.');
	const oracleBytes = readSourceFile(path.join(root, ORACLE_PATH)).bytes;
	demand(
		sha(oracleBytes) === ORACLE_SHA256 && inputs.original_label_oracle_sha256 === ORACLE_SHA256,
		'Original independent label oracle changed.'
	);
	const oracle = JSON.parse(oracleBytes.toString('utf8'));
	demand(
		JSON.stringify(inputs.cohorts) === JSON.stringify(oracle.cohorts),
		'Original cohort labels/order/filters changed.'
	);
	demand(
		inputs.cohorts.length === 3 &&
			JSON.stringify(inputs.cohorts.map((cohort) => cohort.expected_names.length)) === '[18,4,1]',
		'Original cohort census changed.'
	);
	git(['diff', '--exit-code', 'HEAD', '--']);
	demand(
		git(['rev-parse', 'HEAD']).trim() === epoch.candidate,
		'Source HEAD changed during receiving.'
	);
	return {
		schema: 1,
		scope: 'windows-updater-candidate-source-only',
		...epoch,
		head: epoch.candidate,
		tree: git(['rev-parse', `${epoch.candidate}^{tree}`]).trim(),
		git_version: git(['--version']).trim(),
		node_version: process.version,
		tracked_source_clean: true,
		source_scope: [...SOURCE_ROOTS, ALL_AHK_INPUTS],
		sources,
		oracle_sha256: ORACLE_SHA256,
		include_scope:
			'All tracked repository AHK plus Windows/shared/native-builder inputs; actual ambient/native loading is separately received.'
	};
}

function receiveSourceReceipt(epoch) {
	demand(
		epoch !== null &&
			typeof epoch === 'object' &&
			!Array.isArray(epoch) &&
			Object.getPrototypeOf(epoch) === Object.prototype,
		'Fixed original Source context object required.'
	);
	const names = ['candidate', 'run_id', 'run_attempt', 'architecture', 'role', 'context_bound'];
	demand(
		Object.getOwnPropertySymbols(epoch).length === 0 &&
			JSON.stringify(Object.getOwnPropertyNames(epoch).sort()) ===
				JSON.stringify([...names].sort()),
		'Fixed original Source context roster required.'
	);
	const snapshot = {};
	for (const name of names) {
		const descriptor = Object.getOwnPropertyDescriptor(epoch, name);
		demand(
			descriptor && Object.hasOwn(descriptor, 'value'),
			'Source context must contain passive primitive values.'
		);
		snapshot[name] = descriptor.value;
	}
	demand(
		typeof snapshot.candidate === 'string' &&
			/^[0-9a-f]{40}$/.test(snapshot.candidate) &&
			snapshot.architecture === 'x64',
		'Original Source candidate/architecture refused.'
	);
	const local =
		snapshot.role === 'local' &&
		snapshot.context_bound === false &&
		snapshot.run_id === null &&
		snapshot.run_attempt === null;
	const official =
		snapshot.role === 'candidate' &&
		snapshot.context_bound === true &&
		typeof snapshot.run_id === 'string' &&
		/^[1-9][0-9]{0,19}$/.test(snapshot.run_id) &&
		typeof snapshot.run_attempt === 'string' &&
		/^[1-9][0-9]{0,5}$/.test(snapshot.run_attempt);
	demand(local || official, 'Original Source context role/identity coherence refused.');
	// Validated caller metadata stays distinct from authenticated CI/API acceptance.
	return candidateSourceReceipt(snapshot);
}

function localInvocation(args) {
	demand(
		Array.isArray(args) &&
			args.length === 4 &&
			args[0] === '--local' &&
			args
				.slice(1)
				.every(
					(value) => typeof value === 'string' && value.trim() !== '' && !value.startsWith('--')
				),
		'Local invocation requires --local <ahk> <file-version> <absolute-evidence-root>.'
	);
	const hostedContextKeys = [
		'GITHUB_SHA',
		'GITHUB_RUN_ID',
		'GITHUB_RUN_ATTEMPT',
		'GITHUB_EVENT_NAME',
		'GITHUB_JOB',
		'GITHUB_WORKFLOW',
		'GITHUB_ACTIONS',
		'GITHUB_ACTION'
	];
	demand(
		!hostedContextKeys.some((name) => Object.hasOwn(process.env, name)),
		'Local receiving refuses hosted GitHub run context.'
	);
	demand(
		path.isAbsolute(args[1]) && path.isAbsolute(args[3]),
		'Local executable and evidence root must be absolute.'
	);
	demand(process.arch === 'x64', 'Original Windows SDK architecture refused.');
	const candidate = execFileSync('git', ['rev-parse', 'HEAD'], {
		cwd: root,
		env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
		encoding: 'utf8'
	}).trim();
	demand(/^[0-9a-f]{40}$/.test(candidate), 'Actual local Git HEAD unavailable.');
	return {
		local: true,
		arguments: args.slice(1, 3),
		evidence_root: args[3],
		context: {
			candidate,
			run_id: null,
			run_attempt: null,
			architecture: process.arch,
			role: 'local',
			context_bound: false
		}
	};
}

module.exports = { readSourceFile, candidateSourceReceipt: receiveSourceReceipt, localInvocation };
