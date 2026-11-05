'use strict';
const fs = require('node:fs'),
	path = require('node:path'),
	assert = require('node:assert/strict');
const base = path.resolve(__dirname, '..'),
	manifest = JSON.parse(fs.readFileSync(path.join(base, 'findings.json'), 'utf8'));
assert.equal(manifest.schema_version, 1);
assert.equal(manifest.scope, 'windows-diagnostics');
assert.equal(manifest.audited_sha, '3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a');
assert.equal(manifest.created_at, '2026-11-05');
assert.equal(
	manifest.report_path,
	'docs/audits/platform-parity/2026-11-05-native-ui/windows-diagnostics/report.md'
);
assert.equal(manifest.findings.length, 1);
for (const f of manifest.findings) {
	assert.match(f.id, /^WDG-\d{3}$/);
	assert.ok(['critical', 'high', 'medium', 'low'].includes(f.severity));
	assert.ok(['high', 'medium', 'low'].includes(f.confidence));
	for (const k of ['title', 'reproduction', 'root_cause', 'silent_failure', 'regression_test'])
		assert.ok(typeof f[k] === 'string' && f[k].length > 0);
	assert.ok(f.guarantees.length);
}
const receipts = [1, 2].map((n) => {
	const s = fs.readFileSync(path.join(base, 'logs', `dry-pass-${n}.txt`), 'utf8');
	assert.ok(s.includes('RESULT 8 controls passed'));
	assert.ok(
		s.includes('CONFIRMED both unchanged production crash writers retain truncated canonical JSON')
	);
	const r = JSON.parse(s.split('RECEIPT ')[1]);
	assert.equal(r.pass, n);
	assert.equal(r.new_roots_after_last_finding, 0);
	assert.equal(r.sources.length, 26);
	assert.equal(r.native_windows_executed, false);
	return r;
});
assert.deepEqual(receipts[0].sources, receipts[1].sources);
assert.ok(fs.statSync(path.join(base, 'report.md')).size > 1000);
console.log(
	'PASS campaign schema, WDG-001 fields/enums, actual partial-write proof, two dry passes and 26 unchanged source identities'
);
