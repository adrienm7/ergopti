// tools/test/test-codegen-proxy-precedence.cjs

/**
 * ==============================================================================
 * MODULE: Proxy Precedence Shell Projection Gate
 * DESCRIPTION:
 * The shell scripts' proxy expansions are generated from proxy_policy.json
 * (codegen-proxy-precedence.cjs). This gate pins that:
 *   1. the committed scripts equal the projection (a hand edit, or a policy
 *      change without regeneration, is red);
 *   2. a different precedence in the policy really changes the projection, and
 *      only the two expansions (no_proxy, http_proxy and other defaults stay);
 *   3. a malformed policy is refused instead of projected.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
	project,
	generate,
	SOURCE,
	SCRIPTS,
	OWNED_ELSEWHERE
} = require('../codegen/codegen-proxy-precedence.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
generate(ROOT, { check: true });

const policy = JSON.parse(fs.readFileSync(path.join(ROOT, SOURCE), 'utf8'));
const reordered = structuredClone(policy);
reordered.environment_precedence.https = ['ALL_PROXY', 'all_proxy', 'HTTPS_PROXY', 'https_proxy'];
// The script the bootstrap-retry generator owns must also agree with the policy.
for (const script of OWNED_ELSEWHERE)
	assert.equal(
		project(fs.readFileSync(path.join(ROOT, script), 'utf8'), policy),
		fs.readFileSync(path.join(ROOT, script), 'utf8'),
		`${script} drifted from ${SOURCE}`
	);
for (const script of [...SCRIPTS, ...OWNED_ELSEWHERE]) {
	const text = fs.readFileSync(path.join(ROOT, script), 'utf8');
	const changed = project(text, reordered);
	assert.notEqual(changed, text, `${script} must follow the policy precedence`);
	assert.ok(changed.includes('${ALL_PROXY:-${all_proxy:-${HTTPS_PROXY:-${https_proxy:-}}}}'));
	assert.equal(project(changed, policy), text, `${script} projection must be reversible`);
	for (const untouched of text.match(/\$\{(?:NO_PROXY|no_proxy|http_proxy):-[^}]*\}/g) || [])
		assert.ok(changed.includes(untouched), `${untouched} must stay as written`);
}
for (const bad of [
	{ ...policy, environment_precedence: { https: ['https_proxy'] } },
	{ ...policy, environment_precedence: { https: ['a b', 'c'] } },
	{ ...policy, system_lookup_environment_exclusions: ['x', 'x'] }
])
	assert.throws(() => project('x', bad));
console.log('[OK] proxy precedence shell projection: committed, policy-driven, closed.');
