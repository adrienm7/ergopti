// tools/test/test-apple-shortcuts-installed-target.cjs

/**
 * ==============================================================================
 * MODULE: Installed Shortcuts Target Portable Controls
 * DESCRIPTION:
 * Enroll the unchanged real-filesystem reader and retained-source/output tests.
 * Native POSIX runs two ordinary Python children; Windows checks source only.
 * No child invokes LaunchServices, the Swift resolver or collector main.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = fs.realpathSync(path.resolve(__dirname, '../..'));
const DIRECTORY = 'tools/diagnostics/apple_shortcuts_installed_target';
const FILES = {
	'collect_installed_target.py': 'c22ccb7883beb7e471f1f0155f6105b64ba0ec04402a27a003f5e4c5c45fb26a',
	'installed_target_reader.py': '080eec4c55817e972f78e920cbcbbad02d0939618281aca23b845ec512fa976e',
	'test_collector_source_binding.py':
		'9290c8666a3cfe120ec25026764785a32892d5324058c463c45c919039cc012b',
	'resolve_installed_target.swift':
		'8a6c93b202dbfd38d8c404b5f55ae60f63ecacc82b7c240f6d9fcaffcef4fc92',
	'test_installed_target_reader.py':
		'979c1275edea97836eb52596b95a9aa48668a4d79683354a1813ad3b73a69c04',
	'run_controls.py': '1cab447dc669760333269989bef113c3d9520b52088d9cdec4bf97a94021ceb0',
	'portable_cases.json': 'c63e79e2d060b034289289231ad5e191b56846d6fda9b65478c3ef03210165fa'
};
const DEPENDENCIES = {
	'tools/diagnostics/macos_owned_process.py':
		'9b985af7e8bf549cb843b289885a2bea38a67ea3ce44defaf389dab1001fef98',
	'tools/diagnostics/apple_shortcuts_probe/run_probe.py':
		'eeb75f1686a4fb50e85e9e79e8a632f344c4e19d756fab7f5e086237520ab257'
};
// These names/order come from the original independently frozen 19+15 corpus.
const GROUPS = {
	reader: [
		'test_installed_target_reader.InstalledTargetReaderTests.test_binary_plist_explicit_ns_declaration',
		'test_installed_target_reader.InstalledTargetReaderTests.test_both_explicit_identical_declarations',
		'test_installed_target_reader.InstalledTargetReaderTests.test_bundle_ancestor_symlink_refused',
		'test_installed_target_reader.InstalledTargetReaderTests.test_conflicting_declared_dictionaries',
		'test_installed_target_reader.InstalledTargetReaderTests.test_dictionary_named_entry_replacement_refused',
		'test_installed_target_reader.InstalledTargetReaderTests.test_dictionary_symlink_refused',
		'test_installed_target_reader.InstalledTargetReaderTests.test_exact_xml_source_bytes_and_metadata_only',
		'test_installed_target_reader.InstalledTargetReaderTests.test_fifo_and_empty_dictionary_refused',
		'test_installed_target_reader.InstalledTargetReaderTests.test_malformed_and_duplicate_plist_refused',
		'test_installed_target_reader.InstalledTargetReaderTests.test_missing_exact_declared_dictionary',
		'test_installed_target_reader.InstalledTargetReaderTests.test_no_declared_dictionary_even_when_file_exists',
		'test_installed_target_reader.InstalledTargetReaderTests.test_no_extension_guess',
		'test_installed_target_reader.InstalledTargetReaderTests.test_original_deadline_not_refreshed',
		'test_installed_target_reader.InstalledTargetReaderTests.test_oversized_source_files_refused',
		'test_installed_target_reader.InstalledTargetReaderTests.test_resolution_exact_target_and_single_native_route',
		'test_installed_target_reader.InstalledTargetReaderTests.test_resolution_foreign_duplicate_ambiguous_and_traversal_refused',
		'test_installed_target_reader.InstalledTargetReaderTests.test_retained_descriptors_all_closed_on_refusal',
		'test_installed_target_reader.InstalledTargetReaderTests.test_traversal_absolute_and_nonstring_declarations',
		'test_installed_target_reader.InstalledTargetReaderTests.test_wrong_identifier'
	],
	loader_output: [
		'test_collector_source_binding.OutputCustodyTests.test_completed_receipt_exact_bytes_and_closed_resources',
		'test_collector_source_binding.OutputCustodyTests.test_exclusive_directory_and_file_bytes',
		'test_collector_source_binding.OutputCustodyTests.test_moved_output_refuses_without_writing_foreign_replacement',
		'test_collector_source_binding.OutputCustodyTests.test_original_cancellation_has_priority_over_receipt_io',
		'test_collector_source_binding.OutputCustodyTests.test_original_retirement_error_has_priority_over_lost_output_name',
		'test_collector_source_binding.OutputCustodyTests.test_receipt_refusal_without_pending_primary_is_not_success',
		'test_collector_source_binding.OutputCustodyTests.test_symlink_receiving_parent_and_existing_destination_refused',
		'test_collector_source_binding.SourceBindingTests.test_all_source_descriptors_closed_after_read_refusal',
		'test_collector_source_binding.SourceBindingTests.test_change_after_validated_read_cannot_reopen_foreign_source',
		'test_collector_source_binding.SourceBindingTests.test_changed_timestamp_valid_pyc_is_never_executed',
		'test_collector_source_binding.SourceBindingTests.test_exact_retained_actual_owner_image',
		'test_collector_source_binding.SourceBindingTests.test_final_source_symlink_refused',
		'test_collector_source_binding.SourceBindingTests.test_named_source_replacement_during_read_refuses_before_execution',
		'test_collector_source_binding.SourceBindingTests.test_source_ancestor_symlink_refused',
		'test_collector_source_binding.SourceBindingTests.test_wrong_source_digest_refuses_before_any_execution'
	]
};
const SOURCE_LIMIT = 65536;
const CHILD_TIMEOUT_MS = 60000;
// Ordinary unittest output only; this does not change native capture's byte cap.
const CHILD_OUTPUT_LIMIT = 1024 * 1024;
const POSIX = process.platform === 'linux' || process.platform === 'darwin';
const WINDOWS = process.platform === 'win32';
assert(POSIX || WINDOWS, 'unsupported portable control host');

/** Hash an exact retained byte image. */
function sha(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}

/** Snapshot regular-file identity without narrowing native or issuer authority. */
function identity(info) {
	return [info.dev, info.ino, info.mode, info.size, info.mtimeNs, info.ctimeNs].map(String);
}

/** Read one bounded original file, refusing final/ancestor links and name drift. */
function retained(base, relative) {
	assert(!path.isAbsolute(relative) && !relative.split('/').includes('..'));
	const parts = relative.split('/');
	assert(parts.every((part) => part !== '' && part !== '.'));
	const ancestors = [];
	let current = base;
	for (const part of parts.slice(0, -1)) {
		current = path.join(current, part);
		const info = fs.lstatSync(current, { bigint: true });
		assert(info.isDirectory() && !info.isSymbolicLink(), 'source ancestor refused');
		ancestors.push([current, [info.dev, info.ino, info.mode].map(String)]);
	}
	const filename = path.join(base, ...parts);
	const named = fs.lstatSync(filename, { bigint: true });
	assert(named.isFile() && !named.isSymbolicLink(), 'regular source required');
	assert(named.size > 0n && named.size <= BigInt(SOURCE_LIMIT), 'source bound refused');
	const flags = fs.constants.O_RDONLY | (POSIX ? fs.constants.O_NOFOLLOW : 0);
	const fd = fs.openSync(filename, flags);
	try {
		const before = fs.fstatSync(fd, { bigint: true });
		assert.deepEqual(identity(before), identity(named), 'source open/name changed');
		const storage = Buffer.alloc(SOURCE_LIMIT + 1);
		let count = 0;
		while (count < storage.length) {
			const received = fs.readSync(fd, storage, count, storage.length - count, null);
			if (received === 0) break;
			count += received;
		}
		const bytes = storage.subarray(0, count);
		assert.equal(bytes.length, Number(before.size));
		assert(bytes.length <= SOURCE_LIMIT);
		assert.deepEqual(identity(fs.fstatSync(fd, { bigint: true })), identity(before));
		assert.deepEqual(identity(fs.lstatSync(filename, { bigint: true })), identity(before));
		for (const [directory, original] of ancestors) {
			const now = fs.lstatSync(directory, { bigint: true });
			assert(now.isDirectory() && !now.isSymbolicLink());
			assert.deepEqual([now.dev, now.ino, now.mode].map(String), original);
		}
		return { bytes, sha256: sha(bytes), identity: identity(before) };
	} finally {
		fs.closeSync(fd);
	}
}

/** Require exact reviewed byte images before any test process is allocated. */
function inputs(validate = true) {
	const result = {};
	for (const [name, expected] of Object.entries(FILES)) {
		const relative = DIRECTORY + '/' + name;
		const row = retained(ROOT, relative);
		if (validate) assert.equal(row.sha256, expected, 'reviewed diagnostic source changed: ' + name);
		result[relative] = row;
	}
	for (const [relative, expected] of Object.entries(DEPENDENCIES)) {
		const row = retained(ROOT, relative);
		if (validate)
			assert.equal(row.sha256, expected, 'original owner dependency changed: ' + relative);
		result[relative] = row;
	}
	return result;
}

/** Write an exclusive file only into this guard's freshly owned projection. */
function write(filename, bytes) {
	fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
	fs.writeFileSync(filename, bytes, { flag: 'wx', mode: 0o600 });
}

/** Keep only custody metadata in JSON; raw source bytes stay in sealed files. */
function census(rows) {
	return Object.fromEntries(
		Object.entries(rows).map(([name, row]) => [
			name,
			{ sha256: row.sha256, identity: row.identity }
		])
	);
}

/** Rejoin actual source bytes and exact opened-file identities after children. */
function current(before) {
	const after = inputs();
	assert.deepEqual(census(after), census(before), 'original source custody changed');
	return after;
}

const before = inputs();
const declared = JSON.parse(before[DIRECTORY + '/portable_cases.json'].bytes.toString('utf8'));
assert.deepEqual(Object.keys(declared), ['groups']);
assert.deepEqual(declared.groups, GROUPS, 'independent full name/order census changed');
assert.equal(GROUPS.reader.length, 19);
assert.equal(GROUPS.loader_output.length, 15);
for (const names of Object.values(GROUPS)) {
	assert.equal(new Set(names).size, names.length, 'duplicate case');
	assert(names.every((name) => typeof name === 'string' && name.length > 0));
}
const collector = before[DIRECTORY + '/collect_installed_target.py'].bytes.toString('utf8');
assert(collector.includes('compile(raw, str(path), "exec", dont_inherit=True)'));
assert.doesNotMatch(collector, /SourceFileLoader|exec_module/);
assert(collector.includes('deadline = time.monotonic() + 20'));
assert.match(collector, /"catalogue_observed": False,\s+"permission_observed": False/);
assert.match(collector, /"invocation_qualified": False,\s+"running_target_observed": False/);

if (WINDOWS) {
	current(before);
	process.stdout.write(
		'Installed target source structure checked; portable_fd_controls=UNRUN_UNSUPPORTED; native=UNRUN\n'
	);
} else {
	const session = fs.realpathSync(
		fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-installed-target-'))
	);
	fs.chmodSync(session, 0o700);
	const worker = path.join(session, 'worker');
	const evidence = path.join(session, 'evidence');
	const scratch = path.join(session, 'tmp');
	fs.mkdirSync(worker, { mode: 0o700 });
	fs.mkdirSync(evidence, { mode: 0o700 });
	fs.mkdirSync(scratch, { mode: 0o700 });
	const projection = {};
	for (const name of Object.keys(FILES)) {
		const relative = ['run_controls.py', 'portable_cases.json'].includes(name)
			? name
			: 'candidate/' + name;
		write(path.join(worker, relative), before[DIRECTORY + '/' + name].bytes);
		projection[relative] = retained(worker, relative);
	}
	for (const relative of Object.keys(DEPENDENCIES)) {
		write(path.join(worker, 'dependencies', relative), before[relative].bytes);
		projection['dependencies/' + relative] = retained(worker, 'dependencies/' + relative);
	}
	write(
		path.join(evidence, 'source-before.json'),
		JSON.stringify(census(before), null, '\t') + '\n'
	);
	write(
		path.join(evidence, 'projection-before.json'),
		JSON.stringify(census(projection), null, '\t') + '\n'
	);
	const outcomes = [];
	try {
		// Always retain both ordinary raw child outcomes before judging their results.
		for (const group of ['reader', 'loader_output']) {
			const destination = path.join(evidence, group + '.json');
			const args = [
				'-B',
				path.join(worker, 'run_controls.py'),
				'--worker',
				worker,
				'--plan',
				path.join(worker, 'portable_cases.json'),
				'--group',
				group,
				'--result',
				destination
			];
			const started = Date.now();
			const raw = spawnSync('python3', args, {
				cwd: worker,
				env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1', TMPDIR: scratch },
				timeout: CHILD_TIMEOUT_MS,
				maxBuffer: CHILD_OUTPUT_LIMIT,
				killSignal: 'SIGTERM'
			});
			write(path.join(evidence, group + '.stdout'), raw.stdout || Buffer.alloc(0));
			write(path.join(evidence, group + '.stderr'), raw.stderr || Buffer.alloc(0));
			const outcome = {
				group,
				command: 'python3',
				args,
				cwd: worker,
				started_ms: started,
				finished_ms: Date.now(),
				exit: raw.status,
				signal: raw.signal,
				error: raw.error
					? { name: raw.error.name, code: raw.error.code || null, message: raw.error.message }
					: null,
				timed_out: !!raw.error && raw.error.code === 'ETIMEDOUT',
				stdout_bytes: raw.stdout ? raw.stdout.length : 0,
				stderr_bytes: raw.stderr ? raw.stderr.length : 0,
				result_path: destination,
				timeout_ms: CHILD_TIMEOUT_MS,
				output_limit: CHILD_OUTPUT_LIMIT,
				native_observation: false
			};
			write(path.join(evidence, group + '.raw.json'), JSON.stringify(outcome, null, '\t') + '\n');
			outcomes.push(outcome);
		}
		// Save actual after-images before judging currency or child outcomes.
		const after = inputs(false);
		const projectionAfter = Object.fromEntries(
			Object.keys(projection).map((relative) => [relative, retained(worker, relative)])
		);
		write(
			path.join(evidence, 'source-after.json'),
			JSON.stringify(census(after), null, '\t') + '\n'
		);
		write(
			path.join(evidence, 'projection-after.json'),
			JSON.stringify(census(projectionAfter), null, '\t') + '\n'
		);
		assert.deepEqual(census(after), census(before), 'original source custody changed');
		assert.deepEqual(census(projectionAfter), census(projection), 'closed projection changed');
		for (const raw of outcomes) {
			assert.equal(raw.error, null, 'raw child error: ' + JSON.stringify(raw));
			assert.equal(raw.signal, null, 'raw child signal: ' + JSON.stringify(raw));
			assert.equal(raw.exit, 0, 'raw child exit: ' + JSON.stringify(raw));
			const packet = JSON.parse(retained(evidence, raw.group + '.json').bytes.toString('utf8'));
			assert.deepEqual(
				Object.keys(packet).sort(),
				[
					'schema',
					'group',
					'tests',
					'seen',
					'successes',
					'failures',
					'errors',
					'skipped',
					'expected_failures',
					'unexpected_successes',
					'census_valid',
					'native_observation'
				].sort()
			);
			assert.equal(packet.schema, 1);
			assert.equal(packet.group, raw.group);
			assert.equal(packet.tests, GROUPS[raw.group].length);
			assert.deepEqual(packet.seen, GROUPS[raw.group]);
			assert.deepEqual(packet.successes, GROUPS[raw.group]);
			assert.equal(packet.census_valid, true);
			assert.equal(packet.native_observation, false);
			for (const field of [
				'failures',
				'errors',
				'skipped',
				'expected_failures',
				'unexpected_successes'
			])
				assert.deepEqual(packet[field], [], 'unexpected portable result: ' + field);
		}
		write(
			path.join(evidence, 'verdict.json'),
			JSON.stringify(
				{
					schema: 1,
					status: 'PORTABLE_34_PASSED',
					counts: { reader: 19, loader_output: 15 },
					native_observation: false,
					source_current: true,
					projection_current: true
				},
				null,
				'\t'
			) + '\n'
		);
		process.stdout.write('Installed target portable controls: 19+15 passed; native=UNRUN\n');
	} catch (error) {
		write(
			path.join(evidence, 'refusal.json'),
			JSON.stringify(
				{
					schema: 1,
					status: 'PORTABLE_REFUSED',
					native_observation: false,
					error: { name: error.name, message: error.message }
				},
				null,
				'\t'
			) + '\n'
		);
		throw error;
	} finally {
		// Only the owned input projection is disposable; raw evidence stays available.
		fs.rmSync(worker, { recursive: true, force: false });
		fs.rmSync(scratch, { recursive: true, force: false });
		process.stdout.write('Installed target raw portable evidence: ' + evidence + '\n');
	}
}
