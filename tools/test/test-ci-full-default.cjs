'use strict';

/** Constructed source controls only; skipped native work never receives credit. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Full = require('./ci-full-default.cjs');
const Raw = require('./ci-pipeline.cjs');
const Policy = require('../ci/dev-release-qualification.cjs');
const source = Raw.files();
const MAC = '.github/workflows/ci-macos.yml';
const ENTRY = '.github/workflows/ci.yml';
let passed = 0;
function check(name, fn) {
	fn();
	passed++;
}
function changed(rel, before, after) {
	return source.map((f) => {
		if (f.rel !== rel) return { ...f };
		assert.equal(f.text.split(before).length, 2, `one genuine mutation seam: ${before}`);
		return { ...f, text: f.text.replace(before, () => after) };
	});
}
check('raw loader remains raw and exact', () => {
	assert.equal(
		Raw.field(Raw.job('core'), 'if'),
		"needs.validate.outputs.fast_prerelease != 'true'"
	);
	assert.equal(Raw.field(Raw.job('tooltip-canvas'), 'if'), '${{ !inputs.fast_prerelease }}');
	for (const f of source) assert.equal(f.text, fs.readFileSync(`${Raw.ROOT}/${f.rel}`, 'utf8'));
});
check('opt-in mandatory full/default predicates', () => {
	assert.equal(Full.field(Full.job('core'), 'if'), null);
	assert.equal(Full.field(Full.job('tooltip-canvas'), 'if'), null);
	assert.equal(
		Full.field(Full.job('release'), 'if'),
		"github.event_name == 'push' && needs.validate.outputs.release == 'true'"
	);
	assert.equal(
		Full.stepField(
			Full.step(
				Full.job('managed-ollama-native'),
				'Qualify actual SDK accepted-owner and deadline XCTest controls'
			),
			'if'
		),
		null
	);
	assert.equal(
		Full.stepField(
			Full.step(
				Full.job('managed-ollama-native'),
				'Qualify actual native PAC and WPAD XCTest controls'
			),
			'if'
		),
		'${{ !cancelled() }}'
	);
});
check('all old product scripts remain exact', () => {
	for (const f of source)
		for (const j of Raw.jobsOfText(f.text, f.rel)) {
			for (const s of Raw.steps(j.body)) {
				if (
					[
						'Resolve authorized temporary fast prerelease',
						'Recheck temporary publication authorization',
						'Recheck temporary fast prerelease authorization',
						'Record UNQUALIFIED temporary test deferral',
						'Retain the explicit unqualified test receipt'
					].includes(s.name) ||
					!s.name
				)
					continue;
				assert.equal(
					Full.stepField(Full.step(Full.job(j.id), s.name), 'run'),
					Raw.stepField(s.body, 'run'),
					`${j.id}/${s.name}`
				);
			}
		}
});
for (const [name, rel, before, after] of [
	[
		'default true',
		MAC,
		'        default: false\n        type: boolean',
		'        default: true\n        type: boolean'
	],
	[
		'duplicate global authority',
		MAC,
		'  ERGOPTI_FAST_PRERELEASE: ${{ inputs.fast_prerelease }}\n',
		'  ERGOPTI_FAST_PRERELEASE: ${{ inputs.fast_prerelease }}\n  ERGOPTI_FAST_PRERELEASE: false\n'
	],
	[
		'wrong input type',
		MAC,
		'        default: false\n        type: boolean',
		'        default: false\n        type: string'
	],
	[
		'duplicate input',
		MAC,
		'      fast_prerelease:\n',
		'      fast_prerelease:\n        type: boolean\n      fast_prerelease:\n'
	],
	[
		'foreign selector',
		ENTRY,
		'run: node tools/ci/dev-release-qualification.cjs --fast-action select',
		'run: echo fast_prerelease=true >> "$GITHUB_OUTPUT"'
	],
	['skippable selector', ENTRY, '        id: fast\n', '        id: fast\n        if: false\n'],
	[
		'ignored selector error',
		ENTRY,
		'        id: fast\n',
		'        id: fast\n        continue-on-error: true\n'
	],
	[
		'duplicate selector context',
		ENTRY,
		'          ERGOPTI_DEV_RELEASE_TAG: ${{ steps.meta.outputs.tag }}\n',
		'          ERGOPTI_DEV_RELEASE_TAG: ${{ steps.meta.outputs.tag }}\n          ERGOPTI_DEV_RELEASE_TAG: v0.0.0-dev.158\n'
	],
	[
		'unbound output',
		ENTRY,
		'      fast_prerelease: ${{ steps.fast.outputs.fast_prerelease }}',
		'      fast_prerelease: true'
	],
	[
		'foreign job condition',
		MAC,
		'  managed-ollama-native:\n',
		'  managed-ollama-native:\n    if: ${{ inputs.fast_prerelease }}\n'
	],
	[
		'arbitrary SDK exclusion',
		MAC,
		'      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n        if: ${{ !inputs.fast_prerelease }}',
		'      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n        if: ${{ false }}'
	],
	[
		'arbitrary additional SDK predicate',
		MAC,
		'      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n        if: ${{ !inputs.fast_prerelease }}',
		'      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n        if: ${{ !inputs.fast_prerelease && false }}'
	],
	[
		'changed receipt command',
		MAC,
		'run: node tools/ci/dev-release-qualification.cjs --fast-action receipt --lane macos',
		'run: echo qualified:true'
	],
	[
		'missing actual needs',
		MAC,
		'          NEEDS: ${{ toJSON(needs) }}\n        run: node tools/ci/dev-release-qualification.cjs --fast-action receipt --lane macos',
		'          NEEDS: "{}"\n        run: node tools/ci/dev-release-qualification.cjs --fast-action receipt --lane macos'
	],
	[
		'wrong receipt path',
		MAC,
		'          path: fast-prerelease-macos.json',
		'          path: foreign.json'
	],
	[
		'ignored missing receipt',
		MAC,
		'          path: fast-prerelease-macos.json\n          if-no-files-found: error',
		'          path: fast-prerelease-macos.json\n          if-no-files-found: ignore'
	],
	[
		'wrong package admission',
		'.github/workflows/ci-windows.yml',
		'run: node tools/ci/dev-release-qualification.cjs --fast-action admit',
		'run: true'
	],
	[
		'changed pinned duplicate Node',
		'.github/workflows/ci-windows.yml',
		"node-version-file: '.node-version'\n\n      - name: Recheck temporary fast prerelease authorization",
		'node-version: latest\n\n      - name: Recheck temporary fast prerelease authorization'
	]
]) {
	check(`refuse ${name}`, () => assert.throws(() => Full.fromFiles(changed(rel, before, after))));
}
check('refuse genuine late package admission (ci-full-default-late-admission)', () => {
	const rel = '.github/workflows/ci-windows.yml';
	const entry = source.find((f) => f.rel === rel);
	const job = Raw.jobsOfText(entry.text, rel).find((j) => j.id === 'package-windows');
	const admission = Raw.step(job.body, 'Recheck temporary fast prerelease authorization');
	const build = Raw.step(job.body, 'Build and test native navigation event owner');
	const moved = job.body
		.replace(admission + '\n', '')
		.replace(build, () => build + '\n\n' + admission);
	assert.equal(
		Raw.steps(moved).filter((s) => s.name === 'Recheck temporary fast prerelease authorization')
			.length,
		1
	);
	assert.equal(
		Raw.steps(moved).filter((s) => s.name === 'Build and test native navigation event owner')
			.length,
		1
	);
	assert.ok(moved.indexOf(admission) > moved.indexOf(build));
	assert.throws(
		() => Full.fromFiles(changed(rel, job.body, moved)),
		/package-windows admission before product\/publication work/
	);
});
check('caller literal true is never normalized', () => {
	const rel = ENTRY;
	const f = source.find((f) => f.rel === rel);
	const j = Raw.jobsOfText(f.text, rel).find((j) => j.id === 'macos');
	const body = j.body.replace(
		"fast_prerelease: ${{ needs.validate.outputs.fast_prerelease == 'true' }}",
		'fast_prerelease: true'
	);
	assert.throws(() => Full.fromFiles(changed(rel, j.body, body)));
});
check('unknown conditions remain visible to old mandatory guards', () => {
	const modified = changed(
		MAC,
		'      - name: Admit the canonical native toolchain and public inputs\n',
		'      - name: Admit the canonical native toolchain and public inputs\n        if: false\n'
	);
	const view = Full.fromFiles(modified);
	assert.equal(
		view.stepField(
			view.step(
				view.job('managed-ollama-native'),
				'Admit the canonical native toolchain and public inputs'
			),
			'if'
		),
		'false'
	);
});
const context = {
	github_actions: 'true',
	repository: 'adrienm7/ergopti',
	event_name: 'push',
	ref: 'refs/heads/dev',
	release: true,
	prerelease: 'true',
	channel: 'dev',
	tag: 'v0.0.0-dev.157',
	version: '0.0.0-dev.157'
};
const eligible = new Date('2026-10-09T14:00:00Z');
check('sole authorized diagnostic context', () =>
	assert.equal(Policy.fastPrerelease(context, eligible), true)
);
for (const [key, value] of [
	['github_actions', 'false'],
	['repository', 'foreign/ergopti'],
	['event_name', 'workflow_dispatch'],
	['event_name', 'pull_request'],
	['ref', 'refs/heads/main'],
	['release', false],
	['prerelease', 'false'],
	['channel', 'main'],
	['tag', 'v0.0.0-dev.158'],
	['version', '0.0.0-dev.158']
]) {
	check(`full for ${key}=${value}`, () => {
		const foreign = { ...context, [key]: value };
		assert.equal(Policy.fastPrerelease(foreign, eligible), false);
		assert.throws(() => Policy.validateFastPrerelease(true, foreign, eligible));
		assert.equal(Policy.validateFastPrerelease(false, foreign, eligible), false);
	});
}
check('expiry restores full route', () => {
	const expired = new Date('2026-10-10T07:00:00Z');
	assert.equal(Policy.fastPrerelease(context, expired), false);
	assert.throws(() => Policy.validateFastPrerelease(true, context, expired));
});
const sha = '1'.repeat(40);
const needs = {
	windows: {
		'test-ahk': 'skipped',
		'e2e-ahk': 'skipped',
		'package-windows': 'success',
		'launch-windows': 'skipped'
	},
	macos: {
		'cold-bootstrap-native': 'skipped',
		'test-hs': 'skipped',
		'e2e-hs': 'skipped',
		'package-macos': 'success',
		launch: 'skipped',
		'tooltip-canvas': 'skipped',
		'managed-ollama-native': 'success'
	},
	linux: {
		'test-linux': 'skipped',
		'e2e-linux': 'skipped',
		'package-linux': 'success',
		'install-linux': 'skipped'
	}
};
for (const [lane, result] of Object.entries(needs))
	check(`${lane} never qualifies skipped work`, () => {
		const receipt = Policy.fastPrereleaseReceipt(
			lane,
			Object.fromEntries(Object.entries(result).map(([k, v]) => [k, { result: v }])),
			sha,
			context,
			eligible
		);
		assert.equal(receipt.status, 'UNQUALIFIED');
		assert.equal(receipt.qualified, false);
		assert.equal(receipt.tests, 'DEFERRED');
	});
check('full release predicate preserves implicit successful dependencies', () => {
	const expression = Raw.field(Raw.job('release'), 'if').slice(3, -2);
	const evaluate = new Function('needs', 'github', 'cancelled', `return (${expression});`);
	const names = ['validate', 'core', 'macos', 'windows', 'linux'];
	let cases = 0;
	for (const failure of names)
		for (const status of ['success', 'failure', 'cancelled', 'skipped', 'unknown', null]) {
			for (const event of ['push', 'workflow_dispatch'])
				for (const release of ['true', 'false'])
					for (const cancelled of [false, true]) {
						const needs = Object.fromEntries(
							names.map((name) => [name, { result: name === failure ? status : 'success' }])
						);
						needs.validate.outputs = { release, fast_prerelease: 'false' };
						assert.equal(
							evaluate(needs, { event_name: event }, () => cancelled),
							!cancelled &&
								event === 'push' &&
								release === 'true' &&
								names.every((name) => needs[name].result === 'success')
						);
						cases++;
					}
		}
	assert.equal(cases, 240);
});
check('full Linux package keeps cancellation and manual receiving allowance', () => {
	const expression = Raw.field(Raw.job('package-linux'), 'if')
		.slice(3, -2)
		.replaceAll('needs.e2e-linux.result', "needs['e2e-linux'].result");
	const evaluate = new Function(
		'inputs',
		'needs',
		'github',
		'cancelled',
		`return (${expression});`
	);
	let cases = 0;
	for (const event of ['push', 'pull_request', 'workflow_dispatch', 'schedule', 'unknown', null])
		for (const result of ['success', 'failure', 'cancelled', 'skipped', 'unknown', null])
			for (const cancelled of [false, true]) {
				assert.equal(
					evaluate(
						{ fast_prerelease: false },
						{ 'e2e-linux': { result } },
						{ event_name: event },
						() => cancelled
					),
					!cancelled &&
						(result === 'success' || (event === 'workflow_dispatch' && result === 'failure'))
				);
				cases++;
			}
	assert.equal(cases, 72);
});
for (const lane of ['macos', 'windows', 'linux'])
	check(`fatal retained receipt failure ${lane} (ci-full-default-receipt-retention)`, () => {
		const rel = `.github/workflows/ci-${lane}.yml`;
		const job = Raw.jobsOfText(source.find((f) => f.rel === rel).text, rel).find(
			(j) => j.id === `${lane}-ok`
		);
		const retain = Raw.step(job.body, 'Retain the explicit unqualified test receipt');
		const ignored = retain.replace(
			'      - name: Retain the explicit unqualified test receipt\n',
			'      - name: Retain the explicit unqualified test receipt\n        continue-on-error: true\n'
		);
		assert.notEqual(ignored, retain);
		assert.throws(
			() => Full.fromFiles(changed(rel, retain, ignored)),
			/retained receipt failure must remain fatal/
		);
	});
console.log(
	`PASS: explicit full-default/raw fast-route source controls=${passed}; native execution UNRUN.`
);
