import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
const root = process.argv[2];
const m = JSON.parse(fs.readFileSync(path.join(root, 'findings.json'), 'utf8'));
assert.equal(m.schema_version, 1);
assert.equal(m.scope, 'wpm-windows');
assert.match(m.audited_sha, /^[a-f0-9]{40}$/);
assert.match(m.created_at, /^\d{4}-\d{2}-\d{2}$/);
assert(fs.existsSync(path.join(root, m.report_path)));
const ids = new Set();
for (const f of m.findings) {
	assert.match(f.id, /^WPMW-\d{3}$/);
	assert(!ids.has(f.id));
	ids.add(f.id);
	for (const k of [
		'title',
		'severity',
		'confidence',
		'reproduction',
		'root_cause',
		'silent_failure',
		'regression_test'
	])
		assert.equal(typeof f[k], 'string');
	assert(['critical', 'high', 'medium', 'low'].includes(f.severity));
	assert(['high', 'medium', 'low'].includes(f.confidence));
	assert(f.guarantees.length > 0 && f.guarantees.every((g) => /^G[1-5]$/.test(g)));
	for (const e of f.evidence) {
		assert(!path.isAbsolute(e));
		assert(fs.existsSync(path.join(root, e)));
	}
}
for (const file of ['report.md', 'findings.json', 'coverage.json'])
	assert(!fs.readFileSync(path.join(root, file), 'utf8').includes('\r'));
console.log(
	`PASS scratch schema1; ${m.findings.length} findings; IDs/severity/confidence/G1-G5/required text/evidence existence/UTF8-LF checked.`
);
console.log(
	'Repository workflow.cjs validator not applicable to the scratch contract: refused report outside repository, and requires docs/audits/<ahk|hammerspoon>/<date>/ paths plus platform IDs. No repository write used to bypass that refusal.'
);
