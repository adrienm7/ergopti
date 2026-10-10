// tools/test/test-lease165-xctest-evidence.cjs
'use strict';

/** Modeled receiver controls, with historical identities; no native execution. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync, spawnSync } = require('node:child_process');
const reader = require('../diagnostics/lease165_xctest_evidence.cjs');
const full = require('../diagnostics/swift_xctest_evidence.cjs');
const corpus = require('./fixtures/lease165-native-xctest-corpus.json');
const stamp = '2026-10-09 19:49:09.845.';
const summary = (count) =>
	` Executed ${count} tests, with 0 failures (0 unexpected) in 1.000 (1.001) seconds`;
const opening = (name) => `Test Case '${name}' started.`;
const terminal = (name) => `Test Case '${name}' passed (0.001 seconds).`;
const lines = [
	`Test Suite 'Selected tests' started at ${stamp}`,
	`Test Suite 'ErgoptiPlusPackageTests.xctest' started at ${stamp}`
];
for (const cohort of corpus.cohorts) {
	lines.push(`Test Suite '${cohort.class_name}' started at ${stamp}`);
	for (const name of cohort.names) lines.push(opening(name), terminal(name));
	lines.push(`Test Suite '${cohort.class_name}' passed at ${stamp}`, summary(cohort.names.length));
}
lines.push(
	`Test Suite 'ErgoptiPlusPackageTests.xctest' passed at ${stamp}`,
	summary(165),
	`Test Suite 'Selected tests' passed at ${stamp}`,
	summary(165)
);
const valid = lines.join('\n') + '\n';
const first = corpus.cohorts[0].names[0];
let passed = 0;
const check = (label, action) => {
	action();
	passed++;
	console.log(`PASS ${label}`);
};
const refuses = (text, swift = 0, tee = 0) => {
	let verdict;
	try {
		verdict = reader.evaluate(text, swift, tee);
	} catch {
		return;
	}
	assert.equal(verdict.complete, false);
	assert.equal(verdict.full_package_qualified, false);
};
check('closed selected success', () => {
	const result = reader.evaluate(valid, 0, 0);
	assert.equal(result.complete, true);
	assert.equal(result.passed, 165);
	assert.equal(result.completed, 165);
	assert.equal(result.full_package_qualified, false);
});
// This closed independent fixture fails with the original full-package reader.
check('original full-package reader stays strict', () =>
	assert.notEqual(full.evaluate(valid, 0, 0).exit_status, 0)
);
check('historical original failures refused', () => {
	// Original actual run was failing; this fixed historical native identity failed.
	const failed =
		'-[ErgoptiPlusTests.KarabinerLeaseWorkerTests testRetainedDiagnosticPrivateRecordsAndAtomicReplacement]';
	assert.ok(corpus.cohorts[0].names.includes(failed));
	refuses(valid.replace(terminal(failed), terminal(failed).replace('passed', 'failed')));
});
check('full root refused', () => refuses(valid.replaceAll("'Selected tests'", "'All tests'")));
check('zero tests refused', () =>
	refuses(
		`Test Suite 'Selected tests' started at ${stamp}\nTest Suite 'Selected tests' passed at ${stamp}\n${summary(0)}\n`
	)
);
check('missing terminal refused', () => refuses(valid.replace(terminal(first) + '\n', '')));
check('skip refused', () =>
	refuses(valid.replace(terminal(first), terminal(first).replace('passed', 'skipped')))
);
check('case failure refused', () =>
	refuses(valid.replace(terminal(first), terminal(first).replace('passed', 'failed')))
);
check('duplicate identity refused', () =>
	refuses(
		valid.replace(terminal(first), terminal(first) + '\n' + opening(first) + '\n' + terminal(first))
	)
);
check('foreign identity refused', () =>
	refuses(valid.replaceAll(first, '-[ErgoptiPlusTests.KarabinerLeaseWorkerTests testForeign]'))
);
check('wrong count refused', () => refuses(valid.replace(summary(146), summary(145))));
check('failed suite refused', () =>
	refuses(
		valid.replace(
			`Test Suite 'KarabinerLeaseWorkerTests' passed`,
			`Test Suite 'KarabinerLeaseWorkerTests' failed`
		)
	)
);
check('missing root close refused', () =>
	refuses(valid.replace(`Test Suite 'Selected tests' passed at ${stamp}\n${summary(165)}\n`, ''))
);
check('malformed summary refused', () =>
	refuses(valid.replace(summary(146), summary(146) + ' private suffix'))
);
check('out of order close refused', () =>
	refuses(
		valid.replace(
			`Test Suite 'KarabinerLeaseWorkerTests' passed`,
			`Test Suite 'Selected tests' passed`
		)
	)
);
check('terminal outside suite refused', () => refuses(terminal(first) + '\n' + valid));
check('swift nonzero refused', () => refuses(valid, 1, 0));
check('capture nonzero refused', () => refuses(valid, 0, 1));
check('invalid status refused', () => refuses(valid, '00', 0));
check('extra test frame refused', () => refuses(valid + "Test Case 'foreign' unsupported\n"));
check('PTY normalization retains exact frames', () =>
	assert.equal(
		reader.evaluate('\x1b[32m' + valid.replaceAll('\n', '\r\n') + '\x1b[0m', 0, 0).complete,
		true
	)
);
check('bundle missing refused', () =>
	refuses(valid.replace(`Test Suite 'ErgoptiPlusPackageTests.xctest' started at ${stamp}\n`, ''))
);
check('foreign suite refused', () =>
	refuses(
		valid.replace("Test Suite 'KarabinerLeaseWorkerTests' started", "Test Suite 'Foreign' started")
	)
);
check('root summary wrong count refused', () =>
	refuses(valid.slice(0, valid.lastIndexOf(summary(165))) + summary(164) + '\n')
);
check('elapsed malformed refused', () =>
	refuses(valid.replace('in 1.000 (1.001) seconds', 'in -1.000 (1.001) seconds'))
);
check('fatal compile error refused', () => refuses('fatal error: build failed\n' + valid));

// Windows lacks getuid and POSIX0600; project only the exact private modeled leaf/FD.
// Real file kind, identity, link count, size and time cuts are never changed.
const modeledReceiptBootstrap = (leaf, requestedMode = 0o600) => {
	if (process.platform !== 'win32') return '';
	assert.ok([0o600, 0o644].includes(requestedMode));
	return `
const modelFs = require('node:fs');
const modelPath = require('node:path');
const modelLeaf = ${JSON.stringify(leaf)};
const modelMode = ${requestedMode};
const modelUid = 1000;
process.getuid = () => modelUid;
const modelDescriptors = new Set();
const actualOpen = modelFs.openSync;
const actualClose = modelFs.closeSync;
const actualLstat = modelFs.lstatSync;
const actualFstat = modelFs.fstatSync;
const ownsLeaf = (file) => typeof file === 'string' && modelPath.resolve(file) === modelLeaf;
const observed = (record) => {
	if (record.isFile()) {
		if (typeof record.uid === 'bigint') {
			record.uid = BigInt(modelUid);
			record.mode = (record.mode & ~0o7777n) | BigInt(modelMode);
		} else {
			record.uid = modelUid;
			record.mode = (record.mode & ~0o7777) | modelMode;
		}
	}
	return record;
};
modelFs.openSync = (file, ...args) => {
	const fd = actualOpen(file, ...args);
	if (ownsLeaf(file)) modelDescriptors.add(fd);
	return fd;
};
modelFs.closeSync = (fd) => { modelDescriptors.delete(fd); return actualClose(fd); };
modelFs.lstatSync = (file, ...args) => {
	const record = actualLstat(file, ...args);
	return ownsLeaf(file) ? observed(record) : record;
};
modelFs.fstatSync = (fd, ...args) => {
	const record = actualFstat(fd, ...args);
	return modelDescriptors.has(fd) ? observed(record) : record;
};
`;
};
let unavailableFileOperations = 0;
const checkReceiptOperation = (label, action) => {
	try {
		action();
	} catch (error) {
		if (process.platform !== 'win32' || !['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code))
			throw error;
		unavailableFileOperations++;
		console.log(`SKIP ${label}: host file operation unavailable; no native ownership proof.`);
		return;
	}
	passed++;
	console.log(`PASS ${label}`);
};

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'lease165-receiver-controls-'));
try {
	const git = (args) =>
		execFileSync('git', args, {
			cwd: scratch,
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe']
		});
	git(['init', '-q']);
	const put = (relative, text) => {
		const file = path.join(scratch, relative);
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, text);
		return file;
	};
	for (const cohort of corpus.cohorts)
		put(
			cohort.source,
			cohort.names.map((name) => `func ${/ (test\w+)\]$/.exec(name)[1]}() {}`).join('\n') + '\n'
		);
	put(
		'static/ergopti_plus/macos/launcher/Package.swift',
		'// Controlled source inventory fixture; never native readiness.\n'
	);
	put('tools/test/fixtures/lease165-native-xctest-corpus.json', JSON.stringify(corpus) + '\n');
	put(
		'static/ergopti_plus/macos/launcher/Sources/Fixture/bytes.bin',
		Buffer.from([255, 0, 192, 10])
	);
	git(['add', '.']);
	git([
		'-c',
		'user.name=Receiver fixture',
		'-c',
		'user.email=fixture@example.invalid',
		'commit',
		'-qm',
		'Controlled receiver source fixture'
	]);
	const sha = git(['rev-parse', 'HEAD']).trim();
	const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
	const initial = reader.sourceReceipt(scratch, sha, arch, arch);
	const log = put('evidence/selected.log', valid);
	const before = path.join(scratch, 'evidence/before.json'),
		verdict = path.join(scratch, 'evidence/verdict.json');
	check('source receipt binds raw nonUTF8 bytes', () =>
		assert.equal(
			initial.sources['static/ergopti_plus/macos/launcher/Sources/Fixture/bytes.bin'],
			require('node:crypto')
				.createHash('sha256')
				.update(Buffer.from([255, 0, 192, 10]))
				.digest('hex')
		)
	);
	check('wrong commit refused', () =>
		assert.throws(() => reader.sourceReceipt(scratch, '0'.repeat(40), arch, arch))
	);
	check('wrong architecture refused', () =>
		assert.throws(() =>
			reader.sourceReceipt(scratch, sha, arch, arch === 'arm64' ? 'x86_64' : 'arm64')
		)
	);
	check('wrong source method set refused', () => {
		const file = path.join(scratch, corpus.cohorts[0].source),
			original = fs.readFileSync(file);
		fs.writeFileSync(file, Buffer.concat([original, Buffer.from('\nfunc testForeign() {}\n')]));
		git(['add', corpus.cohorts[0].source]);
		git([
			'-c',
			'user.name=Receiver fixture',
			'-c',
			'user.email=fixture@example.invalid',
			'commit',
			'-qm',
			'Malformed method model'
		]);
		assert.throws(() =>
			reader.sourceReceipt(scratch, git(['rev-parse', 'HEAD']).trim(), arch, arch)
		);
		fs.writeFileSync(file, original);
		git(['add', corpus.cohorts[0].source]);
		git([
			'-c',
			'user.name=Receiver fixture',
			'-c',
			'user.email=fixture@example.invalid',
			'commit',
			'-qm',
			'Restore controlled method model'
		]);
	});
	const candidate = git(['rev-parse', 'HEAD']).trim();
	const command = (args, receiptMode = 0o600) =>
		spawnSync(
			process.execPath,
			[
				'-e',
				modeledReceiptBootstrap(
					path.join(scratch, 'evidence/lease165-swift-child-status.txt'),
					receiptMode
				) +
					'process.exitCode = require(process.argv[1]).main(process.argv.slice(3), process.argv[2]);',
				path.resolve(__dirname, '../diagnostics/lease165_xctest_evidence.cjs'),
				scratch,
				...args
			],
			{ encoding: 'utf8', timeout: 10000 }
		);
	check('actual CLI begin and judge source-held model', () => {
		const begun = command(['begin', candidate, arch, arch, before]);
		assert.equal(begun.status, 0, begun.stderr);
		assert.equal(begun.stdout, '');
		// Modeled child status preparation only; never a native Swift execution receipt.
		fs.writeFileSync(path.join(scratch, 'evidence/lease165-swift-child-status.txt'), '0\n', {
			flag: 'wx',
			mode: 0o600
		});
		const judged = command(['judge', log, '0', '0', candidate, arch, arch, before, verdict]);
		assert.equal(judged.status, 0, judged.stderr);
		const receipt = JSON.parse(fs.readFileSync(verdict, 'utf8'));
		assert.equal(receipt.complete, true);
		assert.equal(receipt.full_package_qualified, false);
		assert.equal(receipt.source.candidate, candidate);
		assert.equal(receipt.passed, 165);
	});
	check('changed source receipt refused', () => {
		const changed = path.join(scratch, 'evidence/changed.json');
		const record = JSON.parse(fs.readFileSync(before, 'utf8'));
		record.sources['static/ergopti_plus/macos/launcher/Package.swift'] = '0'.repeat(64);
		fs.writeFileSync(changed, JSON.stringify(record));
		const result = command([
			'judge',
			log,
			'0',
			'0',
			candidate,
			arch,
			arch,
			changed,
			path.join(scratch, 'evidence/changed-verdict.json')
		]);
		assert.equal(result.status, 1);
		assert.equal(result.stdout, '');
		assert.ok(!fs.existsSync(path.join(scratch, 'evidence/changed-verdict.json')));
	});
	check('untracked implicit compiler input refused', () => {
		const file = put(
			'static/ergopti_plus/macos/launcher/Sources/Fixture/foreign.swift',
			'// foreign\n'
		);
		assert.throws(() => reader.sourceReceipt(scratch, candidate, arch, arch));
		fs.unlinkSync(file);
	});
	checkReceiptOperation('symlink capture refused', () => {
		const link = path.join(scratch, 'evidence/alias.log');
		fs.symlinkSync(log, link);
		assert.throws(() => reader.readBoundedRegular(link, 16777216));
	});
	check('oversize capture refused', () => assert.throws(() => reader.readBoundedRegular(log, 1)));
	checkReceiptOperation('hardlink capture refused', () => {
		const link = path.join(scratch, 'evidence/hard.log');
		fs.linkSync(log, link);
		assert.throws(() => reader.readBoundedRegular(log, 16777216));
		fs.unlinkSync(link);
	});
	check('exclusive verdict ownership preserved', () => {
		const result = command(['judge', log, '0', '0', candidate, arch, arch, before, verdict]);
		assert.equal(result.status, 1);
	});
	check('actual CLI nonzero pipeline remains refused', () => {
		const file = path.join(scratch, 'evidence/failure.json');
		const result = command(['judge', log, '1', '0', candidate, arch, arch, before, file]);
		assert.equal(result.status, 1);
		assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).complete, false);
	});
	// Fixed independent BEFORE requirements; all status files below are software models.
	const directStatusFile = path.join(scratch, 'evidence/lease165-swift-child-status.txt');
	const directVectors = [
		['complete165_child0_wrapper0_capture0', 'regular', '0\n', '0', '0', 'valid', true],
		['complete165_child1_wrapper0', 'regular', '1\n', '0', '0', 'valid', false],
		['complete165_child_missing', 'absent', null, '0', '0', 'valid', false],
		['complete165_child_nonnumeric', 'regular', 'not-a-status\n', '0', '0', 'valid', false],
		['complete165_child_out_of_range', 'regular', '256\n', '0', '0', 'valid', false],
		['complete165_child_noncanonical', 'regular', '00\n', '0', '0', 'valid', false],
		['complete165_child_extra_content', 'regular', '0\n1\n', '0', '0', 'valid', false],
		['complete165_child_symlink', 'symlink', '0\n', '0', '0', 'valid', false],
		['complete165_child_hardlink', 'hardlink', '0\n', '0', '0', 'valid', false],
		['complete165_child_foreign_owner', 'foreign-uid-port', '0\n', '0', '0', 'valid', false],
		['complete165_child0_wrapper1', 'regular', '0\n', '1', '0', 'valid', false],
		['complete165_child0_capture1', 'regular', '0\n', '0', '1', 'valid', false],
		['incomplete165_child0', 'regular', '0\n', '0', '0', 'incomplete', false],
		['failed_case_child0', 'regular', '0\n', '0', '0', 'failed', false],
		['skipped_case_child0', 'regular', '0\n', '0', '0', 'skipped', false],
		['changed_source_child0', 'regular', '0\n', '0', '0', 'changed', false],
		['complete165_child_empty_receipt', 'regular', '', '0', '0', 'valid', false],
		['complete165_child_no_final_lf', 'regular', '0', '0', '0', 'valid', false],
		['complete165_child_permissive_mode', 'mode0644', '0\n', '0', '0', 'valid', false]
	];
	assert.equal(directVectors.length, 19);
	for (const [name, kind, bytes, wrapper, capture, shape, expected] of directVectors) {
		checkReceiptOperation(`direct child frozen requirement ${name}`, () => {
			try {
				fs.unlinkSync(directStatusFile);
			} catch (error) {
				if (error.code !== 'ENOENT') throw error;
			}
			const target = path.join(scratch, `evidence/${name}-target.txt`);
			if (kind === 'symlink') {
				fs.writeFileSync(target, bytes, { flag: 'wx', mode: 0o600 });
				fs.symlinkSync(target, directStatusFile);
			} else if (kind !== 'absent') {
				fs.writeFileSync(directStatusFile, bytes, { flag: 'wx', mode: 0o600 });
				if (kind === 'hardlink') fs.linkSync(directStatusFile, target);
				if (kind === 'mode0644') fs.chmodSync(directStatusFile, 0o644);
			}
			let text = valid;
			if (shape === 'incomplete') text = valid.replace(terminal(first) + '\n', '');
			if (shape === 'failed')
				text = valid.replace(terminal(first), terminal(first).replace('passed', 'failed'));
			if (shape === 'skipped')
				text = valid.replace(terminal(first), terminal(first).replace('passed', 'skipped'));
			const vectorLog = put(`evidence/${name}.log`, text);
			const vectorVerdict = path.join(scratch, `evidence/${name}.json`);
			const args = [
				'judge',
				vectorLog,
				wrapper,
				capture,
				candidate,
				arch,
				arch,
				shape === 'changed' ? path.join(scratch, 'evidence/changed.json') : before,
				vectorVerdict
			];
			// No chown or native authority: model only the public current-UID port.
			const result =
				kind === 'foreign-uid-port'
					? spawnSync(
							process.execPath,
							[
								'-e',
								modeledReceiptBootstrap(directStatusFile) +
									'const actualUid = process.getuid(); process.getuid = () => actualUid + 1; process.exitCode = require(process.argv[1]).main(process.argv.slice(3), process.argv[2]);',
								path.resolve(__dirname, '../diagnostics/lease165_xctest_evidence.cjs'),
								scratch,
								...args
							],
							{ encoding: 'utf8', timeout: 10000 }
						)
					: command(args, kind === 'mode0644' ? 0o644 : 0o600);
			assert.equal(result.status, expected ? 0 : 1, result.stderr);
			if (fs.existsSync(vectorVerdict)) {
				const record = JSON.parse(fs.readFileSync(vectorVerdict, 'utf8'));
				assert.equal(record.complete, expected);
				assert.equal(record.full_package_qualified, false);
				assert.equal(record.swift_status, Number(bytes));
				assert.equal(record.wrapper_status, Number(wrapper));
				assert.equal(record.capture_status, Number(capture));
			} else {
				assert.equal(expected, false);
				assert.equal(result.stdout, '');
			}
			if (fs.existsSync(target)) fs.unlinkSync(target);
			// Restore the modeled old38 setup for the next vector without a success override.
			try {
				fs.unlinkSync(directStatusFile);
			} catch (error) {
				if (error.code !== 'ENOENT') throw error;
			}
			fs.writeFileSync(directStatusFile, '0\n', { flag: 'wx', mode: 0o600 });
		});
	}
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(`Lease165 receiver controls: ${passed} passed, 0 failed; native execution unrun.`);
console.log(
	`Receipt host models: Windows UID/mode=${process.platform === 'win32'}; file operations skipped=${unavailableFileOperations}; native ownership unavailable on Windows.`
);
