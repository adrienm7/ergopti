'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const directory = path.resolve(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'findings.json'), 'utf8'));
assert.equal(manifest.schema_version, 1);
assert.equal(manifest.scope, 'windows-runtime');
assert.match(manifest.audited_sha, /^[0-9a-f]{40}$/);
assert.equal(manifest.created_at, '2026-11-05');
assert.equal(manifest.report_path, path.join(directory, 'report.md'));
assert.ok(fs.statSync(manifest.report_path).size > 0);
assert.ok(Array.isArray(manifest.findings));
assert.equal(manifest.findings.length, 0);
const receipts = [1, 2].map((pass) => {
	const text = fs.readFileSync(path.join(directory, 'logs', `dry-pass-${pass}.txt`), 'utf8');
	assert.ok(text.includes('RESULT 17 passed; native Windows functions NOT invoked'));
	const receipt = JSON.parse(text.slice(text.indexOf('{')));
	assert.equal(receipt.pass, pass);
	assert.equal(receipt.source_count, 19);
	assert.equal(receipt.new_confirmed_findings, 0);
	assert.equal(receipt.native_windows_executed, false);
	return receipt;
});
assert.deepEqual(receipts[0].sources, receipts[1].sources);
console.log(
	'PASS windows-runtime scratch report schema, empty confirmed set, two dry receipts and 19 identical source identities'
);
