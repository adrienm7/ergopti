'use strict';

/** Raw full-default controls; source models never qualify skipped native work. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const Full = require('./ci-full-default.cjs');
const Raw = require('./ci-pipeline.cjs');
const Policy = require('../ci/dev-release-qualification.cjs');
const Scoped = require('./fixtures/ci-scoped-full-branches.cjs');
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
	assert.deepEqual(view.rawFiles(), source);
	for (const entry of source) {
		assert.equal(entry.text, fs.readFileSync(`${Raw.ROOT}/${entry.rel}`, 'utf8'));
		assert.equal(view.file(entry.rel), Scoped.projectScopedSteps(entry.text, entry.rel));
	}
	assert.equal(
		view.text(),
		view
			.files()
			.map((entry) => entry.text)
			.join('\n')
	);
	assert.deepEqual(view.calls(), Raw.calls());
	assert.equal(Raw.field(Raw.job('core'), 'if'), null);
	assert.equal(Raw.field(Raw.job('tooltip-canvas'), 'if'), null);
});
check('every scoped full body remains owned; all other product scripts remain exact', () => {
	let jobs = 0,
		steps = 0;
	for (const entry of source)
		for (const job of Raw.jobsOfText(entry.text, entry.rel)) {
			jobs++;
			assert.equal(Full.field(Full.job(job.id), 'if'), Raw.field(job.body, 'if'));
			for (const step of Raw.steps(job.body)) {
				if (!step.name) continue;
				steps++;
				const retained = Full.step(Full.job(job.id), step.name);
				const slot = Scoped.contract.slots.find(
					(slot) => slot.file === entry.rel && slot.job === job.id && slot.step === step.name
				);
				if (slot) {
					assert.equal(Full.stepField(retained, 'if'), Raw.stepField(step.body, 'if'));
					assert.equal(
						Full.stepField(retained, 'continue-on-error'),
						Raw.stepField(step.body, 'continue-on-error')
					);
					assert.equal(
						Full.stepField(retained, 'timeout-minutes'),
						Raw.stepField(step.body, 'timeout-minutes')
					);
					assert.equal(
						Full.runOf(retained).join('\n'),
						Scoped.unwrap(Raw.runOf(step.body).join('\n'), Scoped.contract.protocols[slot.protocol])
					);
				} else assert.equal(retained, step.body);
				assert.equal(Full.stepField(step.body, 'run'), Raw.stepField(step.body, 'run'));
			}
		}
	assert.equal(jobs, 26);
	assert.ok(steps > 150, 'the full retained script inventory is nonvacuous');
});
const testedProtocols = new Set();
for (const slot of Scoped.contract.slots) {
	if (testedProtocols.has(slot.protocol)) continue;
	testedProtocols.add(slot.protocol);
	const original = source.find((file) => file.rel === slot.file);
	const job = Raw.jobsOfText(original.text, slot.file).find((job) => job.id === slot.job);
	const step = Raw.step(job.body, slot.step);
	check(`${slot.job}/${slot.step} refuses same-length unknown validation command`, () => {
		const mutated = step.replace('--validate-scope-receipt', '--validate-scope-receipx');
		assert.notEqual(mutated, step);
		assert.equal(mutated.length, step.length);
		assert.throws(() => Full.fromFiles(changed(slot.file, step, mutated)), /admission/);
	});
	check(`${slot.job}/${slot.step} refuses weakened scope validation`, () => {
		const mutated = step.replace('--validate-scope-receipt', '--receipt');
		assert.notEqual(mutated, step);
		assert.throws(() => Full.fromFiles(changed(slot.file, step, mutated)), /admission/);
	});
	check(`${slot.job}/${slot.step} refuses alternate full-mode admission`, () => {
		const protocol = Scoped.contract.protocols[slot.protocol];
		const before = protocol.format === 'bash' ? '[ "$mode" = full ]' : "$mode -ceq 'full'";
		const mutated = step.replace(
			before,
			protocol.format === 'bash' ? '[ "$mode" != deferred ]' : "$mode -cne 'deferred'"
		);
		assert.notEqual(mutated, step);
		assert.throws(() => Full.fromFiles(changed(slot.file, step, mutated)), /admission/);
	});
	check(`${slot.job}/${slot.step} refuses swallowed selector failure`, () => {
		const mutated = step.replace('--validate-scope-receipt', '--validate-scope-receipt-unknown');
		assert.notEqual(mutated, step);
		assert.throws(() => Full.fromFiles(changed(slot.file, step, mutated)), /admission/);
	});
}
for (const mode of ['delete-step', 'missing-run']) {
	check(`every reviewed owner refuses ${mode}`, () => {
		let cases = 0;
		for (const slot of Scoped.contract.slots) {
			const file = source.find((file) => file.rel === slot.file);
			const job = Raw.jobsOfText(file.text, file.rel).find((job) => job.id === slot.job);
			const step = Raw.step(job.body, slot.step);
			let replacement = '';
			if (mode === 'missing-run') {
				const block = /^        run: \|\n(?: {10}[^\n]*(?:\n|$)|\n)*/m.exec(step);
				assert.ok(block, 'the genuine reviewed run body exists');
				replacement = step.replace(block[0], '');
			}
			assert.notEqual(replacement, step);
			assert.throws(
				() => Full.fromFiles(changed(slot.file, step, replacement)),
				`${slot.job}/${slot.step} must retain its actual ${mode === 'delete-step' ? 'registration' : 'run body'}`
			);
			cases++;
		}
		assert.equal(cases, Scoped.contract.slots.length);
		assert.ok(cases > 150, 'all reviewed scoped owners are exercised nonvacuously');
	});
}
check('native custody scope preserves the complete original full block', () => {
	const script = fs.readFileSync(
		Raw.ROOT + '/static/ergopti_plus/linux/tests/hardware/run_daemon_live.sh',
		'utf8'
	);
	const retained = Scoped.projectLinuxHarness(script);
	assert.ok(
		retained.includes(
			'\tpython3 tests/hardware/run_native_subreaper.py luajit tests/hardware/run_simultaneous_configuration_real.lua\n\tCUSTODY=$?\nfi\nif [ "${CUSTODY}" != "0" ]; then'
		)
	);
	for (const [before, after] of [
		['--validate-scope-receipt', '--receipt'],
		['elif [ "$mode" = full ]', 'elif [ "$mode" != deferred ]'],
		['CUSTODY=2\n\tfi', 'CUSTODY=0\n\tfi']
	]) {
		const altered = script.replace(before, after);
		assert.notEqual(altered, script);
		assert.throws(() => Scoped.projectLinuxHarness(altered));
	}
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
	[MAC, 'item36-native', 'Observe the actual no-prompt SDK permission API independently'],
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
check(
	'actual no-prompt SDK observation keeps its full default condition and cannot disappear',
	() => {
		const name = 'Observe the actual no-prompt SDK permission API independently';
		const job = Raw.jobsOfText(source.find((entry) => entry.rel === MAC).text, MAC).find(
			(entry) => entry.id === 'item36-native'
		);
		const body = Raw.step(job.body, name);
		assert.equal(
			Full.stepField(Full.step(Full.job('item36-native'), name), 'if'),
			'${{ !cancelled() }}'
		);
		assert.ok(
			body.includes('sdk_permission_xctest_evidence.cjs judge'),
			'actual SDK observation is judged'
		);
		assert.throws(() => Full.fromFiles(changed(MAC, body, '')), {
			message: `[ci-pipeline] no step named '${name}' in this job`
		});
	}
);
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
check('package duplicate HTTP receiving scopes only the native wire command', () => {
	const job = Raw.jobsOfText(source.find((entry) => entry.rel === MAC).text, MAC).find(
		(entry) => entry.id === 'package-macos'
	);
	const code = Raw.runOf(Raw.step(job.body, 'Receive actual managed HTTP native clients')).join(
		'\n'
	);
	const first =
		'"$ERGOPTI_NATIVE_HTTP_PYTHON" tools/diagnostics/macos_owned_process_native_test.py || status=1';
	const second =
		'"$ERGOPTI_NATIVE_HTTP_PYTHON" static/ergopti_plus/macos/tests/support/native_http_receiving_test.py --client-only || status=1';
	const wire =
		'"$ERGOPTI_NATIVE_HTTP_PYTHON" static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py || status=1';
	assert.ok(code.indexOf(first) < code.indexOf('--scope macos-native-http'));
	assert.ok(code.indexOf(second) < code.indexOf('--scope macos-native-http'));
	assert.ok(code.includes('elif [ "$mode" = full ]; then\n    ' + wire));
	assert.ok(code.includes('stable-macos-native-http-package.json'));
	assert.equal(
		Full.runOf(
			Full.step(Full.job('package-macos'), 'Receive actual managed HTTP native clients')
		).join('\n'),
		['set -euo pipefail', 'status=0', first, second, wire, 'exit "$status"'].join('\n')
	);
});
check('package duplicate keeps both mandatory failure acknowledgments', () => {
	const original = source.find((entry) => entry.rel === MAC);
	const job = Raw.jobsOfText(original.text, MAC).find((entry) => entry.id === 'package-macos');
	const step = Raw.step(job.body, 'Receive actual managed HTTP native clients');
	for (const command of [
		'macos_owned_process_native_test.py',
		'native_http_receiving_test.py --client-only'
	]) {
		const before = command + ' || status=1';
		const mutated = step.replace(before, command + ' || true');
		assert.notEqual(mutated, step);
		assert.throws(() => Full.fromFiles(changed(MAC, step, mutated)), /admission/);
	}
	const uploader = Raw.step(job.body, 'Retain scoped native Brew qualification receipt');
	assert.ok(
		uploader.includes('${{ runner.temp }}/dev-release-qualification/macos-brew-archive.json')
	);
	assert.ok(uploader.includes('${{ runner.temp }}/stable-macos-native-http-package.json'));
	assert.equal(Raw.stepField(uploader, 'if'), '${{ always() }}');
	assert.match(uploader, /^ {10}if-no-files-found: error$/m);
});
check(
	'duplicate native HTTP scope remains full for every foreign stable context and expiry',
	() => {
		const stable = JSON.parse(fs.readFileSync(Policy.STABLE_POLICY_PATH, 'utf8'));
		const admitted = Object.fromEntries(
			['repository', 'event_name', 'ref', 'release', 'prerelease', 'channel', 'tag', 'version'].map(
				(key) => [key, stable[key]]
			)
		);
		admitted.github_actions = 'true';
		const clock = new Date('2026-10-09T20:00:00Z');
		assert.equal(
			Policy.resolveQualificationProfile(admitted, clock, 'macos-native-http').id,
			stable.id
		);
		for (const [key, value] of [
			['github_actions', 'false'],
			['repository', 'foreign/ergopti'],
			['event_name', 'pull_request'],
			['event_name', 'workflow_dispatch'],
			['ref', 'refs/heads/dev'],
			['release', false],
			['prerelease', 'true'],
			['channel', 'dev'],
			['tag', 'v1.0.1'],
			['version', '1.0.1']
		])
			assert.equal(
				Policy.resolveQualificationProfile(
					{ ...admitted, [key]: value },
					clock,
					'macos-native-http'
				),
				null
			);
		assert.equal(
			Policy.resolveQualificationProfile(
				admitted,
				new Date(stable.expires_at),
				'macos-native-http'
			),
			null
		);
		assert.equal(Object.keys(stable.scopes).length, 13);
	}
);
check(
	'package Swift duplicate scopes only the existing PAC classes and preserves the full body',
	() => {
		const original = source.find((entry) => entry.rel === MAC);
		const job = Raw.jobsOfText(original.text, MAC).find((entry) => entry.id === 'package-macos');
		const code = Raw.runOf(Raw.step(job.body, 'Run Swift launcher tests')).join('\n');
		assert.ok(
			code.includes(
				'node tools/ci/dev-release-qualification.cjs --scope macos-native-pac --receipt "$pac_receipt"'
			)
		);
		assert.ok(code.includes('elif [ "$mode" = full ]; then\n    :'));
		assert.ok(code.includes('--pac-skip-pattern "$pac_receipt"'));
		assert.equal(code.split(' --pac-qualification-receipt "$pac_receipt"').length, 3);
		const full = Full.runOf(Full.step(Full.job('package-macos'), 'Run Swift launcher tests')).join(
			'\n'
		);
		assert.ok(
			full.includes(
				'script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher --scratch-path "$RUNNER_TEMP/swift-launcher-ci" 2>&1 | tee "$xctest_log"'
			)
		);
		assert.ok(full.includes('if ! grep -Fq "Test Suite \'All tests\' passed" "$xctest_log"; then'));
		assert.ok(
			full.includes(
				'node tools/diagnostics/tis_evidence_transport.cjs "$ERGOPTI_TIS_EVIDENCE_DIR" "$ERGOPTI_TIS_EVIDENCE_SESSION"'
			)
		);
		for (const removed of [
			'--pac-skip-pattern',
			'--pac-qualification-receipt',
			'pac_skip_args',
			'swift_root_suite'
		])
			assert.equal(full.includes(removed), false, removed);
		assert.equal(Scoped.contract.slots.length, 162);
		const retained = Raw.step(job.body, 'Retain scoped native Brew qualification receipt');
		assert.ok(
			retained.includes(
				'${{ runner.temp }}/swift-launcher-evidence/native-pac-package-qualification.json'
			)
		);
		assert.equal(Raw.stepField(retained, 'if'), '${{ always() }}');
	}
);
check('embedded Swift admission refuses omitted collector binding or changed source gate', () => {
	const original = source.find((entry) => entry.rel === MAC);
	const job = Raw.jobsOfText(original.text, MAC).find((entry) => entry.id === 'package-macos');
	const step = Raw.step(job.body, 'Run Swift launcher tests');
	const receiptOption = ' --pac-qualification-receipt "$pac_receipt"';
	const missing = step.replace(receiptOption, '');
	assert.notEqual(missing, step);
	assert.throws(() => Full.fromFiles(changed(MAC, step, missing)), /binding/);
	const changedGate = step.replace('--pac-skip-pattern', '--pac-skip-patterx');
	assert.notEqual(changedGate, step);
	assert.throws(() => Full.fromFiles(changed(MAC, step, changedGate)), /admission/);
});
check('Swift PAC arguments preserve empty and selected arrays under nounset', () => {
	const original = source.find((entry) => entry.rel === MAC);
	const job = Raw.jobsOfText(original.text, MAC).find((entry) => entry.id === 'package-macos');
	const code = Raw.runOf(Raw.step(job.body, 'Run Swift launcher tests')).join('\n');
	const safe = '${pac_skip_args[@]+"${pac_skip_args[@]}"}';
	assert.ok(code.includes(' ' + safe + ' 2>&1 | tee "$xctest_log"'));
	assert.equal(code.includes(' "${pac_skip_args[@]}" 2>&1'), false);
	const invocation = code
		.split('\n')
		.find((line) => line.startsWith('script -q '))
		.split(' 2>&1 | tee ')[0];
	const pattern =
		'^ErgoptiPlusTests[.](?:ManagedHTTPWorkerTests|ManagedHTTPWireTests|ManagedHTTPWPADWireTests)/';
	const expected = [
		'-q',
		'/dev/null',
		'swift',
		'test',
		'--package-path',
		'static/ergopti_plus/macos/launcher',
		'--scratch-path',
		'/owned path/swift-launcher-ci'
	];
	for (const deferred of [false, true]) {
		const shell =
			'set -euo pipefail\nRUNNER_TEMP="/owned path"\n' +
			'script() { printf "%s\\0" "$@"; }\n' +
			(deferred ? 'pac_skip_args=(--skip "$1")\n' : 'pac_skip_args=()\n') +
			invocation;
		const result = spawnSync(
			bashExecutable(),
			['--noprofile', '--norc', '-c', shell, 'owned-argv', pattern],
			{ encoding: 'utf8' }
		);
		assert.equal(result.error, undefined);
		assert.equal(result.status, 0, result.stderr);
		assert.equal(result.stderr, '');
		assert.deepEqual(
			result.stdout.split('\0').slice(0, -1),
			deferred ? [...expected, '--skip', pattern] : expected
		);
	}
	const unsafe = code.replace(safe, '"${pac_skip_args[@]}"');
	assert.notEqual(unsafe, code);
	assert.throws(() => Full.fromFiles(changed(MAC, safe, '"${pac_skip_args[@]}"')), /binding/);
});
console.log(
	`PASS: raw full-default and retired-route source controls=${passed}; native execution UNRUN.`
);
