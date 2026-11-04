'use strict';
const assert = require('node:assert/strict'),
	fs = require('node:fs'),
	path = require('node:path');
const root = path.resolve(__dirname, '..');
const m = JSON.parse(fs.readFileSync(path.join(root, 'findings.json'), 'utf8'));
assert.equal(m.schema_version, 1);
assert.equal(m.scope, 'windows-crypto');
assert.equal(m.audited_sha, '213d65af24d2aa4845ba47743c9bab6787b61964');
assert.equal(m.created_at, '2026-11-04');
assert(fs.existsSync(m.report_path));
const ids = new Set();
for (const f of m.findings) {
	assert.match(f.id, /^WCR-\d{3}$/);
	assert(!ids.has(f.id));
	ids.add(f.id);
	for (const k of ['title', 'reproduction', 'root_cause', 'silent_failure', 'regression_test'])
		assert.equal(typeof f[k], 'string');
	assert(['critical', 'high', 'medium', 'low'].includes(f.severity));
	assert(['high', 'medium', 'low'].includes(f.confidence));
	assert(Array.isArray(f.guarantees));
	assert(f.guarantees.every((g) => /^G[1-5]$/.test(g)));
	if (f.guarantees.length === 0) assert.equal(typeof f.additional_property, 'string');
}
const ledger = JSON.parse(fs.readFileSync(path.join(__dirname, 'pass-ledger.json'), 'utf8'));
assert.equal(ledger.consecutive_dry_passes, 2);
assert(ledger.passes.slice(-2).every((p) => p.new_confirmed_root_causes.length === 0));
const bytes = fs.readFileSync(path.join(__dirname, 'windows-prefix-sql-migration.ahk'));
assert(bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf])));
assert(!bytes.includes(13));
console.log(
	'Requested scratch schema/IDs/G properties, two dry passes and AHK artifact BOM+LF: valid. Native AHK was not executed.'
);
