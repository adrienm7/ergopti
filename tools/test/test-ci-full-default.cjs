'use strict';

/** Raw full-default controls; source models never qualify skipped native work. */
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
	return source.map((entry) => {
		if (entry.rel !== rel) return { ...entry };
		assert.equal(entry.text.split(before).length, 2, `one genuine mutation seam: ${before}`);
		return { ...entry, text: entry.text.replace(before, () => after) };
	});
}
check('raw loader and full view retain every exact source byte', () => {
	const view = Full.fromFiles(source);
	assert.deepEqual(view.files(), source);
	for (const entry of source) {
		assert.equal(entry.text, fs.readFileSync(`${Raw.ROOT}/${entry.rel}`, 'utf8'));
		assert.equal(view.file(entry.rel), entry.text);
	}
	assert.equal(view.text(), Raw.text());
	assert.deepEqual(view.calls(), Raw.calls());
	assert.equal(Raw.field(Raw.job('core'), 'if'), null);
	assert.equal(Raw.field(Raw.job('tooltip-canvas'), 'if'), null);
});
check('all product scripts remain exact, without a projection', () => {
	let jobs = 0,
		steps = 0;
	for (const entry of source)
		for (const job of Raw.jobsOfText(entry.text, entry.rel)) {
			jobs++;
			assert.equal(Full.job(job.id), job.body);
			for (const step of Raw.steps(job.body)) {
				if (!step.name) continue;
				steps++;
				assert.equal(Full.step(Full.job(job.id), step.name), step.body);
				assert.equal(Full.stepField(step.body, 'run'), Raw.stepField(step.body, 'run'));
			}
		}
	assert.equal(jobs, 26);
	assert.ok(steps > 150, 'the full retained script inventory is nonvacuous');
});
check('mandatory default predicates are the actual workflow predicates', () => {
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
for (const entry of source) {
	for (const [name, fragment] of [
		['public input', '      fast_prerelease: true\n'],
		['environment authority', '  ERGOPTI_FAST_PRERELEASE: true\n'],
		['selector', '        run: node tools/ci/dev-release-qualification.cjs --fast-action select\n'],
		['admission', '        run: node tools/ci/dev-release-qualification.cjs --fast-action admit\n'],
		[
			'receipt',
			'        run: node tools/ci/dev-release-qualification.cjs --fast-action receipt --lane macos\n'
		]
	])
		check(`${entry.rel} refuses retired ${name}`, () => {
			const mutated = source.map((file) =>
				file.rel === entry.rel ? { ...file, text: file.text + fragment } : { ...file }
			);
			assert.throws(() => Full.fromFiles(mutated), /retired fast route/);
		});
	for (const job of Raw.jobsOfText(entry.text, entry.rel)) {
		check(`${job.id} cannot acquire a skipping predicate`, () => {
			const condition = Raw.field(job.body, 'if');
			const body =
				condition === null
					? '    if: false\n' + job.body
					: job.body.replace(`    if: ${condition}\n`, '    if: false\n');
			assert.notEqual(body, job.body);
			assert.throws(() => Full.fromFiles(changed(entry.rel, job.body, body)), /full job condition/);
		});
		check(`${job.id} cannot forgive its failure`, () => {
			assert.throws(
				() =>
					Full.fromFiles(changed(entry.rel, job.body, '    continue-on-error: true\n' + job.body)),
				/failure must remain fatal/
			);
		});
	}
}
for (const [name, files] of [
	['duplicate workflow', [...source, { ...source[0] }]],
	['missing workflow', source.slice(1)],
	[
		'foreign workflow',
		source.map((entry, index) => (index === 0 ? { ...entry, rel: 'foreign.yml' } : { ...entry }))
	]
])
	check(`refuse ${name}`, () => assert.throws(() => Full.fromFiles(files)));
for (const lane of ['macos', 'windows', 'linux']) {
	const job = Raw.jobsOfText(source.find((entry) => entry.rel === ENTRY).text, ENTRY).find(
		(entry) => entry.id === lane
	);
	check(`${lane} cannot substitute a foreign caller`, () => {
		const body = job.body.replace(
			`uses: ./.github/workflows/ci-${lane}.yml`,
			'uses: foreign/workflow@main'
		);
		assert.notEqual(body, job.body);
		assert.throws(() => Full.fromFiles(changed(ENTRY, job.body, body)), /actual caller/);
	});
	for (const key of ['release', 'prerelease', 'channel', 'tag', 'version'])
		check(`${lane} retains source-bound ${key}`, () => {
			const expression =
				key === 'release'
					? "needs.validate.outputs.release == 'true'"
					: `needs.validate.outputs.${key}`;
			const body = job.body.replace(
				`      ${key}: \${{ ${expression} }}\n`,
				`      ${key}: true\n`
			);
			assert.notEqual(body, job.body);
			assert.throws(() => Full.fromFiles(changed(ENTRY, job.body, body)), /source binding/);
		});
}
for (const [rel, id, name] of [
	[MAC, 'managed-ollama-native', 'Qualify actual SDK accepted-owner and deadline XCTest controls'],
	[MAC, 'managed-ollama-native', 'Qualify actual native PAC and WPAD XCTest controls'],
	[MAC, 'macos-ok', 'Verify mandatory jobs and launch scenarios'],
	['.github/workflows/ci-windows.yml', 'windows-ok', 'Verify mandatory jobs and launch scenarios'],
	['.github/workflows/ci-linux.yml', 'linux-ok', 'Assert all mandatory subjects ran and passed']
]) {
	const job = Raw.jobsOfText(source.find((entry) => entry.rel === rel).text, rel).find(
		(entry) => entry.id === id
	);
	const step = Raw.step(job.body, name);
	check(`${id}/${name} cannot skip`, () => {
		const condition = Raw.stepField(step, 'if');
		const body =
			condition === null
				? step.replace(`      - name: ${name}\n`, `      - name: ${name}\n        if: false\n`)
				: step.replace(`        if: ${condition}\n`, '        if: false\n');
		assert.notEqual(body, step);
		assert.throws(() => Full.fromFiles(changed(rel, step, body)), /full step condition/);
	});
	check(`${id}/${name} cannot forgive failure`, () => {
		const body = step.replace(
			`      - name: ${name}\n`,
			`      - name: ${name}\n        continue-on-error: true\n`
		);
		assert.notEqual(body, step);
		assert.throws(() => Full.fromFiles(changed(rel, step, body)), /failure must remain fatal/);
	});
}
check('unknown step conditions stay visible to existing mandatory guards', () => {
	const view = Full.fromFiles(
		changed(
			MAC,
			'      - name: Admit the canonical native toolchain and public inputs\n',
			'      - name: Admit the canonical native toolchain and public inputs\n        if: false\n'
		)
	);
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
check('retired exported grants are absent', () => {
	for (const name of ['fastPrerelease', 'validateFastPrerelease', 'fastPrereleaseReceipt'])
		assert.equal(Object.hasOwn(Policy, name), false, name);
});
const configuration = JSON.parse(fs.readFileSync(Policy.POLICY_PATH, 'utf8'));
const context = Object.fromEntries(
	['repository', 'event_name', 'ref', 'release', 'prerelease', 'channel', 'tag', 'version'].map(
		(key) => [key, configuration[key]]
	)
);
context.github_actions = 'true';
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
])
	check(`bounded scopes keep full defaults for ${key}=${value}`, () => {
		const foreign = { ...context, [key]: value };
		assert.equal(
			Policy.resolveQualificationProfile(foreign, new Date('2026-10-09T14:00:00Z')),
			null
		);
		assert.throws(() =>
			Policy.authorizeQualificationProfile(
				configuration.id,
				foreign,
				new Date('2026-10-09T14:00:00Z')
			)
		);
	});
check('expiry cannot authorize any remaining scope', () => {
	assert.equal(
		Policy.resolveQualificationProfile(context, new Date(configuration.expires_at)),
		null
	);
	assert.throws(() =>
		Policy.authorizeQualificationProfile(
			configuration.id,
			context,
			new Date(configuration.expires_at)
		)
	);
});
check('release keeps real full predicates and implicit successful dependency admission', () => {
	const expression = Raw.field(Raw.job('release'), 'if');
	assert.equal(
		expression,
		"github.event_name == 'push' && needs.validate.outputs.release == 'true'"
	);
	const evaluate = new Function('needs', 'github', `return (${expression});`);
	const names = ['validate', 'core', 'macos', 'windows', 'linux'];
	assert.deepEqual(Raw.needsOf(Raw.job('release')), names);
	let cases = 0;
	for (const failure of names)
		for (const status of ['success', 'failure', 'cancelled', 'skipped', 'unknown', null])
			for (const event of ['push', 'workflow_dispatch'])
				for (const release of ['true', 'false'])
					for (const cancelled of [false, true]) {
						const needs = Object.fromEntries(
							names.map((name) => [name, { result: name === failure ? status : 'success' }])
						);
						needs.validate.outputs = { release };
						const implicitSuccess =
							!cancelled && names.every((name) => needs[name].result === 'success');
						assert.equal(
							implicitSuccess && evaluate(needs, { event_name: event }),
							!cancelled &&
								event === 'push' &&
								release === 'true' &&
								names.every((name) => needs[name].result === 'success')
						);
						cases++;
					}
	assert.equal(cases, 240);
});
check('full Linux package retains cancellation and manual receiving allowance', () => {
	const expression = Raw.field(Raw.job('package-linux'), 'if')
		.slice(3, -2)
		.replaceAll('needs.e2e-linux.result', "needs['e2e-linux'].result");
	const evaluate = new Function('needs', 'github', 'cancelled', `return (${expression});`);
	let cases = 0;
	for (const event of ['push', 'pull_request', 'workflow_dispatch', 'schedule', 'unknown', null])
		for (const result of ['success', 'failure', 'cancelled', 'skipped', 'unknown', null])
			for (const cancelled of [false, true]) {
				assert.equal(
					evaluate({ 'e2e-linux': { result } }, { event_name: event }, () => cancelled),
					!cancelled &&
						(result === 'success' || (event === 'workflow_dispatch' && result === 'failure'))
				);
				cases++;
			}
	assert.equal(cases, 72);
});
console.log(
	`PASS: raw full-default and retired-route source controls=${passed}; native execution UNRUN.`
);
