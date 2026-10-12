'use strict';

/**
 * Read the mandatory full CI graph without rewriting any source predicate.
 * The temporary all-suite fast route is retired. Its reintroduction refuses;
 * the independent bounded qualification scopes remain owned by their policy.
 * Known scoped wrappers are admitted before inspecting their retained full commands.
 * All workflow predicates and unrelated scripts remain unchanged.
 */
const raw = require('./ci-pipeline.cjs');
const assert = require('node:assert/strict');
const YAML = require('yaml');
const macRole = require('./fixtures/macos-stage-source.cjs');
const macPlans = require('../ci/macos-stage-roles.cjs');
const { projectScopedSteps } = require('./fixtures/ci-scoped-full-branches.cjs');
const ROOT = raw.ROOT;
const ENTRY_REL = raw.ENTRY_REL;
const JOBS = [
	['.github/workflows/ci.yml', 'validate', null],
	['.github/workflows/ci.yml', 'core', null],
	['.github/workflows/ci-common.yml', 'prepare-common', null],
	['.github/workflows/ci-common.yml', 'shared-validation', null],
	['.github/workflows/ci-common.yml', 'common-unit-verdict', null],
	['.github/workflows/ci-common.yml', 'common-e2e', null],
	['.github/workflows/ci.yml', 'macos', "needs.validate.outputs.lane_macos == 'true'"],
	['.github/workflows/ci.yml', 'windows', "needs.validate.outputs.lane_windows == 'true'"],
	['.github/workflows/ci.yml', 'linux', "needs.validate.outputs.lane_linux == 'true'"],
	['.github/workflows/ci.yml', 'publication-plan', 'always() && !cancelled()'],
	[
		'.github/workflows/ci.yml',
		'release',
		"github.event_name == 'push' && needs.publication-plan.outputs.release == 'true'"
	],
	['.github/workflows/ci-macos.yml', 'test-hs', null],
	['.github/workflows/ci-macos.yml', 'e2e-hs', null],
	['.github/workflows/ci-macos.yml', 'package-macos', null],
	['.github/workflows/ci-macos.yml', 'launch', null],
	['.github/workflows/ci-macos.yml', 'macos-ok', 'always()'],
	['.github/workflows/ci-windows.yml', 'test-ahk', null],
	['.github/workflows/ci-windows.yml', 'e2e-ahk', null],
	['.github/workflows/ci-windows.yml', 'package-windows', null],
	['.github/workflows/ci-windows.yml', 'launch-windows', null],
	['.github/workflows/ci-windows.yml', 'windows-ok', 'always()'],
	['.github/workflows/ci-linux.yml', 'test-linux', null],
	['.github/workflows/ci-linux.yml', 'e2e-linux', null],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		"${{ !cancelled() && needs.e2e-linux.outputs.ci_unit_result == 'success' && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}"
	],
	['.github/workflows/ci-linux.yml', 'install-linux', null],
	['.github/workflows/ci-linux.yml', 'linux-ok', 'always()']
];
const FULL_STEPS = [
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive closed lease silence transcript controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'lease-silence-native' && (github.event_name == 'workflow_dispatch' && !inputs.release) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Execute the actual paired native silence control',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'lease-silence-native' && (github.event_name == 'workflow_dispatch' && !inputs.release) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain exact paired-process native receiving',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'lease-silence-native' && (github.event_name == 'workflow_dispatch' && !inputs.release) && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Observe independent native Apple Shortcuts SDK preflight and discovery',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && github.event_name == 'workflow_dispatch' && !inputs.release) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native Apple Shortcuts SDK observation',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && github.event_name == 'workflow_dispatch' && !inputs.release) }}"
	],
	[
		'.github/workflows/ci-linux.yml',
		'test-linux',
		'Qualify actual LuaJIT XI2 ABI and property cookies',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-linux.yml',
		'test-linux',
		'Retain actual LuaJIT XI2 diagnostic evidence',
		'always()'
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Prepare genuine pinned Go toolchain',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Acquire and verify genuine pinned upstream inputs',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Build and admit the actual native source asset',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual selected number-row Carbon XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive selected-release shell corpus and native guardian cancellation',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain selected number-row Carbon XCTest diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive native final-byte number-row causal refusal',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain native final-byte number-row causal diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain selected-release native ownership receiving',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Observe the actual no-prompt SDK permission API independently',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'item36-native' && (github.event_name == 'workflow_dispatch' && !inputs.release) && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Prepare locked native HTTP receiving clients',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive actual private-session and numeric TLS peer controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain actual private-session and numeric TLS peer diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual SDK accepted-owner and deadline XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual native PAC source ownership XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native SDK XCTest diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual native PAC and WPAD XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native PAC XCTest diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive actual independent managed HTTP native clients',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native HTTP clock receiving',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && steps.native_http_clock.outputs.clock_expected == 'true') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual explicit curl stream ownership',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive actual native model create, pull, inference and retirement',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && steps.ollama-native-build.outcome == 'success') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run reporter lifecycle self-tests',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run owned program XCTest notice constructed-policy controls',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Admit native nonreaping Python prerequisites',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Prepare locked managed HTTP native clients',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Prepare scoped native qualification profile',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run portable Brew ownership and refusal controls',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Verify scoped Swift test target exclusion',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Receive actual managed HTTP native clients',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run Swift launcher tests',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain scoped native Brew qualification receipt',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Upload Swift launcher failure transcript',
		"${{ steps.stage-admission.outcome == 'success' && (failure() && steps.swift-launcher-tests.outcome == 'failure') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain archive diagnostic session',
		"${{ steps.stage-admission.outcome == 'success' && (always() && steps.swift-launcher-tests.outputs.archive_session_dir != '') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain closed TIS diagnostic session',
		"${{ steps.stage-admission.outcome == 'success' && (always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run signed Hammerspoon program provider inventory',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native Hammerspoon provider inventory',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Observe native notification constructors',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native notification constructor observations',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Observe native global application switcher',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native global application switcher observations',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Observe native Apple Shortcuts discovery',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native Apple Shortcuts observation',
		"${{ steps.stage-admission.outcome == 'success' && (always()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Remove the launcher log the Swift tests wrote',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Self-test the launch verdict',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Receive actual cold native MLX bootstrap',
		"${{ steps.stage-admission.outcome == 'success' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
		"${{ steps.stage-admission.outcome == 'success' && (inputs.release) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain packaged application startup evidence',
		"${{ steps.stage-admission.outcome == 'success' && (always() && inputs.release) }}"
	],
	['.github/workflows/ci-macos.yml', 'macos-ok', 'Download launch evidence', null],
	['.github/workflows/ci-macos.yml', 'macos-ok', 'Download native cold bootstrap evidence', null],
	[
		'.github/workflows/ci-macos.yml',
		'macos-ok',
		'Verify mandatory jobs and launch scenarios',
		null
	],
	['.github/workflows/ci-windows.yml', 'windows-ok', 'Download launch evidence', null],
	[
		'.github/workflows/ci-windows.yml',
		'windows-ok',
		'Install locked evidence validation dependencies',
		null
	],
	[
		'.github/workflows/ci-windows.yml',
		'windows-ok',
		'Verify mandatory jobs and launch scenarios',
		null
	],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'Install the Flatpak the way a user would',
		null
	],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Launch the Flatpak', null],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'The sandboxed shared data tree resolves and opens',
		null
	],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'Unpack and install the tarball the way a user would',
		null
	],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Launch what the tarball installed', null],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'The installed shared data tree resolves and opens',
		null
	],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Record mandatory package evidence', null],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Upload mandatory package evidence', null],
	['.github/workflows/ci-linux.yml', 'linux-ok', 'Download assertion evidence', null],
	[
		'.github/workflows/ci-linux.yml',
		'linux-ok',
		'Assert all mandatory subjects ran and passed',
		null
	]
];

function refuse(message) {
	throw new Error(`[ci-full-default] ${message}`);
}
function requireEqual(actual, expected, label) {
	if (actual !== expected) refuse(label);
}
const LEASE_SILENCE_NATIVE_BODY =
	"    name: 'Native paired lease silence · ${{ matrix.architecture }}'\n    if: ${{ github.event_name == 'workflow_dispatch' && !inputs.release }}\n    runs-on: ${{ matrix.runner }}\n    timeout-minutes: 20\n    strategy:\n      fail-fast: false\n      matrix:\n        include:\n          - runner: macos-15\n            architecture: arm64\n          - runner: macos-15-intel\n            architecture: amd64\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n        with:\n          node-version-file: '.node-version'\n      - name: Receive closed lease silence transcript controls\n        run: node tools/test/test-lease-silence-xctest-evidence.cjs\n      - name: Execute the actual paired native silence control\n        shell: bash\n        run: bash tools/diagnostics/run_lease_silence_native.sh '${{ matrix.architecture }}'\n      - name: Retain exact paired-process native receiving\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: lease-silence-native-${{ github.sha }}-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}\n          retention-days: 7\n          if-no-files-found: error\n          path: |\n            ${{ runner.temp }}/lease-silence-native/source.json\n            ${{ runner.temp }}/lease-silence-native/verdict.json\n            ${{ runner.temp }}/lease-silence-native/xctest.log\n            ${{ runner.temp }}/lease-silence-native/swift-status.txt\n            ${{ runner.temp }}/lease-silence-native/script-status.txt\n            ${{ runner.temp }}/lease-silence-native/capture-status.txt";
function validateRaw(files) {
	if (!Array.isArray(files)) refuse('workflow files must be an array');
	const entries = new Map();
	for (const entry of files) {
		if (
			!entry ||
			typeof entry.rel !== 'string' ||
			typeof entry.text !== 'string' ||
			entries.has(entry.rel)
		)
			refuse('invalid or duplicate workflow identity');
		entries.set(entry.rel, entry.text);
		const executable = entry.text
			.split('\n')
			.filter((line) => !line.trimStart().startsWith('#'))
			.join('\n');
		if (/fast_prerelease|ERGOPTI_FAST_PRERELEASE|--fast-action/.test(executable))
			refuse(`${entry.rel} retired fast route`);
	}
	const expectedFiles = [...new Set(JOBS.map((row) => row[0]))];
	if (entries.size !== expectedFiles.length || expectedFiles.some((rel) => !entries.has(rel)))
		refuse('exact five workflow call graph');
	const jobs = files.flatMap((entry) => raw.jobsOfText(entry.text, entry.rel));
	if (jobs.length !== JOBS.length) refuse('complete mandatory job inventory');
	for (const [rel, id, condition] of JOBS) {
		const found = jobs.filter((job) => job.file === rel && job.id === id);
		if (found.length !== 1) refuse(`ambiguous/missing job ${rel}/${id}`);
		requireEqual(raw.field(found[0].body, 'if'), condition, `${id} full job condition`);
		requireEqual(
			raw.field(found[0].body, 'continue-on-error'),
			null,
			`${id} job failure must remain fatal`
		);
	}
	for (const [rel, id, name, condition] of FULL_STEPS) {
		const job = jobs.find((entry) => entry.file === rel && entry.id === id);
		const body = raw.step(job.body, name);
		requireEqual(raw.stepField(body, 'if'), condition, `${id}/${name} full step condition`);
		if (name === 'Build and admit the actual native source asset') {
			requireEqual(
				raw.stepField(body, 'id'),
				'ollama-native-build',
				'native producer exact build id'
			);
			const members = raw.steps(job.body);
			requireEqual(
				members.filter((member) => raw.stepField(member.body, 'id') === 'ollama-native-build')
					.length,
				1,
				'native producer unique build id'
			);
			requireEqual(
				members.findIndex((member) => member.name === name) <
					members.findIndex(
						(member) =>
							member.name === 'Receive actual native model create, pull, inference and retirement'
					),
				true,
				'native producer precedes model receiving'
			);
		}
		if (name === 'Receive selected-release shell corpus and native guardian cancellation') {
			requireEqual(raw.stepField(body, 'shell'), 'bash', 'selected-release receiver exact shell');
			requireEqual(
				raw.runOf(body)?.join('\n'),
				[
					'set -euo pipefail',
					'node tools/diagnostics/macos_release_stage_native_receiving.cjs \\',
					'  --output "$RUNNER_TEMP/native-selected-release-$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE"'
				].join('\n'),
				'selected-release receiver exact command'
			);
		}
		requireEqual(
			raw.stepField(body, 'continue-on-error'),
			null,
			`${id}/${name} failure must remain fatal`
		);
	}
	const macText = entries.get('.github/workflows/ci-macos.yml');
	const macContract = require('./fixtures/macos-stage-contract.json');
	assert.deepEqual(
		Object.entries(YAML.parse(macText).jobs).map(([id, job]) => ({
			id,
			metadata: Object.fromEntries(Object.entries(job).filter(([key]) => key !== 'steps'))
		})),
		macContract.jobs.map(({ id, metadata }) => ({ id, metadata })),
		'Mac stage metadata differs.'
	);
	const originalSilence = YAML.parse('job:\n' + LEASE_SILENCE_NATIVE_BODY).job;
	const expectedSilenceSteps = originalSilence.steps.map((step) => ({
		...step,
		if: macRole.condition('lease-silence-native', step.if ?? null)
	}));
	const silenceSteps = YAML.parse(macRole.body(macText, 'lease-silence-native')).steps;
	assert.deepEqual(
		silenceSteps,
		expectedSilenceSteps,
		'lease silence native exact source/artifact owner'
	);
	const context = {
		source_sha: 'a'.repeat(40),
		run_id: '1',
		event_name: 'workflow_dispatch',
		release: false,
		scenarios: ['clean']
	};
	assert.deepEqual(
		macPlans.plan('e2e', context).filter((cell) => cell.role === 'lease-silence-native'),
		originalSilence.strategy.matrix.include.map((cell) => ({
			role: 'lease-silence-native',
			...cell,
			timeout_minutes: 20,
			scenario: ''
		})),
		'lease silence exact host, architecture and timeout owner'
	);
	for (const lane of ['macos', 'windows', 'linux']) {
		const caller = jobs.find((job) => job.file === ENTRY_REL && job.id === lane);
		requireEqual(
			raw.field(caller.body, 'uses'),
			`./.github/workflows/ci-${lane}.yml`,
			`${lane} actual caller`
		);
		for (const key of ['release', 'prerelease', 'channel', 'tag', 'version']) {
			const value =
				key === 'release'
					? "needs.validate.outputs.release == 'true'"
					: `needs.validate.outputs.${key}`;
			const line = `      ${key}: \${{ ${value} }}\n`;
			if (caller.body.split(line).length !== 2) refuse(`${lane} exact ${key} source binding`);
		}
	}
}
function fromFiles(files) {
	validateRaw(files);
	const projected = files.map((entry) => ({
		...entry,
		text: projectScopedSteps(entry.text, entry.rel)
	}));
	const file = (rel) => {
		const found = projected.find((f) => f.rel === rel);
		if (!found) refuse(`unknown file ${rel}`);
		return found.text;
	};
	const jobs = (rel) => raw.jobsOfText(file(rel), rel);
	const locate = (id) => {
		const found = projected.flatMap((f) => jobs(f.rel)).filter((j) => j.id === id);
		if (found.length !== 1) refuse(`ambiguous/missing raw job ${id}`);
		return found[0];
	};
	const text = () => projected.map((f) => f.text).join('\n');
	const findStep = (name) => {
		const found = projected.flatMap((f) =>
			jobs(f.rel).flatMap((j) =>
				raw
					.steps(j.body)
					.filter((s) => s.name === name)
					.map((s) => ({ file: f.rel, job: j.id, body: s.body }))
			)
		);
		if (found.length !== 1) refuse(`ambiguous/missing projected step ${name}`);
		return found[0];
	};
	return {
		...raw,
		files: () => projected.map((f) => ({ ...f })),
		rawFiles: () => files.map((f) => ({ ...f })),
		file,
		text,
		jobs,
		locate,
		job: (id) => locate(id).body,
		findStep,
		textWithout: (id) => {
			const j = locate(id);
			return projected
				.map((f) => (f.rel === j.file ? f.text.replace(j.body, '') : f.text))
				.join('\n');
		},
		calls: (rel = ENTRY_REL) =>
			jobs(rel)
				.map((j) => ({ id: j.id, uses: raw.field(j.body, 'uses') }))
				.filter((j) => j.uses !== null)
	};
}
function open(root) {
	return fromFiles(raw.open(root).files());
}
module.exports = { ...open(ROOT), open, fromFiles, validateRaw };
