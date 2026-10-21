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
	['.github/workflows/ci.yml', 'prepare-common', null],
	// Common: each stage caller keeps its stage job's id and predicate; the
	// stage job in its own file runs whenever its caller does.
	['.github/workflows/ci-common.yml', 'shared-validation', null],
	['.github/workflows/ci-common.yml', 'common-unit-verdict', 'always()'],
	['.github/workflows/ci-common.yml', 'common-e2e', null],
	['.github/workflows/ci-common.yml', 'common-build', null],
	['.github/workflows/ci-common.yml', 'common-testbuild', null],
	['.github/workflows/ci-common-unit.yml', 'shared-validation', null],
	['.github/workflows/ci-common-e2e.yml', 'common-e2e', null],
	['.github/workflows/ci-common-build.yml', 'common-build', null],
	['.github/workflows/ci-common-install.yml', 'common-testbuild', null],
	['.github/workflows/ci-common-verdict.yml', 'common-unit-verdict', null],
	['.github/workflows/ci.yml', 'macos', "needs.validate.outputs.lane_macos == 'true'"],
	['.github/workflows/ci.yml', 'windows', "needs.validate.outputs.lane_windows == 'true'"],
	['.github/workflows/ci.yml', 'linux', "needs.validate.outputs.lane_linux == 'true'"],
	['.github/workflows/ci.yml', 'publication', 'always() && !cancelled()'],
	['.github/workflows/ci-release.yml', 'publication-plan', null],
	[
		'.github/workflows/ci-release.yml',
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
	['.github/workflows/ci-windows-unit.yml', 'test-ahk', null],
	['.github/workflows/ci-windows-e2e.yml', 'e2e-ahk', null],
	['.github/workflows/ci-windows-build.yml', 'package-windows', null],
	['.github/workflows/ci-windows-install.yml', 'launch-windows', null],
	['.github/workflows/ci-windows-verdict.yml', 'windows-ok', null],
	['.github/workflows/ci-linux.yml', 'test-linux', null],
	['.github/workflows/ci-linux.yml', 'e2e-linux', null],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		"${{ !cancelled() && needs.e2e-linux.outputs.ci_unit_result == 'success' && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}"
	],
	['.github/workflows/ci-linux.yml', 'package-flatpak', null],
	['.github/workflows/ci-linux.yml', 'install-linux', null],
	['.github/workflows/ci-linux.yml', 'linux-ok', 'always()'],
	['.github/workflows/ci-linux-unit.yml', 'test-linux', null],
	['.github/workflows/ci-linux-e2e.yml', 'e2e-linux', null],
	['.github/workflows/ci-linux-build.yml', 'package-linux', null],
	['.github/workflows/ci-linux-flatpak.yml', 'package-flatpak', null],
	['.github/workflows/ci-linux-install.yml', 'install-linux', null],
	['.github/workflows/ci-linux-verdict.yml', 'linux-ok', null]
];
const FULL_STEPS = [
	[
		'.github/workflows/ci-common-unit.yml',
		'shared-validation',
		'Check hotstring TOML files are sorted and formatted',
		"${{ !cancelled() && steps.common-lot.outputs.suite == 'hotstrings-format' }}"
	],
	[
		'.github/workflows/ci-common-build.yml',
		'common-build',
		'Build and seal production site — ${{ matrix.lot }}',
		null
	],
	[
		'.github/workflows/ci-common-install.yml',
		'common-testbuild',
		'Test received production site — ${{ matrix.lot }}',
		null
	],
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
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && github.event_name == 'workflow_dispatch' && !inputs.release && matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native Apple Shortcuts SDK observation',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && github.event_name == 'workflow_dispatch' && !inputs.release && matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-linux-unit.yml',
		'test-linux',
		'Qualify actual LuaJIT XI2 ABI and property cookies',
		"${{ !cancelled() && matrix.group == 'meta' }}"
	],
	[
		'.github/workflows/ci-linux-unit.yml',
		'test-linux',
		'Retain actual LuaJIT XI2 diagnostic evidence',
		"${{ always() && matrix.group == 'meta' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Prepare genuine pinned Go toolchain',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-build' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Acquire and verify genuine pinned upstream inputs',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-build' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Build and admit the actual native source asset',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-build' && (!cancelled()) }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Seal the clean native source build for its receiving cell',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-build' && (!cancelled() && steps.ollama-native-producer.outcome == 'success') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Hand the clean native source build to its receiving cell',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-build' && (!cancelled() && steps.ollama-native-seal.outcome == 'success') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive and admit the clean native source asset from its build cell',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual selected number-row Carbon XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive selected-release shell corpus and native guardian cancellation',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain selected number-row Carbon XCTest diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify native input-source and launcher XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain native input-source and launcher XCTest diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain selected-release native ownership receiving',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && matrix.scenario != 'xctest') }}"
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
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain actual private-session and numeric TLS peer diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual SDK accepted-owner and deadline XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify numeric logger boundary XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual native PAC source ownership XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native SDK XCTest diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual native PAC and WPAD XCTest controls',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native PAC XCTest diagnostics',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && matrix.scenario != 'runtime') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive actual independent managed HTTP native clients',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Retain independent native HTTP clock receiving',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (always() && steps.native_http_clock.outputs.clock_expected == 'true' && matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Qualify actual explicit curl stream ownership',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && matrix.scenario != 'xctest') }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'e2e-hs',
		'Receive actual native model create, pull, inference and retirement',
		"${{ steps.stage-admission.outcome == 'success' && matrix.role == 'managed-ollama-native' && (!cancelled() && steps.ollama-native-build.outcome == 'success' && matrix.scenario != 'xctest') }}"
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
		'Run Swift launcher tests on macOS 26',
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
	['.github/workflows/ci-windows-verdict.yml', 'windows-ok', 'Download launch evidence', null],
	[
		'.github/workflows/ci-windows-verdict.yml',
		'windows-ok',
		'Install locked evidence validation dependencies',
		null
	],
	[
		'.github/workflows/ci-windows-verdict.yml',
		'windows-ok',
		'Verify mandatory jobs and launch scenarios',
		null
	],
	[
		'.github/workflows/ci-linux-flatpak.yml',
		'package-flatpak',
		'Install the Flatpak the way a user would',
		null
	],
	['.github/workflows/ci-linux-flatpak.yml', 'package-flatpak', 'Launch the Flatpak', null],
	[
		'.github/workflows/ci-linux-flatpak.yml',
		'package-flatpak',
		'The sandboxed shared data tree resolves and opens',
		null
	],
	[
		'.github/workflows/ci-linux-build.yml',
		'package-linux',
		'Unpack and install the tarball the way a user would',
		null
	],
	[
		'.github/workflows/ci-linux-build.yml',
		'package-linux',
		'Launch what the tarball installed',
		null
	],
	[
		'.github/workflows/ci-linux-build.yml',
		'package-linux',
		'The installed shared data tree resolves and opens',
		null
	],
	[
		'.github/workflows/ci-linux-build.yml',
		'package-linux',
		'Record mandatory package evidence',
		null
	],
	[
		'.github/workflows/ci-linux-build.yml',
		'package-linux',
		'Upload mandatory package evidence',
		null
	],
	[
		'.github/workflows/ci-linux-flatpak.yml',
		'package-flatpak',
		'Record mandatory Flatpak evidence',
		null
	],
	[
		'.github/workflows/ci-linux-flatpak.yml',
		'package-flatpak',
		'Upload mandatory Flatpak evidence',
		null
	],
	['.github/workflows/ci-linux-verdict.yml', 'linux-ok', 'Download assertion evidence', null],
	[
		'.github/workflows/ci-linux-verdict.yml',
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
		refuse('exact workflow call graph');
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
		const expectedCondition =
			rel === '.github/workflows/ci-macos.yml' ? macRole.metadata(condition, id) : condition;
		requireEqual(raw.stepField(body, 'if'), expectedCondition, `${id}/${name} full step condition`);
		if (name === 'Check hotstring TOML files are sorted and formatted') {
			requireEqual(raw.stepField(body, 'id'), 'hotstrings-format', 'mandatory TOML step identity');
			requireEqual(
				raw.runOf(body)?.join('\n'),
				'python tools/format_toml.py --hotstrings --all --check',
				'mandatory TOML check command'
			);
		}
		// The clean producer runs in its own build cell; the receiving cell admits
		// its sealed handoff under the original build id, before model receiving.
		if (name === 'Build and admit the actual native source asset') {
			requireEqual(
				raw.stepField(body, 'id'),
				'ollama-native-producer',
				'native producer exact build id'
			);
			const members = raw.steps(job.body);
			requireEqual(
				members.filter((member) => raw.stepField(member.body, 'id') === 'ollama-native-producer')
					.length,
				1,
				'native producer unique build id'
			);
			requireEqual(
				members.findIndex((member) => member.name === name) <
					members.findIndex(
						(member) => member.name === 'Seal the clean native source build for its receiving cell'
					),
				true,
				'native producer precedes its sealed handoff'
			);
		}
		if (name === 'Receive and admit the clean native source asset from its build cell') {
			requireEqual(raw.stepField(body, 'id'), 'ollama-native-build', 'native admission build id');
			requireEqual(
				raw.runOf(body)?.join('\n'),
				'set -euo pipefail\nnode tools/ci/managed-ollama-handoff.cjs receive "$RUNNER_TEMP/managed-ollama-handoff"',
				'native admission exact command'
			);
			const members = raw.steps(job.body);
			requireEqual(
				members.filter((member) => raw.stepField(member.body, 'id') === 'ollama-native-build')
					.length,
				1,
				'native admission unique build id'
			);
			requireEqual(
				members.findIndex((member) => member.name === name) <
					members.findIndex(
						(member) =>
							member.name === 'Receive actual native model create, pull, inference and retirement'
					),
				true,
				'native admission precedes model receiving'
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
	// The Mac stage contract reads the lane inlined, its stage jobs as one workflow.
	const macText = raw
		.inlinePipeline(files)
		.find((entry) => entry.rel === '.github/workflows/ci-macos.yml').text;
	const macContract = require('./fixtures/macos-stage-contract.json');
	const macJobs = YAML.parse(macText).jobs;
	assert.deepEqual(
		Object.entries(macJobs).map(([id, job]) => ({
			id,
			metadata: Object.fromEntries(Object.entries(job).filter(([key]) => key !== 'steps'))
		})),
		macContract.jobs.map(({ id, metadata }) => ({ id, metadata })),
		'Mac stage metadata differs.'
	);
	const unitSelection = macJobs['test-hs'].steps.filter((step) => step.id === 'stage-selection');
	assert.deepEqual(unitSelection, [
		{
			name: 'Admit the authored unit lot',
			id: 'stage-selection',
			run: 'node tools/ci/macos-stage-roles.cjs select unit'
		}
	]);
	assert.equal(
		macJobs['test-hs'].steps.indexOf(unitSelection[0]),
		1,
		'Unit selects before products'
	);
	const unitRecord = macJobs['test-hs'].steps.filter(
		(step) => step.name === 'Record actual stage role outcome'
	);
	assert.equal(unitRecord.length, 1, 'Unit keeps one actual receipt writer');
	assert.deepEqual(unitRecord[0].env, {
		MACOS_STAGE_CELL: '${{ steps.stage-selection.outputs.cell }}',
		MACOS_STAGE_RESULT: '${{ job.status }}'
	});
	// Each job names the stage it receives; Build admits Unit beside E2E.
	for (const [id, prior] of [
		['e2e-hs', 'e2e'],
		['package-macos', 'build'],
		['launch', 'testbuild']
	]) {
		const admissions = macJobs[id].steps.filter((step) => step.id === 'stage-admission');
		assert.deepEqual(admissions, [
			{
				name: 'Admit complete successful predecessor stage',
				id: 'stage-admission',
				env: { MACOS_STAGE_NEEDS: '${{ toJSON(needs) }}' },
				run: `node tools/ci/macos-stage-roles.cjs admit ${prior} "$RUNNER_TEMP/macos-stage-inputs" "$RUNNER_TEMP/macos-stage-prior.json"`
			}
		]);
		assert.equal(macJobs[id].steps.indexOf(admissions[0]), 2, `${id} admits before products`);
	}
	const originalSilence = YAML.parse('job:\n' + LEASE_SILENCE_NATIVE_BODY).job;
	const expectedSilenceSteps = originalSilence.steps.map((step) => ({
		...macRole.metadata(step, 'lease-silence-native'),
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
	// The default view reads every lane inlined, as the loader's does; real()
	// reads the projected files as they are, stage files included.
	const actual = raw.view(() => projected);
	const inlined = raw.view(() => raw.inlinePipeline(projected));
	return {
		...raw,
		...inlined,
		rawFiles: () => files.map((f) => ({ ...f })),
		real: () => ({ ...raw, ...actual }),
		laneOf: (rel) => raw.laneOfFile(projected, rel)
	};
}
function open(root) {
	return fromFiles(raw.open(root).real().files());
}
module.exports = { ...open(ROOT), open, fromFiles, validateRaw };
