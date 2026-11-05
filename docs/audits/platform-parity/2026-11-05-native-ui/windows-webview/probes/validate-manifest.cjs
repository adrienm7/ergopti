'use strict';
const fs = require('node:fs'),
	assert = require('node:assert/strict'),
	path = require('node:path');
const dir = process.argv[2] || path.resolve(__dirname, '..');
const m = JSON.parse(fs.readFileSync(path.join(dir, 'findings.json'), 'utf8'));
assert.equal(m.schema_version, 1);
assert.equal(m.scope, 'windows-webview');
assert.equal(m.audited_sha, '3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a');
assert.equal(m.created_at, '2026-11-05');
assert(fs.existsSync(m.report_path));
const ids = new Set();
for (const f of m.findings) {
	assert(/^WVB-\d{3}$/.test(f.id));
	assert(!ids.has(f.id));
	ids.add(f.id);
	for (const k of ['title', 'reproduction', 'root_cause', 'silent_failure', 'regression_test'])
		assert(typeof f[k] === 'string' && f[k].length);
	assert(['critical', 'high', 'medium', 'low'].includes(f.severity));
	assert(['high', 'medium', 'low'].includes(f.confidence));
	assert(f.guarantees.length > 0 && f.guarantees.every((g) => /^G[1-5]$/.test(g)));
	for (const p of f.evidence) assert(fs.existsSync(path.join(dir, p)));
}
console.log(
	JSON.stringify({
		schema: 1,
		scope: m.scope,
		findings: m.findings.length,
		valid: true,
		limitation:
			'repository workflow validator only admits repository docs/audits/{ahk,hammerspoon}; scratch custom scope validated privately'
	})
);
