'use strict';

/** Raw full-default controls; source models never qualify skipped native work. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const Full = require('./ci-full-default.cjs');
const Raw = require('./ci-pipeline.cjs');
const Policy = require('../ci/dev-release-qualification.cjs');
const Scoped = require('./fixtures/ci-scoped-full-branches.cjs');
const macRole = require('./fixtures/macos-stage-source.cjs');
const Publication = require('../ci/publication-plan.cjs');
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
function assertNativeHTTPClockWorkflow(workflow, expected) {
	const job = workflow.jobs['e2e-hs'];
	assert.ok(job && Array.isArray(job.steps), 'Actual managed native clock owner must exist.');
	const owners = job.steps.filter(
		(step) => step.name === 'Receive actual independent managed HTTP native clients'
	);
	assert.equal(owners.length, 1, 'Actual independent client must have one source-owned step.');
	assert.equal(
		job.steps.filter((step) => step.name === 'Retain independent native HTTP clock receiving')
			.length,
		1,
		'Clock artifact transport must have one source-owned step.'
	);
	const index = job.steps.indexOf(owners[0]);
	assert.deepEqual(
		job.steps.slice(index, index + 2),
		expected.jobs['managed-ollama-native'].steps.map((step) =>
			macRole.metadata(
				{
					...step,
					if: macRole.condition('managed-ollama-native', step.if),
					env: {
						GOTOOLCHAIN: 'local',
						ERGOPTI_RELEASE: "${{ inputs.release && 'true' || 'false' }}",
						ERGOPTI_RELEASE_TAG: '${{ inputs.tag }}',
						ERGOPTI_RELEASE_VERSION: '${{ inputs.version }}',
						ERGOPTI_RELEASE_CHANNEL: '${{ inputs.channel }}',
						ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE: '${{ matrix.architecture }}'
					}
				},
				'managed-ollama-native'
			)
		),
		'Actual two clock steps must equal the fixed reviewed producer input.'
	);
	assert.equal(
		job.steps.filter((step) => step.id === 'native_http_clock').length,
		1,
		'Clock output authority must have one unique step ID.'
	);
	const packages = workflow.jobs['package-macos'].steps.filter(
		(step) => step.name === 'Receive actual managed HTTP native clients'
	);
	assert.deepEqual(
		packages,
		[
			{
				name: 'Receive actual managed HTTP native clients',
				if: macRole.condition('package-macos'),
				run: 'set -euo pipefail\nstatus=0\n"$ERGOPTI_NATIVE_HTTP_PYTHON" tools/diagnostics/macos_owned_process_native_test.py || status=1\n"$ERGOPTI_NATIVE_HTTP_PYTHON" static/ergopti_plus/macos/tests/support/native_http_receiving_test.py --client-only || status=1\nreceipt="$RUNNER_TEMP/stable-macos-native-http-package.json"\nmkdir -p "$(dirname "$receipt")"\nnode tools/ci/dev-release-qualification.cjs --scope macos-native-http --receipt "$receipt"\nmode="$(node tools/ci/dev-release-qualification.cjs --scope macos-native-http --validate-scope-receipt "$receipt")"\nif [ "$mode" = deferred ]; then\n    echo "[DEFERRED] macos-native-http: qualified=false; duplicate native wire receiving not executed; owned-process and client-only controls remain mandatory."\nelif [ "$mode" = full ]; then\n    "$ERGOPTI_NATIVE_HTTP_PYTHON" static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py || status=1\nelse\n    echo "Invalid command qualification disposition" >&2\n    exit 1\nfi\nexit "$status"\n',
				'timeout-minutes': 5
			}
		],
		'Package original first-two mandatory controls and duplicate deferral must stay exact.'
	);
}
function receiveClockWorkflow(files) {
	const YAML = require('yaml');
	const actual = files.find((entry) => entry.rel === MAC);
	assert.ok(actual, 'Actual macOS workflow source must be present.');
	const expected = YAML.parse(
		fs.readFileSync(
			`${Raw.ROOT}/tools/test/fixtures/native_http_clock_profile_workflow.yml`,
			'utf8'
		)
	);
	assertNativeHTTPClockWorkflow(YAML.parse(actual.text), expected);
}
check(
	'actual independent clock wiring equals the fixed producer and preserves Package disposition',
	() => {
		receiveClockWorkflow(source);
	}
);
for (const [name, before, after] of [
	[
		'clock upload absence',
		'      - name: Retain independent native HTTP clock receiving\n',
		'      - name: Omitted independent native HTTP clock receiving\n'
	],
	[
		'clock output authority identity',
		'        id: native_http_clock\n',
		'        id: foreign_native_http_clock\n'
	],
	[
		'clock deferred artifact must remain skipped',
		"        if: ${{ steps.stage-admission.outcome == 'success' && env.MACOS_STAGE_ROLE == 'managed-ollama-native' && (always() && steps.native_http_clock.outputs.clock_expected == 'true') }}\n",
		'        if: always()\n'
	],
	[
		'clock exact five-minute command cap',
		'        timeout-minutes: 5\n      - name: Retain independent native HTTP clock receiving\n',
		'        timeout-minutes: 6\n      - name: Retain independent native HTTP clock receiving\n'
	],
	[
		'clock artifact attempt binding',
		'          name: native-http-clock-${{ env.MACOS_STAGE_ARCHITECTURE }}-${{ github.run_id }}-${{ github.run_attempt }}\n',
		'          name: native-http-clock-${{ env.MACOS_STAGE_ARCHITECTURE }}-${{ github.run_id }}\n'
	],
	[
		'clock capture status remains independently fatal',
		'              for code in "${owned_status[@]}" "${public_status[@]}" "${client_status[@]}"; do\n',
		'              for code in "${owned_status[0]}" "${public_status[0]}" "${client_status[0]}"; do\n'
	],
	[
		'clock source-after judge cannot be omitted',
		'              node tools/ci/native_http_clock_evidence.cjs judge ',
		'              true omitted_clock_judge '
	],
	[
		'Package first-two commands remain outside duplicate wire deferral',
		'      - name: Receive actual managed HTTP native clients\n        if: ${{ steps.stage-admission.outcome == \'success\' }}\n        run: |\n          set -euo pipefail\n          status=0\n          "$ERGOPTI_NATIVE_HTTP_PYTHON" tools/diagnostics/macos_owned_process_native_test.py || status=1\n',
		"      - name: Receive actual managed HTTP native clients\n        if: ${{ steps.stage-admission.outcome == 'success' }}\n        run: |\n          set -euo pipefail\n          status=0\n          true omitted_package_owned_process\n"
	]
]) {
	check(name + ' is refused by actual live equality', () => {
		assert.throws(() => receiveClockWorkflow(changed(MAC, before, after)), /clock|Clock|Package/);
	});
}
check('profile wrapper retains the original immutable full clock body byte for byte', () => {
	const YAML = require('yaml');
	const original = YAML.parse(
		fs.readFileSync(`${Raw.ROOT}/tools/test/fixtures/native_http_clock_workflow.yml`, 'utf8')
	).jobs['managed-ollama-native'].steps[0].run;
	const profile = YAML.parse(
		fs.readFileSync(
			`${Raw.ROOT}/tools/test/fixtures/native_http_clock_profile_workflow.yml`,
			'utf8'
		)
	).jobs['managed-ollama-native'].steps[0].run;
	const seam = 'elif [ "$mode" = full ]; then\n';
	const refusal =
		'else\n    echo "Invalid command qualification disposition" >&2\n    exit 1\nfi\n';
	assert.equal(original.split(seam).length, 2, 'one original full branch');
	assert.ok(original.endsWith(refusal), 'original refusal remains closed');
	const originalBody = original
		.slice(original.indexOf(seam) + seam.length, -refusal.length)
		.split('\n')
		.map((line) => {
			if (line === '') return line;
			assert.ok(line.startsWith('    '), 'original full branch indentation');
			return line.slice(4);
		})
		.join('\n');
	const full =
		Scoped.unwrap(
			macRole.metadata(profile.trimEnd(), 'managed-ollama-native'),
			Scoped.contract.protocols[2]
		) + '\n';
	const expectedBody = macRole.metadata(originalBody, 'managed-ollama-native');
	assert.equal(
		full,
		expectedBody,
		'profile publication retains every reviewed clock byte after metadata projection'
	);
	assert.notEqual(full.replace('client_status=("${PIPESTATUS[@]}")', 'client_status=(0 0)'), full);
	assert.notEqual(full.replace('if [ "$clock_status" -ne 0 ]; then status=1; fi', 'true'), full);
	for (const mutant of [
		full.replace('client_status=("${PIPESTATUS[@]}")', 'client_status=(0 0)'),
		full.replace('if [ "$clock_status" -ne 0 ]; then status=1; fi', 'true')
	])
		assert.throws(() => assert.equal(mutant, expectedBody));
});
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
	assert.equal(Raw.field(Raw.job('shared-validation'), 'if'), null);
	assert.equal(Raw.field(Raw.job('e2e-hs'), 'if'), null);
});
check('every scoped full body remains owned; all other product scripts remain exact', () => {
	let jobs = 0,
		steps = 0;
	for (const entry of source)
		for (const job of Raw.jobsOfText(entry.text, entry.rel)) {
			jobs++;
			const retainedJob = Full.job(job.id);
			assert.equal(Full.field(retainedJob, 'if'), Raw.field(job.body, 'if'));
			for (const step of Raw.steps(job.body)) {
				if (!step.name) continue;
				steps++;
				const retained = Full.step(retainedJob, step.name);
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
	assert.deepEqual(
		Raw.jobsOfText(
			source.find((entry) => entry.rel === '.github/workflows/ci-common.yml').text,
			'.github/workflows/ci-common.yml'
		).map((job) => job.id),
		['shared-validation', 'common-e2e', 'common-build', 'common-testbuild', 'common-unit-verdict'],
		'Common preserves every unit lot and browser E2E before production Build and Testbuild'
	);
	assert.equal(jobs, 28);
	assert.equal(
		source
			.flatMap((entry) => Raw.jobsOfText(entry.text, entry.rel))
			.filter(
				(job) =>
					job.file === MAC &&
					job.id === 'e2e-hs' &&
					macRole.selected(job.body, 'lease-silence-native').length === 5
			).length,
		1
	);
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
	assert.equal(Full.field(Full.job('shared-validation'), 'if'), null);
	assert.equal(Full.field(Full.job('e2e-hs'), 'if'), null);
	assert.equal(
		Full.field(Full.job('release'), 'if'),
		"github.event_name == 'push' && needs.publication-plan.outputs.release == 'true'"
	);
	assert.equal(
		Full.stepField(
			Full.step(
				Full.job('e2e-hs'),
				'Qualify actual SDK accepted-owner and deadline XCTest controls'
			),
			'if'
		),
		macRole.condition('managed-ollama-native')
	);
	assert.equal(
		Full.stepField(
			Full.step(Full.job('e2e-hs'), 'Qualify actual native PAC and WPAD XCTest controls'),
			'if'
		),
		macRole.condition('managed-ollama-native', '${{ !cancelled() }}')
	);
});
check('Common TOML receiving retains its owned step, identity and check command', () => {
	const rel = '.github/workflows/ci-common.yml';
	const original = source.find((entry) => entry.rel === rel);
	const job = Raw.jobsOfText(original.text, rel).find((entry) => entry.id === 'shared-validation');
	const step = Raw.step(job.body, 'Check hotstring TOML files are sorted and formatted');
	for (const mutant of [
		'',
		step.replace('id: hotstrings-format', 'id: foreign-format'),
		step.replace('--hotstrings --all --check', '--hotstrings --all')
	]) {
		assert.notEqual(mutant, step, 'each TOML control changes the actual registered step');
		assert.throws(() => Full.fromFiles(changed(rel, step, mutant)));
	}
});
check('Unit refuses withdrawn, deferred, foreign or late human-lot selection', () => {
	const original = source.find((entry) => entry.rel === MAC);
	const job = Raw.jobsOfText(original.text, MAC).find((entry) => entry.id === 'test-hs');
	const step = Raw.step(job.body, 'Admit the authored unit lot');
	for (const mutant of [
		'',
		step + '\n' + step,
		step.replace('select unit', 'select e2e'),
		step.replace('id: stage-selection', 'id: foreign-selection'),
		step.replace('id: stage-selection', 'id: stage-selection\n        if: false'),
		step.replace('id: stage-selection', 'id: stage-selection\n        continue-on-error: true'),
		'      - run: echo premature product work\n' + step
	]) {
		assert.notEqual(mutant, step, 'each Unit selection control changes the actual step');
		assert.throws(() => Full.fromFiles(changed(MAC, step, mutant)));
	}
	const record = Raw.step(job.body, 'Record actual stage role outcome');
	const foreign = record.replace('steps.stage-selection.outputs.cell', 'matrix.lot');
	assert.notEqual(foreign, record);
	assert.throws(() => Full.fromFiles(changed(MAC, record, foreign)));
});
for (const [id, prior, predecessor, output] of [
	['e2e-hs', 'unit', 'test-hs', 'e2e'],
	['package-macos', 'e2e', null, null],
	['launch', 'build', 'package-macos', 'testbuild']
]) {
	check(`${id} preserves the genuine receiver admission before products`, () => {
		const original = source.find((entry) => entry.rel === MAC);
		const job = Raw.jobsOfText(original.text, MAC).find((entry) => entry.id === id);
		const step = Raw.step(job.body, 'Admit complete successful predecessor stage');
		for (const mutant of [
			'',
			step + '\n' + step,
			step.replace(`admit ${prior}`, 'admit foreign'),
			step.replace('${{ toJSON(needs) }}', '${{ toJSON(github) }}'),
			step.replace('id: stage-admission', 'id: stage-admission\n        if: false'),
			step.replace('id: stage-admission', 'id: stage-admission\n        continue-on-error: true'),
			'      - run: echo premature product work\n' + step
		]) {
			assert.notEqual(mutant, step, 'each predecessor control changes the actual step');
			assert.throws(() => Full.fromFiles(changed(MAC, step, mutant)));
		}
		if (predecessor) {
			const binding = `      MACOS_STAGE_METADATA: \${{ needs.${predecessor}.outputs.${output}_metadata }}`;
			for (const replacement of [
				'',
				binding.replace(predecessor, 'foreign'),
				binding.replace(`${output}_metadata`, `${output}_matrix`),
				binding.replace(' }}', '[matrix.lot] }}')
			]) {
				const mutant = job.body.replace(binding, replacement);
				assert.notEqual(mutant, job.body, 'the whole-map binding mutation is effective');
				assert.throws(() => Full.fromFiles(changed(MAC, job.body, mutant)));
			}
		}
	});
}
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
	[
		'.github/workflows/ci-common.yml',
		'shared-validation',
		'Check hotstring TOML files are sorted and formatted'
	],
	[
		'.github/workflows/ci-common.yml',
		'common-build',
		'Build and seal production site — ${{ matrix.lot }}'
	],
	[
		'.github/workflows/ci-common.yml',
		'common-testbuild',
		'Test received production site — ${{ matrix.lot }}'
	],
	[MAC, 'e2e-hs', 'Qualify actual selected number-row Carbon XCTest controls'],
	[MAC, 'e2e-hs', 'Retain selected number-row Carbon XCTest diagnostics'],
	[MAC, 'e2e-hs', 'Observe the actual no-prompt SDK permission API independently'],
	[MAC, 'e2e-hs', 'Qualify actual SDK accepted-owner and deadline XCTest controls'],
	[MAC, 'e2e-hs', 'Qualify actual native PAC and WPAD XCTest controls'],
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
			(entry) => entry.id === 'e2e-hs'
		);
		const body = Raw.step(job.body, name);
		assert.equal(
			Full.stepField(Full.step(Full.job('e2e-hs'), name), 'if'),
			macRole.condition('item36-native', '${{ !cancelled() }}')
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
	const name = 'Admit the canonical native toolchain and public inputs';
	const before = Raw.step(Raw.job('e2e-hs'), name);
	const after = before.replace(
		'        if: ' + macRole.condition('managed-ollama-native'),
		'        if: false'
	);
	assert.notEqual(after, before);
	const view = Full.fromFiles(changed(MAC, before, after));
	assert.equal(view.stepField(view.step(view.job('e2e-hs'), name), 'if'), 'false');
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
		"github.event_name == 'push' && needs.publication-plan.outputs.release == 'true'"
	);
	const evaluate = new Function(
		'needs',
		'github',
		'return (' + expression.replaceAll('needs.publication-plan', "needs['publication-plan']") + ');'
	);
	const preflight = Raw.job('publication-plan');
	assert.equal(Raw.field(preflight, 'if'), 'always() && !cancelled()');
	assert.deepEqual(Raw.needsOf(preflight), ['macos', 'windows', 'linux', 'core']);
	assert.deepEqual(Raw.needsOf(Raw.job('release')), ['publication-plan']);
	const names = ['validate', 'core', 'macos', 'windows', 'linux'];
	let cases = 0;
	for (const failure of names)
		for (const status of ['success', 'failure', 'cancelled', 'skipped', 'unknown', null])
			for (const event of ['push', 'workflow_dispatch'])
				for (const release of ['true', 'false'])
					for (const cancelled of [false, true]) {
						const jobs = Object.fromEntries(
							names.map((name) => [name, { result: name === failure ? status : 'success' }])
						);
						const env = {
							GITHUB_REPOSITORY: 'Test/ergopti',
							GITHUB_SHA: 'a'.repeat(40),
							GITHUB_RUN_ID: '123',
							GITHUB_RUN_ATTEMPT: '1',
							GITHUB_EVENT_NAME: event,
							GITHUB_REF: 'refs/heads/dev',
							CI_OS_SELECTION: 'all',
							CI_PLAN_RELEASE: release,
							CI_PLAN_CHANNEL: 'dev',
							CI_PLAN_LINUX_BUNDLE: 'ergopti-linux.tar.gz',
							CI_PLAN_NATIVE_QUALIFICATION_PROFILE: '',
							CI_PLAN_LANE_WINDOWS: 'true',
							CI_PLAN_LANE_MACOS: 'true',
							CI_PLAN_LANE_LINUX: 'true',
							CI_PLAN_VERSION: release === 'true' ? '0.0.0-dev.200' : '',
							CI_PLAN_TAG: release === 'true' ? 'v0.0.0-dev.200' : '',
							CI_PLAN_TITLE: release === 'true' ? 'Ergopti v0.0.0-dev.200' : '',
							CI_PLAN_PRERELEASE: release === 'true' ? 'true' : ''
						};
						let admission = { result: cancelled ? 'cancelled' : 'failure', outputs: {} };
						if (!cancelled) {
							try {
								// A failed Validate cannot produce its terminal retained artifact.
								const record =
									jobs.validate.result === 'success' ? Publication.create(env) : undefined;
								const lanes = Object.fromEntries(names.slice(1).map((name) => [name, jobs[name]]));
								admission = { result: 'success', outputs: Publication.receive(record, env, lanes) };
							} catch (error) {
								assert.ok(error instanceof Error);
							}
						}
						assert.equal(
							admission.result === 'success' &&
								evaluate({ 'publication-plan': admission }, { event_name: event }),
							!cancelled &&
								event === 'push' &&
								release === 'true' &&
								names.every((name) => jobs[name].result === 'success')
						);
						cases++;
					}
	assert.equal(cases, 240);
});
check('full Linux package retains cancellation and manual receiving allowance', () => {
	const expression = Raw.field(Raw.job('package-linux'), 'if')
		.slice(3, -2)
		.replaceAll(
			'needs.e2e-linux.outputs.ci_unit_result',
			"needs['e2e-linux'].outputs.ci_unit_result"
		)
		.replaceAll('needs.e2e-linux.result', "needs['e2e-linux'].result");
	const evaluate = new Function('needs', 'github', 'cancelled', `return (${expression});`);
	const accepted = new Set([
		'push:success:success:false',
		'pull_request:success:success:false',
		'workflow_dispatch:success:success:false',
		'workflow_dispatch:success:failure:false',
		'schedule:success:success:false',
		'unknown:success:success:false',
		'null:success:success:false'
	]);
	let cases = 0;
	for (const event of ['push', 'pull_request', 'workflow_dispatch', 'schedule', 'unknown', null])
		for (const unitResult of ['success', 'failure', 'cancelled', 'skipped', 'unknown', null])
			for (const result of ['success', 'failure', 'cancelled', 'skipped', 'unknown', null])
				for (const cancelled of [false, true]) {
					assert.equal(
						evaluate(
							{ 'e2e-linux': { result, outputs: { ci_unit_result: unitResult } } },
							{ event_name: event },
							() => cancelled
						),
						accepted.has(`${event}:${unitResult}:${result}:${cancelled}`)
					);
					cases++;
				}
	assert.equal(cases, 432);
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
	assert.equal(
		Raw.stepField(uploader, 'if'),
		macRole.condition('package-macos', '${{ always() }}')
	);
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
		assert.equal(
			Raw.stepField(retained, 'if'),
			macRole.condition('package-macos', '${{ always() }}')
		);
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

// The same closed manual receiver now owns two real matrix cells in E2E.
{
	const sourceMac = source.find((entry) => entry.rel === MAC).text;
	const job = Raw.jobsOfText(sourceMac, MAC).find((job) => job.id === 'e2e-hs');
	const lease = macRole.selected(job.body, 'lease-silence-native');
	const first = lease[0].body;
	const command = Raw.step(job.body, 'Execute the actual paired native silence control');
	const parser = Raw.step(job.body, 'Receive closed lease silence transcript controls');
	const retained = Raw.step(job.body, 'Retain exact paired-process native receiving');
	for (const [label, before, after] of [
		['role absent', first, ''],
		['role duplicate', first, first + '\n' + first],
		['role coupled', '    needs:\n      - test-hs\n', '    needs:\n      - package-macos\n'],
		['role forgiven', '  e2e-hs:\n', '  e2e-hs:\n    continue-on-error: true\n'],
		['release output', '  e2e-hs:\n', '  e2e-hs:\n    outputs:\n      assets: fake\n'],
		['secret inherited', '  e2e-hs:\n', '  e2e-hs:\n    secrets: inherit\n'],
		[
			'automatic/release admission',
			first,
			first.replace(macRole.condition('lease-silence-native'), 'always()')
		],
		[
			'ARM host authority wrong',
			job.body,
			job.body.replace(
				'runs-on: ${{ fromJSON(needs.test-hs.outputs.e2e_metadata)[matrix.lot].runner }}',
				'runs-on: ubuntu-latest'
			)
		],
		[
			'Intel plan absent',
			job.body,
			job.body.replace('needs.test-hs.outputs.e2e_matrix', 'inputs.foreign')
		],
		[
			'source runner wrong',
			command,
			command.replace('run_lease_silence_native.sh', 'foreign_native.sh')
		],
		[
			'closed parser control omitted',
			parser,
			parser.replace('node tools/test/test-lease-silence-xctest-evidence.cjs', 'echo omitted')
		],
		[
			'artifact missing status',
			retained,
			retained.replace('            ${{ runner.temp }}/lease-silence-native/swift-status.txt\n', '')
		],
		[
			'artifact missing forbidden',
			retained,
			retained.replace('if-no-files-found: error', 'if-no-files-found: ignore')
		],
		[
			'native budget widened',
			job.body,
			job.body.replace(
				'timeout-minutes: ${{ fromJSON(needs.test-hs.outputs.e2e_metadata)[matrix.lot].timeout_minutes }}',
				'timeout-minutes: 360'
			)
		]
	])
		check('lease silence: ' + label, () => {
			assert.notEqual(after, before, 'one real source mutation');
			assert.throws(() => Full.fromFiles(changed(MAC, before, after)));
		});
}

check(
	'v101 scope admission is exact main push before expiry and all foreign contexts stay full',
	() => {
		const stable = JSON.parse(fs.readFileSync(Policy.STABLE_V102_POLICY_PATH, 'utf8'));
		assert.equal(stable.id, 'stable-v1-0-2-20261017-six-macos-native-scopes');
		assert.equal(stable.expires_at, '2026-10-20T22:00:00Z');
		assert.deepEqual(Object.keys(stable.scopes), [
			'macos-native-pac',
			'macos-native-http',
			'macos-brew-archive',
			'macos-native-model-receiving',
			'macos-shortcuts-discovery',
			'macos-launch-appleevents',
			'macos-owned-runtime'
		]);
		const context = Object.fromEntries(
			['repository', 'event_name', 'ref', 'release', 'prerelease', 'channel', 'tag', 'version'].map(
				(key) => [key, stable[key]]
			)
		);
		context.github_actions = 'true';
		const clock = new Date('2026-10-20T21:59:59.999Z');
		for (const scope of Object.keys(stable.scopes)) {
			assert.equal(Policy.resolveQualificationProfile(context, clock, scope).id, stable.id);
			assert.equal(
				Policy.resolveQualificationProfile(context, new Date(stable.expires_at), scope),
				null
			);
			for (const [key, value] of [
				['github_actions', 'false'],
				['repository', 'foreign/ergopti'],
				['event_name', 'workflow_dispatch'],
				['event_name', 'pull_request'],
				['ref', 'refs/heads/dev'],
				['release', false],
				['prerelease', 'true'],
				['channel', 'dev'],
				['tag', 'v1.0.3'],
				['version', '1.0.3']
			])
				assert.equal(
					Policy.resolveQualificationProfile({ ...context, [key]: value }, clock, scope),
					null
				);
		}
		for (const scope of [
			'macos-native-model-receiving-unadmitted',
			'core-js-suite',
			'linux-unit-suite',
			'windows-native-desktop'
		])
			assert.equal(Policy.resolveQualificationProfile(context, clock, scope), null);
	}
);
check('v101 retains the full dispatch-only Item36 cohort and public Brew receipt', () => {
	const entry = source.find((file) => file.rel === MAC);
	const item = Raw.jobsOfText(entry.text, MAC).find((job) => job.id === 'e2e-hs');
	assert.equal(
		Raw.stepField(
			Raw.step(item.body, 'Qualify scoped item 36 native archive XCTest controls'),
			'if'
		),
		macRole.condition('item36-native')
	);
	const itemCode = Raw.runOf(
		Raw.step(item.body, 'Qualify scoped item 36 native archive XCTest controls')
	).join('\n');
	assert.equal(itemCode.includes('--skip'), false);
	assert.ok(
		itemCode.includes("SparkleArchiveUpdateAcceptanceTests|HomebrewArchiveAcceptanceTests'")
	);
	assert.equal(itemCode.includes('HomebrewAutomationConsent'), false);
	const job = Raw.jobsOfText(entry.text, MAC).find((row) => row.id === 'package-macos');
	const prepare = Raw.runOf(Raw.step(job.body, 'Prepare scoped native qualification profile')).join(
		'\n'
	);
	assert.ok(prepare.includes('--scope macos-brew-archive --github-env "$GITHUB_ENV"'));
	assert.ok(
		prepare.includes(
			'cp "$RUNNER_TEMP/dev-release-qualification/macos-brew-archive.json" "$RUNNER_TEMP/stable-macos-brew-archive.json"'
		)
	);
	const retain = Raw.step(job.body, 'Retain source-bound package native qualification receipt');
	assert.equal(Raw.stepField(retain, 'if'), macRole.condition('package-macos', 'always()'));
	assert.ok(retain.includes('name: assets-qualification-package-macos'));
	assert.ok(retain.includes('path: ${{ runner.temp }}/stable-macos-brew-archive.json'));
	assert.match(retain, /^ {10}if-no-files-found: error$/m);
});
check('v101 managed PAC admission retains Worker filter and exact collector authority', () => {
	const entry = source.find((file) => file.rel === MAC);
	const job = Raw.jobsOfText(entry.text, MAC).find((row) => row.id === 'e2e-hs');
	const step = Raw.step(job.body, 'Qualify actual native PAC and WPAD XCTest controls');
	const code = Raw.runOf(step).join('\n');
	assert.ok(code.includes('--validate-scope-receipt-profile "$receipt"'));
	assert.ok(code.includes('test -z "$profile"'));
	assert.ok(
		code.includes("--filter 'ManagedHTTPWorkerTests|ManagedHTTPWireTests|ManagedHTTPWPADWireTests'")
	);
	assert.ok(code.includes('pac_evidence_args=(--pac-qualification-receipt "$receipt")'));
	for (const token of [
		'--validate-scope-receipt-profile',
		'pac_evidence_args=(--pac-qualification-receipt',
		'ManagedHTTPWorkerTests|'
	]) {
		const mutant = step.replace(token, token.slice(0, -1) + 'x');
		assert.notEqual(mutant, step);
		assert.throws(() => Full.fromFiles(changed(MAC, step, mutant)));
	}
	const marker = 'set -euo pipefail\ntest -n "$ERGOPTI_NATIVE_HTTP_PYTHON"';
	assert.equal(code.split(marker).length, 2);
	const admission = code
		.slice(0, code.indexOf(marker))
		.replaceAll('${{ env.MACOS_STAGE_ARCHITECTURE }}', 'arm64');
	for (const mode of ['full', 'deferred']) {
		const shell =
			`set -euo pipefail
RUNNER_TEMP="/owned path"
mkdir() { :; }
node() {
    case "$*" in
        *--validate-scope-receipt-profile*) printf '%s' "$PROFILE" ;;
        *--validate-scope-receipt*) printf '%s' "$MODE" ;;
        *--pac-skip-pattern*) printf '%s' '^exact-owned-pattern$' ;;
        *) : ;;
    esac
}
` +
			admission +
			'\nargv() { printf "%s\\0" "$#"; for arg in "$@"; do printf "%s\\0" "$arg"; done; }\nargv ${native_pac_skip_args[@]+"${native_pac_skip_args[@]}"} ${pac_evidence_args[@]+"${pac_evidence_args[@]}"}';
		const result = spawnSync(bashExecutable(), ['--noprofile', '--norc', '-c', shell], {
			encoding: 'utf8',
			env: {
				...process.env,
				MODE: mode,
				PROFILE: mode === 'full' ? '' : 'stable-v1-0-2-20261017-six-macos-native-scopes'
			}
		});
		assert.equal(result.status, 0, result.stderr);
		assert.equal(result.stderr, '');
		if (mode === 'deferred') {
			assert.ok(
				result.stdout.endsWith(
					'4\0--skip\0^exact-owned-pattern$\0--pac-qualification-receipt\0/owned path/stable-macos-native-pac-arm64.json\0'
				)
			);
		} else assert.equal(result.stdout, '0\0');
	}
});
check('v101 HTTP receiver defers only wire and preserves both mandatory statuses', () => {
	const entry = source.find((file) => file.rel === MAC);
	for (const [id, name] of [
		['e2e-hs', 'Receive actual independent managed HTTP native clients'],
		['package-macos', 'Receive actual managed HTTP native clients']
	]) {
		const job = Raw.jobsOfText(entry.text, MAC).find((row) => row.id === id);
		const step = Raw.step(job.body, name);
		const code = Raw.runOf(step)
			.join('\n')
			.replaceAll('${{ env.MACOS_STAGE_ARCHITECTURE }}', 'arm64')
			.replaceAll('${{ github.sha }}', 'a'.repeat(40))
			.replaceAll('${{ github.run_id }}', '123')
			.replaceAll('${{ github.run_attempt }}', '2');
		assert.doesNotMatch(code, /\$\{\{/, 'every fixture-only workflow input is explicitly bound');
		for (const [mode, profile, refused, failedCommand, expected] of [
			['full', '', false, '', 0],
			['deferred', 'stable-v1-0-2-20261017-six-macos-native-scopes', false, '', 0],
			['deferred', 'stable-v1-0-2-20261017-six-macos-native-scopes', false, 'owned', 1],
			['deferred', 'stable-v1-0-2-20261017-six-macos-native-scopes', false, 'client', 1],
			['full', '', true, '', 17],
			['full', '', false, 'owned', 1],
			['full', '', false, 'client', 1],
			['full', '', false, 'wire', 1],
			['full', '', false, 'owned-capture', 1],
			['full', '', false, 'client-capture', 1],
			['full', '', false, 'wire-capture', 1]
		]) {
			if (id === 'package-macos' && failedCommand.endsWith('-capture')) continue;
			const shell =
				`
set -euo pipefail
RUNNER_TEMP="$1"
GITHUB_OUTPUT="$RUNNER_TEMP/github-output"
ERGOPTI_NATIVE_HTTP_PYTHON=owned_python
mkdir() {
    if [ "$#" -eq 2 ] && [ "$1" = -p ] && [ "$2" = "$RUNNER_TEMP" ]; then
        printf '%s\\0' "$@" >> "$RUNNER_TEMP/mkdir-requests"
        command mkdir "$@"
    elif [ "$#" -eq 4 ] && [ "$1" = -m ] && [ "$2" = 700 ] &&
        [ "$3" = "$RUNNER_TEMP/native-http-clock-arm64-123-2" ] &&
        [ "$4" = "$3/private-cache" ]; then
        printf '%s\\0' "$@" >> "$RUNNER_TEMP/mkdir-requests"
        # Windows records the requested POSIX mode; native hosts still apply it.
        if [ "$ERGOPTI_HTTP_FIXTURE_HOST" = win32 ]; then
            command mkdir "$3" "$4"
        else
            command mkdir "$@"
        fi
    else
        return 91
    fi
}
tee() {
    command tee "$@" || return $?
    case "$*" in
        *owned-process.log*) test "$FAILED" != owned-capture ;;
        *public-native.log*) test "$FAILED" != client-capture ;;
        *independent-client.log*) test "$FAILED" != wire-capture ;;
        *) return 91 ;;
    esac
}
node() {
    case "$*" in
        *--validate-scope-receipt-profile*) printf '%s' "$PROFILE" ;;
        *--validate-scope-receipt*) if [ "$REFUSED" = true ]; then return 17; fi; printf '%s' "$MODE" ;;
        *) : ;;
    esac
}
owned_python() {
    case "$*" in
        *macos_owned_process_native_test.py*) printf 'owned\\n'; test "$FAILED" != owned ;;
        *native_http_receiving_test.py*) printf 'client\\n'; test "$FAILED" != client ;;
        *native_http_wire_client_receiving.py*) printf 'wire\\n'; test "$FAILED" != wire ;;
        *) return 91 ;;
    esac
}
` + code;
			const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-http-profile with space-'));
			let result;
			try {
				result = spawnSync(
					bashExecutable(),
					['--noprofile', '--norc', '-c', shell, 'owned-http', owned],
					{
						encoding: 'utf8',
						env: {
							...process.env,
							ERGOPTI_HTTP_FIXTURE_HOST: process.platform,
							MODE: mode,
							PROFILE: profile,
							REFUSED: String(refused),
							FAILED: failedCommand
						}
					}
				);
				if (result.status === expected) {
					const clockRoot = owned + '/native-http-clock-arm64-123-2';
					const expectedRequests = ['-p', owned];
					if (id === 'e2e-hs' && mode === 'full' && !refused) {
						expectedRequests.push('-m', '700', clockRoot, clockRoot + '/private-cache');
						for (const [file, text] of [
							['owned-process.log', 'owned\n'],
							['public-native.log', 'client\n'],
							['independent-client.log', 'wire\n']
						]) {
							assert.equal(
								fs.readFileSync(path.join(clockRoot, file), 'utf8'),
								text,
								'recorded command output remains in the actual owned directory'
							);
						}
					}
					assert.deepEqual(
						fs.readFileSync(path.join(owned, 'mkdir-requests'), 'utf8').split('\0'),
						[...expectedRequests, ''],
						'only the intended setup paths and mode are requested'
					);
				}
			} finally {
				fs.rmSync(owned, { recursive: true, force: true });
			}
			assert.equal(result.error, undefined);
			assert.equal(result.status, expected, result.stderr);
			assert.equal(result.stderr, '');
			const lines = result.stdout.split('\n');
			assert.equal(
				lines.filter((line) => line === 'owned').length,
				refused && id === 'e2e-hs' ? 0 : 1
			);
			assert.equal(
				lines.filter((line) => line === 'client').length,
				refused && id === 'e2e-hs' ? 0 : 1
			);
			assert.equal(
				lines.filter((line) => line === 'wire').length,
				mode === 'full' && !refused ? 1 : 0
			);
		}
		for (const token of [
			'macos_owned_process_native_test.py || status=1',
			'native_http_receiving_test.py --client-only || status=1'
		]) {
			const mutant = step.replace(token, token.replace('status=1', 'true'));
			assert.notEqual(mutant, step);
			assert.throws(() => Full.fromFiles(changed(MAC, step, mutant)));
		}
	}
});
check('v101 package joins only validated PAC and Brew identities', () => {
	const entry = source.find((file) => file.rel === MAC);
	const job = Raw.jobsOfText(entry.text, MAC).find((row) => row.id === 'package-macos');
	const step = Raw.step(job.body, 'Run Swift launcher tests');
	const code = Raw.runOf(step).join('\n');
	for (const token of [
		'test "$brew_mode" = deferred',
		'test "$brew_profile" = "$profile"',
		'test "$brew_mode" = full',
		'test -z "$brew_profile"'
	]) {
		assert.ok(code.includes(token));
		const mutant = step.replace(token, ': # removed');
		assert.throws(() => Full.fromFiles(changed(MAC, step, mutant)));
	}
	assert.equal(code.split(' ${brew_evidence_args[@]+"${brew_evidence_args[@]}"}').length, 3);
	assert.ok(
		code.includes('--pac-skip-pattern "$pac_receipt" --brew-qualification-receipt "$brew_receipt"')
	);
	const full = Full.runOf(Full.step(Full.job('package-macos'), 'Run Swift launcher tests')).join(
		'\n'
	);
	assert.equal(full.includes('brew_evidence_args'), false);
	assert.equal(full.includes('--brew-qualification-receipt'), false);
});

check('v101 Shortcuts keeps portable/full work and publishes its validated exact receipt', () => {
	const entry = source.find((file) => file.rel === MAC);
	const job = Raw.jobsOfText(entry.text, MAC).find((candidate) => candidate.id === 'package-macos');
	const probe = Raw.step(job.body, 'Observe native Apple Shortcuts discovery');
	const code = Raw.runOf(probe).join('\n');
	const portable = code.indexOf(
		'python3 -m unittest discover -s tools/diagnostics/apple_shortcuts_probe'
	);
	const jxa = code.indexOf('node tools/diagnostics/apple_shortcuts_probe/test_probe.cjs');
	const admission = code.indexOf(
		"policy.validateQualificationReceipt(receipt, 'macos-shortcuts-discovery'"
	);
	const emission = code.indexOf('fs.writeFileSync(');
	const full = code.indexOf('if [ "$shortcuts_mode" = full ]; then');
	assert(
		portable >= 0 && jxa > portable && admission > jxa && emission > admission && full > emission
	);
	assert(code.includes("{ flag: 'wx' }"));
	assert(code.includes('python3 tools/diagnostics/apple_shortcuts_probe/run_probe.py'));
	const upload = Raw.step(job.body, 'Retain source-bound Shortcuts native qualification receipt');
	assert.equal(Raw.stepField(upload, 'if'), macRole.condition('package-macos'));
	assert(upload.includes('name: assets-qualification-shortcuts-macos'));
	assert(upload.includes('path: ${{ runner.temp }}/stable-macos-shortcuts-discovery.json'));
	assert(upload.includes('if-no-files-found: error'));
});

check('v101 AppleEvents records only exact transport rows and preserves installed launch', () => {
	const entry = source.find((file) => file.rel === MAC);
	const job = Raw.jobsOfText(entry.text, MAC).find((candidate) => candidate.id === 'launch');
	const code = Raw.runOf(Raw.step(job.body, 'Record the launch qualification scope')).join('\n');
	assert(
		code.includes(
			'policy.validateLaunchQualificationReceipt(receipt, scenario, runner, process.env.GITHUB_SHA, policy.environmentContext())'
		)
	);
	assert(
		code.indexOf('policy.validateLaunchQualificationReceipt') < code.indexOf('fs.writeFileSync')
	);
	assert(code.includes("{ flag: 'wx' }"));
	const upload = Raw.step(job.body, 'Retain source-bound AppleEvent launch qualification receipt');
	assert.equal(
		Raw.stepField(upload, 'if'),
		macRole.condition(
			'launch',
			"${{ matrix.scenario == 'clean' || matrix.scenario == 'karabiner_config' }}"
		)
	);
	assert(
		upload.includes(
			'name: assets-qualification-launch-macos-${{ env.MACOS_STAGE_RUNNER }}-${{ env.MACOS_STAGE_SCENARIO }}'
		)
	);
	assert(upload.includes('if-no-files-found: error'));
	const launch = Raw.runOf(Raw.step(job.body, 'Launch over the user state and judge it')).join(
		'\n'
	);
	assert(
		launch.includes('python3 tools/diagnostics/macos_launch_gate.py /Applications/ErgoptiPlus.app')
	);
	assert(launch.includes('--qualification-receipt "$RUNNER_TEMP/launch-qualification.json"'));
	assert(entry.text.includes('node tools/build/macos-release-archives.cjs --ci-install'));
});

console.log(
	`PASS: raw full-default and retired-route source controls=${passed}; native execution UNRUN.`
);
