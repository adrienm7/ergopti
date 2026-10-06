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
