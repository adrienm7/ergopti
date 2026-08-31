// tools/test/test-linux-feature-parity.cjs

/**
 * ============================================================================
 * MODULE: Linux Feature Parity Evidence Tests
 * DESCRIPTION:
 * Ensures every canonical feature has an explicit Linux status, absence reason,
 * implementation state, owner, and proof tier without treating declaration as
 * runtime or hardware evidence.
 * ============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { buildParityRows, summarize } = require('./linux-feature-parity.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST_PATH = path.join(ROOT, 'static', 'ergopti_plus', 'linux', '_generated', 'features_manifest.lua');
const EVIDENCE_PATH = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'features', 'linux_evidence.json');
const manifest = fs.readFileSync(MANIFEST_PATH, 'utf8');
const evidenceConfig = JSON.parse(fs.readFileSync(EVIDENCE_PATH, 'utf8'));

function build(config = evidenceConfig) {
	return buildParityRows({ manifest, evidenceConfig: config, rootDirectory: ROOT });
}

const rows = build();
const summary = summarize(rows);
assert.strictEqual(summary.total, 324, 'the canonical Linux projection must classify all 324 features');
assert.ok(summary.claimed_supported >= 126, 'supported feature count may only increase from the audited 126');
assert.ok(summary.unavailable <= 198, 'unavailable feature count may only decrease from the audited 198');
assert.strictEqual(summary.claimed_supported + summary.unavailable, summary.total);
assert.strictEqual(rows.filter((row) => !row.reason?.kind).length, 0, 'every row needs a reason classification');
assert.strictEqual(rows.filter((row) => !row.owner).length, 0, 'every row needs an owner');
assert.strictEqual(rows.filter((row) => row.status === 'unavailable' && row.intentional === false && row.reason.kind !== 'linux_parity_gap').length, 0);
assert.strictEqual(summary.unverified_supported, 0,
	'every supported Linux feature needs software evidence instead of inheriting a declaration');
assert.strictEqual(summary.proven_above_declaration, summary.claimed_supported,
	'every supported Linux feature needs proof above the declaration tier');

const mutation = JSON.parse(JSON.stringify(evidenceConfig));
mutation.supported_defaults.proof_tier = 'unit';
assert.throws(() => build(mutation), /claims proof without a tracked evidence path/);

const missingField = JSON.parse(JSON.stringify(evidenceConfig));
delete missingField.supported_defaults.applied;
assert.throws(() => build(missingField), /missing evidence field applied/);

const unknown = JSON.parse(JSON.stringify(evidenceConfig));
unknown.overrides['does.not.exist'] = { registered: 'yes' };
assert.throws(() => build(unknown), /unknown path/);

const unknownGroupMember = JSON.parse(JSON.stringify(evidenceConfig));
unknownGroupMember.evidence_groups.unknown = {
	...unknownGroupMember.evidence_groups.gestures,
	members: ['does.not.exist'],
};
assert.throws(() => build(unknownGroupMember), /names unknown path/);

const duplicateGroupMember = JSON.parse(JSON.stringify(evidenceConfig));
duplicateGroupMember.evidence_groups.duplicate = {
	...duplicateGroupMember.evidence_groups.gestures,
	members: [duplicateGroupMember.evidence_groups.gestures.members[0]],
};
assert.throws(() => build(duplicateGroupMember), /belongs to more than one evidence group/);

if (process.argv.includes('--report')) {
	process.stdout.write(`${JSON.stringify({ summary, features: rows }, null, 2)}\n`);
} else {
	process.stdout.write(`PASS: ${summary.total} Linux features classified; ` +
		`${summary.claimed_supported} claimed supported, ${summary.unavailable} unavailable, ` +
		`${summary.parity_gaps} parity gaps, ${summary.unverified_supported} software claims unverified, ` +
		`${summary.hardware_pending} supported claims awaiting hardware proof.\n`);
}
