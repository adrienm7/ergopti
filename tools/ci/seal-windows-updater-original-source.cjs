// tools/ci/seal-windows-updater-original-source.cjs
// Refresh only source pins; original native behavior expectations remain independent.
'use strict';
const nativeAssertions = require('node:assert/strict');
const { isNativeError } = require('node:util').types;
const declaredDiagnostics = new WeakMap();
const pairedWriteFailures = new WeakSet();
const nativeMessageDescriptor = Object.getOwnPropertyDescriptor;
const assert = Object.fromEntries(
	['ok', 'equal', 'match', 'deepEqual'].map((method) => {
		const predicate = nativeAssertions[method];
		return [
			method,
			(...args) => {
				try {
					return Reflect.apply(predicate, nativeAssertions, args);
				} catch (failure) {
					const diagnostic = args.at(-1);
					if (isNativeError(failure) && typeof diagnostic === 'string')
						declaredDiagnostics.set(failure, diagnostic);
					throw failure;
				}
			}
		];
	})
);
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { readSourceFile } = require('./windows-updater-original-source.cjs');

const root = path.resolve(__dirname, '../..');
const inputsPath = 'tools/ci/windows-updater-original-diagnostic-cohort-inputs.json';
const oraclePath = 'tools/ci/windows-updater-original-label-oracle.json';
const oracleSha = '2b00c32567273c9e671b3460fe54b52059032b0188f10103076523d58b59eb01';
const sourcePaths = Object.freeze([
	'static/ergopti_plus/windows/_generated/update_channels.ahk',
	'static/ergopti_plus/windows/_generated/update_schedule.ahk',
	'static/ergopti_plus/windows/infra/config_io.ahk',
	'static/ergopti_plus/windows/infra/config_migrate.ahk',
	'static/ergopti_plus/windows/infra/config_transition_runtime.ahk',
	'static/ergopti_plus/windows/infra/config_write_lease.ahk',
	'static/ergopti_plus/windows/infra/toml/toml_document.ahk',
	'static/ergopti_plus/windows/modules/updater.ahk',
	'static/ergopti_plus/windows/modules/updater/changelog.ahk',
	'static/ergopti_plus/windows/modules/updater/channels.ahk',
	'static/ergopti_plus/windows/modules/updater/config_backup.ahk',
	'static/ergopti_plus/windows/modules/updater/core.ahk',
	'static/ergopti_plus/windows/modules/updater/release_install.ahk',
	'static/ergopti_plus/windows/modules/updater/schedule.ahk',
	'static/ergopti_plus/windows/modules/updater/self_update.ahk',
	'static/ergopti_plus/windows/tests/run_all.ahk',
	'static/ergopti_plus/windows/tests/test_framework.ahk',
	'static/ergopti_plus/windows/tests/unit/test_config_scope_manifest.ahk',
	'static/ergopti_plus/windows/tests/unit/test_updater.ahk',
	'static/ergopti_plus/windows/tests/unit/updater/test_global_config_admission.ahk',
	'tools/test/validate-ahk-suite-manifest.cjs'
]);
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const git = (args) => {
	try {
		return execFileSync('git', args, {
			cwd: root,
			env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
			maxBuffer: 32 * 1024 * 1024,
			stdio: 'pipe'
		});
	} catch (failure) {
		if (isNativeError(failure))
			declaredDiagnostics.set(failure, `Source seal Git ${args[0]} request refused.`);
		throw failure;
	}
};
function refusalDiagnostic(failure) {
	if (pairedWriteFailures.has(failure))
		return 'SOURCE_SEAL_REFUSAL stage=write_and_close error_count=2';
	const declared = declaredDiagnostics.get(failure);
	if (declared !== undefined) return declared;
	if (isNativeError(failure)) {
		const message = nativeMessageDescriptor(failure, 'message');
		if (message && Object.hasOwn(message, 'value') && typeof message.value === 'string') {
			for (const admitted of [
				'Regular unaliased source/image required.',
				'Source/image acquisition refused.',
				'Source/image changed during receiving.',
				'Source/image receiving and closure refused.'
			])
				if (message.value === admitted) return admitted;
		}
	}
	return 'SOURCE_SEAL_REFUSAL stage=unclassified error_count=unknown';
}
function actualFile(relative) {
	const absolute = path.join(root, relative);
	for (let parent = path.dirname(absolute); parent !== root; parent = path.dirname(parent)) {
		const state = fs.lstatSync(parent);
		assert.ok(state.isDirectory() && !state.isSymbolicLink(), 'Source directory alias refused.');
	}
	return readSourceFile(absolute);
}
function protectedFields(value) {
	const result = { ...value };
	delete result.source_sha256;
	delete result.source_pin_base;
	return result;
}
function main(args) {
	assert.ok(
		args.length === 3 &&
			args[0] === '--ref' &&
			/^[0-9a-f]{40}$/.test(args[1]) &&
			(args[2] === '--check' || args[2] === '--write'),
		'Usage: node tools/ci/seal-windows-updater-original-source.cjs --ref <reviewed-40-SHA> --check|--write'
	);
	const ref = args[1];
	assert.equal(
		git(['cat-file', '-t', ref]).toString('utf8').trim(),
		'commit',
		'Immutable source commit required.'
	);
	const head = git(['rev-parse', 'HEAD']).toString('utf8').trim();
	assert.match(head, /^[0-9a-f]{40}$/, 'Immutable template HEAD required.');
	const template = JSON.parse(git(['show', `${head}:${inputsPath}`]).toString('utf8'));
	assert.deepEqual(
		Object.keys(template.source_sha256),
		sourcePaths,
		'Frozen 21 source roster changed.'
	);
	const immutableOracle = git(['show', `${head}:${oraclePath}`]);
	assert.equal(digest(immutableOracle), oracleSha, 'Independent original oracle changed.');
	assert.equal(template.original_label_oracle_sha256, oracleSha, 'Original oracle pin changed.');
	assert.deepEqual(
		template.cohorts,
		JSON.parse(immutableOracle.toString('utf8')).cohorts,
		'Original cohort oracle differs.'
	);
	assert.deepEqual(
		template.cohorts.map((cohort) => cohort.expected_names.length),
		[18, 4, 1]
	);
	const before = actualFile(inputsPath);
	const actualInputs = JSON.parse(before.bytes.toString('utf8'));
	assert.deepEqual(
		Object.keys(actualInputs),
		Object.keys(template),
		'Source data field roster changed.'
	);
	assert.deepEqual(
		Object.keys(actualInputs.source_sha256),
		sourcePaths,
		'Actual source roster changed.'
	);
	assert.deepEqual(
		protectedFields(actualInputs),
		protectedFields(template),
		'Protected source data changed.'
	);
	assert.deepEqual(
		actualFile(oraclePath).bytes,
		immutableOracle,
		'Actual independent oracle differs.'
	);
	const sourceHashes = {};
	const received = {};
	for (const relative of sourcePaths) {
		const row = git(['ls-tree', ref, '--', relative]).toString('utf8');
		const match = /^(100644|100755) blob ([0-9a-f]{40})\t([^\n]+)\n$/.exec(row);
		assert.ok(match && match[3] === relative, 'Regular immutable source entry required.');
		const expected = git(['cat-file', 'blob', match[2]]);
		const observed = actualFile(relative);
		assert.deepEqual(
			observed.bytes,
			expected,
			`Actual worktree source differs from --ref: ${relative}`
		);
		sourceHashes[relative] = digest(expected);
		received[relative] = observed.sha256;
	}
	const successor = { ...template, source_sha256: sourceHashes, source_pin_base: ref };
	const encoded = Buffer.from(JSON.stringify(successor, null, '\t') + '\n', 'utf8');
	assert.deepEqual(protectedFields(successor), protectedFields(template));
	for (const relative of sourcePaths)
		assert.equal(actualFile(relative).sha256, received[relative], 'Source changed during sealing.');
	assert.deepEqual(actualFile(oraclePath).bytes, immutableOracle, 'Oracle changed during sealing.');
	assert.equal(git(['rev-parse', 'HEAD']).toString('utf8').trim(), head, 'Template HEAD changed.');
	assert.deepEqual(
		actualFile(inputsPath).bytes,
		before.bytes,
		'Source data changed during sealing.'
	);
	if (args[2] === '--check') {
		assert.deepEqual(
			before.bytes,
			encoded,
			'Source seal is stale; review the commit and run --write.'
		);
	} else if (!before.bytes.equals(encoded)) {
		// Write only the acquired existing file; never follow a replacement symlink.
		const fd = fs.openSync(
			path.join(root, inputsPath),
			fs.constants.O_RDWR | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0)
		);
		let sealingFailed = false,
			sealingFailure;
		try {
			const acquired = fs.fstatSync(fd, { bigint: true });
			assert.ok(
				acquired.isFile() &&
					acquired.nlink === 1n &&
					String(acquired.dev) === before.identity.dev &&
					String(acquired.ino) === before.identity.ino,
				'Source output ownership changed.'
			);
			const named = actualFile(inputsPath);
			assert.equal(named.identity.dev, before.identity.dev, 'Named output device changed.');
			assert.equal(named.identity.ino, before.identity.ino, 'Named output inode changed.');
			assert.deepEqual(named.bytes, before.bytes, 'Acquired output changed.');
			for (let offset = 0; offset < encoded.length; ) {
				const written = fs.writeSync(fd, encoded, offset, encoded.length - offset, offset);
				assert.ok(written > 0, 'Source seal write did not progress.');
				offset += written;
			}
			fs.ftruncateSync(fd, encoded.length);
			assert.deepEqual(actualFile(inputsPath).bytes, encoded, 'Published source seal differs.');
		} catch (error) {
			sealingFailed = true;
			sealingFailure = error;
			throw error;
		} finally {
			try {
				fs.closeSync(fd);
			} catch (closureFailure) {
				if (sealingFailed) {
					const refusal = new AggregateError(
						[sealingFailure, closureFailure],
						'Source seal write and closure refused.',
						{ cause: sealingFailure }
					);
					pairedWriteFailures.add(refusal);
					throw refusal;
				}
				throw closureFailure;
			}
		}
	}
	for (const relative of sourcePaths)
		assert.equal(
			actualFile(relative).sha256,
			sourceHashes[relative],
			'Source changed before final seal receiving.'
		);
	assert.deepEqual(
		actualFile(oraclePath).bytes,
		immutableOracle,
		'Oracle changed before final seal receiving.'
	);
	assert.equal(
		git(['rev-parse', 'HEAD']).toString('utf8').trim(),
		head,
		'Template HEAD changed before final seal receiving.'
	);
	process.stdout.write(
		`WINDOWS_UPDATER_SOURCE_SEAL ref=${ref} inputs=21 mode=${args[2].slice(2)} native=false official=false\n`
	);
}
if (require.main === module) {
	try {
		main(process.argv.slice(2));
	} catch (error) {
		process.exitCode = 1;
		console.error(refusalDiagnostic(error));
	}
}
