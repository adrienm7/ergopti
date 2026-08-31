// tools/test/test-linux-ci-evidence.cjs

/**
 * ============================================================================
 * MODULE: Linux CI Evidence Contract Tests
 * DESCRIPTION:
 * Mutation-tests every GitHub dependency result and the evidence requirements
 * that prevent linux-ok from accepting a skipped or unexecuted mandatory lane.
 * ============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { verifyAggregate } = require('./linux-ci-evidence.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(ROOT, '.github', 'linux-ci-coverage.json'), 'utf8'));
const WORKFLOW = fs.readFileSync(path.join(ROOT, '.github', 'workflows', 'ci.yml'), 'utf8');
const SHA = '0123456789abcdef';

function fixtures() {
	const needs = {};
	const evidence = [];
	for (const [job, contract] of Object.entries(MANIFEST.jobs)) {
		needs[job] = { result: 'success' };
		evidence.push({
			schema_version: 1,
			job,
			sha: SHA,
			architecture: 'X64',
			distro: 'test-distro',
			session: 'headless',
			interpreter: 'LuaJIT 2.1',
			subjects: { ...contract.subjects },
		});
	}
	return { needs, evidence };
}

function rejects(mutate, pattern) {
	const state = fixtures();
	mutate(state);
	assert.throws(() => verifyAggregate({
		manifest: MANIFEST,
		needs: state.needs,
		evidence: state.evidence,
		expectedSha: SHA,
	}), pattern);
}

verifyAggregate({ manifest: MANIFEST, ...fixtures(), expectedSha: SHA });

for (const result of ['failure', 'cancelled', 'skipped', null]) {
	rejects(({ needs }) => { needs['test-linux'].result = result; }, /mandatory job test-linux concluded/);
}
rejects(({ needs }) => { delete needs['test-linux']; }, /mandatory job test-linux is missing/);
rejects(({ evidence }) => { evidence[0].subjects.unit = 0; }, /no positive executed assertion count/);
rejects(({ evidence }) => { delete evidence[0].subjects.unit; }, /has no evidence for unit/);
rejects(({ evidence }) => { evidence[0].sha = 'wrong'; }, /evidence belongs to wrong/);
rejects(({ evidence }) => { evidence[0].subjects.unknown = 1; }, /unclassified subject/);
rejects(({ evidence }) => { evidence[0].job = 'unknown'; }, /unclassified job/);
rejects(({ evidence }) => { evidence.push({ ...evidence[0] }); }, /duplicate evidence/);
rejects(({ needs }) => { needs.unclassified = { result: 'success' }; }, /unclassified Linux job/);

assert.match(WORKFLOW, /node tools\/test\/linux-ci-evidence\.cjs verify/);
assert.match(WORKFLOW, /pattern:\s*linux-ci-evidence-\*/);
assert.doesNotMatch(WORKFLOW, /all \$total job\(s\) passed \(or skipped\)/);
assert.doesNotMatch(WORKFLOW, /no Wayland socket appeared[^\n]*[\s\S]{0,180}exit 0/);
assert.doesNotMatch(WORKFLOW, /WebKit\/lgi unavailable[^\n]*[\s\S]{0,180}exit 0/);
assert.doesNotMatch(WORKFLOW, /has no luajit package[^\n]*[\s\S]{0,180}exit 0/);

process.stdout.write('PASS: Linux CI requires successful jobs and complete assertion evidence.\n');
