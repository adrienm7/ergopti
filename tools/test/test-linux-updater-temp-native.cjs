// tools/test/test-linux-updater-temp-native.cjs

/** Independent original twelve-case receipt corpus; no native execution here. */
'use strict';
const assert = require('node:assert/strict');
const runner = require('./run-linux-updater-temp-native.cjs');
const HEAD = '0123456789abcdef0123456789abcdef01234567';
// Manually retained from the original fixture's independent case oracles.
const corpus = {
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
let count = 0;
function control(name, body) {
	body();
	count++;
}
for (const family of ['ownership', 'allocation']) {
	const lines = corpus[family].map((label) => 'PASS native ' + label);
	const summary = 'Native updater temporary ' + family + ' receipts: 12 checks, 0 failures';
	const good = {
		status: 0,
		signal: null,
		error: null,
		stdout: [...lines, summary].join('\n') + '\n',
		stderr: ''
	};
	control(family + ' complete original corpus', () =>
		assert.equal(runner.fixtureReceipt(family, good), true)
	);
	control(family + ' failed exit', () =>
		assert.equal(runner.fixtureReceipt(family, { ...good, status: 1 }), false)
	);
	control(family + ' signal', () =>
		assert.equal(runner.fixtureReceipt(family, { ...good, signal: 'SIGTERM' }), false)
	);
	control(family + ' unknown closure', () =>
		assert.equal(runner.fixtureReceipt(family, { ...good, error: 'owned_cleanup_pending' }), false)
	);
	control(family + ' stderr', () =>
		assert.equal(
			runner.fixtureReceipt(family, { ...good, stderr: 'unqualified native failure' }),
			false
		)
	);
	control(family + ' missing case', () =>
		assert.equal(
			runner.fixtureReceipt(family, { ...good, stdout: good.stdout.replace(lines[0] + '\n', '') }),
			false
		)
	);
	control(family + ' duplicate case', () =>
		assert.equal(
			runner.fixtureReceipt(family, { ...good, stdout: lines[0] + '\n' + good.stdout }),
			false
		)
	);
	control(family + ' wrong order', () =>
		assert.equal(
			runner.fixtureReceipt(family, {
				...good,
				stdout: [lines[1], lines[0], ...lines.slice(2), summary].join('\n') + '\n'
			}),
			false
		)
	);
	control(family + ' retained namespace', () =>
		assert.equal(
			runner.fixtureReceipt(family, {
				...good,
				stdout: 'RETAINED native updater fixture inputs: closure not qualified\n' + good.stdout
			}),
			false
		)
	);
	control(family + ' partial final line', () =>
		assert.equal(
			runner.fixtureReceipt(family, { ...good, stdout: good.stdout.slice(0, -1) }),
			false
		)
	);
	control(family + ' failure summary', () =>
		assert.equal(
			runner.fixtureReceipt(family, {
				...good,
				stdout: good.stdout.replace('0 failures', '1 failures')
			}),
			false
		)
	);
	const receipt =
		'[OK] Linux updater namespace cleanup: SHA=' +
		HEAD +
		'; 5 actual checks; 0 skipped; closure complete.\n' +
		'[OK] Linux updater temporary ' +
		family +
		': SHA=' +
		HEAD +
		'; 24 actual checks; 0 skipped; closure complete.\n';
	control(family + ' dual ABI receipt', () =>
		assert.equal(runner.evidenceCount(family, receipt, HEAD), 24)
	);
	control(family + ' single ABI credit refused', () =>
		assert.throws(() =>
			runner.evidenceCount(family, receipt.replace('24 actual', '12 actual'), HEAD)
		)
	);
	control(family + ' wrong source head refused', () =>
		assert.throws(() =>
			runner.evidenceCount(family, receipt, 'ffffffffffffffffffffffffffffffffffffffff')
		)
	);
	control(family + ' duplicate evidence refused', () =>
		assert.throws(() => runner.evidenceCount(family, receipt + receipt, HEAD))
	);
}
control('unknown family cannot borrow native evidence', () =>
	assert.throws(() => runner.evidenceCount('foreign', '', HEAD))
);
control('malformed source head refuses', () =>
	assert.throws(() => runner.evidenceCount('ownership', '', 'HEAD'))
);
assert.equal(count, 32, 'Independent temporary updater receipt floor changed');
console.log('[OK] Linux updater temporary receipts: 32 source controls passed; no native credit.');

// Independently fixed native opaque-ABI receipt oracles. These do not execute C.
const namespaceCases = ['regular', 'hardlink', 'symlink', 'dangling', 'unexpected-basename'];
const nativeCorpus = {
	schema_version: 1,
	state: 'native_namespace_conflicts_passed',
	passed: 5,
	failed: 0,
	skipped: 0,
	fixture_debt: 0,
	native_owner_debt: 0,
	cases: namespaceCases.map((name) => ({
		case: name,
		passed: true,
		same_owner: true,
		conflicts: 2,
		fixture_competitor_removed: true,
		native_descriptors_closed: true,
		native_disposed_once: true,
		sentinel_preserved: true,
		fixture_debt: 0
	}))
};
const nativeGood = {
	status: 0,
	signal: null,
	error: null,
	stderr: '',
	stdout: JSON.stringify(nativeCorpus) + '\n'
};
function changedNamespace(change) {
	const copy = JSON.parse(JSON.stringify(nativeCorpus));
	change(copy);
	return { ...nativeGood, stdout: JSON.stringify(copy) + '\n' };
}
control('complete literal independent five-case C receipt', () =>
	assert.equal(runner.namespaceReceipt(nativeGood), true)
);
control('C failing exit cannot credit', () =>
	assert.equal(runner.namespaceReceipt({ ...nativeGood, status: 1 }), false)
);
control('C unknown native closure cannot credit', () =>
	assert.equal(runner.namespaceReceipt({ ...nativeGood, error: 'owned_cleanup_pending' }), false)
);
control('C unexpected stderr cannot credit', () =>
	assert.equal(runner.namespaceReceipt({ ...nativeGood, stderr: 'failure' }), false)
);
control('C omitted case cannot credit', () =>
	assert.equal(runner.namespaceReceipt(changedNamespace((row) => row.cases.pop())), false)
);
control('C duplicate case cannot credit', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.cases[1] = row.cases[0];
			})
		),
		false
	)
);
control('C skipped case cannot credit', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.skipped = 1;
			})
		),
		false
	)
);
control('C fixture FD debt cannot credit', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.fixture_debt = 1;
			})
		),
		false
	)
);
control('C native owner debt cannot credit', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.native_owner_debt = 1;
			})
		),
		false
	)
);
control('C one refusal cannot prove retry', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.cases[0].conflicts = 1;
			})
		),
		false
	)
);
control('C competitor removal cannot be inferred', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.cases[0].fixture_competitor_removed = false;
			})
		),
		false
	)
);
control('C old pointer cannot borrow successor', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.cases[0].same_owner = false;
			})
		),
		false
	)
);
control('C disposed authority must be literal true', () =>
	assert.equal(
		runner.namespaceReceipt(
			changedNamespace((row) => {
				row.cases[0].native_disposed_once = 1;
			})
		),
		false
	)
);
control('C partial final line cannot credit', () =>
	assert.equal(
		runner.namespaceReceipt({ ...nativeGood, stdout: nativeGood.stdout.slice(0, -1) }),
		false
	)
);
control('C duplicate JSON receipts cannot credit', () =>
	assert.equal(
		runner.namespaceReceipt({ ...nativeGood, stdout: nativeGood.stdout + nativeGood.stdout }),
		false
	)
);
const ownershipEvidence =
	'[OK] Linux updater namespace cleanup: SHA=' +
	HEAD +
	'; 5 actual checks; 0 skipped; closure complete.\n' +
	'[OK] Linux updater temporary ownership: SHA=' +
	HEAD +
	'; 24 actual checks; 0 skipped; closure complete.\n';
control('five C checks have separate native subject', () =>
	assert.equal(runner.evidenceCount('namespace', ownershipEvidence, HEAD), 5)
);
control('legacy family receipt missing mandatory C refused', () =>
	assert.throws(() =>
		runner.evidenceCount('ownership', ownershipEvidence.split('\n').slice(1).join('\n'), HEAD)
	)
);
assert.equal(count, 49, 'Independent C receipt extension floor changed');
console.log('[OK] Linux updater namespace receipts: 17 source controls passed; no native credit.');

// Actual filesystem admission controls; no child process or native qualification.
if (process.platform === 'linux') {
	const fs = require('node:fs');
	const os = require('node:os');
	const path = require('node:path');
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-temp-root-control-'));
	fs.chmodSync(work, 0o700);
	const owned = path.join(work, 'owned');
	fs.mkdirSync(owned, { mode: 0o700 });
	const select = (selected, extra = {}) =>
		runner.temporaryWorkRoot({ ...extra, ERGOPTI_UPDATER_TEMP_NATIVE_WORK_ROOT: selected });
	let admissionCount = 0;
	function admission(name, body) {
		body();
		admissionCount++;
	}
	try {
		admission('existing caller-owned root is selected without allocating', () => {
			assert.equal(select(owned), owned);
			assert.deepEqual(fs.readdirSync(owned), []);
		});
		admission('explicit root wins over generic TMPDIR', () => {
			assert.equal(select(owned, { TMPDIR: path.join(work, 'missing-tmpdir') }), owned);
			assert.equal(fs.existsSync(path.join(work, 'missing-tmpdir')), false);
		});
		admission('empty opt-in cannot fall back', () => assert.throws(() => select('')));
		admission('relative opt-in is refused', () => assert.throws(() => select('relative')));
		admission('non-string opt-in is refused', () => assert.throws(() => select(7)));
		admission('missing opt-in is refused without creating it', () => {
			const missing = path.join(work, 'missing');
			assert.throws(() => select(missing));
			assert.equal(fs.existsSync(missing), false);
		});
		admission('regular file is refused and preserved', () => {
			const file = path.join(work, 'file');
			fs.writeFileSync(file, 'sentinel', { mode: 0o600 });
			assert.throws(() => select(file));
			assert.equal(fs.readFileSync(file, 'utf8'), 'sentinel');
		});
		admission('symlink root including trailing slash is refused', () => {
			const link = path.join(work, 'link');
			fs.symlinkSync(owned, link);
			assert.throws(() => select(link));
			assert.throws(() => select(link + path.sep));
			assert.equal(fs.readlinkSync(link), owned);
			assert.deepEqual(fs.readdirSync(owned), []);
		});
		admission('symlink ancestor cannot hide behind an ordinary leaf', () => {
			const nested = path.join(owned, 'nested');
			fs.mkdirSync(nested, { mode: 0o700 });
			assert.throws(() => select(path.join(work, 'link', 'nested')));
			assert.deepEqual(fs.readdirSync(nested), []);
		});
		admission('public root is refused without chmod or allocation', () => {
			fs.chmodSync(owned, 0o755);
			assert.throws(() => select(owned));
			assert.equal(fs.lstatSync(owned).mode & 0o7777, 0o755);
			fs.chmodSync(owned, 0o700);
		});
		admission('special mode bits are refused without changing owner root', () => {
			fs.chmodSync(owned, 0o1700);
			assert.throws(() => select(owned));
			assert.equal(fs.lstatSync(owned).mode & 0o7777, 0o1700);
			fs.chmodSync(owned, 0o700);
		});
		assert.equal(admissionCount, 11, 'Independent work-root admission floor changed');
		console.log(
			'[OK] Linux updater work-root admission: 11 filesystem controls passed; no native credit.'
		);
	} finally {
		// Only this tiny control fixture is disposable, never a native runner work root.
		fs.rmSync(work, { recursive: true, force: true });
	}
}

// Drive the same environment producer used for every native family.
if (process.platform === 'linux') {
	const fs = require('node:fs');
	const os = require('node:os');
	const path = require('node:path');
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-tmpdir-control-'));
	fs.chmodSync(work, 0o700);
	try {
		const environment = {
			ERGOPTI_UPDATER_TEMP_NATIVE_WORK_ROOT: work,
			TMPDIR: work,
			PYTHONDONTWRITEBYTECODE: '0',
			LC_ALL: 'foreign',
			ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD: HEAD
		};
		assert.equal(runner.temporaryWorkRoot(environment), work);
		const native = runner.nativeFixtureEnvironment(environment);
		assert.equal(native.TMPDIR, '/var/tmp/ergopti-cloud-validation');
		assert.notEqual(native.TMPDIR, work, 'Opted clone root must not replace native fixture policy');
		assert.equal(native.PYTHONDONTWRITEBYTECODE, '1');
		assert.equal(native.LC_ALL, 'C.UTF-8');
		assert.equal(native.ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD, HEAD);
		assert.equal(environment.TMPDIR, work, 'Caller environment must remain unchanged');
		assert.deepEqual(fs.readdirSync(work), []);
		assert.equal(runner.nativeFixtureEnvironment({}).TMPDIR, '/var/tmp/ergopti-cloud-validation');
		console.log('[OK] Updater clone opt-in preserves canonical native TMPDIR; no native credit.');
	} finally {
		fs.rmSync(work, { recursive: true, force: true });
	}
}
