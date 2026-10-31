// tools/test/test-macos-swiftpm-cache-scope.cjs

/**
 * ==============================================================================
 * MODULE: macOS SwiftPM Build Cache Scope
 * DESCRIPTION:
 * The Intel XCTest cell of the macOS E2E stage restores a cached SwiftPM build
 * tree, as a trial: its cold debug build took 215 s of the cell on run
 * 40498535042. A cached build must never reach packaging, the launch lots or
 * any other cell, whose builds stay clean.
 *
 * FEATURES & RATIONALE:
 * 1. Every actions/cache step of every workflow whose path holds a Swift build
 *    tree is one of exactly two steps: the restore and the save in e2e-hs,
 *    guarded to the managed-ollama-native role and its xctest scenario. The
 *    SwiftPM dependency caches (artifacts, checkouts, repositories) hold
 *    downloaded package sources, not build products, and stay as they are.
 * 2. The restore has no restore-keys, so a partial key never restores a stale
 *    tree, and both steps use the one key the naming step computes.
 * 3. Mutation control: the same cache in package-macos, a second role, or a
 *    fallback key is refused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const YAML = require('yaml');

const ROOT = path.resolve(__dirname, '..', '..');
const WORKFLOWS = path.join(ROOT, '.github', 'workflows');
const GUARD =
	"steps.stage-admission.outcome == 'success' && env.MACOS_STAGE_ROLE == 'managed-ollama-native'";
const KEY = '${{ steps.swiftpm-xctest-key.outputs.key }}';
const PATH = '${{ env.ERGOPTI_OLLAMA_BUILD_ROOT }}/swift';
const EXPECTED = [
	{
		file: 'ci-macos.yml',
		job: 'e2e-hs',
		name: 'Restore the Intel XCTest SwiftPM build',
		uses: 'actions/cache/restore@v4',
		if: '${{ ' + GUARD + " && (env.MACOS_STAGE_SCENARIO == 'xctest') }}",
		with: { path: PATH, key: KEY }
	},
	{
		file: 'ci-macos.yml',
		job: 'e2e-hs',
		name: 'Save the Intel XCTest SwiftPM build',
		uses: 'actions/cache/save@v4',
		if:
			'${{ ' +
			GUARD +
			" && (env.MACOS_STAGE_SCENARIO == 'xctest' && steps.swiftpm-xctest-cache.outputs.cache-hit != 'true') }}",
		with: { path: PATH, key: KEY }
	}
];

/**
 * Lists the cache steps of the given workflow texts that touch a Swift build.
 * @param {Object<string,string>} texts Workflow file name -> YAML text.
 * @returns {object[]} One record per step, in file and job order.
 */
function swiftCaches(texts) {
	const found = [];
	for (const [file, text] of Object.entries(texts)) {
		const jobs = YAML.parse(text).jobs || {};
		for (const [job, body] of Object.entries(jobs)) {
			for (const step of body.steps || []) {
				if (!/^actions\/cache(\/(restore|save))?@/.test(step.uses || '')) continue;
				const paths = String((step.with || {}).path || '')
					.split('\n')
					.map((line) => line.trim())
					.filter(Boolean);
				const buildTree = paths.some(
					(line) =>
						/swift|\.build/i.test(line) && !/\/(artifacts|checkouts|repositories)$/.test(line)
				);
				if (!buildTree) continue;
				found.push({ file, job, name: step.name, uses: step.uses, if: step.if, with: step.with });
			}
		}
	}
	return found;
}

const texts = Object.fromEntries(
	fs
		.readdirSync(WORKFLOWS)
		.filter((name) => name.endsWith('.yml'))
		.map((name) => [name, fs.readFileSync(path.join(WORKFLOWS, name), 'utf8')])
);
assert.ok(Object.keys(texts).includes('ci-macos.yml'), 'the macOS workflow is scanned');
assert.deepEqual(swiftCaches(texts), EXPECTED, 'only the Intel XCTest cell caches a Swift build');

const naming = YAML.parse(texts['ci-macos.yml']).jobs['e2e-hs'].steps.find(
	(step) => step.id === 'swiftpm-xctest-key'
);
assert.ok(naming, 'the cache key has one naming step');
for (const input of [
	'git ls-files -s static/ergopti_plus/macos/launcher .github/ci',
	'"$ImageOS" "$ImageVersion"',
	'swift --version',
	'"$ERGOPTI_DEV_RELEASE_RELEASE"'
])
	assert.ok(naming.run.includes(input), 'the key names ' + input);

// ===== Mutation control =====

const mac = texts['ci-macos.yml'];
const restore = '          key: ${{ steps.swiftpm-xctest-key.outputs.key }}\n      - name: Report';
assert.ok(mac.includes(restore), 'the restore step is locatable');
for (const [what, changed] of [
	[
		'a fallback key',
		mac.replace(
			restore,
			'          key: ${{ steps.swiftpm-xctest-key.outputs.key }}\n          restore-keys: swiftpm-intel-xctest-\n      - name: Report'
		)
	],
	[
		'another role',
		mac.replace(
			'if: ${{ ' +
				GUARD +
				" && (env.MACOS_STAGE_SCENARIO == 'xctest') }}\n        uses: actions/cache/restore@v4",
			'if: ${{ ' + GUARD + ' }}\n        uses: actions/cache/restore@v4'
		)
	],
	[
		'packaging',
		mac.replace(
			/^  package-macos:\n([\s\S]*?)^    steps:\n/m,
			(block) =>
				block +
				'      - uses: actions/cache@v4\n        with:\n          path: static/ergopti_plus/macos/launcher/.build\n          key: swift-build\n'
		)
	]
]) {
	assert.notEqual(changed, mac, what + ' must actually mutate the workflow');
	assert.throws(
		() => assert.deepEqual(swiftCaches({ ...texts, 'ci-macos.yml': changed }), EXPECTED),
		what + ' must be refused'
	);
}
console.log('macos-swiftpm-cache-scope: OK (the Intel XCTest cell alone caches its Swift build)');
