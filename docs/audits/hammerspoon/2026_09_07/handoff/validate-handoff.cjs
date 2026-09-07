// docs/audits/hammerspoon/2026_09_07/handoff/validate-handoff.cjs

'use strict';

// The repository CLI permits one immutable report per date. Validate this
// additional handoff without replacing that date's original evidence.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '../../../../..');
const report = JSON.parse(fs.readFileSync(path.join(__dirname, 'findings.json'), 'utf8'));
assert.equal(report.schema_version, 1);
assert.equal(report.scope, 'hammerspoon');
assert.match(report.audited_sha, /^[0-9a-f]{40}$/);
assert.equal(report.created_at, '2026-09-07');
assert.equal(report.report_path, 'docs/audits/hammerspoon/2026_09_07/handoff/report.md');
execFileSync('git', ['cat-file', '-e', report.audited_sha + '^{commit}'], { cwd: root });
const previous = JSON.parse(fs.readFileSync(path.join(__dirname, '../findings.json'), 'utf8'));
const previousIds = new Set(previous.findings.map(finding => finding.id));
const seen = new Set();
assert.ok(Array.isArray(report.findings) && report.findings.length > 0);
for (const finding of report.findings) {
    assert.match(finding.id, /^HS-\d{3}$/);
    assert.ok(!seen.has(finding.id) && !previousIds.has(finding.id), finding.id);
    seen.add(finding.id);
    assert.ok(['critical', 'high', 'medium', 'low'].includes(finding.severity));
    assert.ok(['high', 'medium', 'low'].includes(finding.confidence));
    assert.ok(Array.isArray(finding.guarantees) && finding.guarantees.length > 0);
    for (const guarantee of finding.guarantees) assert.match(guarantee, /^G[1-5]$/);
    for (const field of ['title', 'reproduction', 'root_cause', 'silent_failure', 'regression_test']) {
        assert.ok(typeof finding[field] === 'string' && finding[field].trim(), finding.id + ':' + field);
    }
}
for (const filename of ['TODO.md', 'report.md']) {
    const content = fs.readFileSync(path.join(__dirname, filename), 'utf8');
    assert.ok(!content.includes('\r'), filename + ' must use LF');
    for (const id of seen) assert.ok(content.includes(id), filename + ' missing ' + id);
    for (const match of content.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
        const target = match[1].split('#')[0];
        if (!target || /^[a-z]+:/i.test(target)) continue;
        assert.ok(fs.existsSync(path.resolve(__dirname, target)), filename + ': missing ' + target);
    }
}
console.log('Handoff validated: ' + seen.size + ' unique confirmed findings, source commit, fields and local links.');
