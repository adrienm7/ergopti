// tools/test/test-ci-pipeline-wiring.cjs

/**
 * ==============================================================================
 * MODULE: CI Pipeline Wiring Guard
 * DESCRIPTION:
 * Pins how ci.yml wires its root, "Validate and plan", into the three OS lanes
 * and Release: the shape of the run graph, the plan's outputs, what each lane
 * caller passes and waits for, which secrets and permissions reach a job, how
 * the root validates inputs before it deepens the clone for the plan, and the
 * release preflight that runs before any side effect. It also proves that no
 * job of ci.yml and no step of the pipeline can be switched off, or have its
 * failure swallowed, while the run stays green.
 *
 * ROOT CAUSE ENCODED:
 * After the pipeline was split into one reusable workflow per OS, a review
 * found single-line edits that kept every contract test green and broke a
 * release: `release: false` on the Windows caller published without the exe,
 * plan's channel hard-wired to `dev` put a stable build on the dev feed,
 * `secrets: inherit` handed PAT_ERGOPTI to every box, a caller that stopped
 * needing validate let release publish over a red Validate, a deleted
 * Windows E2E step or preflight went unnoticed, and reverting plan's tag probe
 * to `git ls-remote ... | grep -q` read a network error as "tag free".
 * A second review found the next layer: `if: false` or an event condition on
 * a box caller skipped a whole OS (and release with it) on a green run;
 * `continue-on-error` on validate, plan or release forgave them; `if:
 * ${{ !cancelled() && false }}` or `npm run test:js || true` switched off
 * Validate; `if: false` on any gating step of a box (the Swift XCTest, the
 * Hammerspoon suite, the Windows LLM suites, a Linux smoke, the Linux evidence
 * gate itself), `|| true` after a test runner, or a `| tee` without pipefail
 * turned a failure green; and the Windows compiler-warning and LLM gates could
 * drop their failing exit or move into the release-only job.
 * The run graph then became hard to read: two roots each wired to every first
 * job, lanes that started with two or three jobs, and several leaf jobs per
 * lane wired to the release. GitHub flattens a called workflow into the run's
 * graph, so only its entry and exit jobs decide what the graph shows. The plan
 * job merged into validate, which deepens its clone for the plan only after
 * the checks, since several test:js gates shell out to git.
 *
 * FEATURES & RATIONALE:
 * 1. Derived, not listed: every plan output must come from a plan step that
 *    writes it, every caller input must be the plan output of the same name,
 *    and release must wait, directly or through a lane, on every other job of
 *    ci.yml. No job forgives failure; OS callers consume exact selection
 *    outputs. The publication preflight receives the retained original plan
 *    and every required lane before release can run.
 * 2. Private secrets reach a lane only on a release run, through one exact
 *    expression; the public Sparkle key is the only allow-listed exception.
 *    Every pipeline file reads contents only; release alone may write.
 * 3. The root checks TOML, then deepens its checkout with one exact script,
 *    which retries a failed fetch and rejects a clone still shallow. The
 *    parallel core matrix has a separate shallow checkout for its JS gates,
 *    properties and main-only mutations, pinned by test-desktop-ci-evidence.
 * 4. One root, one lane per OS: ci.yml has exactly one job without needs, the
 *    root; each lane caller needs the root alone. The publication preflight
 *    needs core and the three lanes; release needs only that preflight.
 *    Each OS exposes Unit, E2E, Build, Testbuild and Verdict in order.
 *    macOS retains every native role inside its E2E and Testbuild matrices,
 *    including the scoped manual roles and the native tooltip canvas.
 * 5. Only the steps in STEP_CONDITIONS set an `if`, each exactly its own, and
 *    e2e-linux's harnesses run under !cancelled(). No script swallows a test
 *    runner's failure with `|| true`, and every `| tee` runs under pipefail.
 * 6. The release preflight precedes the first step that writes to GitHub, the
 *    release steps keep their order, and both tag probes capture ls-remote
 *    before testing it (N5). Every assets-* upload fails on a missing file and
 *    outlives a next-day re-run, and release merges them into one folder. The
 *    asset list of the preflight is derived from the release notes by
 *    tools/test/test-release-notes-assets-are-uploaded.cjs.
 * 7. Each rule is also run on a mutated copy of the real workflow, for every
 *    form a review used, and must report it: a rule that cannot fail is
 *    reported as broken.
 * ==============================================================================
 */

'use strict';

const pipeline = require('./ci-full-default.cjs');
const { canRunSymlinkCase } = require('./lib/host-capabilities.cjs');
const scoped = require('./fixtures/ci-scoped-full-branches.cjs');
const macRole = require('./fixtures/macos-stage-source.cjs');
const LinuxE2E = require('./fixtures/linux-e2e-shards.cjs');
const macContract = require('./fixtures/macos-stage-contract.json');
const YAML = require('yaml');
// Initialized before early matrix admission invokes the Mac source guard.
const LEASE_SILENCE_NATIVE_BODY =
	"    name: 'Native paired lease silence · ${{ matrix.architecture }}'\n    if: ${{ github.event_name == 'workflow_dispatch' && !inputs.release }}\n    runs-on: ${{ matrix.runner }}\n    timeout-minutes: 20\n    strategy:\n      fail-fast: false\n      matrix:\n        include:\n          - runner: macos-15\n            architecture: arm64\n          - runner: macos-15-intel\n            architecture: amd64\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n        with:\n          node-version-file: '.node-version'\n      - name: Receive closed lease silence transcript controls\n        run: node tools/test/test-lease-silence-xctest-evidence.cjs\n      - name: Execute the actual paired native silence control\n        shell: bash\n        run: bash tools/diagnostics/run_lease_silence_native.sh '${{ matrix.architecture }}'\n      - name: Retain exact paired-process native receiving\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: lease-silence-native-${{ github.sha }}-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}\n          retention-days: 7\n          if-no-files-found: error\n          path: |\n            ${{ runner.temp }}/lease-silence-native/source.json\n            ${{ runner.temp }}/lease-silence-native/verdict.json\n            ${{ runner.temp }}/lease-silence-native/xctest.log\n            ${{ runner.temp }}/lease-silence-native/swift-status.txt\n            ${{ runner.temp }}/lease-silence-native/script-status.txt\n            ${{ runner.temp }}/lease-silence-native/capture-status.txt";

/** Builds a mutation seam from the actual retained step and independently fixed predicate. */
function macConditionalPrefix(head, stage = null) {
	const name = /- name: ([^\n]+)/.exec(head)?.[1];
	const expected = macContract.jobs
		.filter((job) => stage === null || job.id === stage)
		.flatMap((job) => job.steps)
		.filter((step) => step.name === name);
	assert.equal(expected.length, 1, 'One authored Mac step condition.');
	const actual = pipeline
		.jobs(MACOS_BOX)
		.filter((job) => stage === null || job.id === stage)
		.flatMap((job) => pipeline.steps(job.body))
		.filter((step) => step.name === name);
	assert.equal(actual.length, 1, 'One actual Mac condition owner.');
	assert.equal(pipeline.stepField(actual[0].body, 'if'), expected[0].if);
	const marker = '        if: ' + expected[0].if + '\n';
	const offset = actual[0].body.indexOf(marker);
	assert.ok(offset >= 0);
	return actual[0].body.slice(0, offset) + marker;
}
/** Relocates fixed original managed step bytes, preserving their complete run bodies. */
function retainedManagedStep(original) {
	const originalIf = pipeline.stepField(original, 'if');
	const environment =
		"        env:\n          GOTOOLCHAIN: 'local'\n          ERGOPTI_RELEASE: \"${{ inputs.release && 'true' || 'false' }}\"\n          ERGOPTI_RELEASE_TAG: '${{ inputs.tag }}'\n          ERGOPTI_RELEASE_VERSION: '${{ inputs.version }}'\n          ERGOPTI_RELEASE_CHANNEL: '${{ inputs.channel }}'\n          ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE: '${{ env.MACOS_STAGE_ARCHITECTURE }}'\n";
	const marker = original.indexOf('\n') + 1;
	assert.ok(marker > 0 && originalIf !== null);
	return (original.slice(0, marker) + environment + original.slice(marker)).replace(
		'        if: ' + originalIf + '\n',
		'        if: ' + macRole.condition('managed-ollama-native', originalIf) + '\n'
	);
}
function macConditionEntry(row) {
	const [file, role, name, condition] = row;
	if (file !== '.github/workflows/ci-macos.yml' || condition?.includes('steps.stage-admission'))
		return row;
	return [file, macRole.stage[role], name, macRole.condition(role, condition)];
}
/** The fixed contract is reviewed independently; altered workflow bytes cannot refresh it. */
function macStageProblems(source) {
	try {
		const actual = YAML.parse(source, { uniqueKeys: true });
		const observed = Object.entries(actual.jobs).map(([id, job]) => ({
			id,
			metadata: Object.fromEntries(Object.entries(job).filter(([key]) => key !== 'steps')),
			steps: job.steps.map((step) =>
				Object.fromEntries(
					macContract.step_fields
						.filter((key) => Object.hasOwn(step, key))
						.map((key) => [key, step[key]])
				)
			)
		}));
		assert.deepEqual(
			observed,
			macContract.jobs,
			'Mac stage/role registration or predicate differs.'
		);
		const expectedLease = YAML.parse('job:\n' + LEASE_SILENCE_NATIVE_BODY).job.steps.map(
			(step) => ({
				...macRole.metadata(step, 'lease-silence-native'),
				if: macRole.condition('lease-silence-native', step.if)
			})
		);
		assert.deepEqual(
			YAML.parse(macRole.body(source, 'lease-silence-native')).steps,
			expectedLease,
			'Mac lease commands and evidence must remain exact.'
		);
		return [];
	} catch (error) {
		return ['Mac stage source refused: ' + error.message];
	}
}
function isRetainedQualification(entry, candidate, step) {
	// The contract names the real file; the inlined view shows it in its lane.
	const owner = scoped.contract.retained_steps.find(
		(owner) =>
			[owner.file, pipeline.laneOf(owner.file)].includes(entry.rel) &&
			owner.job === candidate.id &&
			owner.name === step.name
	);
	if (!owner) return false;
	assert.equal(
		step.body.replace(/\n+$/, ''),
		owner.body,
		'exact qualification receipt transport must remain'
	);
	return true;
}
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const manual = require('../ci/manual-ci-lanes.cjs');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ENTRY = pipeline.ENTRY_REL;
const COMMON_BOX = '.github/workflows/ci-common.yml';
const MACOS_BOX = '.github/workflows/ci-macos.yml';
const WINDOWS_BOX = '.github/workflows/ci-windows.yml';
const LINUX_BOX = '.github/workflows/ci-linux.yml';
// The Linux E2E stage file, where the raw harness steps sit before inlining.
const LINUX_E2E_BOX = '.github/workflows/ci-linux-e2e.yml';
const BOXES = [MACOS_BOX, WINDOWS_BOX, LINUX_BOX];
// Release verifies every lane against the persisted plan, then publishes.
const RELEASE_BOX = '.github/workflows/ci-release.yml';
// ci.yml's caller of RELEASE_BOX: it alone needs the lanes and grants write.
const PUBLICATION = 'publication';
// The run graph's single root: the repository-wide checks, then the release
// plan every lane and release read.
const ROOT = 'validate';
const RELEASE_INPUT = `\${{ needs.${ROOT}.outputs.release == 'true' }}`;
const RELEASE_IF =
	"github.event_name == 'push' && needs.publication-plan.outputs.release == 'true'";
const NOT_CANCELLED = '${{ !cancelled() }}';
// The native checks outside the Lua suite run once, in the meta row of the unit matrix.
const LINUX_UNIT_META_ROW = "matrix.group == 'meta'";
const MANUAL_RUNTIME_IF =
	"${{ github.event_name == 'workflow_dispatch' && !inputs.release && !cancelled() && " +
	LINUX_UNIT_META_ROW +
	' }}';
const MANUAL_RUNTIME_EVIDENCE_IF = MANUAL_RUNTIME_IF;
const MANUAL_VERDICT_IF = 'always() && !cancelled()';
const LANE_IF = (os) => `needs.${ROOT}.outputs.lane_${os} == 'true'`;
// Public by design: SUPublicEDKey ships inside every app, and a CI package
// without it cannot pass the launch gate.
const PUBLIC_SECRETS = new Set(['SPARKLE_PUBLIC_KEY']);
const PREFLIGHT = 'Refuse to publish an incomplete or already-taken release';
// A step that writes to GitHub: the tag, the release, its notes, or a push. A
// read such as `gh release view` is not one.
const SIDE_EFFECT = /\bgh api\b|\bgh release (?:create|edit|upload|delete)\b|\bgit\b[^\n]*\bpush\b/;

// Floors — today: 7 plan outputs, 3 callers, 6 release-only secrets (the
// Sparkle private key and the macOS code-signing .p12 and its password, then
// Windows' certificate, password and subject). Raised from 4 with the macOS
// certificate, so dropping either of its secrets from the caller fails here.
const MIN_PLAN_OUTPUTS = 7;
const MIN_GATED_SECRETS = 6;

// The root's checks after its setup, in order, with the one command each runs.
const VALIDATE_SETUP = 'Prepare plan validation';
const COMMON_FORMAT_CHECKS = [
	[
		'Check hotstring TOML files are sorted and formatted',
		'python tools/format_toml.py --hotstrings --all --check'
	]
];
// Then the plan: the clone is deepened only after every check, because
// several test:js gates shell out to git and were written against the default
// depth-1 clone. --unshallow gives the plan the full history of every shallow
// commit, HEAD included, and --tags every tag; the plan steps follow it. The
// fetch is tried three times, as actions/checkout tried the fetch-depth: 0
// fetch the plan used to get from it, since one network error here stops
// every lane; --unshallow is passed only while the clone is still shallow,
// because an attempt can fail after completing it and --unshallow refuses a
// complete clone. A third failure, or a clone still shallow, fails the step.
const DEEPEN_STEP = 'Deepen history for the release plan';
const DEEPEN_SCRIPT = [
	'set -euo pipefail',
	'for attempt in 1 2 3; do',
	'    unshallow=()',
	'    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then',
	'        unshallow=(--unshallow)',
	'    fi',
	'    if git fetch --prune "${unshallow[@]}" --tags origin; then',
	'        break',
	'    fi',
	'    if [ "$attempt" = 3 ]; then',
	'        echo "::error::git fetch failed 3 times: the release plan needs the full history and every tag."',
	'        exit 1',
	'    fi',
	'    echo "::warning::git fetch failed (attempt $attempt of 3), retrying in 15 s."',
	'    sleep 15',
	'done',
	'if [ "$(git rev-parse --is-shallow-repository)" != false ]; then',
	'    echo "::error::the clone is still shallow after the fetch: the release plan would number a tag from a partial history."',
	'    exit 1',
	'fi'
];
// The deepening step exactly as ci.yml writes it, for the self-check fixtures.
const DEEPEN_TEXT =
	`      - name: ${DEEPEN_STEP}\n        shell: bash\n        run: |\n` +
	DEEPEN_SCRIPT.map((line) => `          ${line}\n`).join('');
// Any other way to deepen the clone: a step before the deepening one that runs
// it would hand the checks a clone deeper than the one they were written for.
const HISTORY_FETCH =
	/\bgit\b.*\b(?:fetch|pull|clone)\b|--(?:unshallow|deepen|depth|shallow-since|shallow-exclude)\b/;
const PLAN_STEPS = ['Load the Linux release artifact contract', 'Compute tag and version'];

// The only steps of the pipeline that may set an `if`, each with its only
// accepted value. Every other step runs whenever its job runs, so no edit can
// skip a gate while its job stays green.
const MACOS_NATIVE_STEP_CONDITIONS = [
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Observe independent native Apple Shortcuts SDK preflight and discovery',
		"${{ !cancelled() && github.event_name == 'workflow_dispatch' && !inputs.release && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain independent native Apple Shortcuts SDK observation',
		"${{ always() && github.event_name == 'workflow_dispatch' && !inputs.release && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Observe installed Shortcuts Events metadata without launch',
		"${{ github.event_name == 'workflow_dispatch' && !inputs.release && !cancelled() && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain installed Shortcuts Events metadata diagnostic',
		"${{ always() && github.event_name == 'workflow_dispatch' && !inputs.release && matrix.scenario != 'xctest' }}"
	],
	// The clean source build runs in its own parallel cell and hands its sealed
	// bytes to the receiving cell, which admits them under the original build id.
	[MACOS_BOX, 'managed-ollama-build', 'Prepare genuine pinned Go toolchain', NOT_CANCELLED],
	[
		MACOS_BOX,
		'managed-ollama-build',
		'Acquire and verify genuine pinned upstream inputs',
		NOT_CANCELLED
	],
	[
		MACOS_BOX,
		'managed-ollama-build',
		'Build and admit the actual native source asset',
		NOT_CANCELLED
	],
	[
		MACOS_BOX,
		'managed-ollama-build',
		'Seal the clean native source build for its receiving cell',
		"${{ !cancelled() && steps.ollama-native-producer.outcome == 'success' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-build',
		'Hand the clean native source build to its receiving cell',
		"${{ !cancelled() && steps.ollama-native-seal.outcome == 'success' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Receive and admit the clean native source asset from its build cell',
		"${{ !cancelled() && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Receive actual native model create, pull, inference and retirement',
		"${{ !cancelled() && steps.ollama-native-build.outcome == 'success' && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Qualify actual selected number-row Carbon XCTest controls',
		"${{ !cancelled() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain selected number-row Carbon XCTest diagnostics',
		"${{ always() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Qualify native input-source and launcher XCTest controls',
		"${{ !cancelled() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain native input-source and launcher XCTest diagnostics',
		"${{ always() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain selected-release native ownership receiving',
		"${{ always() && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Qualify actual native PAC source ownership XCTest controls',
		"${{ !cancelled() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Qualify actual native PAC and WPAD XCTest controls',
		"${{ !cancelled() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain independent native PAC XCTest diagnostics',
		"${{ always() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'item36-native',
		'Observe the actual no-prompt SDK permission API independently',
		NOT_CANCELLED
	],
	[MACOS_BOX, 'item36-native', 'Retain scoped item 36 native diagnostics', 'always()'],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Qualify actual explicit curl stream ownership',
		"${{ !cancelled() && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Receive actual independent managed HTTP native clients',
		"${{ !cancelled() && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain independent native HTTP clock receiving',
		"${{ always() && steps.native_http_clock.outputs.clock_expected == 'true' && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Upload the actual managed native release asset',
		"${{ inputs.release && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Upload the catalogue sealed into the signed application',
		'inputs.release'
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain independent native launcher compiler diagnostics',
		"${{ always() && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain independent native SDK XCTest diagnostics',
		"${{ always() && matrix.scenario != 'runtime' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain actual private-session and numeric TLS peer diagnostics',
		"${{ always() && matrix.scenario != 'xctest' }}"
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain actual native producer, catalogue and receiving evidence',
		'always()'
	],
	[
		MACOS_BOX,
		'managed-ollama-native',
		'Retain passive security service logs after native receiving failure',
		"${{ !cancelled() && failure() && (steps.managed-ollama-pac-receiving.outcome == 'failure' || steps.native_http_clock.outcome == 'failure' || steps.managed-ollama-model-receiving.outcome == 'failure') }}"
	],
	[MACOS_BOX, 'package-macos', 'Retain launcher build diagnostics', 'always()'],
	[MACOS_BOX, 'package-macos', 'Retain application build diagnostics', 'always()'],
	[
		MACOS_BOX,
		'package-macos',
		'Retain source-bound package native qualification receipt',
		'always()'
	],
	[
		MACOS_BOX,
		'cold-bootstrap-native',
		'Receive actual official cold Ollama without stock Python',
		"${{ !cancelled() && steps.cold-app.outcome == 'success' }}"
	],
	[MACOS_BOX, 'cold-bootstrap-native', 'Retain official cold Ollama receipt only', 'always()'],
	[MACOS_BOX, 'cold-bootstrap-native', 'Retain native cold bootstrap evidence', 'always()']
].map(macConditionEntry);
const WINDOWS_FILE_RETENTION = [
	{
		name: 'Retain managed Ollama file component evidence',
		condition: 'always()',
		artifact:
			'windows-ollama-file-component-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.module }}',
		paths: ['${{ runner.temp }}/windows-ollama-file-component/']
	},
	{
		name: 'Retain exact managed Ollama file roots',
		condition:
			"${{ always() && env.ERGOPTI_FILE_COMPONENT_TEST_ROOT != '' && env.ERGOPTI_FILE_COMPONENT_SOURCE_ROOT != '' }}",
		artifact:
			'windows-ollama-file-roots-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.module }}',
		paths: [
			'${{ env.ERGOPTI_FILE_COMPONENT_TEST_ROOT }}/',
			'${{ env.ERGOPTI_FILE_COMPONENT_SOURCE_ROOT }}/'
		]
	}
];

const STEP_CONDITIONS = [
	[LINUX_BOX, 'test-linux', 'Retain Linux Lua timing diagnostics', '${{ !cancelled() }}'],
	[MACOS_BOX, 'test-hs', 'Retain macOS Lua timing diagnostics', '${{ !cancelled() }}'],
	[
		COMMON_BOX,
		'shared-validation',
		'Retain captured JS failure output',
		"always() && steps.common-lot.outputs.suite == 'js'"
	],
	[MACOS_BOX, 'lease-silence-native', 'Retain exact paired-process native receiving', 'always()'],
	...WINDOWS_FILE_RETENTION.map((owner) => [WINDOWS_BOX, 'test-ahk', owner.name, owner.condition]),
	...MACOS_NATIVE_STEP_CONDITIONS,
	...scoped.contract.retained_steps.map((owner) => [
		pipeline.laneOf(owner.file),
		owner.job,
		owner.name,
		owner.condition
	]),
	[
		WINDOWS_BOX,
		'test-ahk',
		'Retain native PAC artifact and source identity',
		"${{ always() && (steps.native-pac-build.outcome == 'success' || steps.native-pac-cache.outputs.cache-hit == 'true') }}"
	],
	// The unit runners alone reuse a PAC evaluator built from identical inputs.
	[
		WINDOWS_BOX,
		'test-ahk',
		'Build and test native full-URL PAC evaluator',
		"steps.native-pac-cache.outputs.cache-hit != 'true'"
	],
	[
		WINDOWS_BOX,
		'test-ahk',
		'Save the native PAC evaluator for identical unit runs',
		"steps.native-pac-cache.outputs.cache-hit != 'true'"
	],
	[
		LINUX_BOX,
		'test-linux',
		'Emit Configuration assertion from failed unit log',
		"${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}"
	],
	[
		LINUX_BOX,
		'test-linux',
		'Upload failed unit log',
		"${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}"
	],
	[LINUX_BOX, 'e2e-linux', 'Qualify three actual XI2 property cookies', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Retain actual XI2 property-cookie evidence', 'always()'],
	[
		LINUX_BOX,
		'test-linux',
		'Qualify actual LuaJIT XI2 ABI and property cookies',
		'${{ !cancelled() && ' + LINUX_UNIT_META_ROW + ' }}'
	],
	[
		LINUX_BOX,
		'test-linux',
		'Retain actual LuaJIT XI2 diagnostic evidence',
		'${{ always() && ' + LINUX_UNIT_META_ROW + ' }}'
	],
	[LINUX_BOX, 'e2e-linux', 'Qualify genuine Nix installed runtime', NOT_CANCELLED],
	[LINUX_BOX, 'test-linux', 'Verify native metrics aggregation equivalence', LINUX_UNIT_META_ROW],
	[
		LINUX_BOX,
		'test-linux',
		'Verify native cross-driver histogram multiplicity',
		LINUX_UNIT_META_ROW
	],
	[LINUX_BOX, 'test-linux', 'Run manual official runtime and model acceptance', MANUAL_RUNTIME_IF],
	[
		LINUX_BOX,
		'test-linux',
		'Upload manual runtime acceptance evidence',
		MANUAL_RUNTIME_EVIDENCE_IF
	],
	[LINUX_BOX, 'e2e-linux', 'Qualify native runtime prerequisites', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify native retained FD SHA-256', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Prepare authenticated managed HTTP validation tools', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify native managed HTTP public and retained output', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify native updater archive pipeline', NOT_CANCELLED],
	[LINUX_BOX, 'e2e-linux', 'Qualify archive crypto and bin parent source controls', NOT_CANCELLED],
	[
		COMMON_BOX,
		'shared-validation',
		'Check hotstring TOML files are sorted and formatted',
		"${{ !cancelled() && steps.common-lot.outputs.suite == 'hotstrings-format' }}"
	],
	[RELEASE_BOX, 'release', 'Create git tag', "steps.preflight.outputs.create_tag == 'true'"],
	[
		RELEASE_BOX,
		'release',
		'Create draft release, verify assets and publish',
		"steps.preflight.outputs.create_release == 'true'"
	],
	[
		RELEASE_BOX,
		'release',
		'Publish channel feed for Sparkle',
		"steps.preflight.outputs.skip_feed != 'true'"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
		'inputs.release'
	],
	[
		MACOS_BOX,
		'package-macos',
		'Retain packaged application startup evidence',
		'always() && inputs.release'
	],
	[
		MACOS_BOX,
		'package-macos',
		'Retain scoped native Brew qualification receipt',
		'${{ always() }}'
	],
	[
		MACOS_BOX,
		'package-macos',
		'Retain archive diagnostic session',
		"${{ always() && steps.swift-launcher-tests.outputs.archive_session_dir != '' }}"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Retain closed TIS diagnostic session',
		"${{ always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '' }}"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Upload Swift launcher failure transcript',
		"${{ failure() && steps.swift-launcher-tests.outcome == 'failure' }}"
	],
	[
		MACOS_BOX,
		'package-macos',
		'Run signed Hammerspoon program provider inventory',
		'${{ always() }}'
	],
	[MACOS_BOX, 'package-macos', 'Retain native Hammerspoon provider inventory', '${{ always() }}'],
	[MACOS_BOX, 'package-macos', 'Observe native notification constructors', '${{ always() }}'],
	[
		MACOS_BOX,
		'package-macos',
		'Retain native notification constructor observations',
		'${{ always() }}'
	],
	[MACOS_BOX, 'package-macos', 'Observe native Apple Shortcuts discovery', '${{ always() }}'],
	[MACOS_BOX, 'package-macos', 'Observe native global application switcher', '${{ always() }}'],
	[
		MACOS_BOX,
		'package-macos',
		'Retain native global application switcher observations',
		'${{ always() }}'
	],
	[MACOS_BOX, 'package-macos', 'Retain native Apple Shortcuts observation', '${{ always() }}'],
	[MACOS_BOX, 'package-macos', 'Sign declared archives with Sparkle EdDSA key', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Generate Sparkle appcast', 'inputs.release'],
	[MACOS_BOX, 'package-macos', 'Package latest keylayout bundle', 'inputs.release'],
	[MACOS_BOX, 'launch', 'Retain launch evidence', 'always()'],
	[
		MACOS_BOX,
		'launch',
		'Retain source-bound AppleEvent launch qualification receipt',
		"${{ contains(format('__{0}__', env.MACOS_STAGE_SCENARIO), '__clean__') || contains(format('__{0}__', env.MACOS_STAGE_SCENARIO), '__karabiner_config__') }}"
	],
	[
		MACOS_BOX,
		'tooltip-canvas',
		'Retain native captures, source, provisioning and retirement receipts',
		'always()'
	],
	[
		WINDOWS_BOX,
		'test-ahk',
		'Download AutoHotkey v2 runtime',
		"steps.cache-ahk.outputs.cache-hit != 'true'"
	],
	[WINDOWS_BOX, 'e2e-ahk', 'Download E2E runtime', "steps.cache-ahk.outputs.cache-hit != 'true'"],
	[WINDOWS_BOX, 'package-windows', 'Sign and verify ErgoptiPlus.exe', 'inputs.release'],
	[WINDOWS_BOX, 'test-ahk', 'Annotate AHK results', 'always()'],
	[WINDOWS_BOX, 'test-ahk', 'Publish AHK execution manifest', 'always()'],
	[WINDOWS_BOX, 'e2e-ahk', 'Retain E2E native streams', 'always()'],
	[WINDOWS_BOX, 'test-ahk', 'Publish native desktop AHK evidence', 'always()'],
	// The whole-driver boot gates do not depend on the module group: one runner.
	[
		WINDOWS_BOX,
		'test-ahk',
		'Run the full-driver startup smoke',
		"matrix.module == 'hotstrings-shortcuts'"
	],
	[
		WINDOWS_BOX,
		'test-ahk',
		'Test fresh Git clone bootstrap and warm startup',
		"matrix.module == 'hotstrings-shortcuts'"
	],
	[
		WINDOWS_BOX,
		'launch-windows',
		'Qualify programmable hotstrings in the actual compiled package',
		NOT_CANCELLED
	],
	[
		WINDOWS_BOX,
		'launch-windows',
		'Upload mandatory compiled programmable package evidence',
		'always()'
	],
	[WINDOWS_BOX, 'launch-windows', 'Upload mandatory launch evidence', 'always()'],
	// Failed upgrade setup/launch must retain its negative receipt before the verdict.
	[WINDOWS_BOX, 'launch-windows', 'Upload mandatory compiled upgrade failure evidence', 'always()'],
	[LINUX_BOX, 'install-linux', 'Prepare the container', "env.INSTALL_KIND == 'install'"],
	[
		LINUX_BOX,
		'install-linux',
		'Verify source compiler and checkout',
		"env.INSTALL_KIND == 'install'"
	],
	[LINUX_BOX, 'install-linux', 'Create the installation user', "env.INSTALL_KIND == 'install'"],
	[
		LINUX_BOX,
		'install-linux',
		'Install as an ordinary user without runtime dependencies',
		"env.INSTALL_KIND == 'install'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'The installed tree is the one the daemon expects',
		"env.INSTALL_KIND == 'install'"
	],
	[
		LINUX_BOX,
		'install-linux',
		"The unit suite on this distribution's LuaJIT",
		"env.INSTALL_KIND == 'install'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload the native distro unit log',
		"${{ !cancelled() && env.INSTALL_KIND == 'install' }}"
	],
	[LINUX_BOX, 'install-linux', 'Record mandatory distro evidence', "env.INSTALL_KIND == 'install'"],
	[LINUX_BOX, 'install-linux', 'Upload mandatory distro evidence', "env.INSTALL_KIND == 'install'"],
	[
		LINUX_BOX,
		'install-linux',
		'Install on ${{ env.INSTALL_IMAGE }} and verify the first run',
		"env.INSTALL_KIND == 'first'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Record mandatory first-install evidence',
		"env.INSTALL_KIND == 'first'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload mandatory first-install evidence',
		"env.INSTALL_KIND == 'first'"
	],
	[LINUX_BOX, 'install-linux', 'Download the .deb built above (deb)', "env.INSTALL_KIND == 'deb'"],
	[
		LINUX_BOX,
		'install-linux',
		'Install it the way a user would (deb)',
		"env.INSTALL_KIND == 'deb'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'The package installed the files the daemon reads (deb)',
		"env.INSTALL_KIND == 'deb'"
	],
	[LINUX_BOX, 'install-linux', 'Launch the installed binary (deb)', "env.INSTALL_KIND == 'deb'"],
	[
		LINUX_BOX,
		'install-linux',
		'The installed shared data tree resolves and opens (deb)',
		"env.INSTALL_KIND == 'deb'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Record mandatory .deb smoke evidence (deb)',
		"env.INSTALL_KIND == 'deb'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload mandatory .deb smoke evidence (deb)',
		"env.INSTALL_KIND == 'deb'"
	],
	[LINUX_BOX, 'install-linux', 'Tools the job itself needs (rpm)', "env.INSTALL_KIND == 'rpm'"],
	[LINUX_BOX, 'install-linux', 'Download the .rpm built above (rpm)', "env.INSTALL_KIND == 'rpm'"],
	[
		LINUX_BOX,
		'install-linux',
		'Install it the way a user would (rpm)',
		"env.INSTALL_KIND == 'rpm'"
	],
	[LINUX_BOX, 'install-linux', 'Launch the installed binary (rpm)', "env.INSTALL_KIND == 'rpm'"],
	[
		LINUX_BOX,
		'install-linux',
		'The installed shared data tree resolves and opens (rpm)',
		"env.INSTALL_KIND == 'rpm'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Record mandatory .rpm smoke evidence (rpm)',
		"env.INSTALL_KIND == 'rpm'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload mandatory .rpm smoke evidence (rpm)',
		"env.INSTALL_KIND == 'rpm'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Download the AppImage built above',
		"env.INSTALL_KIND == 'appimage'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Unpack it (no FUSE on this runner)',
		"env.INSTALL_KIND == 'appimage'"
	],
	[LINUX_BOX, 'install-linux', 'Launch it', "env.INSTALL_KIND == 'appimage'"],
	[
		LINUX_BOX,
		'install-linux',
		'Every bundled ELF file loads on the oldest supported LTS',
		"env.INSTALL_KIND == 'appimage'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'It shows its tray icon on Ubuntu 22.04, offline',
		"env.INSTALL_KIND == 'appimage'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'The bundled shared data tree resolves and opens',
		"env.INSTALL_KIND == 'appimage'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Record mandatory AppImage smoke evidence',
		"env.INSTALL_KIND == 'appimage'"
	],
	[
		LINUX_BOX,
		'install-linux',
		'Upload mandatory AppImage smoke evidence',
		"env.INSTALL_KIND == 'appimage'"
	]
].map(macConditionEntry);
// e2e-linux runs each harness under !cancelled(), so a red one hides no other;
// tools/test/test-linux-ci-evidence.cjs pins which of its steps those are. The
// job is a domain matrix: each harness condition also names its own row, as
// tools/test/fixtures/linux-e2e-shards.json assigns it.
const HARNESS_JOB = 'e2e-linux';
/** A Linux E2E condition narrowed to the step's own matrix row. */
const linuxRow = (name, condition) =>
	LinuxE2E.has(name) ? LinuxE2E.condition(name, condition) : condition;

// A command whose exit status is a gate: a test runner, a verdict script, a
// package build, an install or a launch. `|| true` after one turns its failure
// green; `|| {` with an explicit failing exit is still allowed.
const GATE_COMMAND = new RegExp(
	[
		/\btests\/(?:run\.lua|e2e\/run_e2e\.lua|hardware\/|distro\/)/,
		/\brun_all\.ahk\b|\brun_e2e\.ahk\b|\brun_llm_[a-z_]+\.ahk\b/,
		/\bswift (?:test|build)\b|\bplutil -lint\b/,
		/_test\.py\b|\bmacos_launch_gate\.py\b|\bmacos-release-launch\.py\b|\bmacos_tooltip_canvas\.py\b/,
		/\blinux-ci-evidence\.cjs (?:verify|record)\b|\bvalidate-ahk-suite-manifest\.cjs\b/,
		/\btools\/test\/test-[\w-]+\.(?:py|cjs)\b/,
		/\bprepare-linux-distro-unit\.sh\b/,
		/\bnpm run (?:test|build)\b/,
		/\bformat_toml\.py\b/,
		/\binstall\.sh\b|\binstalled_layout_check\.lua\b/,
		/\btools\/build\/build[\w-]*\.(?:sh|ps1)\b/,
		/\s--help\b/
	]
		.map((pattern) => pattern.source)
		.join('|')
);
const SWALLOWED = /\|\|\s*(?:true\b|:(?=\s|$)|exit\s+0\b|echo\b)/;

// The release steps, in the only order that publishes a complete release: the
// tag before the release, the release before its feed, the changelog before
// the notes that embed it.
const RELEASE_ORDER = [
	'Download all build artifacts',
	PREFLIGHT,
	'Create git tag',
	'Create draft release, verify assets and publish',
	'Publish channel feed for Sparkle',
	'Build changelog section',
	'Write release body with platform sections'
];

// Seven days on a release run, so a next-day "Re-run failed jobs" still finds
// the gated files; package-windows runs on release runs only.
const ASSET_RETENTION = new Map([
	['assets-macos', '${{ inputs.release && 7 || 1 }}'],
	['assets-windows', '7'],
	['assets-linux', '${{ inputs.release && 7 || 1 }}']
]);

const errors = [];

/** Drops full-line comments, which may name a forbidden form to explain it. */
function codeOf(body) {
	return body
		.split('\n')
		.filter((line) => !line.trimStart().startsWith('#'))
		.join('\n');
}

/**
 * Reads the one-line entries of a job-level block mapping such as `with:`,
 * `secrets:` or `outputs:`; null when the job has no such block.
 * @param {string} body Job body.
 * @param {string} key Job-level key.
 * @param {string} where Job id, for the messages.
 * @returns {Map<string, string>|null}
 */
function mappingOf(body, key, where) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => new RegExp(`^ {4}${key}:\\s*$`).test(line));
	if (at < 0) return null;
	const entries = new Map();
	for (let index = at + 1; index < lines.length; index++) {
		const line = lines[index];
		if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
		if (line.length - line.trimStart().length <= 4) break;
		const entry = /^ {6}([A-Za-z0-9_-]+):\s*(\S.*?)\s*$/.exec(line);
		if (!entry) {
			errors.push(
				`${where}: unreadable ${key} entry '${line.trim()}'; write one \`key: value\` per line`
			);
			continue;
		}
		if (entries.has(entry[1])) errors.push(`${where}: ${key}.${entry[1]} is set twice`);
		entries.set(entry[1], entry[2]);
	}
	return entries;
}

/** Runs `read`, recording a loader error instead of stopping every other check. */
function attempt(read) {
	try {
		return read();
	} catch (error) {
		errors.push(error.message);
		return null;
	}
}

/**
 * Returns a step's script as logical lines: comments dropped, and a line ending
 * in a bash `\` or a PowerShell backtick joined with the next.
 * @param {string} body Step body.
 * @returns {string[]}
 */
function logicalLines(body) {
	const joined = [];
	let pending = '';
	for (const line of pipeline.runOf(body) ?? []) {
		const text = line.trim();
		if (text.startsWith('#')) continue;
		if (/(?:\\|`)$/.test(text)) {
			pending += `${text.slice(0, -1)} `;
			continue;
		}
		joined.push(pending + text);
		pending = '';
	}
	if (pending !== '') joined.push(pending.trim());
	return joined;
}

/**
 * Proves a rule can fail: once `from` is replaced by `to` in the pipeline file
 * `rel`, `problemsOf` must report something for the mutated pipeline.
 * @param {string} what The review form this reproduces.
 * @param {string} rel Pipeline file to mutate.
 * @param {string} from Exact text, present once in the file.
 * @param {string} to Replacement.
 * @param {(files: Array<{rel: string, text: string}>) => string[]} problemsOf The rule.
 */
function mustCatch(what, rel, from, to, problemsOf) {
	const text = pipeline.file(rel);
	const count = text.split(from).length - 1;
	if (count !== 1) {
		errors.push(
			`self-check "${what}": expected one '${from.trim()}' in ${rel}, found ${count}; re-derive the fixture`
		);
		return;
	}
	const mutated = pipeline
		.files()
		.map((entry) => (entry.rel === rel ? { rel, text: text.replace(from, () => to) } : entry));
	let problems;
	try {
		problems = problemsOf(mutated);
	} catch (error) {
		problems = [error.message];
	}
	if (problems.length === 0)
		errors.push(`self-check "${what}" went unnoticed, so this rule cannot fail`);
}

// ========================================
// ========================================
// ======= 1/ The Root And Its Plan =======
// ========================================
// ========================================

const plan = pipeline.job(ROOT);
const planSteps = pipeline.steps(plan);
const planOutputs = mappingOf(plan, 'outputs', ROOT) ?? new Map();
if (planOutputs.size < MIN_PLAN_OUTPUTS) {
	errors.push(
		`${ROOT} declares ${planOutputs.size} plan output(s) (floor ${MIN_PLAN_OUTPUTS}); the outputs block moved`
	);
}
for (const [key, value] of planOutputs) {
	const source = new RegExp(`^\\$\\{\\{ steps\\.([A-Za-z0-9_-]+)\\.outputs\\.${key} \\}\\}$`).exec(
		value
	);
	if (!source) {
		errors.push(
			`${ROOT} output ${key} must forward \${{ steps.<id>.outputs.${key} }}, got: ${value}`
		);
		continue;
	}
	const owner = planSteps.find(
		(candidate) => pipeline.stepField(candidate.body, 'id') === source[1]
	);
	if (!owner) {
		errors.push(`${ROOT} output ${key} reads step '${source[1]}', which ${ROOT} does not have`);
	} else if (
		!(source[1] === 'lanes' && ['lane_windows', 'lane_macos', 'lane_linux'].includes(key)) &&
		!(
			source[1] === 'qualification' &&
			key === 'native_qualification_profile' &&
			pipeline.stepField(owner.body, 'run') ===
				'node tools/ci/dev-release-qualification.cjs --publication-select >> "$GITHUB_OUTPUT"'
		) &&
		!new RegExp(`\\bemit ${key} |"${key}=`).test(codeOf(owner.body))
	) {
		errors.push(`${ROOT} output ${key} reads step '${source[1]}', which never writes ${key}`);
	}
}
const COMMON_MATRIX = '${{ fromJSON(inputs.common_plan).matrix }}';

/** Admit the one root plan transport and its complete cross-workflow consumer. */
function commonPlanProblems(files) {
	const problems = [];
	try {
		const root = YAML.parse(files.find((file) => file.rel === ENTRY).text, { uniqueKeys: true });
		const common = YAML.parse(files.find((file) => file.rel === COMMON_BOX).text, {
			uniqueKeys: true
		});
		const prepare = root.jobs['prepare-common'];
		assert.deepEqual(
			prepare,
			{
				name: 'Check formatting and plan unit tests',
				'runs-on': 'ubuntu-latest',
				outputs: { plan: '${{ steps.plan.outputs.plan }}' },
				steps: [
					{ uses: 'actions/checkout@v4' },
					{
						uses: 'actions/setup-node@v4',
						with: { 'node-version-file': '.node-version', cache: 'npm' }
					},
					{ uses: 'actions/setup-python@v5', with: { 'python-version': '3.12' } },
					{ run: 'npm ci' },
					{
						name: 'Check formatting',
						run: 'python3 -m pip install --disable-pip-version-check "ruff==$(node tools/lint/format.cjs --ruff-version)"\nnode tools/lint/format.cjs --check\n'
					},
					{
						name: 'Plan every canonical feature and additional suite',
						id: 'plan',
						run: 'set -euo pipefail\nnode tools/ci/js-feature-matrix.cjs plan\n'
					}
				]
			},
			'One genuine shallow formatter and plan producer'
		);
		for (const id of ['core', 'macos', 'windows', 'linux'])
			assert.deepEqual(
				root.jobs[id].needs,
				['validate', 'prepare-common'],
				'Every lane awaits formatting and release plan'
			);
		assert.equal(root.jobs.core.with.common_plan, '${{ needs.prepare-common.outputs.plan }}');
		assert.deepEqual(root.jobs.core.permissions, { contents: 'read', actions: 'read' });
		assert.deepEqual(common.on.workflow_call.inputs.common_plan, {
			description: 'Complete source/ref-bound plan from the shallow formatter checkout',
			required: true,
			type: 'string'
		});
		const unit = common.jobs['shared-validation'];
		assert.equal(unit.needs, undefined);
		assert.deepEqual(unit.strategy, {
			'fail-fast': false,
			matrix: '${{ fromJSON(inputs.common_plan).matrix }}'
		});
		assert.equal(unit.env.COMMON_LOT, '${{ matrix.lot }}');
		assert.equal(unit.env.COMMON_PLAN, '${{ inputs.common_plan }}');
		assert.equal(common.jobs['common-e2e'].env.COMMON_PLAN, '${{ inputs.common_plan }}');
		assert.deepEqual(
			unit.steps.filter((step) => step.id === 'common-lot'),
			[
				{
					name: 'Admit the complete Common lot map',
					id: 'common-lot',
					run: 'node tools/ci/js-feature-matrix.cjs select'
				}
			]
		);
		assert.ok(
			unit.steps.findIndex((step) => step.id === 'common-lot') <
				unit.steps.findIndex((step) => step.name === 'Install native validation tools')
		);
		const expectedReads = [
			[ENTRY, '      common_plan: ${{ needs.prepare-common.outputs.plan }}'],
			[COMMON_BOX, '      matrix: ${{ fromJSON(inputs.common_plan).matrix }}'],
			[COMMON_BOX, '      COMMON_PLAN: ${{ inputs.common_plan }}'],
			[COMMON_BOX, '      COMMON_PLAN: ${{ inputs.common_plan }}']
		];
		const reads = files.flatMap((file) =>
			file.text
				.split('\n')
				.filter((line) => /needs\.prepare-common\.outputs|inputs\.common_plan/.test(line))
				.map((line) => [file.rel, line])
		);
		assert.deepEqual(reads, expectedReads, 'No extra or foreign root plan readers');
	} catch (error) {
		problems.push('Common root plan transport: ' + error.message);
	}
	return problems;
}

const LUA_TIMING_RETENTION = [
	{
		file: LINUX_BOX,
		job: 'test-linux',
		producer: 'Run the driver unit test suite',
		after: 'Upload manual runtime acceptance evidence',
		directory: 'static/ergopti_plus/linux',
		step: 'Retain Linux Lua timing diagnostics',
		artifact:
			'lua-timings-linux-unit-${{ matrix.group }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}',
		path: '${{ runner.temp }}/linux-lua.json',
		command:
			'node ../../../tools/test/report.cjs --name linux-lua --json "${{ runner.temp }}/linux-lua.json" -- luajit tests/run.lua --module="$LINUX_UNIT_GROUP" 2>&1 | tee "$RUNNER_TEMP/linux-unit.log"'
	},
	{
		file: MACOS_BOX,
		job: 'test-hs',
		producer: 'Run unit + meta tests',
		after: 'Run unit + meta tests',
		directory: 'static/ergopti_plus/macos',
		step: 'Retain macOS Lua timing diagnostics',
		artifact:
			'lua-timings-macos-unit-${{ fromJSON(steps.stage-selection.outputs.cell).role }}-${{ fromJSON(steps.stage-selection.outputs.cell).scenario }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}',
		path: '${{ runner.temp }}/macos-lua.json',
		command:
			'node ../../../tools/test/report.cjs --name macos-lua --json "${{ runner.temp }}/macos-lua.json" -- lua5.4 tests/run.lua --module="$MACOS_UNIT_GROUP"'
	}
];

/** Admits only each matrix include and its exact authored stage-plan producer. */
/** Bind every human-lot output read to its exact adjacent producer and closed field. */
function lotTransport(source, rel) {
	const ranges = [];
	const problems = [];
	try {
		const document = YAML.parse(source, { uniqueKeys: true });
		const jobs = pipeline.jobsOfText(source, rel);
		const routes =
			rel === MACOS_BOX
				? [
						[
							'test-hs',
							'e2e-hs',
							'stage-plan',
							'e2e_matrix',
							'e2e_metadata',
							'Resolve exact E2E stage roles',
							'node tools/ci/macos-stage-roles.cjs plan e2e'
						],
						[
							'package-macos',
							'launch',
							'stage-plan',
							'testbuild_matrix',
							'testbuild_metadata',
							'Resolve exact test-build stage roles',
							'node tools/ci/macos-stage-roles.cjs plan testbuild'
						]
					]
				: rel === COMMON_BOX
					? [
							[
								'common-e2e',
								'common-build',
								'site-plan',
								'site_matrix',
								'site_metadata',
								'Plan both production site targets',
								'node tools/ci/site-matrix.cjs plan'
							],
							[
								'common-build',
								'common-testbuild',
								'site-plan',
								'site_matrix',
								'site_metadata',
								'Admit the complete production site map',
								'node tools/ci/site-matrix.cjs admit'
							]
						]
					: rel === LINUX_BOX
						? [
								[
									'package-linux',
									'install-linux',
									'install-plan',
									'install_matrix',
									'install_metadata',
									'Plan every authored installation lot',
									'node tools/ci/linux-install-matrix.cjs'
								]
							]
						: [];
		if (rel === MACOS_BOX) assert.deepEqual(macStageProblems(source), []);
		for (const [producer, consumer, id, matrix, metadata, name, run] of routes) {
			const preceding = document.jobs[producer],
				receiving = document.jobs[consumer];
			// The Mac test build also admits E2E, which runs beside Build.
			const predecessors =
				rel === MACOS_BOX && consumer === 'launch' ? ['e2e-hs', producer] : [producer];
			assert.deepEqual(receiving.needs, predecessors, 'Exact immediate lot predecessor required');
			const outputs =
				id === 'site-plan' || id === 'install-plan' ? ['matrix', 'metadata'] : [matrix, metadata];
			for (const [index, key] of [matrix, metadata].entries())
				assert.equal(
					preceding.outputs[key],
					'${{ steps.' + id + '.outputs.' + outputs[index] + ' }}'
				);
			const expected = { name, id, run };
			if (rel === MACOS_BOX && producer === 'package-macos')
				expected.env = { MACOS_LAUNCH_SCENARIOS: '${{ steps.profile.outputs.scenarios }}' };
			assert.deepEqual(
				preceding.steps.filter((step) => step.id === id),
				[expected],
				'Mandatory exact lot producer required'
			);
			const expression = '${{ fromJSON(needs.' + producer + '.outputs.' + matrix + ') }}';
			assert.deepEqual(receiving.strategy, { 'fail-fast': false, matrix: expression });
			const selected = 'fromJSON(needs.' + producer + '.outputs.' + metadata + ')[matrix.lot]';
			const fields = [[6, 'matrix', expression]];
			if (rel === MACOS_BOX) {
				fields.push(
					[4, 'runs-on', '${{ ' + selected + '.runner }}'],
					[4, 'timeout-minutes', '${{ ' + selected + '.timeout_minutes }}']
				);
				const env = {
					MACOS_STAGE_LOT: '${{ matrix.lot }}',
					MACOS_STAGE_METADATA: '${{ needs.' + producer + '.outputs.' + metadata + ' }}',
					MACOS_STAGE_CELL: '${{ toJSON(' + selected + ') }}',
					...Object.fromEntries(
						['role', 'runner', 'architecture', 'scenario'].map((field) => [
							'MACOS_STAGE_' + field.toUpperCase(),
							'${{ ' + selected + '.' + field + ' }}'
						])
					)
				};
				assert.deepEqual(receiving.env, env);
				for (const [key, value] of Object.entries(env))
					if (key !== 'MACOS_STAGE_LOT') fields.push([6, key, value]);
			} else if (rel === COMMON_BOX) {
				const env = {
					SITE_LOT: '${{ matrix.lot }}',
					SITE_METADATA: '${{ needs.' + producer + '.outputs.' + metadata + ' }}',
					ERGOPTI_SITE_TARGET: '${{ ' + selected + '.target }}',
					BASE_PATH: '${{ ' + selected + '.base_path }}',
					ERGOPTI_SITE_SOURCE_SHA: '${{ github.sha }}'
				};
				assert.deepEqual(receiving.env, env);
				for (const key of ['SITE_METADATA', 'ERGOPTI_SITE_TARGET', 'BASE_PATH'])
					fields.push([6, key, env[key]]);
				assert.deepEqual(
					receiving.steps.filter((step) => step.id === 'site-plan'),
					[
						{
							name: 'Admit the complete production site map',
							id: 'site-plan',
							run: 'node tools/ci/site-matrix.cjs admit'
						}
					]
				);
				assert.equal(
					receiving.steps[3].id,
					'site-plan',
					'Admit the whole map before any production action'
				);
			} else {
				const env = Object.fromEntries(
					['id', 'kind', 'distro', 'image', 'prep', 'known'].map((field) => [
						'INSTALL_' + field.toUpperCase(),
						'${{ ' + selected + '.' + field + ' }}'
					])
				);
				assert.deepEqual(receiving.env, env);
				assert.equal(receiving.container, '${{ ' + selected + '.container }}');
				fields.push(
					[4, 'container', receiving.container],
					...Object.entries(env).map(([key, value]) => [6, key, value])
				);
				assert.deepEqual(receiving.steps[0], {
					name: 'Require a declared installation lot',
					shell: 'sh',
					run: 'set -eu\ntest -n "$INSTALL_ID"\ncase "$INSTALL_KIND" in\n  install|first|deb|rpm|appimage) ;;\n  *) exit 1 ;;\nesac\n'
				});
				assert.equal(preceding.steps.at(-1).id, id, 'Plan only after mandatory packaging evidence');
			}
			const body = jobs.find((job) => job.id === consumer).body;
			for (const [indent, key, value] of fields) {
				const line = ' '.repeat(indent) + key + ': ' + value + '\n';
				assert.equal(body.split(line).length, 2, 'One exact metadata read field required');
				const start = source.indexOf(body) + body.indexOf(line) + indent + key.length + 2;
				ranges.push({ start, end: start + value.length });
			}
		}
	} catch (error) {
		problems.push(rel + ': human lot transport refused: ' + error.message);
		return { ranges: [], problems };
	}
	return { ranges, problems };
}

/** Keep release-plan outputs at validate and feature matrices at their exact consumers. */
function planReferenceProblems(files) {
	const problems = commonPlanProblems(files);
	for (const file of files) {
		const transport = lotTransport(file.text, file.rel);
		problems.push(...transport.problems);
		const macReferences = transport.ranges;
		const consumers =
			file.rel === COMMON_BOX
				? pipeline.jobsOfText(file.text, file.rel).filter((job) => job.id === 'shared-validation')
				: [];
		const consumer = consumers.length === 1 ? consumers[0] : null;
		const consumerStart = consumer
			? file.text.split('\n').slice(0, consumer.line).join('\n').length + 1
			: -1;
		const strategy =
			consumer && /^ {4}strategy:\n((?: {6}[^\n]*(?:\n|$)|\n)*)/m.exec(consumer.body);
		const matrixField = strategy && /^ {6}matrix: ([^\n]+)$/m.exec(strategy[0]);
		const matrixStart =
			matrixField && matrixField[1] === COMMON_MATRIX
				? consumerStart + strategy.index + matrixField.index + '      matrix: '.length
				: -1;
		for (const match of file.text.matchAll(/needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)/g)) {
			if (file.rel === LINUX_BOX && match[1] === 'e2e-linux' && match[2] === 'ci_unit_result') {
				const build = pipeline
					.jobsOfText(file.text, file.rel)
					.find((job) => job.id === 'package-linux');
				const condition = build && /^ {4}if: ([^\n]+)$/m.exec(build.body);
				const start = condition ? file.text.indexOf(build.body) + condition.index : -1;
				if (
					start >= 0 &&
					match.index >= start &&
					match.index + match[0].length <= start + condition[0].length
				)
					continue;
			}
			const owner = pipeline.jobsOfText(file.text, file.rel).find((job) => {
				const start = file.text.indexOf(job.body);
				return match.index >= start && match.index < start + job.body.length;
			});
			if (
				macReferences.some(
					({ start, end }) => match.index >= start && match.index + match[0].length <= end
				)
			)
				continue;
			if (
				file.rel === RELEASE_BOX &&
				owner?.id === 'release' &&
				match[1] === 'publication-plan' &&
				planOutputs.has(match[2])
			)
				continue;
			if (
				file.rel === ENTRY &&
				owner?.id === 'core' &&
				match[1] === 'prepare-common' &&
				match[2] === 'plan' &&
				commonPlanProblems(files).length === 0
			)
				continue;
			if (match[1] !== ROOT) {
				problems.push(
					`needs.${match[1]}.outputs.${match[2]} is read, but the plan lives in ${ROOT} alone`
				);
			} else if (!planOutputs.has(match[2])) {
				problems.push(
					`needs.${ROOT}.outputs.${match[2]} is read but ${ROOT} declares no such output`
				);
			}
		}
	}
	return problems;
}
errors.push(...planReferenceProblems(pipeline.files()));

// Each output remains private to its actual matrix include and canonical producer.
for (const [producer, consumer, stage, roleStep, role] of [
	[
		'test-hs',
		'e2e-hs',
		'e2e',
		'Run virtual-keyboard harness (stubbed hs.* — no real Hammerspoon)',
		'e2e-hs'
	],
	[
		'package-macos',
		'launch',
		'testbuild',
		'Install, launch and judge every scenario of the lot',
		'launch'
	]
]) {
	const key = stage + '_matrix';
	const reference = 'needs.' + producer + '.outputs.' + key;
	const include = '      matrix: ${{ fromJSON(' + reference + ') }}\n';
	const roleHead = '      - name: ' + roleStep + '\n';
	const rolePrefix = macConditionalPrefix(roleHead, consumer);
	assert.ok(rolePrefix.endsWith('        if: ' + macRole.condition(role) + '\n'));
	for (const [label, before, after] of [
		['foreign producer', include, include.replace('needs.' + producer, 'needs.foreign')],
		['unknown key', include, include.replace('.outputs.' + key, '.outputs.foreign')],
		['wrong consumer', '  ' + consumer + ':\n', '  foreign-consumer:\n'],
		[
			'changed producer command',
			'run: node tools/ci/macos-stage-roles.cjs plan ' + stage + '\n',
			'run: echo foreign-plan\n'
		],
		[
			'changed producer output',
			key + ': ${{ steps.stage-plan.outputs.' + key + ' }}',
			key + ': ${{ steps.foreign.outputs.' + key + ' }}'
		],
		[
			'foreign role',
			rolePrefix,
			rolePrefix.replace(
				"env.MACOS_STAGE_ROLE == '" + role + "'",
				"env.MACOS_STAGE_ROLE == 'foreign'"
			)
		],
		[
			'extra reader inside the legitimate consumer',
			roleHead,
			'      - name: Foreign matrix reader\n        run: echo "${{ ' +
				reference +
				' }}"\n' +
				roleHead
		]
	])
		mustCatch(
			'Mac ' + stage + ' matrix: ' + label,
			MACOS_BOX,
			before,
			after,
			planReferenceProblems
		);
}

/**
 * Lists how the root could stop running its checks as written, or plan from a
 * partial history: it checks out once, at the default depth, and no step
 * before the deepening one fetches history; after its setup it runs exactly
 * the four checks, each with its exact command, then the deepening step with
 * its exact script, then the two plan steps.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function rootProblems(files) {
	const problems = [];
	const root = pipeline
		.jobsOfText(files.find((entry) => entry.rel === ENTRY).text, ENTRY)
		.find((candidate) => candidate.id === ROOT);
	if (!root) return [`ci.yml has no ${ROOT} job`];
	const rootSteps = pipeline.steps(root.body);
	// The checks were written against a depth-1 clone without tags; a deeper
	// checkout changes what the test:js gates that shell out to git see.
	const checkouts = rootSteps.filter((candidate) =>
		/^actions\/checkout@/.test(pipeline.stepField(candidate.body, 'uses') ?? '')
	);
	if (checkouts.length !== 1 || pipeline.stepField(checkouts[0].body, 'with') !== null) {
		problems.push(
			`${ROOT} must check out once, with no with: block: its checks run on the default depth-1 clone`
		);
	}
	const deepenAt = rootSteps.findIndex((candidate) => candidate.name === DEEPEN_STEP);
	for (const earlier of deepenAt < 0 ? rootSteps : rootSteps.slice(0, deepenAt)) {
		const fetching = logicalLines(earlier.body).find((line) => HISTORY_FETCH.test(line));
		if (fetching !== undefined) {
			problems.push(
				`${ROOT} step "${earlier.name || earlier.body.trim().split('\n')[0]}" fetches history before ` +
					`"${DEEPEN_STEP}", so the checks would not run on the depth-1 clone: ${fetching}`
			);
		}
	}
	const setupAt = rootSteps.findIndex((candidate) => candidate.name === VALIDATE_SETUP);
	const after =
		setupAt < 0
			? []
			: rootSteps.slice(setupAt + 1).filter((step) => step.name !== 'Select native OS lanes');
	const expected = [
		DEEPEN_STEP,
		...PLAN_STEPS,
		'Select the proposed one-candidate native qualification',
		'Persist the exact validated publication plan',
		'Retain the plan for failed-job reruns'
	];
	const qualifier = after.at(-3);
	if (
		pipeline.stepField(qualifier?.body ?? '', 'run') !==
		'node tools/ci/dev-release-qualification.cjs --publication-select >> "$GITHUB_OUTPUT"'
	)
		problems.push('the native qualification selector must use the sole typed owner');
	for (const field of ['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION']) {
		if (
			!qualifier?.body.includes(
				'          ERGOPTI_DEV_RELEASE_' +
					field +
					': ${{ steps.meta.outputs.' +
					field.toLowerCase() +
					' }}'
			)
		)
			problems.push('qualification must bind the current plan ' + field);
	}
	if (JSON.stringify(after.map((candidate) => candidate.name)) !== JSON.stringify(expected)) {
		problems.push(
			`${ROOT} must run exactly, after "${VALIDATE_SETUP}": ${expected.join(' | ')}; ` +
				`got: ${after.map((candidate) => candidate.name).join(' | ')}`
		);
		return problems;
	}
	const producer = after.at(-2),
		upload = after.at(-1);
	if (
		pipeline.stepField(producer.body, 'run') !==
		'node tools/ci/publication-plan.cjs create ci-publication-plan.json'
	)
		problems.push('Validate must persist its final source/run-bound plan.');
	const uploadValue = YAML.parse('steps:\n' + upload.body).steps[0];
	if (
		JSON.stringify(uploadValue) !==
		JSON.stringify({
			name: 'Retain the plan for failed-job reruns',
			uses: 'actions/upload-artifact@v4',
			with: {
				name: 'ci-publication-plan-${{ github.sha }}-${{ github.run_id }}',
				path: 'ci-publication-plan.json',
				'if-no-files-found': 'error',
				overwrite: true
			}
		})
	)
		problems.push('Validate must retain its exact terminal plan artifact.');
	const bound = YAML.parse('steps:\n' + producer.body).steps[0];
	for (const [key, owner] of Object.entries({
		release: 'meta',
		version: 'meta',
		tag: 'meta',
		title: 'meta',
		prerelease: 'meta',
		channel: 'meta',
		linux_bundle: 'contract',
		native_qualification_profile: 'qualification',
		lane_windows: 'lanes',
		lane_macos: 'lanes',
		lane_linux: 'lanes'
	}))
		if (
			bound.env['CI_PLAN_' + key.toUpperCase()] !==
			'${{ steps.' + owner + '.outputs.' + key + ' }}'
		)
			problems.push('Retained plan binding differs: ' + key);
	if (bound.env.CI_OS_SELECTION !== "${{ inputs.os_lanes || 'all' }}")
		problems.push('Retained plan selection differs.');
	for (const [name, command] of COMMON_FORMAT_CHECKS) {
		const matches = files.flatMap((entry) =>
			pipeline.jobsOfText(entry.text, entry.rel).flatMap((job) =>
				pipeline
					.steps(job.body)
					.filter((step) => step.name === name)
					.map((step) => ({ entry, job, step }))
			)
		);
		if (
			matches.length !== 1 ||
			matches[0].entry.rel !== COMMON_BOX ||
			matches[0].job.id !== 'shared-validation' ||
			pipeline.stepField(matches[0].step.body, 'run') !== command ||
			pipeline.stepField(matches[0].step.body, 'if') !==
				"${{ !cancelled() && steps.common-lot.outputs.suite == 'hotstrings-format' }}" ||
			pipeline.stepField(matches[0].step.body, 'continue-on-error') !== null
		)
			problems.push(
				'The real hotstring TOML check must run exactly once in its mandatory Common lot.'
			);
	}
	const deepen = pipeline.runOf(after[0].body) ?? [];
	if (JSON.stringify(deepen) !== JSON.stringify(DEEPEN_SCRIPT)) {
		const differs = deepen.findIndex((line, index) => line !== DEEPEN_SCRIPT[index]);
		problems.push(
			`${ROOT} step "${DEEPEN_STEP}" must run exactly its pinned script; first difference at line ` +
				`${(differs < 0 ? Math.min(deepen.length, DEEPEN_SCRIPT.length) : differs) + 1}: ` +
				`${deepen[differs] ?? '(missing)'}`
		);
	}
	return problems;
}

errors.push(...rootProblems(pipeline.files()));
for (const [what, from, to] of [
	[
		'fetch-depth: 0 on the root checkout',
		'    steps:\n      # A depth-1 clone without tags, which the checks below expect.\n      - uses: actions/checkout@v4\n',
		'    steps:\n      # A depth-1 clone without tags, which the checks below expect.\n      - uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n'
	],
	[
		'a history fetch between the checkout and the setup',
		'      - uses: actions/checkout@v4\n\n      - uses: actions/setup-python@v5\n',
		'      - uses: actions/checkout@v4\n\n      - name: Fetch all history\n        run: git fetch --depth=2147483647 --tags origin\n\n      - uses: actions/setup-python@v5\n'
	],
	[
		'a history fetch inside the setup step',
		'      - name: Prepare plan validation\n',
		'      - name: Fetch history\n        run: git pull --unshallow\n\n      - name: Prepare plan validation\n'
	],
	[
		'the deepening fetch without --unshallow',
		'        unshallow=(--unshallow)\n',
		'        unshallow=()\n'
	],
	[
		'the deepening fetch without --tags',
		' --prune "${unshallow[@]}" --tags origin; then\n',
		' --prune "${unshallow[@]}" origin; then\n'
	],
	[
		'the deepening fetch tried once',
		'          for attempt in 1 2 3; do\n',
		'          for attempt in 1; do\n'
	],
	[
		'a failed deepening fetch forgiven',
		'                  exit 1\n              fi\n              echo "::warning::',
		'                  exit 0\n              fi\n              echo "::warning::'
	],
	[
		'the completeness check dropped',
		'          if [ "$(git rev-parse --is-shallow-repository)" != false ]; then\n',
		'          if false; then\n'
	],
	['the deepening step dropped', DEEPEN_TEXT, '']
]) {
	mustCatch(what, ENTRY, from, to, rootProblems);
}
// Moving the fetch ahead of the checks is two edits, so it gets its own copy.
{
	const text = pipeline.file(ENTRY);
	const deepen = `${DEEPEN_TEXT}\n`;
	const setup = `      - name: ${VALIDATE_SETUP}\n`;
	if (text.split(deepen).length !== 2 || text.split(setup).length !== 2) {
		errors.push('self-check "the deepening fetch before the checks": re-derive the fixture');
	} else {
		const moved = text.replace(deepen, '').replace(setup, () => `${deepen}${setup}`);
		const files = pipeline
			.files()
			.map((entry) => (entry.rel === ENTRY ? { rel: ENTRY, text: moved } : entry));
		if (rootProblems(files).length === 0) {
			errors.push(
				'self-check "the deepening fetch before the checks" went unnoticed, so this rule cannot fail'
			);
		}
	}
}

// The Linux lane names its tarball with this output and release writes it into
// the notes and a shell command, so an unsafe name must fail the plan.
const contract = attempt(() =>
	pipeline.runOf(pipeline.step(plan, 'Load the Linux release artifact contract'))
);
if (contract !== null) {
	const at = (pattern) => contract.findIndex((line) => pattern.test(line.trim()));
	const checkAt = at(
		/^if \[\[ ! "\$asset_name" =~ \^\[A-Za-z0-9\._\+-\]\+\\\.tar\\\.gz\$ \]\]; then$/
	);
	const exitAt = at(/^exit 1$/);
	const emitAt = at(/^echo "linux_bundle=\$asset_name" >> "\$GITHUB_OUTPUT"$/);
	if (checkAt < 0 || !(checkAt < exitAt && exitAt < emitAt)) {
		errors.push(
			'plan must refuse an unsafe Linux bundle name (exit 1) before it emits linux_bundle'
		);
	}
}

// ======================================
// ======================================
// ======= 2/ The Lane Callers ==========
// ======================================
// ======================================

// What each caller needs is pinned with the graph shape in section 3.
/** Keep release qualification inputs and the independent shallow inventory producer exact. */
function callerInputProblems(id, inputs) {
	const problems = [];
	if (inputs.get('release') !== RELEASE_INPUT) {
		problems.push(
			`caller ${id} must pass release: ${RELEASE_INPUT}, got: ${inputs.get('release')}`
		);
	}
	for (const [key, value] of inputs) {
		if (key === 'release') continue;
		if (id === 'core' && key === 'common_plan') {
			if (value !== '${{ needs.prepare-common.outputs.plan }}')
				problems.push('Common plan must come from the mandatory shallow formatter owner');
			continue;
		}
		if (value !== `\${{ needs.${ROOT}.outputs.${key} }}`) {
			problems.push(
				`caller ${id} must pass ${key}: \${{ needs.${ROOT}.outputs.${key} }}, got: ${value}`
			);
		}
	}
	if (id === 'core' && !inputs.has('common_plan'))
		problems.push('Common caller requires the complete shallow formatter plan');
	return problems;
}

// Release reads only the dispatch selection and the lane results, and its
// publication secrets only on a push: the release job cannot run otherwise.
const PUBLICATION_INPUTS = [
	['os_lanes', "${{ inputs.os_lanes || 'all' }}"],
	['lane_results', '${{ toJSON(needs) }}']
];
const PUBLICATION_SECRETS = [
	'PAT_ERGOPTI',
	'HOMEBREW_TAP_TOKEN',
	'WINDOWS_SIGNING_CERTIFICATE_BASE64',
	'WINDOWS_SIGNING_CERTIFICATE_PASSWORD',
	'WINDOWS_SIGNER_SUBJECT'
];
/** Lists how the Release caller could leak a secret or forge the lane results. */
function publicationCallerProblems(body) {
	const problems = [];
	const inputs = [...(mappingOf(body, 'with', PUBLICATION) ?? new Map())];
	if (JSON.stringify(inputs) !== JSON.stringify(PUBLICATION_INPUTS))
		problems.push(`${PUBLICATION} must pass exactly ${JSON.stringify(PUBLICATION_INPUTS)}`);
	const secrets = [...(mappingOf(body, 'secrets', PUBLICATION) ?? new Map())];
	const expected = PUBLICATION_SECRETS.map((key) => [
		key,
		`\${{ github.event_name == 'push' && secrets.${key} || '' }}`
	]);
	if (JSON.stringify(secrets) !== JSON.stringify(expected))
		problems.push(`${PUBLICATION} must pass each publication secret on a push only`);
	if (pipeline.field(body, 'if') !== MANUAL_VERDICT_IF)
		problems.push(`${PUBLICATION} must run after every lane, whatever their results`);
	return problems;
}
const publicationBody = pipeline.job(PUBLICATION);
errors.push(...publicationCallerProblems(publicationBody));
for (const [label, before, after] of [
	['dropped lane results', '      lane_results: ${{ toJSON(needs) }}\n', ''],
	['forged selection', "${{ inputs.os_lanes || 'all' }}", "'all'"],
	[
		'ungated token',
		"PAT_ERGOPTI: ${{ github.event_name == 'push' && secrets.PAT_ERGOPTI || '' }}",
		'PAT_ERGOPTI: ${{ secrets.PAT_ERGOPTI }}'
	],
	['skipped on a red lane', 'if: always() && !cancelled()', 'if: success()']
]) {
	const altered = publicationBody.replace(before, after);
	assert.notEqual(altered, publicationBody, label);
	assert.ok(publicationCallerProblems(altered).length > 0, label);
}

const callers = pipeline.calls().filter((call) => call.id !== PUBLICATION);
if (callers.length !== 4)
	errors.push(`ci.yml must call Common and the three OS lanes, found ${callers.length} call(s)`);
let gatedSecrets = 0;
for (const call of callers) {
	const body = pipeline.job(call.id);
	// The release input is the only computed one: a false value on a release
	// run skips the lane's release build while the lane still succeeds.
	const inputs = mappingOf(body, 'with', call.id) ?? new Map();
	errors.push(...callerInputProblems(call.id, inputs));
	const inlineSecrets = /^ {4}secrets:[ \t]*([^\s#].*)$/m.exec(body);
	if (inlineSecrets) {
		errors.push(
			`caller ${call.id} must list each secret it passes, never secrets: ${inlineSecrets[1].trim()}`
		);
	}
	for (const [key, value] of mappingOf(body, 'secrets', call.id) ?? new Map()) {
		if (PUBLIC_SECRETS.has(key)) {
			if (value !== `\${{ secrets.${key} }}`)
				errors.push(`caller ${call.id} must pass ${key}: \${{ secrets.${key} }}`);
			continue;
		}
		gatedSecrets++;
		const gated = `\${{ needs.${ROOT}.outputs.release == 'true' && secrets.${key} || '' }}`;
		if (value !== gated) {
			errors.push(
				`caller ${call.id} passes the private ${key} outside a release run; it must be exactly ${gated}, got: ${value}`
			);
		}
	}
}

for (const [label, id, entries] of [
	['missing Common plan', 'core', [['release', RELEASE_INPUT]]],
	[
		'foreign Common producer',
		'core',
		[
			['release', RELEASE_INPUT],
			['common_plan', '${{ needs.validate.outputs.plan }}']
		]
	],
	[
		'foreign Common output',
		'core',
		[
			['release', RELEASE_INPUT],
			['common_plan', '${{ needs.prepare-common.outputs.matrix }}']
		]
	],
	[
		'Common plan routed into Windows',
		'windows',
		[
			['release', RELEASE_INPUT],
			['common_plan', '${{ needs.prepare-common.outputs.plan }}']
		]
	],
	[
		'Common plan routed into macOS',
		'macos',
		[
			['release', RELEASE_INPUT],
			['common_plan', '${{ needs.prepare-common.outputs.plan }}']
		]
	],
	[
		'Common plan routed into Linux',
		'linux',
		[
			['release', RELEASE_INPUT],
			['common_plan', '${{ needs.prepare-common.outputs.plan }}']
		]
	],
	[
		'qualification input uses inventory owner',
		'core',
		[
			['release', RELEASE_INPUT],
			['common_plan', '${{ needs.prepare-common.outputs.plan }}'],
			['version', '${{ needs.prepare-common.outputs.version }}']
		]
	],
	[
		'release predicate weakened',
		'core',
		[
			['release', 'true'],
			['common_plan', '${{ needs.prepare-common.outputs.plan }}']
		]
	]
])
	assert.ok(callerInputProblems(id, new Map(entries)).length > 0, label);

if (gatedSecrets < MIN_GATED_SECRETS) {
	errors.push(
		`found ${gatedSecrets} release-only secret(s) passed to the lanes (floor ${MIN_GATED_SECRETS}); the secrets parse drifted`
	);
}
if (/^\s*secrets:\s*inherit\b/m.test(pipeline.text())) {
	errors.push(
		'no job may use secrets: inherit, which hands every secret, PAT_ERGOPTI included, to the called workflow'
	);
}

const COMMON_INPUTS = ['release', 'version', 'tag', 'prerelease', 'channel'];
const COMMON_DISPATCH = [
	'case "$SUITE" in',
	'    js) npm run test:js -- --feature "$FEATURE" ;;',
	'    properties) npm run test:properties ;;',
	'    mutation) npm run test:mutation ;;',
	'    hotstrings-format) test "${{ steps.hotstrings-format.outcome }}" = success ;;',
	'    *) exit 1 ;;',
	'esac'
].join('\n');

/** Preserve the reusable Common caller, literal inventory, exact union and browser custody. */
/** Keep production output custody separate from the existing source-rendering E2Es. */
/** Pin the actual receipt pair consumer; a display-only final job cannot pass. */
function commonVerdictProblems(source) {
	const problems = [];
	try {
		const job = YAML.parse(source, { uniqueKeys: true }).jobs['common-unit-verdict'];
		assert.deepEqual(job, {
			name: 'Verdict',
			needs: ['common-testbuild'],
			if: 'always()',
			'runs-on': 'ubuntu-latest',
			permissions: { contents: 'read', actions: 'read' },
			env: {
				SITE_PREDECESSOR_RESULT: '${{ needs.common-testbuild.result }}',
				GH_TOKEN: '${{ github.token }}'
			},
			steps: [
				{ uses: 'actions/checkout@v4' },
				{ uses: 'actions/setup-node@v4', with: { 'node-version-file': '.node-version' } },
				{
					name: 'Receive stable production browser proof',
					uses: 'actions/download-artifact@v4',
					with: { name: 'common-site-testbuild-main', path: 'site-proof/main' }
				},
				{
					name: 'Receive development production browser proof',
					uses: 'actions/download-artifact@v4',
					with: { name: 'common-site-testbuild-dev', path: 'site-proof/dev' }
				},
				{
					name: 'Require both exact Build and browser receipts',
					run: 'node tools/ci/site-verdict.cjs verify site-proof'
				}
			]
		});
	} catch (error) {
		problems.push('Shared Verdict must receive both tested receipt pairs: ' + error.message);
	}
	return problems;
}

function commonSiteProblems(source) {
	const errors = [];
	try {
		const doc = require('yaml').parse(source);
		const same = (a, b, label) => {
			if (JSON.stringify(a) !== JSON.stringify(b)) errors.push(label);
		};
		const command = (job, name, run) => {
			const rows = job.steps.filter((s) => s.name === name);
			if (
				rows.length !== 1 ||
				rows[0].run !== run ||
				rows[0].if !== undefined ||
				rows[0]['continue-on-error'] !== undefined
			)
				errors.push(name);
		};
		const build = doc.jobs['common-build'],
			test = doc.jobs['common-testbuild'];
		for (const [job, previous, name, timeout] of [
			[build, 'common-e2e', 'Build', 60],
			[test, 'common-build', 'Install and launch', 30]
		]) {
			same(job.needs, [previous], 'adjacent production stage');
			same(job.name, name, 'actual API stage name');
			same(job['runs-on'], 'ubuntu-latest', 'production runner');
			same(job['timeout-minutes'], timeout, 'bounded production stage');
			same(
				job.strategy,
				{
					'fail-fast': false,
					matrix: '${{ fromJSON(needs.' + previous + '.outputs.site_matrix) }}'
				},
				'two exact independent production targets'
			);
			same(
				job.env,
				{
					SITE_LOT: '${{ matrix.lot }}',
					SITE_METADATA: '${{ needs.' + previous + '.outputs.site_metadata }}',
					ERGOPTI_SITE_TARGET:
						'${{ fromJSON(needs.' + previous + '.outputs.site_metadata)[matrix.lot].target }}',
					BASE_PATH:
						'${{ fromJSON(needs.' + previous + '.outputs.site_metadata)[matrix.lot].base_path }}',
					ERGOPTI_SITE_SOURCE_SHA: '${{ github.sha }}'
				},
				'actual source and separate target'
			);
			for (const key of ['if', 'continue-on-error', 'permissions'])
				if (job[key] !== undefined) errors.push('production job ' + key);
			same(
				job.outputs,
				job === build
					? {
							site_matrix: '${{ steps.site-plan.outputs.matrix }}',
							site_metadata: '${{ steps.site-plan.outputs.metadata }}'
						}
					: undefined,
				'whole map forwarding only from Build'
			);
			same(
				job.steps[3],
				{
					name: 'Admit the complete production site map',
					id: 'site-plan',
					run: 'node tools/ci/site-matrix.cjs admit'
				},
				'admit the whole source map before production'
			);
			for (const step of job.steps)
				for (const key of ['if', 'continue-on-error'])
					if (step[key] !== undefined) errors.push('production step ' + key);
			same(
				job.steps.slice(0, 3),
				[
					{ uses: 'actions/checkout@v4' },
					{
						uses: 'actions/setup-node@v4',
						with: { 'node-version-file': '.node-version', cache: 'npm' }
					},
					{ run: 'npm ci' }
				],
				'actual production dependencies'
			);
		}
		same(build.steps.length, 6, 'closed production build steps');
		command(
			build,
			'Build and seal production site — ${{ matrix.lot }}',
			'set -euo pipefail\nbundle="$RUNNER_TEMP/common-site-$ERGOPTI_SITE_TARGET"\nmkdir "$bundle"\nnpm run build\ncmp -- static/CNAME build/CNAME\nmv build "$bundle/site"\nnode tools/ci/site-artifact.cjs seal "$bundle/site" "$bundle/build.json"\n'
		);
		same(
			build.steps[5],
			{
				name: 'Retain exact production site',
				uses: 'actions/upload-artifact@v4',
				with: {
					name: 'common-site-build-${{ env.ERGOPTI_SITE_TARGET }}',
					path: '${{ runner.temp }}/common-site-${{ env.ERGOPTI_SITE_TARGET }}/',
					'include-hidden-files': true,
					'if-no-files-found': 'error',
					overwrite: true
				}
			},
			'retain complete sealed output'
		);
		same(test.steps.length, 8, 'closed production receiving steps');
		same(
			test.steps[4],
			{
				name: 'Install production site browsers',
				run: 'node tools/ci/install-playwright.cjs chromium webkit'
			},
			'both production browser engines'
		);
		same(
			test.steps[5],
			{
				name: 'Receive exact production site',
				uses: 'actions/download-artifact@v4',
				with: {
					name: 'common-site-build-${{ env.ERGOPTI_SITE_TARGET }}',
					path: '${{ runner.temp }}/received-site'
				}
			},
			'receive the actual target build'
		);
		command(
			test,
			'Test received production site — ${{ matrix.lot }}',
			'set -euo pipefail\nnode tools/test/browser/site-artifact-smoke.playwright.cjs "$RUNNER_TEMP/received-site/site" "$RUNNER_TEMP/received-site/build.json" "$RUNNER_TEMP/site-testbuild.json"\nmkdir "$RUNNER_TEMP/site-proof"\ncp "$RUNNER_TEMP/received-site/build.json" "$RUNNER_TEMP/site-proof/build.json"\ncp "$RUNNER_TEMP/site-testbuild.json" "$RUNNER_TEMP/site-proof/site-testbuild.json"\n'
		);
		same(
			test.steps[7],
			{
				name: 'Retain production browser proof',
				uses: 'actions/upload-artifact@v4',
				with: {
					name: 'common-site-testbuild-${{ env.ERGOPTI_SITE_TARGET }}',
					path: '${{ runner.temp }}/site-proof/',
					'if-no-files-found': 'error',
					overwrite: true
				}
			},
			'retain actual production proof'
		);
	} catch (error) {
		errors.push(error.message);
	}
	return errors;
}

/** Publication gets write permission only after receiving the exact tested artifact. */
const SITE_PRODUCER_CONDITION =
	"${{ github.event_name == 'workflow_dispatch' || (github.event.workflow_run.event == 'push' && github.event.workflow_run.conclusion == 'success') }}";

const SITE_RUN_NAME =
	"Deploy site (${{ github.event_name == 'workflow_dispatch' && format('manual, run {0}', inputs.run_id) || github.event.workflow_run.head_branch }})";

function siteDeploymentProblems(source) {
	const errors = [];
	try {
		const doc = require('yaml').parse(source);
		const same = (a, b, label) => {
			if (JSON.stringify(a) !== JSON.stringify(b)) errors.push(label);
		};
		same(
			doc.on,
			{
				workflow_run: { workflows: ['CI'], types: ['completed'], branches: ['main', 'dev'] },
				workflow_dispatch: {
					inputs: {
						run_id: {
							description: 'Exact successful canonical CI run containing the tested site',
							required: true,
							type: 'string'
						}
					}
				}
			},
			'all completed source changes and exact manual run'
		);
		same(doc['run-name'], SITE_RUN_NAME, 'the run names its producer branch, not main');
		same(doc.permissions, { contents: 'read', actions: 'read' }, 'read-only before preflight');
		same(Object.keys(doc.jobs), ['preflight', 'deploy'], 'closed publication chain');
		const pre = doc.jobs.preflight,
			deploy = doc.jobs.deploy;
		same(pre.needs, undefined, 'preflight entry');
		same(pre.permissions, undefined, 'preflight cannot gain write permission');
		same(deploy.needs, ['preflight'], 'write job awaits completed byte verification');
		same(
			deploy.permissions,
			{ contents: 'write', actions: 'read' },
			'write permission only after preflight'
		);
		same(
			deploy.concurrency,
			{ group: 'deploy-site-gh-pages', 'cancel-in-progress': false },
			'serialize shared publication branch'
		);
		same(
			deploy.env,
			{
				SITE_TARGET: '${{ needs.preflight.outputs.target }}',
				SITE_SOURCE_SHA: '${{ needs.preflight.outputs.source_sha }}'
			},
			'publish admitted source and target'
		);
		same(
			pre.outputs,
			Object.fromEntries(
				['source_sha', 'target', 'run_id', 'build_artifact_id', 'testbuild_artifact_id'].map(
					(key) => [key, '${{ steps.admit.outputs.' + key + ' }}']
				)
			),
			'forward actual admission'
		);
		// A failed, cancelled or dispatched CI run has no site to publish: the
		// receiver used to start for it and fail red on every dev push. The
		// condition mirrors the admission's own event check, which still refuses.
		same(pre.if, SITE_PRODUCER_CONDITION, 'only a successful push reaches the receiver');
		for (const job of [pre, deploy]) {
			same(job['runs-on'], 'ubuntu-latest', 'publication runner');
			same(job['timeout-minutes'], 20, 'bounded publication');
			if (job !== pre && job.if !== undefined) errors.push('publication job if');
			for (const key of ['continue-on-error', 'strategy', 'uses'])
				if (job[key] !== undefined) errors.push('publication job ' + key);
			for (const step of job.steps)
				for (const key of ['if', 'continue-on-error'])
					if (step[key] !== undefined) errors.push('publication step ' + key);
			same(
				job.steps[0],
				{
					name: 'Checkout trusted receiver',
					uses: 'actions/checkout@v4',
					with: { 'persist-credentials': false }
				},
				'trusted receiver without stored token'
			);
			same(
				job.steps[1],
				{ uses: 'actions/setup-node@v4', with: { 'node-version-file': '.node-version' } },
				'canonical receiver runtime'
			);
		}
		same(pre.steps.length, 8, 'closed preflight steps');
		same(deploy.steps.length, 8, 'closed publication steps');
		same(
			pre.steps[2],
			{
				name: 'Admit exact completed producer',
				id: 'admit',
				env: { GH_TOKEN: '${{ github.token }}' },
				run: 'node tools/ci/site-deploy-admission.cjs admit "$GITHUB_EVENT_PATH" "$RUNNER_TEMP/site-admission.json"'
			},
			'actual metadata admission'
		);
		const downloaded = (prefix, key, directory, name) => ({
			name,
			uses: 'actions/download-artifact@v4',
			with: {
				'artifact-ids': '${{ ' + prefix + '.' + key + ' }}',
				'merge-multiple': true,
				'run-id': '${{ ' + prefix + '.run_id }}',
				'github-token': '${{ github.token }}',
				path: '${{ runner.temp }}/' + directory
			}
		});
		same(
			pre.steps[3],
			{
				name: 'Checkout exact producer source',
				uses: 'actions/checkout@v4',
				with: {
					ref: '${{ steps.admit.outputs.source_sha }}',
					path: 'producer-source',
					'persist-credentials': false
				}
			},
			'exact read-only source checkout'
		);
		same(
			pre.steps[4],
			downloaded(
				'steps.admit.outputs',
				'build_artifact_id',
				'received-site',
				'Receive selected build artifact'
			),
			'preflight exact build ID'
		);
		same(
			pre.steps[5],
			downloaded(
				'steps.admit.outputs',
				'testbuild_artifact_id',
				'received-testbuild',
				'Receive selected browser proof'
			),
			'preflight exact proof ID'
		);
		const verify = (admission) =>
			'node tools/ci/site-deploy-admission.cjs verify "$RUNNER_TEMP/' +
			admission +
			'/site-admission.json" "$RUNNER_TEMP/received-site/site" "$RUNNER_TEMP/received-site/build.json" "$RUNNER_TEMP/received-testbuild/site-testbuild.json" "$GITHUB_WORKSPACE/producer-source"';
		same(
			pre.steps[6],
			{
				name: 'Verify tested bytes and source',
				env: { GH_TOKEN: '${{ github.token }}' },
				run: verify('').replace('$RUNNER_TEMP//', '$RUNNER_TEMP/')
			},
			'preflight actual byte and proof receiving'
		);
		same(
			pre.steps[7],
			{
				name: 'Retain admitted producer identity',
				uses: 'actions/upload-artifact@v4',
				with: {
					name: 'site-deployment-admission',
					path: '${{ runner.temp }}/site-admission.json',
					'if-no-files-found': 'error',
					overwrite: true
				}
			},
			'retain validated admission'
		);
		same(
			deploy.steps[2],
			{
				name: 'Checkout exact publication source',
				uses: 'actions/checkout@v4',
				with: { ref: '${{ needs.preflight.outputs.source_sha }}', path: 'producer-source' }
			},
			'exact publication source'
		);
		same(
			deploy.steps[3],
			{
				name: 'Receive admitted producer identity',
				uses: 'actions/download-artifact@v4',
				with: { name: 'site-deployment-admission', path: '${{ runner.temp }}/admission' }
			},
			'receive admitted identity'
		);
		same(
			deploy.steps[4],
			downloaded(
				'needs.preflight.outputs',
				'build_artifact_id',
				'received-site',
				'Receive selected build artifact'
			),
			'publication exact build ID'
		);
		same(
			deploy.steps[5],
			downloaded(
				'needs.preflight.outputs',
				'testbuild_artifact_id',
				'received-testbuild',
				'Receive selected browser proof'
			),
			'publication exact proof ID'
		);
		same(
			deploy.steps[6],
			{
				name: 'Verify tested bytes and source again',
				env: { GH_TOKEN: '${{ github.token }}' },
				run: verify('admission')
			},
			'repeat actual receiving before mutation'
		);
		const publish = deploy.steps[7];
		same(publish.name, 'Deploy to GitHub Pages', 'terminal publication owner');
		same(publish['working-directory'], 'producer-source', 'isolated admitted source checkout');
		same(
			publish.env,
			{ GH_TOKEN: '${{ github.token }}' },
			'read API token for final source freshness'
		);
		for (const line of [
			'set -euo pipefail',
			'test "$(git rev-parse HEAD)" = "$SITE_SOURCE_SHA"',
			'case "$SITE_TARGET" in',
			'main) DEPLOY_DIR=.; LABEL=ergopti.fr/ ;;',
			'dev) DEPLOY_DIR=dev; LABEL=ergopti.fr/dev/ ;;',
			'*) exit 1 ;;',
			'SITE="$RUNNER_TEMP/received-site/site"',
			'cmp -- static/CNAME "$SITE/CNAME"',
			'if [[ "$SITE_TARGET" == main ]]; then',
			'test ! -e "$SITE/dev"',
			'node "$GITHUB_WORKSPACE/tools/ci/site-deploy-admission.cjs" current "$RUNNER_TEMP/admission/site-admission.json"',
			'GHP="$RUNNER_TEMP/gh-pages"',
			'test ! -e "$GHP"',
			'git worktree add -b gh-pages "$GHP" FETCH_HEAD',
			'git worktree add --orphan -b gh-pages "$GHP"',
			"! -name '.git'",
			"! -name 'dev'",
			'cp -r "$SITE"/. "$GHP"/',
			'rm -rf "${GHP:?}/$DEPLOY_DIR"',
			'cp -r "$SITE"/. "$GHP/$DEPLOY_DIR/"',
			'cmp -- static/CNAME "$GHP/$DEPLOY_DIR/CNAME"',
			'touch "$GHP/.nojekyll"',
			'git -C "$GHP" add -A',
			'if git -C "$GHP" diff --cached --quiet; then',
			'exit 0',
			'git -C "$GHP" commit -m "deploy: ${LABEL} from ${SITE_SOURCE_SHA} (${SITE_TARGET})"',
			'git -C "$GHP" push origin gh-pages'
		]) {
			if (!publish.run.split('\n').some((row) => row.trim().replace(/\s+\\$/, '') === line))
				errors.push('publication must retain ' + line);
		}
		if (
			/npm|build\/|github\.sha|github\.ref_name|GITHUB_REF_NAME|continue-on-error|\|\| true/.test(
				publish.run
			)
		)
			errors.push('no source rebuild or default event identity fallback');
		if (
			publish.run.indexOf('cmp -- static/CNAME "$SITE/CNAME"') > publish.run.indexOf('git config')
		)
			errors.push('domain before mutation');
		if (publish.run.indexOf('test ! -e "$SITE/dev"') > publish.run.indexOf('git config'))
			errors.push('received main cannot overwrite dev');
		if (
			!publish.run.includes(
				'node "$GITHUB_WORKSPACE/tools/ci/site-deploy-admission.cjs" current "$RUNNER_TEMP/admission/site-admission.json"\ngit -C "$GHP" push origin gh-pages'
			)
		)
			errors.push('current target tip immediately before push');
	} catch (error) {
		errors.push(error.message);
	}
	return errors;
}

const SITE_BUILD_REFUSALS = [
	['missing production build', '  common-build:\n', '  foreign-build:\n'],
	['missing production testbuild', '  common-testbuild:\n', '  foreign-testbuild:\n'],
	['crossed Build dependency', '    needs: [common-e2e]\n', '    needs: [common-unit-verdict]\n'],
	['crossed Testbuild dependency', '    needs: [common-build]\n', '    needs: [common-e2e]\n'],
	[
		'forgiven production build',
		'  common-build:\n',
		'  common-build:\n    continue-on-error: true\n'
	],
	[
		'skipped production browser',
		'      - name: Test received production site — ${{ matrix.lot }}\n',
		'      - name: Test received production site — ${{ matrix.lot }}\n        if: false\n'
	],
	['unverified domain', '          cmp -- static/CNAME build/CNAME\n', ''],
	[
		'unsealed output',
		'          node tools/ci/site-artifact.cjs seal "$bundle/site" "$bundle/build.json"\n',
		''
	],
	[
		'hidden output omitted',
		'          include-hidden-files: true\n',
		'          include-hidden-files: false\n'
	],
	[
		'Testbuild rebuild fallback',
		'      - name: Test received production site — ${{ matrix.lot }}\n',
		'      - run: npm run build\n\n      - name: Test received production site — ${{ matrix.lot }}\n'
	],
	[
		'wrong downloaded target',
		'          name: common-site-build-${{ env.ERGOPTI_SITE_TARGET }}\n          path: ${{ runner.temp }}/received-site',
		'          name: common-site-build-main\n          path: ${{ runner.temp }}/received-site'
	],
	[
		'missing browser proof',
		'          path: ${{ runner.temp }}/site-proof/\n',
		'          path: missing.json\n'
	],
	[
		'false stable base',
		'      BASE_PATH: ${{ fromJSON(needs.common-e2e.outputs.site_metadata)[matrix.lot].base_path }}\n',
		"      BASE_PATH: '/dev'\n"
	]
];
const SITE_DEPLOY_REFUSALS = [
	[
		'steps.admit.outputs build_artifact_id must flatten the one exact admitted ID',
		'          artifact-ids: ${{ steps.admit.outputs.build_artifact_id }}\n          merge-multiple: true\n',
		'          artifact-ids: ${{ steps.admit.outputs.build_artifact_id }}\n'
	],
	[
		'steps.admit.outputs testbuild_artifact_id must flatten the one exact admitted ID',
		'          artifact-ids: ${{ steps.admit.outputs.testbuild_artifact_id }}\n          merge-multiple: true\n',
		'          artifact-ids: ${{ steps.admit.outputs.testbuild_artifact_id }}\n'
	],
	[
		'needs.preflight.outputs build_artifact_id must flatten the one exact admitted ID',
		'          artifact-ids: ${{ needs.preflight.outputs.build_artifact_id }}\n          merge-multiple: true\n',
		'          artifact-ids: ${{ needs.preflight.outputs.build_artifact_id }}\n'
	],
	[
		'needs.preflight.outputs testbuild_artifact_id must flatten the one exact admitted ID',
		'          artifact-ids: ${{ needs.preflight.outputs.testbuild_artifact_id }}\n          merge-multiple: true\n',
		'          artifact-ids: ${{ needs.preflight.outputs.testbuild_artifact_id }}\n'
	],
	['main artifact overwrites dev', '              test ! -e "$SITE/dev"\n', ''],
	[
		'missing final source freshness',
		'          node "$GITHUB_WORKSPACE/tools/ci/site-deploy-admission.cjs" current "$RUNNER_TEMP/admission/site-admission.json"\n',
		''
	],
	[
		'premature write permission',
		'permissions:\n  contents: read\n',
		'permissions:\n  contents: write\n'
	],
	['missing preflight edge', '    needs: [preflight]\n', '    needs: []\n'],
	['forgiven preflight', '  preflight:\n', '  preflight:\n    continue-on-error: true\n'],
	[
		'run labelled with the default branch',
		'  Deploy site (${{ github.event_name',
		'  Deploy site (main ${{ github.event_name'
	],
	[
		'receiver switched off',
		" || (github.event.workflow_run.event == 'push' && github.event.workflow_run.conclusion == 'success') }}\n",
		' && false }}\n'
	],
	[
		'receiver admits a failed producer',
		"github.event.workflow_run.conclusion == 'success'",
		"github.event.workflow_run.conclusion != 'cancelled'"
	],
	[
		'publication job skipped on its own',
		'    needs: [preflight]\n',
		'    needs: [preflight]\n    if: false\n'
	],
	['domain-only changes excluded', '    branches: [main, dev]\n', '    branches: [dev]\n'],
	['missing exact manual identity', '      run_id:\n', '      latest:\n'],
	[
		'wrong source checkout',
		'          ref: ${{ steps.admit.outputs.source_sha }}\n',
		'          ref: main\n'
	],
	[
		'wrong selected build ID',
		'          artifact-ids: ${{ steps.admit.outputs.build_artifact_id }}\n',
		'          artifact-ids: 1\n'
	],
	[
		'wrong selected proof ID',
		'          artifact-ids: ${{ needs.preflight.outputs.testbuild_artifact_id }}\n',
		'          artifact-ids: 1\n'
	],
	[
		'missing preflight verification',
		'      - name: Verify tested bytes and source\n',
		'      - name: Missing byte verification\n'
	],
	[
		'missing publication verification',
		'      - name: Verify tested bytes and source again\n',
		'      - name: Missing repeated verification\n'
	],
	[
		'root copy from source',
		'              cp -r "$SITE"/. "$GHP"/\n',
		'              cp -r build/. "$GHP"/\n'
	],
	[
		'development overwrite root',
		'              cp -r "$SITE"/. "$GHP/$DEPLOY_DIR/"\n',
		'              cp -r "$SITE"/. "$GHP"/\n'
	],
	['main erases dev', "                     ! -name 'dev' \\\n", ''],
	['missing root nojekyll', '          touch "$GHP/.nojekyll"\n', ''],
	['missing copied domain check', '          cmp -- static/CNAME "$GHP/$DEPLOY_DIR/CNAME"\n', ''],
	['wrong commit source', 'from ${SITE_SOURCE_SHA}', 'from ${GITHUB_SHA}']
];

function commonProblems(files) {
	const problems = commonPlanProblems(files);
	const entry = files.find((file) => file.rel === ENTRY);
	const common = files.find((file) => file.rel === COMMON_BOX);
	const callers = entry ? pipeline.jobsOfText(entry.text, ENTRY) : [];
	const call = callers.find((job) => job.id === 'core');
	const children = common ? pipeline.jobsOfText(common.text, COMMON_BOX) : [];
	const byId = new Map(children.map((job) => [job.id, job]));
	const child = byId.get('shared-validation');
	const prepare = callers.find((job) => job.id === 'prepare-common');
	const verdict = byId.get('common-unit-verdict');
	const browser = byId.get('common-e2e');
	if (!call || pipeline.field(call.body, 'uses') !== './.github/workflows/ci-common.yml')
		problems.push('core must call the exact reusable Common workflow');
	if (
		!call ||
		JSON.stringify(pipeline.needsOf(call.body)) !== JSON.stringify([ROOT, 'prepare-common'])
	)
		problems.push('Common caller must await validation and the independent formatter');
	for (const key of ['if', 'continue-on-error', 'secrets', 'runs-on', 'strategy', 'env', 'steps'])
		if (call && pipeline.field(call.body, key) !== null)
			problems.push('Common caller must set no ' + key);
	const fieldBlock = (body, key) =>
		new RegExp('^ {4}' + key + ':\\n((?: {6}[^\\n]*(?:\\n|$)|\\n)*)', 'm')
			.exec(body)?.[0]
			.trimEnd();
	const callerInputs =
		'    with:\n      common_plan: ${{ needs.prepare-common.outputs.plan }}\n' +
		COMMON_INPUTS.map(
			(key) =>
				`      ${key}: \${{ needs.validate.outputs.${key}${key === 'release' ? " == 'true'" : ''} }}`
		).join('\n');
	if (!call || fieldBlock(call.body, 'with') !== callerInputs)
		problems.push('Common caller must forward exactly the five canonical plan inputs');
	const dependencies = {
		'shared-validation': [],
		'common-unit-verdict': ['common-testbuild'],
		'common-e2e': ['shared-validation'],
		'common-build': ['common-e2e'],
		'common-testbuild': ['common-build']
	};
	if (
		JSON.stringify(children.map((job) => job.id).sort()) !==
		JSON.stringify(Object.keys(dependencies).sort())
	)
		problems.push('Common must retain its complete Unit, E2E, Build and Testbuild chain');
	for (const [id, needs] of Object.entries(dependencies)) {
		const job = byId.get(id);
		if (!job || JSON.stringify(pipeline.needsOf(job.body)) !== JSON.stringify(needs))
			problems.push(id + ' must await its exact mandatory prerequisites');
		for (const key of ['if', 'continue-on-error', 'uses', 'secrets'])
			if (
				job &&
				pipeline.field(job.body, key) !==
					(id === 'common-unit-verdict' && key === 'if' ? 'always()' : null)
			)
				problems.push(id + ' must set no ' + key);
		if (!job || pipeline.field(job.body, 'runs-on') !== 'ubuntu-latest')
			problems.push(id + ' must retain its Ubuntu runner');
	}
	const strategy = '    strategy:\n      fail-fast: false\n      matrix: ' + COMMON_MATRIX;
	if (!child || fieldBlock(child.body, 'strategy') !== strategy)
		problems.push('Common must consume the exact prepared inventory matrix without fail-fast');
	if (
		!prepare ||
		fieldBlock(prepare.body, 'outputs') !==
			'    outputs:\n      plan: ${{ steps.plan.outputs.plan }}'
	)
		problems.push('Common must expose the actual prepared matrix');
	const environment =
		'    env:\n' +
		['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION']
			.map((key) => `      ERGOPTI_DEV_RELEASE_${key}: \${{ inputs.${key.toLowerCase()} }}`)
			.join('\n');
	for (const job of [child, browser])
		if (
			!job ||
			fieldBlock(job.body, 'env') !==
				(job === child
					? environment.replace(
							'    env:\n',
							'    env:\n      COMMON_LOT: ${{ matrix.lot }}\n      COMMON_PLAN: ${{ inputs.common_plan }}\n'
						)
					: environment.replace(
							'    env:\n',
							'    env:\n      COMMON_PLAN: ${{ inputs.common_plan }}\n      COMMON_PREDECESSOR_RESULT: ${{ needs.shared-validation.result }}\n      GH_TOKEN: ${{ github.token }}\n'
						))
		)
			problems.push('Common must retain exact qualification input bindings');
	if (common) {
		if (/^concurrency:/m.test(common.text))
			problems.push('Common must leave concurrency ownership with its root caller');
		const onStart = common.text.indexOf('\non:\n');
		const permissionStart = common.text.indexOf('\npermissions:\n');
		const trigger = common.text.slice(onStart + 1, permissionStart);
		const names = [...trigger.matchAll(/^ {6}([a-z_]+):$/gm)].map((match) => match[1]);
		if (
			onStart < 0 ||
			permissionStart <= onStart ||
			!trigger.startsWith('on:\n  workflow_call:\n    inputs:\n') ||
			JSON.stringify(names) !== JSON.stringify(['common_plan', ...COMMON_INPUTS]) ||
			[...trigger.matchAll(/^ {2}([a-z_]+):$/gm)].some((match) => match[1] !== 'workflow_call')
		)
			problems.push('Common must accept only its exact workflow_call interface');
		for (const key of ['common_plan', ...COMMON_INPUTS]) {
			const type = key === 'release' ? 'boolean' : 'string';
			if (
				!new RegExp(
					'^ {6}' +
						key +
						':\\n(?: {8}description:[^\\n]*\\n)? {8}required: true\\n {8}type: ' +
						type +
						'(?=\\n|$)',
					'm'
				).test(trigger)
			)
				problems.push('Common input ' + key + ' must retain its required type');
		}
		if (!common.text.includes('permissions:\n  contents: read\n\njobs:\n'))
			problems.push('Common must retain read-only contents permission');
	}
	const exactStep = (job, name, command) => {
		const matches = job ? pipeline.steps(job.body).filter((step) => step.name === name) : [];
		if (
			matches.length !== 1 ||
			pipeline.runOf(matches[0].body)?.join('\n') !== command ||
			pipeline.stepField(matches[0].body, 'if') !== null ||
			pipeline.stepField(matches[0].body, 'continue-on-error') !== null
		)
			problems.push(name + ' must retain its mandatory exact command');
		return matches[0]?.body;
	};
	const plan = exactStep(
		prepare,
		'Plan every canonical feature and additional suite',
		'set -euo pipefail\nnode tools/ci/js-feature-matrix.cjs plan'
	);
	if (!plan || pipeline.stepField(plan, 'id') !== 'plan')
		problems.push('Common matrix output must come from its actual plan step');
	const selected = exactStep(
		child,
		'Admit the complete Common lot map',
		'node tools/ci/js-feature-matrix.cjs select'
	);
	if (!selected || pipeline.stepField(selected, 'id') !== 'common-lot')
		problems.push('Common must admit the whole source-owned lot map before dispatch.');
	const dispatch = exactStep(child, 'Run shared validation suite', COMMON_DISPATCH);
	if (
		!dispatch ||
		pipeline.stepField(dispatch, 'env') !==
			'SUITE: ${{ steps.common-lot.outputs.suite }} FEATURE: ${{ steps.common-lot.outputs.feature }}'
	)
		problems.push('Common must dispatch the exact suite and feature from its declared matrix');
	const consumer = scoped.contract.receipt_consumers[0];
	exactStep(browser, consumer.step, consumer.body);
	for (const [name, artifact, directory] of [
		[
			'Download exact source-bound qualification',
			'name: assets-qualification-core-js',
			'qualification'
		],
		['Download completed feature timings', 'pattern: core-js-timings-*', 'feature-timings']
	]) {
		const matches = browser
			? pipeline.steps(browser.body).filter((step) => step.name === name)
			: [];
		if (
			matches.length !== 1 ||
			pipeline.stepField(matches[0].body, 'uses') !== 'actions/download-artifact@v4' ||
			pipeline.stepField(matches[0].body, 'with') !== `${artifact} path: ${directory}` ||
			pipeline.stepField(matches[0].body, 'if') !== null ||
			pipeline.stepField(matches[0].body, 'continue-on-error') !== null
		)
			problems.push(name + ' must acquire its exact source-bound evidence');
	}
	for (const [name, command] of [
		['Install shared UI browsers', 'node tools/ci/install-playwright.cjs chromium webkit'],
		['Test shared layer editor rendering', 'npm run test:browser:layer-editor'],
		['Test shared physical shortcut rendering', 'npm run test:browser:physical-shortcuts'],
		['Test shared Versions installation rendering', 'npm run test:browser:changelog-install']
	])
		exactStep(browser, name, command);
	if (browser) {
		const steps = pipeline.steps(browser.body);
		const admission = steps.findIndex((step) => step.name === consumer.step);
		const firstSetup = steps.findIndex(
			(step) => pipeline.stepField(step.body, 'uses') === 'actions/setup-python@v5'
		);
		if (admission < 0 || admission >= firstSetup)
			problems.push('Unit receipt admission must precede all browser preparation');
	}
	if (common)
		problems.push(...commonSiteProblems(common.text), ...commonVerdictProblems(common.text));
	return problems;
}
errors.push(...commonProblems(pipeline.files()));

for (const [label, from, to] of [
	['missing site Verdict', '  common-unit-verdict:\n', '  missing-verdict:\n'],
	['Verdict wrong predecessor', '    needs: [common-testbuild]\n', '    needs: [common-build]\n'],
	[
		'Verdict forged aggregate',
		'      SITE_PREDECESSOR_RESULT: ${{ needs.common-testbuild.result }}\n',
		'      SITE_PREDECESSOR_RESULT: success\n'
	],
	[
		'Verdict missing stable proof',
		'          name: common-site-testbuild-main\n',
		'          name: foreign\n'
	],
	[
		'Verdict missing development proof',
		'          name: common-site-testbuild-dev\n',
		'          name: foreign\n'
	],
	[
		'Verdict omits actual receipt receiving',
		'run: node tools/ci/site-verdict.cjs verify site-proof',
		'run: echo passed'
	],
	[
		'Verdict forgives receiving',
		'      - name: Require both exact Build and browser receipts\n',
		'      - name: Require both exact Build and browser receipts\n        continue-on-error: true\n'
	]
])
	mustCatch(label, COMMON_BOX, from, to, (files) =>
		commonVerdictProblems(files.find((file) => file.rel === COMMON_BOX).text)
	);

for (const [label, from, to] of SITE_BUILD_REFUSALS) {
	const source = pipeline.file(COMMON_BOX);
	assert.equal(source.split(from).length, 2, label + ' has one real source seam');
	assert.ok(commonSiteProblems(source.replace(from, () => to)).length > 0, label);
}

assert.deepEqual(
	planReferenceProblems(pipeline.files()),
	[],
	'actual prepared matrix keeps its exact Common consumer'
);
for (const [label, from, to] of [
	['foreign matrix producer', COMMON_MATRIX, '${{ fromJSON(needs.foreign.outputs.matrix) }}'],
	[
		'unknown prepared output',
		COMMON_MATRIX,
		'${{ fromJSON(needs.prepare-common.outputs.foreign) }}'
	],
	['unknown root output', COMMON_MATRIX, '${{ fromJSON(needs.validate.outputs.foreign) }}'],
	[
		'noncanonical matrix expression',
		COMMON_MATRIX,
		'${{ fromJSON(needs.prepare-common.outputs.matrix) || false }}'
	],
	[
		'arbitrary step script in the legitimate consumer',
		'      - name: Run shared validation suite\n',
		'      - name: Foreign prepared output reader\n        run: echo "${{ needs.prepare-common.outputs.matrix }}"\n\n      - name: Run shared validation suite\n'
	],
	[
		'arbitrary job field in the legitimate consumer',
		"    name: 'Unit tests'\n",
		"    name: 'Unit tests ${{ needs.prepare-common.outputs.matrix }}'\n"
	],
	[
		'foreign Common consumer',
		'  common-e2e:\n',
		'  common-e2e:\n    env:\n      FORGED_MATRIX: ${{ needs.prepare-common.outputs.matrix }}\n'
	],
	[
		'prepared output outside a job',
		'jobs:\n',
		'env:\n  FORGED_MATRIX: ${{ needs.prepare-common.outputs.matrix }}\njobs:\n'
	],
	[
		'duplicate Common consumer',
		'  shared-validation:\n',
		'  shared-validation:\n    runs-on: ubuntu-latest\n    env:\n      FORGED_MATRIX: ${{ needs.prepare-common.outputs.matrix }}\n  shared-validation:\n'
	]
]) {
	mustCatch(label, COMMON_BOX, from, to, planReferenceProblems);
}
mustCatch(
	'prepared matrix cannot become a release caller input',
	ENTRY,
	"    uses: ./.github/workflows/ci-common.yml\n    permissions:\n      contents: read\n      actions: read\n    with:\n      common_plan: ${{ needs.prepare-common.outputs.plan }}\n      release: ${{ needs.validate.outputs.release == 'true' }}\n      version: ${{ needs.validate.outputs.version }}\n      tag: ${{ needs.validate.outputs.tag }}\n",
	"    uses: ./.github/workflows/ci-common.yml\n    permissions:\n      contents: read\n      actions: read\n    with:\n      common_plan: ${{ needs.prepare-common.outputs.plan }}\n      release: ${{ needs.validate.outputs.release == 'true' }}\n      version: ${{ needs.validate.outputs.version }}\n      tag: ${{ needs.prepare-common.outputs.matrix }}\n",
	planReferenceProblems
);
for (const [what, file, from, to] of [
	['missing Common workflow call', ENTRY, '    uses: ./.github/workflows/ci-common.yml\n', ''],
	[
		'redirected Common workflow call',
		ENTRY,
		'./.github/workflows/ci-common.yml',
		'./.github/workflows/foreign.yml'
	],
	[
		'dropped Common plan input',
		ENTRY,
		pipeline.job('core'),
		pipeline.job('core').replace('      tag: ${{ needs.validate.outputs.tag }}\n', '')
	],
	[
		'Common caller skips',
		ENTRY,
		"    name: 'YAML, shared code & web'\n",
		"    name: 'YAML, shared code & web'\n    if: false\n"
	],
	[
		'Common claims caller concurrency',
		COMMON_BOX,
		'\npermissions:\n',
		'\nconcurrency: caller-group\n\npermissions:\n'
	],
	['Common missing child', COMMON_BOX, '  shared-validation:\n', '  foreign:\n'],
	[
		'Common child skips',
		COMMON_BOX,
		'  shared-validation:\n',
		'  shared-validation:\n    if: false\n'
	],
	[
		'Common serializes fail-fast',
		COMMON_BOX,
		'      fail-fast: false\n      matrix: ' + COMMON_MATRIX,
		'      fail-fast: true\n      matrix: ' + COMMON_MATRIX
	],
	[
		'Common withdraws canonical matrix',
		COMMON_BOX,
		COMMON_MATRIX,
		`\${{ fromJSON('["js","properties"]') }}`
	],
	[
		'Common changes release binding',
		COMMON_BOX,
		pipeline.job('shared-validation'),
		pipeline
			.job('shared-validation')
			.replace(
				'      ERGOPTI_DEV_RELEASE_RELEASE: ${{ inputs.release }}\n',
				'      ERGOPTI_DEV_RELEASE_RELEASE: false\n'
			)
	],
	['Common changes input type', COMMON_BOX, '        type: boolean\n', '        type: string\n'],
	[
		'Common drops shared command',
		COMMON_BOX,
		'js) npm run test:js -- --feature "$FEATURE" ;;',
		'echo skipped-shared-validation'
	],
	[
		'Common omits prepare dependency',
		ENTRY,
		pipeline.job('core'),
		pipeline.job('core').replace('needs: [validate, prepare-common]', 'needs: [validate]')
	],
	[
		'Common omits a unit verdict prerequisite',
		COMMON_BOX,
		'    needs: [shared-validation]\n',
		'    needs: [prepare-common]\n'
	],
	[
		'Common browsers bypass exact unit union',
		COMMON_BOX,
		'      - name: Require every declared check exactly once\n',
		'      - name: Require every declared check exactly once\n        if: false\n'
	],
	[
		'Common substitutes matrix planner',
		ENTRY,
		'node tools/ci/js-feature-matrix.cjs plan',
		'node tools/ci/foreign-matrix.cjs'
	],
	[
		'Common drops planner identity',
		ENTRY,
		pipeline.job('prepare-common'),
		pipeline.job('prepare-common').replace('        id: plan\n', '        id: foreign\n')
	],
	[
		'Common changes feature input',
		COMMON_BOX,
		'          FEATURE: ${{ steps.common-lot.outputs.feature }}\n',
		'          FEATURE: foreign\n'
	],
	[
		'Common omits property dispatch',
		COMMON_BOX,
		'    properties) npm run test:properties ;;',
		'    properties) echo skipped ;;'
	],
	[
		'Common omits mutation dispatch',
		COMMON_BOX,
		'    mutation) npm run test:mutation ;;',
		'    mutation) echo skipped ;;'
	],
	[
		'Common omits qualified union consumer',
		COMMON_BOX,
		'node tools/ci/validate-js-feature-results.cjs feature-timings',
		'echo skipped-union'
	],
	[
		'Common substitutes qualification artifact',
		COMMON_BOX,
		'          name: assets-qualification-core-js\n          path: qualification',
		'          name: unrelated-qualification\n          path: qualification'
	],
	[
		'Common substitutes feature artifacts',
		COMMON_BOX,
		'          pattern: core-js-timings-*\n',
		'          pattern: unrelated-timings-*\n'
	],
	[
		'Common drops browser command',
		COMMON_BOX,
		'npm run test:browser:physical-shortcuts',
		'echo skipped-physical-browser'
	]
])
	mustCatch(what, file, from, to, commonProblems);

/**
 * Reject additional issuers, missing consumers and changed readonly union
 * commands. The Unit stage file issues the receipt; the E2E stage file reads it.
 */
function checkCommonReceiptConsumer() {
	const COMMON_UNIT = '.github/workflows/ci-common-unit.yml';
	const COMMON_E2E = '.github/workflows/ci-common-e2e.yml';
	const owners = scoped.contract.receipt_consumers.filter((owner) => owner.file === COMMON_E2E);
	assert.equal(owners.length, 1);
	const owner = owners[0];
	assert.equal(owner.job, 'common-e2e');
	assert.equal(owner.scope, 'core-js-suite');
	assert.equal(owner.issuer_file, COMMON_UNIT);
	assert.equal(owner.issuer_job, 'shared-validation');
	assert.equal(owner.issuer_step, 'Run shared validation suite');
	assert.equal(owner.issuer_command, 'npm run test:js');
	const source = pipeline.rawFiles().find((entry) => entry.rel === COMMON_E2E).text;
	const unit = pipeline.rawFiles().find((entry) => entry.rel === COMMON_UNIT).text;
	const job = pipeline.jobsOfText(source, COMMON_E2E).find((entry) => entry.id === owner.job);
	const step = pipeline.step(job.body, owner.step);
	assert.equal(pipeline.runOf(step).join('\n'), owner.body);
	assert.ok(scoped.projectScopedSteps(source, COMMON_E2E));
	assert.ok(scoped.projectScopedSteps(unit, COMMON_UNIT));
	const retained = scoped.contract.retained_steps.filter((entry) => entry.file === COMMON_UNIT);
	assert.equal(retained.length, 2);
	for (const entry of retained) {
		const child = pipeline
			.jobsOfText(unit, COMMON_UNIT)
			.find((candidate) => candidate.id === entry.job);
		const transport = pipeline.step(child.body, entry.name).replace(/\n+$/, '');
		assert.match(transport, /^ {10}overwrite: true$/m);
		assert.equal(
			isRetainedQualification(
				{ rel: COMMON_UNIT },
				{ id: entry.job },
				{ name: entry.name, body: transport }
			),
			true
		);
		const missingOverwrite = transport.replace('          overwrite: true', '');
		assert.notEqual(missingOverwrite, transport);
		assert.throws(() =>
			isRetainedQualification(
				{ rel: COMMON_UNIT },
				{ id: entry.job },
				{ name: entry.name, body: missingOverwrite }
			)
		);
	}
	for (const [before, after] of [
		[owner.step, 'Unknown readonly consumer'],
		[
			'--validate-scope-receipt qualification/stable-core-js-suite.json',
			'--receipt qualification/stable-core-js-suite.json'
		],
		[
			'node tools/ci/validate-js-feature-results.cjs feature-timings',
			'node tools/ci/validate-js-feature-results.cjs feature-timings || true'
		],
		['node tools/ci/validate-js-feature-results.cjs feature-timings', 'echo skipped-union']
	]) {
		const changed = source.replace(before, after);
		assert.notEqual(changed, source);
		assert.throws(() => scoped.projectScopedSteps(changed, COMMON_E2E));
	}
	assert.throws(() => scoped.projectScopedSteps(source.replace(step, ''), COMMON_E2E));
	const unknown =
		'      - name: Unknown receipt reader\n        run: node tools/ci/dev-release-qualification.cjs --scope core-js-suite --validate-scope-receipt qualification/stable-core-js-suite.json\n';
	assert.throws(() => scoped.projectScopedSteps(source.replace(step, step + unknown), COMMON_E2E));
}
checkCommonReceiptConsumer();

// Release waits for every original job: its caller in ci.yml must reach every
// other job of ci.yml through needs, and inside ci-release.yml publication
// waits for the preflight. The dispatch-only verdict cannot run on a release
// push and is checked independently below.
const topJobs = pipeline.jobs(ENTRY);
const needsById = new Map(
	topJobs.map((candidate) => [candidate.id, pipeline.needsOf(candidate.body)])
);
const awaited = new Set();
const pending = [...(needsById.get(PUBLICATION) ?? [])];
while (pending.length > 0) {
	const id = pending.pop();
	if (awaited.has(id)) continue;
	awaited.add(id);
	pending.push(...(needsById.get(id) ?? []));
}
for (const candidate of topJobs) {
	if (candidate.id !== PUBLICATION && !awaited.has(candidate.id)) {
		errors.push(`release can publish without waiting for ${candidate.id}`);
	}
}
if (pipeline.field(pipeline.job(PUBLICATION), 'uses') !== `./${RELEASE_BOX}`)
	errors.push(`${PUBLICATION} must call ${RELEASE_BOX}`);
if (
	JSON.stringify(pipeline.needsOf(pipeline.job('release'))) !== JSON.stringify(['publication-plan'])
)
	errors.push('release must wait for its publication preflight');

// ============================================
// ============================================
// ======= 3/ One Root, One Lane Per OS =======
// ============================================
// ============================================

/**
 * Lists every way the run graph could stop reading as one root, one lane per
 * OS and one release. GitHub draws no box around a called workflow: it
 * flattens its jobs into the run's graph, so a second job without needs in a
 * lane is a second edge from the root, and a second job nothing needs is a
 * second edge into the release. Release still needs the root: it reads the
 * plan from it, and a plan handed through the lanes' outputs would depend on
 * those outputs surviving "Re-run failed jobs", where a lost value skips the
 * release instead of failing it.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
// Exact intended independent receiver from the previously reviewed manual enrollment design.

/**
 * Each lane's jobs in file order, with the exact needs and the stage of each.
 * Stages follow one another except for declared parallel siblings: the Linux
 * Flatpak job builds from the package beside the install cells, and the
 * verdict waits for both; the macOS Build packages after Unit beside E2E, and
 * the test build waits for both.
 */
const LANE_GRAPHS = {
	[MACOS_BOX]: [
		['test-hs', [], 'unit'],
		['e2e-hs', ['test-hs'], 'e2e'],
		['package-macos', ['test-hs'], 'build'],
		['launch', ['e2e-hs', 'package-macos'], 'testbuild'],
		['macos-ok', ['launch'], 'verdict']
	],
	[WINDOWS_BOX]: [
		['test-ahk', [], 'unit'],
		['e2e-ahk', ['test-ahk'], 'e2e'],
		['package-windows', ['e2e-ahk'], 'build'],
		['launch-windows', ['package-windows'], 'testbuild'],
		['windows-ok', ['launch-windows'], 'verdict']
	],
	[LINUX_BOX]: [
		['test-linux', [], 'unit'],
		['e2e-linux', ['test-linux'], 'e2e'],
		['package-linux', ['e2e-linux'], 'build'],
		['package-flatpak', ['package-linux'], 'build'],
		['install-linux', ['package-linux'], 'testbuild'],
		['linux-ok', ['install-linux', 'package-flatpak'], 'verdict']
	]
};

function graphProblems(files) {
	const problems = [];
	const topLevel = pipeline.jobsOfText(files.find((entry) => entry.rel === ENTRY).text, ENTRY);
	const roots = topLevel
		.filter((candidate) => pipeline.needsOf(candidate.body).length === 0)
		.map((candidate) => candidate.id);
	if (JSON.stringify(roots) !== JSON.stringify(['prepare-common', ROOT])) {
		problems.push(
			`ci.yml must have exactly the formatter and release-plan roots, ${ROOT}, that needs nothing; got [${roots.join(', ')}]`
		);
	}
	const lanes = topLevel.filter(
		(candidate) => pipeline.field(candidate.body, 'uses') !== null && candidate.id !== PUBLICATION
	);
	for (const lane of lanes) {
		const needs = pipeline.needsOf(lane.body);
		if (JSON.stringify(needs) !== JSON.stringify([ROOT, 'prepare-common'])) {
			problems.push(
				`caller ${lane.id} must need the formatter and release-plan roots, [${ROOT}], so the root fans out to one job per lane; got [${needs.join(', ')}]`
			);
		}
	}
	const releaseEntry = files.find((entry) => entry.rel === RELEASE_BOX);
	const releaseJobs = releaseEntry ? pipeline.jobsOfText(releaseEntry.text, RELEASE_BOX) : [];
	const release = releaseJobs.find((candidate) => candidate.id === 'release');
	const releaseNeeds = release ? [...pipeline.needsOf(release.body)].sort() : [];
	const expectedRelease = ['publication-plan'];
	if (JSON.stringify(releaseNeeds) !== JSON.stringify(expectedRelease)) {
		problems.push(
			`release must need exactly its publication preflight, [${expectedRelease.join(', ')}]; got [${releaseNeeds.join(', ')}]`
		);
	}
	const preflight = releaseJobs.find((candidate) => candidate.id === 'publication-plan');
	if (!preflight || pipeline.needsOf(preflight.body).length !== 0) {
		problems.push(`the publication preflight must be the entry of ${RELEASE_BOX}`);
	}
	if (
		JSON.stringify(releaseJobs.map((job) => job.id)) !==
		JSON.stringify(['publication-plan', 'release'])
	) {
		problems.push(`${RELEASE_BOX} must contain only the publication preflight and release`);
	}
	const verdict = topLevel.find((candidate) => candidate.id === PUBLICATION);
	if (
		!verdict ||
		pipeline.field(verdict.body, 'uses') !== `./${RELEASE_BOX}` ||
		JSON.stringify(pipeline.needsOf(verdict.body)) !==
			JSON.stringify(['macos', 'windows', 'linux', 'core'])
	) {
		problems.push('the release caller must wait for the shared core and every OS result');
	}
	if (
		topLevel.length !== 7 ||
		topLevel.some(
			(job) =>
				!['prepare-common', 'validate', 'core', 'macos', 'windows', 'linux', PUBLICATION].includes(
					job.id
				)
		)
	) {
		problems.push('ci.yml must contain only the plan roots, the four lane callers and Release');
	}
	for (const rel of BOXES) {
		const entry = files.find((candidate) => candidate.rel === rel);
		if (!entry) {
			problems.push(`${rel} is not part of the pipeline`);
			continue;
		}
		const jobs = pipeline.jobsOfText(entry.text, rel);
		const graph = LANE_GRAPHS[rel];
		const sequence = graph.map(([id]) => id);
		if (JSON.stringify(jobs.map((job) => job.id)) !== JSON.stringify(sequence)) {
			problems.push(
				`${rel} must expose unit tests, E2E, package, installed launch and verdict in order`
			);
		}
		for (const [id, expected, stage] of graph) {
			const job = jobs.find((candidate) => candidate.id === id);
			if (!job || JSON.stringify(pipeline.needsOf(job.body)) !== JSON.stringify(expected)) {
				problems.push(`${rel} ${id} must need exactly ${expected.join(', ')}`);
			}
			if (job && rel !== MACOS_BOX && stage !== 'unit' && stage !== 'verdict') {
				const expectedOutputs = [
					'    outputs:',
					...(id === 'package-linux'
						? [
								'      install_matrix: ${{ steps.install-plan.outputs.matrix }}',
								'      install_metadata: ${{ steps.install-plan.outputs.metadata }}'
							]
						: []),
					'      ci_predecessors: ${{ toJSON(needs) }}',
					'      ci_source_sha: ${{ github.sha }}',
					'      ci_run_id: ${{ github.run_id }}',
					'      ci_attempt: ${{ github.run_attempt }}',
					...(id === 'e2e-linux' ? ['      ci_unit_result: ${{ needs.test-linux.result }}'] : [])
				].join('\n');
				const blocks = [...job.body.matchAll(/^ {4}outputs:\n((?: {6}[^\n]*(?:\n|$)|\n)*)/gm)];
				if (blocks.length !== 1 || blocks[0][0].trimEnd() !== expectedOutputs)
					problems.push(`${rel} ${id} must retain genuine adjacent scheduler custody`);
			}
			if (job && pipeline.field(job.body, 'continue-on-error') !== null) {
				problems.push(`${rel} ${id} must remain a mandatory phase`);
			}
			const expectedCondition =
				stage === 'verdict'
					? 'always()'
					: rel === LINUX_BOX && id === 'package-linux'
						? "${{ !cancelled() && needs.e2e-linux.outputs.ci_unit_result == 'success' && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}"
						: null;
			if (job && pipeline.field(job.body, 'if') !== expectedCondition) {
				problems.push(
					`${rel} ${id} must retain its exact mandatory or manual diagnostic admission`
				);
			}
		}
		if (rel === MACOS_BOX) problems.push(...macStageProblems(entry.text));
		const needsOfJob = new Map(
			jobs.map((candidate) => [candidate.id, pipeline.needsOf(candidate.body)])
		);
		const entries = jobs
			.filter((candidate) => needsOfJob.get(candidate.id).length === 0)
			.map((candidate) => candidate.id);
		const needed = new Set([...needsOfJob.values()].flat());
		const exits = jobs
			.filter((candidate) => !needed.has(candidate.id))
			.map((candidate) => candidate.id);
		if (JSON.stringify(entries) !== JSON.stringify([sequence[0]]))
			problems.push(rel + ' must retain exactly its unit entry.');
		if (JSON.stringify(exits) !== JSON.stringify([sequence.at(-1)]))
			problems.push(rel + ' must retain exactly its final verdict exit.');
		for (const [id, needs] of needsOfJob) {
			for (const need of needs) {
				if (!needsOfJob.has(need))
					problems.push(`${rel} job ${id} needs ${need}, which is not a job of its file`);
			}
		}
	}
	return problems;
}

for (const role of [
	'tooltip-canvas',
	'managed-ollama-native',
	'cold-bootstrap-native',
	'item36-native',
	'lease-silence-native'
]) {
	const source = pipeline.file(MACOS_BOX);
	const stage = macRole.stage[role];
	const job = pipeline.jobsOfText(source, MACOS_BOX).find((job) => job.id === stage);
	const steps = macRole.selected(job.body, role);
	const first = steps[0].body;
	const predicate = pipeline.stepField(first, 'if');
	for (const [label, altered] of [
		['missing role', ''],
		['duplicate role', first + '\n' + first],
		[
			'reassigned role',
			first.replace("env.MACOS_STAGE_ROLE == '" + role + "'", "env.MACOS_STAGE_ROLE == 'foreign'")
		],
		['conditional role', first.replace(predicate, 'false')],
		['forgiven role', first + '\n        continue-on-error: true'],
		['broad manual admission', first.replace(predicate, 'always()')]
	])
		mustCatch(role + ': ' + label, MACOS_BOX, first, altered, graphProblems);
	for (const [label, property] of [
		['cross-lane prerequisite', '    needs: test-linux\n'],
		['cycle', '    needs: ' + stage + '\n'],
		['release output', '    outputs:\n      assets: fake\n'],
		['inherited secret', '    secrets: inherit\n']
	])
		mustCatch(
			role + ': ' + label,
			MACOS_BOX,
			'  ' + stage + ':\n',
			'  ' + stage + ':\n' + property,
			graphProblems
		);
}
for (const [label, before, after] of [
	[
		'lease source runner wrong',
		'tools/diagnostics/run_lease_silence_native.sh',
		'tools/diagnostics/foreign_native.sh'
	],
	[
		'lease closed parser omitted',
		'node tools/test/test-lease-silence-xctest-evidence.cjs',
		'echo omitted'
	],
	[
		'lease status absent',
		'            ${{ runner.temp }}/lease-silence-native/swift-status.txt\n',
		''
	],
	[
		'native runner authority',
		pipeline.job('e2e-hs'),
		pipeline
			.job('e2e-hs')
			.replace(
				'runs-on: ${{ fromJSON(needs.test-hs.outputs.e2e_metadata)[matrix.lot].runner }}',
				'runs-on: ubuntu-latest'
			)
	],
	[
		'native timeout authority',
		pipeline.job('e2e-hs'),
		pipeline
			.job('e2e-hs')
			.replace(
				'timeout-minutes: ${{ fromJSON(needs.test-hs.outputs.e2e_metadata)[matrix.lot].timeout_minutes }}',
				'timeout-minutes: 360'
			)
	]
])
	mustCatch(label, MACOS_BOX, before, after, graphProblems);

// Independent Linux suites still gate packaging and the mandatory verdict.
// Ordered Linux suites still gate packaging and the mandatory verdict.
for (const [what, from, to] of [
	[
		'Linux E2E omits its unit prerequisite',
		"  e2e-linux:\n    name: 'E2E tests'\n    needs: [test-linux]\n",
		"  e2e-linux:\n    name: 'E2E tests'\n"
	],
	[
		'Linux package omits units',
		'      ci_unit_result: ${{ needs.test-linux.result }}\n',
		'      ci_unit_result: success\n'
	],
	['Linux package omits E2E', '    needs: [e2e-linux]\n', '    needs: []\n'],
	[
		'Linux package forgives failed units',
		"needs.e2e-linux.outputs.ci_unit_result == 'success' && ",
		''
	],
	[
		'Linux package drops manual failed-E2E diagnostics',
		" || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')",
		''
	],
	[
		'Linux package admits failed E2E automatically',
		"(github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')",
		"(needs.e2e-linux.result == 'failure')"
	]
]) {
	mustCatch(what, LINUX_BOX, from, to, graphProblems);
}

// Unit completion precedes E2E, and neither conditions nor forgiveness may
// turn any required phase into a silent success.
for (const [rel, id, unit] of [
	[WINDOWS_BOX, 'e2e-ahk', 'test-ahk'],
	[MACOS_BOX, 'e2e-hs', 'test-hs'],
	[LINUX_BOX, 'e2e-linux', 'test-linux']
]) {
	const prerequisite =
		rel === MACOS_BOX
			? `      actions: read\n    needs:\n      - ${unit}\n    runs-on: \${{ fromJSON(needs.${unit}`
			: `    needs: [${unit}]\n`;
	for (const suffix of ['    if: false\n', '    continue-on-error: true\n']) {
		mustCatch(
			`${id} must remain mandatory`,
			rel,
			prerequisite,
			rel === MACOS_BOX
				? prerequisite.replace('    runs-on:', suffix + '    runs-on:')
				: prerequisite + suffix,
			graphProblems
		);
	}
}

errors.push(...graphProblems(pipeline.files()));
// E2E and Build both read Actions evidence and need Unit; each anchor names its own runner.
const MACOS_E2E_NEEDS =
	'      actions: read\n    needs:\n      - test-hs\n    runs-on: ${{ fromJSON(needs.test-hs';
const MACOS_BUILD_NEEDS =
	'      actions: read\n    needs:\n      - test-hs\n    runs-on: macos-latest\n';
for (const [what, rel, from, to] of [
	[
		'a second root in ci.yml',
		ENTRY,
		'\njobs:\n',
		'\njobs:\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo lint\n'
	],
	[
		'a caller that no longer needs the root',
		ENTRY,
		"    name: 'Linux'\n    needs: [validate, prepare-common]\n",
		"    name: 'Linux'\n"
	],
	[
		'a caller that also needs another lane',
		ENTRY,
		"    name: 'Windows'\n    needs: [validate, prepare-common]\n",
		"    name: 'Windows'\n    needs: [validate, macos]\n"
	],
	[
		'release that no longer waits for a lane',
		ENTRY,
		'    needs:\n      - macos\n      - windows\n      - linux\n      - core\n',
		'    needs: [core, macos, windows]\n'
	],
	[
		'release that stops reading the plan from the root',
		RELEASE_BOX,
		'    needs: [publication-plan]\n',
		'    needs: [macos, windows, linux]\n'
	],
	[
		'a sixth entry in the macOS lane',
		MACOS_BOX,
		MACOS_E2E_NEEDS,
		MACOS_E2E_NEEDS.replace('    needs:\n      - test-hs\n', '')
	],
	[
		'macOS packaging stops waiting for units',
		MACOS_BOX,
		MACOS_BUILD_NEEDS,
		MACOS_BUILD_NEEDS.replace('    needs:\n      - test-hs\n', '    needs: []\n')
	],
	[
		'macOS packaging waits for E2E again',
		MACOS_BOX,
		MACOS_BUILD_NEEDS,
		MACOS_BUILD_NEEDS.replace('      - test-hs\n', '      - e2e-hs\n')
	],
	[
		'native canvas stops waiting for units',
		MACOS_BOX,
		MACOS_E2E_NEEDS,
		MACOS_E2E_NEEDS.replace('    needs:\n      - test-hs\n', '    needs: []\n')
	],
	[
		'native canvas stops waiting for E2E',
		MACOS_BOX,
		MACOS_E2E_NEEDS,
		MACOS_E2E_NEEDS.replace('      - test-hs\n', '      - package-macos\n')
	],
	[
		'macOS E2E omits its unit prerequisite',
		MACOS_BOX,
		MACOS_E2E_NEEDS,
		MACOS_E2E_NEEDS.replace('    needs:\n      - test-hs\n', '')
	],
	[
		'macOS test build stops waiting for E2E',
		MACOS_BOX,
		'    needs:\n      - e2e-hs\n      - package-macos\n',
		'    needs:\n      - package-macos\n'
	],
	[
		'macOS test build stops waiting for Build',
		MACOS_BOX,
		'    needs:\n      - e2e-hs\n      - package-macos\n',
		'    needs:\n      - e2e-hs\n'
	],
	[
		'a third entry in the Linux lane',
		LINUX_BOX,
		"    name: 'Install and launch'\n    needs: [package-linux]\n    runs-on: ubuntu-latest\n",
		"    name: 'Install and launch'\n    runs-on: ubuntu-latest\n"
	],
	['a third entry in the Windows lane', WINDOWS_BOX, '    needs: [e2e-ahk]\n', ''],
	[
		'Windows packaging stops waiting for unit tests',
		WINDOWS_BOX,
		"  e2e-ahk:\n    name: 'E2E tests'\n    needs: [test-ahk]\n    runs-on: windows-latest\n    outputs:\n      ci_predecessors: ${{ toJSON(needs) }}\n",
		"  e2e-ahk:\n    name: 'E2E tests'\n    needs: [test-ahk]\n    runs-on: windows-latest\n    outputs:\n      ci_predecessors: success\n"
	],
	[
		'Windows packaging stops waiting for E2E tests',
		WINDOWS_BOX,
		'    needs: [e2e-ahk]\n',
		'    needs: [test-ahk]\n'
	],
	[
		'Windows E2E omits its unit prerequisite',
		WINDOWS_BOX,
		"  e2e-ahk:\n    name: 'E2E tests'\n    needs: [test-ahk]\n",
		"  e2e-ahk:\n    name: 'E2E tests'\n"
	],
	[
		'a second exit in the macOS lane',
		MACOS_BOX,
		'    needs:\n      - launch\n',
		'    needs:\n      - test-hs\n'
	],
	[
		'a second exit in the Linux lane',
		LINUX_BOX,
		'    needs: [install-linux, package-flatpak]\n    if: always()\n',
		'    if: always()\n'
	]
]) {
	mustCatch(what, rel, from, to, graphProblems);
}

// ==========================================
// ==========================================
// ======= 4/ Every Job Gates The Run =======
// ==========================================
// ==========================================

/**
 * Lists how a job of ci.yml could skip or forgive a lane. A skipped lane skips
 * release too, so a pull request shows green without that OS and a push to
 * dev or main silently publishes nothing; a forgiven job lets the run pass red.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function topJobProblems(files) {
	const problems = [];
	const jobs = [ENTRY, RELEASE_BOX].flatMap((rel) => {
		const entry = files.find((candidate) => candidate.rel === rel);
		if (!entry) {
			problems.push(`${rel} is not part of the pipeline`);
			return [];
		}
		return pipeline.jobsOfText(entry.text, rel);
	});
	for (const candidate of jobs) {
		const expected =
			candidate.file === RELEASE_BOX && candidate.id === 'release'
				? RELEASE_IF
				: candidate.file === ENTRY && candidate.id === PUBLICATION
					? MANUAL_VERDICT_IF
					: candidate.file === ENTRY && ['windows', 'macos', 'linux'].includes(candidate.id)
						? LANE_IF(candidate.id)
						: null;
		const condition = pipeline.field(candidate.body, 'if');
		if (condition !== expected) {
			problems.push(
				expected === null
					? `${candidate.file} job ${candidate.id} must set no job-level if (got: ${condition}): a skipped lane reads as green`
					: `${candidate.file} job ${candidate.id} must keep exactly if: ${expected}, got: ${condition}`
			);
		}
		const forgiven = pipeline.field(candidate.body, 'continue-on-error');
		if (forgiven !== null) {
			problems.push(
				`${candidate.file} job ${candidate.id} sets continue-on-error: ${forgiven}; its failure must fail the run`
			);
		}
	}
	if (!jobs.some((candidate) => candidate.file === RELEASE_BOX && candidate.id === 'release'))
		problems.push(`${RELEASE_BOX} has no release job`);
	return problems;
}

/**
 * Rejects permissions outside each exact role: three Common custody jobs, and
 * the macOS caller with its E2E stage (whose managed Ollama cells receive the
 * parallel clean build artifact) and its Build (which waits beside E2E for the
 * qualified native inputs), may read Actions evidence; release and its caller
 * in ci.yml alone may write repository contents.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function permissionProblems(files) {
	const problems = [];
	const evidenceReaders = new Set([
		`${ENTRY}:core`,
		`${COMMON_BOX}:common-e2e`,
		`${COMMON_BOX}:common-unit-verdict`,
		`${ENTRY}:macos`,
		`${MACOS_BOX}:e2e-hs`,
		`${MACOS_BOX}:package-macos`
	]);
	for (const entry of files) {
		const lines = entry.text.split('\n');
		const at = lines.findIndex((line) => /^permissions:/.test(line));
		const granted = [];
		if (at >= 0) {
			const inline = lines[at].replace(/^permissions:/, '').trim();
			if (inline !== '') granted.push(inline);
			for (let index = at + 1; index < lines.length; index++) {
				if (lines[index].trim() === '' || lines[index].trimStart().startsWith('#')) continue;
				if (!/^\s/.test(lines[index])) break;
				granted.push(lines[index].trim());
			}
		}
		if (granted.join(', ') !== 'contents: read') {
			problems.push(
				`${entry.rel} must grant exactly permissions: contents: read, got: ${granted.join(', ') || 'none'}`
			);
		}
		for (const candidate of pipeline.jobsOfText(entry.text, entry.rel)) {
			const value = pipeline.field(candidate.body, 'permissions');
			const expected =
				(entry.rel === RELEASE_BOX && candidate.id === 'release') ||
				(entry.rel === ENTRY && candidate.id === PUBLICATION)
					? 'contents: write'
					: evidenceReaders.has(`${entry.rel}:${candidate.id}`)
						? 'contents: read actions: read'
						: null;
			if (value !== expected) {
				problems.push(
					`${entry.rel} job ${candidate.id} must ${expected ? `grant exactly ${expected}` : 'not widen the permissions'}, got: ${value}`
				);
			}
		}
	}
	return problems;
}

// The independent benchmark also receives a repository token on every main push.
// Include it here even though it is not called by the release workflow.
const benchmarkWorkflow = {
	rel: '.github/workflows/bench.yml',
	text: fs.readFileSync(path.resolve(__dirname, '../../.github/workflows/bench.yml'), 'utf8')
};
errors.push(
	...topJobProblems(pipeline.files()),
	...permissionProblems([...pipeline.files(), benchmarkWorkflow])
);
for (const [what, from, to] of [
	['if: false on the Windows caller', '  windows:\n', '  windows:\n    if: false\n'],
	[
		'a push-only condition on the Linux caller',
		'  linux:\n',
		"  linux:\n    if: github.event_name == 'push'\n"
	],
	['always() on the macOS caller', '  macos:\n', '  macos:\n    if: always()\n'],
	['if: false on validate', '  validate:\n', '  validate:\n    if: false\n'],
	['continue-on-error on validate', '  validate:\n', '  validate:\n    continue-on-error: true\n'],
	[
		'continue-on-error on the Windows caller',
		'  windows:\n',
		'  windows:\n    continue-on-error: true\n'
	],
	[
		'continue-on-error on the Release caller',
		`  ${PUBLICATION}:\n`,
		`  ${PUBLICATION}:\n    continue-on-error: true\n`
	],
	['if: false on the Release caller', `    if: ${MANUAL_VERDICT_IF}\n`, '    if: false\n']
]) {
	mustCatch(what, ENTRY, from, to, topJobProblems);
}
for (const [what, from, to] of [
	['continue-on-error on release', '  release:\n', '  release:\n    continue-on-error: true\n'],
	[
		'a status function in release.if',
		`    if: ${RELEASE_IF}\n`,
		`    if: \${{ always() && ${RELEASE_IF} }}\n`
	],
	['if: false on the preflight', '  publication-plan:\n', '  publication-plan:\n    if: false\n']
]) {
	mustCatch(what, RELEASE_BOX, from, to, topJobProblems);
}
for (const [what, rel, from, to] of [
	['missing token permissions', ENTRY, 'permissions:\n  contents: read\n', ''],
	[
		'write-all at the top of ci.yml',
		ENTRY,
		'permissions:\n  contents: read\n',
		'permissions: write-all\n'
	],
	[
		'contents: write for a lane',
		LINUX_BOX,
		'permissions:\n  contents: read\n',
		'permissions:\n  contents: write\n'
	],
	[
		'a write grant on a caller',
		ENTRY,
		"    name: 'macOS'\n",
		"    name: 'macOS'\n    permissions:\n      contents: write\n"
	],
	[
		'a write grant on the preflight',
		RELEASE_BOX,
		"    name: 'Verify all lanes and original plan'\n",
		"    name: 'Verify all lanes and original plan'\n    permissions:\n      contents: write\n"
	],
	[
		'write-all at the top of ci-release.yml',
		RELEASE_BOX,
		'permissions:\n  contents: read\n',
		'permissions: write-all\n'
	]
]) {
	mustCatch(what, rel, from, to, permissionProblems);
}

assert.deepEqual(
	permissionProblems([...pipeline.files(), benchmarkWorkflow]),
	[],
	'Only exact Common evidence readers and release may override workflow permissions.'
);
for (const [rel, id] of [
	[ENTRY, 'core'],
	[COMMON_BOX, 'common-e2e'],
	[COMMON_BOX, 'common-unit-verdict']
]) {
	const matches = pipeline.jobsOfText(pipeline.file(rel), rel).filter((job) => job.id === id);
	assert.equal(matches.length, 1, id + ' has one actual permission owner');
	const body = matches[0].body;
	const grant = '    permissions:\n      contents: read\n      actions: read\n';
	assert.equal(body.split(grant).length, 2, id + ' has one exact evidence grant');
	for (const [label, replacement] of [
		['missing evidence permission', ''],
		['repository write permission', grant.replace('contents: read', 'contents: write')],
		['Actions write permission', grant.replace('actions: read', 'actions: write')],
		['extra permission', grant + '      checks: read\n'],
		['all write permissions', '    permissions: write-all\n'],
		['duplicate permission', grant + grant]
	])
		mustCatch(id + ' ' + label, rel, body, body.replace(grant, replacement), permissionProblems);
}
for (const [rel, id] of [
	[ENTRY, 'validate'],
	[ENTRY, 'prepare-common'],
	[ENTRY, 'windows'],
	[ENTRY, 'macos'],
	[ENTRY, 'linux'],
	[COMMON_BOX, 'shared-validation'],
	[COMMON_BOX, 'common-build'],
	[COMMON_BOX, 'common-testbuild'],
	[WINDOWS_BOX, 'launch-windows'],
	[MACOS_BOX, 'launch'],
	[LINUX_BOX, 'install-linux']
]) {
	const matches = pipeline.jobsOfText(pipeline.file(rel), rel).filter((job) => job.id === id);
	assert.equal(matches.length, 1, id + ' has one actual unrelated job');
	const body = matches[0].body;
	mustCatch(
		id + ' cannot inherit a Common evidence grant',
		rel,
		body,
		'    permissions:\n      contents: read\n      actions: read\n' + body,
		permissionProblems
	);
}

// ============================================
// ============================================
// ======= 5/ The Windows Gating Suites =======
// ============================================
// ============================================

// Unit/native gates belong to test-ahk and the engine harness to e2e-ahk.
// Both run on every profile, before packaging in a fresh workspace. Each
// must keep the failing exit of its failure branch.
const WINDOWS_GATES = [
	{
		name: 'Install the shipped Kana layout for real probes',
		run: './tools/test/install-ci-kana-layout.ps1'
	},
	{
		name: 'Build and test native navigation event owner',
		run: './tools/build/build_windows_nav_owner.ps1'
	},
	{
		name: 'Manifest parity (AHK ↔ HS codegen equivalence)',
		run: 'npm run test:manifest-parity'
	},
	{
		name: 'Verify AHK source encoding (UTF-8 BOM + LF)',
		exits: [['if ($failures.Count -gt 0) {', '1']]
	},
	{
		name: 'Run AHK test suite',
		uses: [
			'tests\\run_all.ahk',
			'tools\\test\\validate-ahk-suite-manifest.cjs',
			'tools\\test\\test-ahk-suite-manifest.cjs" --ahk $ahk'
		],
		exits: [
			['if ($manifestExit -ne 0) {', '$manifestExit'],
			['if ($exit -ne 0) {', '$exit']
		]
	},
	{
		name: 'Run isolated AHK LLM suites',
		uses: ['run_llm_model_browser.ahk', 'run_llm_model_menu_disabled.ahk'],
		exits: [['if ($failed -gt 0) {', '1']]
	},
	{
		name: 'Check for AHK compiler warnings',
		uses: ['tests\\run_all.ahk', '--dry-run'],
		exits: [
			['if ($errors) {', '1'],
			['if ($warnings) {', '1']
		]
	},
	{
		name: 'Run E2E suite (Strategy A — pure engine injection)',
		job: 'e2e-ahk',
		uses: ['tests\\e2e\\run_e2e.ahk'],
		exits: [['if ($exit -ne 0) {', '$exit']]
	}
];

const testAhkAt = attempt(() => pipeline.locate('test-ahk'));
if (testAhkAt !== null && testAhkAt.file !== WINDOWS_BOX) {
	errors.push(`test-ahk must be a job of ${WINDOWS_BOX}, found in ${testAhkAt.file}`);
}
for (const gate of WINDOWS_GATES) {
	const found = attempt(() => pipeline.step(pipeline.job(gate.job ?? 'test-ahk'), gate.name));
	if (!found) {
		errors.push(
			`"${gate.name}" must run in job test-ahk of ${WINDOWS_BOX}, which runs on every run`
		);
		continue;
	}
	for (const key of ['if', 'continue-on-error']) {
		if (pipeline.stepField(found, key) !== null)
			errors.push(`"${gate.name}" gates the Windows box and must not set ${key}`);
	}
	if (gate.run && pipeline.stepField(found, 'run') !== gate.run) {
		errors.push(
			`"${gate.name}" must run exactly \`${gate.run}\`, got: ${pipeline.stepField(found, 'run')}`
		);
	}
	const script = pipeline.runOf(found) ?? [];
	const code = script.filter((line) => !line.trimStart().startsWith('#')).join('\n');
	for (const token of gate.uses ?? []) {
		if (!code.includes(token)) errors.push(`"${gate.name}" no longer runs ${token}`);
	}
	for (const [opener, exit] of gate.exits ?? []) {
		const block = attempt(() => pipeline.scriptBlock(script, opener));
		if (block !== null && !pipeline.blockExits(block, exit)) {
			errors.push(
				`"${gate.name}": the branch \`${opener}\` must end with exit ${exit}, so the failure fails the step`
			);
		}
	}
}

// The release build never consumes a cached build product: package-windows
// compiles and tests the shipped native helpers clean on every run, while the
// unit runners may share one build per exact input set.
const NATIVE_CACHE_KEY = 'windows-native-pac-unit-';
function buildCacheProblems(files) {
	const problems = [];
	const entry = files.find((file) => file.rel === WINDOWS_BOX);
	const jobs = entry ? pipeline.jobsOfText(entry.text, WINDOWS_BOX) : [];
	const build = jobs.find((job) => job.id === 'package-windows');
	if (!build) return ['package-windows is missing'];
	// Named or not, any step of the release build that uses a cache action.
	for (const line of build.body.split('\n'))
		if (/^\s*(?:-\s+)?uses:\s*['"]?actions\/cache(?:\/(?:restore|save))?@/.test(line))
			problems.push(
				`package-windows uses a cache (${line.trim()}); the release build compiles clean`
			);
	if (build.body.includes(NATIVE_CACHE_KEY))
		problems.push('package-windows reads the unit-runner native helper cache');
	const unit = jobs.find((job) => job.id === 'test-ahk');
	if (!unit || !unit.body.includes('key: ' + NATIVE_CACHE_KEY))
		problems.push('the unit-runner native PAC cache key changed; re-derive this rule');
	return problems;
}
{
	const found = buildCacheProblems(pipeline.files());
	errors.push(...found);
	const buildBody = pipeline.job('package-windows');
	const checkout = '      - uses: actions/checkout@v4\n';
	if (buildBody.split(checkout).length !== 2)
		errors.push('package-windows needs one checkout to anchor the cache refusal controls');
	else
		for (const [what, step] of [
			[
				'a restored native PAC build in package-windows',
				'      - name: Restore the native PAC evaluator built from these exact inputs\n        uses: actions/cache/restore@v4\n        with:\n          path: static/ergopti_plus/windows/vendor/ergopti_network_pac.exe\n          key: windows-native-pac-unit-x\n'
			],
			[
				'a cached build tree in package-windows',
				'      - name: Cache the build tree\n        uses: actions/cache@v4\n        with:\n          path: build\n          key: build-tree\n'
			],
			[
				'a saved build in package-windows',
				'      - name: Save the build\n        uses: actions/cache/save@v4\n        with:\n          path: build\n          key: build-tree\n'
			]
		])
			mustCatch(
				what,
				WINDOWS_BOX,
				buildBody,
				buildBody.replace(checkout, () => checkout + '\n' + step),
				buildCacheProblems
			);
}

// ==============================================
// ==============================================
// ======= 6/ No Step Can Switch A Gate Off =====
// ==============================================
// ==============================================

const conditionKey = (rel, job, name) => `${rel} job ${job} step "${name}"`;
const CONDITIONS = new Map(
	STEP_CONDITIONS.map(([rel, job, name, condition]) => [
		conditionKey(rel, job, name),
		rel === LINUX_BOX && job === HARNESS_JOB ? linuxRow(name, condition) : condition
	])
);
if (CONDITIONS.size !== STEP_CONDITIONS.length) errors.push('STEP_CONDITIONS names one step twice');
for (const job of macContract.jobs)
	for (const [index, step] of job.steps.entries()) {
		const key = conditionKey(MACOS_BOX, job.id, step.name || '@' + index);
		if (CONDITIONS.has(key)) assert.equal(CONDITIONS.get(key), step.if ?? null);
		CONDITIONS.set(key, step.if ?? null);
	}

/**
 * Lists every step of the pipeline that could be skipped, or whose gate could
 * fail without failing the step.
 * @param {Array<{rel: string, text: string}>} files The pipeline.
 * @returns {string[]}
 */
function stepProblems(files) {
	const problems = [];
	const unseen = new Set(CONDITIONS.keys());
	for (const entry of files) {
		for (const candidate of pipeline.jobsOfText(entry.text, entry.rel)) {
			for (const [index, found] of pipeline.steps(candidate.body).entries()) {
				const where = conditionKey(
					entry.rel,
					candidate.id,
					entry.rel === MACOS_BOX ? found.name || '@' + index : found.name
				);
				unseen.delete(where);
				const condition = pipeline.stepField(found.body, 'if');
				const expected = CONDITIONS.get(where) ?? null;
				const harness =
					entry.rel === LINUX_BOX &&
					candidate.id === HARNESS_JOB &&
					condition === linuxRow(found.name, NOT_CANCELLED);
				if (condition !== expected && !harness) {
					problems.push(
						expected === null
							? `${where} sets if: ${condition}; only the steps in STEP_CONDITIONS may be conditional`
							: `${where} must keep exactly if: ${expected}, got: ${condition}`
					);
				}
				for (const line of logicalLines(found.body)) {
					if (GATE_COMMAND.test(line) && SWALLOWED.test(line)) {
						problems.push(`${where} swallows the failure of a gate: ${line.slice(0, 160)}`);
					}
				}
				// GitHub runs a step with no shell: key as `bash -e`, without
				// pipefail, so `runner | tee log` reports tee's success.
				const code = (pipeline.runOf(found.body) ?? []).filter(
					(line) => !line.trimStart().startsWith('#')
				);
				// This condition admits one native SDK case, not a broader filtered cohort.
				if (
					where ===
					conditionKey(
						MACOS_BOX,
						'e2e-hs',
						'Observe the actual no-prompt SDK permission API independently'
					)
				) {
					const commands = logicalLines(found.body).filter((line) => /\bswift test\b/.test(line));
					const expectedCommand =
						'script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher' +
						' --scratch-path "$RUNNER_TEMP/swift-launcher-ci"' +
						" --filter 'OwnedAutomationQueryWorkerTests.testActualNoPromptPermissionAPIOnlyPublishesRetiredMetadata'" +
						' 2>&1 | tee "$transcript"';
					if (commands.length !== 1 || commands[0].replace(/\s+/g, ' ') !== expectedCommand)
						problems.push(
							`${where} must select only the original production-process SDK observation case`
						);
				}
				if (
					code.some((line) => /\|\s*tee\b/.test(line)) &&
					pipeline.stepField(found.body, 'shell') !== 'bash' &&
					!code.some((line) => /^\s*set -[a-z]*o pipefail\b/.test(line))
				) {
					problems.push(
						`${where} pipes into tee without pipefail (set -euo pipefail or shell: bash)`
					);
				}
			}
		}
	}
	for (const key of unseen)
		problems.push(`STEP_CONDITIONS lists ${key}, which the pipeline no longer has`);
	return problems;
}

const WINDOWS_FILE_RECEIVER_LINES = [
	'node "$root/tools/test/test-managed-ollama-protocol.cjs" --windows-file-port 1> $modelsOut 2> $modelsErr',
	'& "$windowsPowerShellDirectory/powershell.exe" -NoLogo -NoProfile -NonInteractive -File "$root/static/ergopti_plus/windows/tests/unit/modules/llm/servers/test_ollama_install_files.ps1" 1> $out 2> $err',
	'if ($modelsExit -ne 0) { throw "File component source models refused (exit $modelsExit)." }',
	'if ($nativeExit -ne 0 -or $stderr.Length -ne 0 -or'
];

// These two uploads retain failed component evidence; they do not admit
// skipping the actual file-component receiver or a conditional Windows lane.
function windowsFileRetentionProblems(files) {
	const steps = files
		.filter((entry) => entry.rel === WINDOWS_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'test-ahk')
		.flatMap((job) => pipeline.steps(job.body));
	const problems = [];
	const receivers = steps.filter((step) => step.name === 'Receive managed Ollama file component');
	const script = receivers.length === 1 ? pipeline.runOf(receivers[0].body).join('\n') : '';
	// This closed receiver uses ordinary statements. Multiline comments/strings
	// cannot witness execution; reject their unsupported delimiters locally.
	const commands = /<#|#>|@["']|["']@/.test(script)
		? []
		: receivers.length === 1
			? logicalLines(receivers[0].body)
			: [];
	if (
		receivers.length !== 1 ||
		pipeline.stepField(receivers[0].body, 'if') !== null ||
		!WINDOWS_FILE_RECEIVER_LINES.every((command) => commands.includes(command))
	)
		problems.push('managed Ollama file component receiver and both failing exits remain mandatory');
	for (const owner of WINDOWS_FILE_RETENTION) {
		const found = steps.filter((step) => step.name === owner.name);
		if (found.length !== 1) {
			problems.push(`${owner.name} must exist once in test-ahk`);
			continue;
		}
		const expected =
			`      - name: ${owner.name}\n` +
			`        if: ${owner.condition}\n` +
			'        uses: actions/upload-artifact@v4\n' +
			'        with:\n' +
			`          name: ${owner.artifact}\n` +
			'          path: |\n' +
			owner.paths.map((item) => `            ${item}\n`).join('') +
			'          if-no-files-found: error';
		if (found[0].body.replace(/\n+$/, '') !== expected)
			problems.push(
				`${owner.name} must retain its exact condition, upload action, source-bound name and paths`
			);
	}
	return problems;
}

errors.push(...windowsFileRetentionProblems(pipeline.files()));
for (const owner of WINDOWS_FILE_RETENTION) {
	const head = `      - name: ${owner.name}\n`;
	for (const changed of ['', 'false', 'success()', '${{ always() && false }}'])
		mustCatch(
			`managed component retention condition ${owner.name}: ${changed || '(none)'}`,
			WINDOWS_BOX,
			head + `        if: ${owner.condition}\n`,
			head + (changed ? `        if: ${changed}\n` : ''),
			stepProblems
		);
	const actual = pipeline.step(pipeline.job('test-ahk'), owner.name);
	for (const [description, from, to] of [
		['missing step', actual, ''],
		['renamed step', owner.name, 'Unowned managed component evidence'],
		['different action', 'actions/upload-artifact@v4', 'actions/upload-artifact@v3'],
		['missing evidence allowed', 'if-no-files-found: error', 'if-no-files-found: warn'],
		['unbound artifact', owner.artifact, 'unbound-component-evidence'],
		...owner.paths.map((item) => ['missing root', `            ${item}\n`, ''])
	])
		mustCatch(
			`${owner.name}: ${description}`,
			WINDOWS_BOX,
			actual,
			actual.replace(from, () => to),
			windowsFileRetentionProblems
		);
}
const componentHead = '      - name: Receive managed Ollama file component\n';
for (const condition of ['false', 'success()', 'inputs.release'])
	mustCatch(
		`managed file component receiver cannot be conditional: ${condition}`,
		WINDOWS_BOX,
		componentHead,
		componentHead + `        if: ${condition}\n`,
		windowsFileRetentionProblems
	);
const componentBody = pipeline.step(
	pipeline.job('test-ahk'),
	'Receive managed Ollama file component'
);
for (const command of [
	'test-managed-ollama-protocol.cjs" --windows-file-port',
	'tests/unit/modules/llm/servers/test_ollama_install_files.ps1"',
	// The throw, not the stderr print that shares its condition.
	'if ($modelsExit -ne 0) { throw',
	'if ($nativeExit -ne 0 -or $stderr.Length -ne 0 -or'
])
	mustCatch(
		`missing mandatory component receiver boundary: ${command}`,
		WINDOWS_BOX,
		componentBody,
		componentBody.replace(command, '# omitted boundary'),
		windowsFileRetentionProblems
	);

// A retained literal in a PowerShell comment is not an executed receiver.
for (const command of WINDOWS_FILE_RECEIVER_LINES)
	mustCatch(
		`commented mandatory component boundary: ${command}`,
		WINDOWS_BOX,
		componentBody,
		componentBody.replace(command, '# ' + command),
		windowsFileRetentionProblems
	);

// Multiline comments and literal here-string payloads are not active receivers.
for (const [opening, closing] of [
	['<#', '#>'],
	["$unused = @'", "'@"]
])
	mustCatch(
		'inactive multiline component receiver',
		WINDOWS_BOX,
		componentBody,
		componentBody.replace('        run: |\n', '        run: |\n          ' + opening + '\n') +
			'          ' +
			closing +
			'\n',
		windowsFileRetentionProblems
	);

// Source compilation belongs only to the checkout-install rows. A broader or
// omitted condition could run package acquisition for an archive-only subject.
for (const condition of [
	'',
	'false',
	'always()',
	"env.INSTALL_KIND == 'first'",
	"env.INSTALL_KIND == 'deb'"
]) {
	const head = '      - name: Verify source compiler and checkout\n';
	mustCatch(
		'source compiler condition ' + condition,
		LINUX_BOX,
		head + "        if: env.INSTALL_KIND == 'install'\n",
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing source compiler preparation',
	LINUX_BOX,
	'      - name: Verify source compiler and checkout\n',
	'      - name: Omitted source compiler preparation\n',
	stepProblems
);

// Raw failure logs are diagnostics, separate from success-only distro evidence.
for (const condition of [
	'',
	'false',
	'success()',
	"env.INSTALL_KIND == 'install'",
	'always()',
	"always() && env.INSTALL_KIND == 'install'"
]) {
	const head = '      - name: Upload the native distro unit log\n';
	mustCatch(
		'distro native unit raw log condition ' + condition,
		LINUX_BOX,
		head + "        if: ${{ !cancelled() && env.INSTALL_KIND == 'install' }}\n",
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing native distro unit raw log upload',
	LINUX_BOX,
	'      - name: Upload the native distro unit log\n',
	'      - name: Omitted native distro unit raw log upload\n',
	stepProblems
);
// The assertion annotation belongs only to the original failed unit run.
// A skipped or renamed diagnostic must be observed by the normal wiring gate.
for (const condition of ['', 'success()', 'failure()', 'always()', 'false']) {
	const head = '      - name: Emit Configuration assertion from failed unit log\n';
	mustCatch(
		'Configuration assertion condition ' + condition,
		LINUX_BOX,
		head +
			"        if: ${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}\n",
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing Configuration assertion diagnostic',
	LINUX_BOX,
	'      - name: Emit Configuration assertion from failed unit log\n',
	'      - name: Omitted Configuration assertion diagnostic\n',
	stepProblems
);
// Passive diagnostics never authorize a receiving gate or forgive its failure.
{
	const name = 'Retain passive security service logs after native receiving failure';
	const condition = macRole.condition(
		'managed-ollama-native',
		"${{ !cancelled() && failure() && (steps.managed-ollama-pac-receiving.outcome == 'failure' || steps.native_http_clock.outcome == 'failure' || steps.managed-ollama-model-receiving.outcome == 'failure') }}"
	);
	assert.equal(CONDITIONS.get(conditionKey(MACOS_BOX, 'e2e-hs', name)), condition);
	const realStep = pipeline.step(pipeline.job('e2e-hs'), name);
	const head = realStep.slice(0, realStep.indexOf('        if:'));
	const changedConditions = [
		'',
		'always()',
		'failure()',
		'success()',
		'false',
		condition.replace('!cancelled() && ', ''),
		condition.replace('failure() && ', '')
	];
	for (const identifier of [
		'managed-ollama-pac-receiving',
		'native_http_clock',
		'managed-ollama-model-receiving'
	]) {
		const clause = `steps.${identifier}.outcome == 'failure'`;
		changedConditions.push(condition.replace(clause, clause.replace("'failure'", "'success'")));
		changedConditions.push(condition.replace(clause, 'false'));
	}
	for (const changed of changedConditions)
		mustCatch(
			'passive Security observation condition ' + (changed || '(none)'),
			MACOS_BOX,
			head + `        if: ${condition}\n`,
			head + (changed ? `        if: ${changed}\n` : ''),
			stepProblems
		);
	mustCatch(
		'passive Security observation missing exact step',
		MACOS_BOX,
		head,
		'      - name: Unknown passive Security observation\n',
		stepProblems
	);
	for (const [rel, job] of [
		[MACOS_BOX, 'package-macos'],
		[MACOS_BOX, 'test-hs'],
		[WINDOWS_BOX, 'test-ahk'],
		[LINUX_BOX, 'test-linux']
	])
		assert.equal(CONDITIONS.has(conditionKey(rel, job, name)), false);
}

// Each new native evidence condition is exact, scoped to its job and source-owned step.
for (const [rel, job, name, condition] of MACOS_NATIVE_STEP_CONDITIONS) {
	const realStep = pipeline.step(pipeline.job(job), name);
	const head = realStep.slice(0, realStep.indexOf('        if:'));
	const from = head + `        if: ${condition}\n`;
	for (const changed of ['', 'false', 'success()']) {
		mustCatch(
			`${job} ${name}: replaced native evidence condition ${changed || '(none)'}`,
			rel,
			from,
			head + (changed ? `        if: ${changed}\n` : ''),
			stepProblems
		);
	}
	const scopedAcquisition =
		rel === MACOS_BOX &&
		job === 'e2e-hs' &&
		name === 'Acquire and verify genuine pinned upstream inputs';
	mustCatch(
		`${job} ${name}: missing native evidence step`,
		rel,
		scopedAcquisition ? from : head,
		`      - name: Omitted ${name}\n` + (scopedAcquisition ? `        if: ${condition}\n` : ''),
		stepProblems
	);
}
// A narrowly admitted SDK condition must never migrate to another job or selector.
{
	const name = 'Observe the actual no-prompt SDK permission API independently';
	const key = conditionKey(MACOS_BOX, 'e2e-hs', name);
	assert.equal(CONDITIONS.get(key), macRole.condition('item36-native', '${{ !cancelled() }}'));
	for (const [rel, job, changed] of [
		[MACOS_BOX, 'package-macos', name],
		[MACOS_BOX, 'managed-ollama-native', name],
		[MACOS_BOX, 'item36-unknown', name],
		[WINDOWS_BOX, 'item36-native', name],
		[MACOS_BOX, 'item36-native', 'Unknown SDK observation']
	])
		assert.equal(CONDITIONS.has(conditionKey(rel, job, changed)), false);
	const head = `      - name: ${name}\n`;
	for (const changed of ['always()', 'failure()', '${{ !cancelled() && false }}'])
		mustCatch(
			`SDK observation replaced condition ${changed}`,
			MACOS_BOX,
			macConditionalPrefix(head),
			head + `        if: ${changed}\n`,
			stepProblems
		);
	mustCatch(
		'unknown SDK observation name',
		MACOS_BOX,
		head,
		'      - name: Unknown SDK observation\n',
		stepProblems
	);
	const filter =
		"--filter 'OwnedAutomationQueryWorkerTests.testActualNoPromptPermissionAPIOnlyPublishesRetiredMetadata'";
	for (const changed of [
		"--filter 'OwnedAutomationQueryWorkerTests'",
		"--filter '.*'",
		"--filter 'OwnedAutomationQueryWorkerTests.testConstructedPacket'",
		'--skip-build ' + filter
	])
		mustCatch(
			`SDK observation broadened or substituted selector ${changed}`,
			MACOS_BOX,
			filter,
			changed,
			stepProblems
		);
	const mac = pipeline.file(MACOS_BOX);
	const start = mac.indexOf(head);
	const end = mac.indexOf('      - name: Retain scoped item 36 native diagnostics\n', start);
	assert.ok(start > 0 && end > start);
	const step = mac.slice(start, end);
	const moved = mac
		.replace(step, '')
		.replace(
			'  e2e-hs:\n',
			'  unknown-sdk-job:\n    runs-on: macos-latest\n    steps:\n' + step + '\n  e2e-hs:\n'
		);
	const problems = stepProblems(
		pipeline
			.files()
			.map((entry) => (entry.rel === MACOS_BOX ? { rel: entry.rel, text: moved } : entry))
	);
	assert.ok(
		problems.some((problem) => problem.includes('unknown-sdk-job') && problem.includes(name))
	);
	assert.ok(problems.some((problem) => problem.includes('STEP_CONDITIONS lists ' + key)));
}

const officialColdHead = '      - name: Receive actual official cold Ollama without stock Python\n';
for (const condition of [
	'always()',
	'${{ !cancelled() }}',
	"${{ !cancelled() && steps.cold-app.outcome != 'failure' }}"
]) {
	mustCatch(
		'official cold runtime receiver broadened admission ' + condition,
		MACOS_BOX,
		macConditionalPrefix(officialColdHead),
		officialColdHead + `        if: ${condition}\n`,
		stepProblems
	);
}
// Upload only closed receipts: the owned script corpus contains newline names,
// and recursively uploading its private fixture tree also exposes unnecessary data.
const NATIVE_INVENTORY_ARTIFACT = 'Retain native Hammerspoon provider inventory';
const NATIVE_INVENTORY_PATHS = [
	'${{ runner.temp }}/native-hs-program-providers/summary.json',
	'${{ runner.temp }}/native-hs-program-providers/*/receipt.json',
	'${{ runner.temp }}/native-hs-program-providers/*/physical-group.json',
	'${{ runner.temp }}/native-hs-program-providers/*/diagnostic-facts.json'
];

/** Rejects missing failure receipts and recursive private-fixture uploads. */
function nativeInventoryArtifactProblems(files) {
	const found = files
		.filter((entry) => entry.rel === MACOS_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'package-macos')
		.flatMap((job) => pipeline.steps(job.body))
		.filter((step) => step.name === NATIVE_INVENTORY_ARTIFACT);
	if (found.length !== 1) return ['native inventory artifact step must exist exactly once'];
	const body = found[0].body;
	const lines = body.split('\n');
	const pathAt = lines.indexOf('          path: |');
	const paths = [];
	if (pathAt >= 0) {
		for (const line of lines.slice(pathAt + 1)) {
			if (line.trim() === '') continue;
			if (!/^ {12}\S/.test(line)) break;
			paths.push(line.trim());
		}
	}
	const problems = [];
	if (JSON.stringify(paths) !== JSON.stringify(NATIVE_INVENTORY_PATHS))
		problems.push(
			'native inventory artifact must whitelist only summary and per-scenario closed receipts'
		);
	if (
		pipeline.stepField(body, 'if') !== macRole.condition('package-macos', '${{ always() }}') ||
		pipeline.stepField(body, 'uses') !== 'actions/upload-artifact@v4' ||
		!/^ {10}if-no-files-found: error$/m.test(body)
	)
		problems.push(
			'native inventory failure evidence must upload with always() and fail on missing files'
		);
	return problems;
}

errors.push(...nativeInventoryArtifactProblems(pipeline.files()));
const nativeInventoryPathBlock =
	'          path: |\n' + NATIVE_INVENTORY_PATHS.map((item) => `            ${item}\n`).join('');
for (const replacement of [
	'          path: ${{ runner.temp }}/native-hs-program-providers\n',
	'          path: ${{ runner.temp }}/native-hs-program-providers/**\n',
	nativeInventoryPathBlock +
		'            ${{ runner.temp }}/native-hs-program-providers/*/configuration/**\n',
	...NATIVE_INVENTORY_PATHS.map((item) =>
		nativeInventoryPathBlock.replace(`            ${item}\n`, '')
	)
]) {
	mustCatch(
		'native inventory closed evidence whitelist',
		MACOS_BOX,
		nativeInventoryPathBlock,
		replacement,
		nativeInventoryArtifactProblems
	);
}
for (const replacement of ['', '          if-no-files-found: warn\n']) {
	mustCatch(
		'native inventory missing-file refusal',
		MACOS_BOX,
		nativeInventoryPathBlock + '          if-no-files-found: error\n',
		nativeInventoryPathBlock + replacement,
		nativeInventoryArtifactProblems
	);
}

const NATIVE_ACTION_PROBES = [
	{
		run: 'Observe native notification constructors',
		retain: 'Retain native notification constructor observations',
		folder: 'native-notification-constructors',
		commands: [
			'python3 -m unittest discover -s tools/diagnostics/native_notification_constructors -p test_receipt.py -v',
			'python3 tools/diagnostics/native_notification_constructors/run_native.py',
			'--source-root "$GITHUB_WORKSPACE"',
			'--source-sha "$GITHUB_SHA"',
			'--output "$RUNNER_TEMP/native-notification-constructors"',
			'--download'
		],
		files: [
			'receipt.json',
			'physical-group.json',
			'summary.json',
			'failure.json',
			'pending-retirement.json'
		]
	},
	{
		run: 'Observe native global application switcher',
		retain: 'Retain native global application switcher observations',
		folder: 'native-global-switcher',
		commands: [
			"python3 -m unittest discover -s tools/diagnostics/native_global_switcher -p 'test_*.py' -v",
			'brew install lua@5.4',
			'test -x "$global_switcher_lua54"',
			'python3 tools/diagnostics/native_global_switcher/run_owner_controls.py --lua "$global_switcher_lua54"',
			'python3 tools/diagnostics/native_global_switcher/run_ci_probe.py',
			'--source-root "$GITHUB_WORKSPACE"',
			'--output "$RUNNER_TEMP/native-global-switcher"',
			'2>&1 | env -u ERGOPTI_NATIVE_HS_METADATA_TOKEN tee "$RUNNER_TEMP/native-global-switcher-ci.log"'
		],
		files: ['report.json', 'native-result.json'],
		extraPaths: ['${{ runner.temp }}/native-global-switcher-ci.log']
	}
];

/** Keeps native action probes mandatory and their artifacts limited to receipts. */
function nativeActionProbeProblems(files) {
	const steps = files
		.filter((entry) => entry.rel === MACOS_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'package-macos')
		.flatMap((job) => pipeline.steps(job.body));
	const problems = [];
	for (const spec of NATIVE_ACTION_PROBES) {
		const runs = steps.filter((step) => step.name === spec.run);
		const artifacts = steps.filter((step) => step.name === spec.retain);
		if (runs.length !== 1 || artifacts.length !== 1) {
			problems.push(`${spec.run} needs exactly one execution and evidence step`);
			continue;
		}
		const body = runs[0].body;
		if (
			pipeline.stepField(body, 'if') !== macRole.condition('package-macos', '${{ always() }}') ||
			pipeline.stepField(body, 'timeout-minutes') !== '5' ||
			!spec.commands.every((command) => (pipeline.runOf(body) ?? []).join('\n').includes(command))
		)
			problems.push(`${spec.run} must run its controls and exact native command independently`);
		const artifact = artifacts[0].body;
		const lines = artifact.split('\n');
		const at = lines.indexOf('          path: |');
		const paths = [];
		if (at >= 0) {
			for (const line of lines.slice(at + 1)) {
				if (!line.trim()) continue;
				if (!/^ {12}\S/.test(line)) break;
				paths.push(line.trim());
			}
		}
		const expected = spec.files.map((file) => '${{ runner.temp }}/' + spec.folder + '/' + file);
		expected.push(...(spec.extraPaths ?? []));
		if (
			JSON.stringify(paths) !== JSON.stringify(expected) ||
			pipeline.stepField(artifact, 'if') !==
				macRole.condition('package-macos', '${{ always() }}') ||
			pipeline.stepField(artifact, 'uses') !== 'actions/upload-artifact@v4' ||
			!/^ {10}if-no-files-found: error$/m.test(artifact)
		)
			problems.push(`${spec.retain} must retain only closed receipts and refuse absent evidence`);
	}
	return problems;
}

errors.push(...nativeActionProbeProblems(pipeline.files()));
for (const spec of NATIVE_ACTION_PROBES) {
	const steps = pipeline
		.jobsOfText(pipeline.file(MACOS_BOX), MACOS_BOX)
		.filter((job) => job.id === 'package-macos')
		.flatMap((job) => pipeline.steps(job.body));
	const run = steps.find((step) => step.name === spec.run);
	const artifact = steps.find((step) => step.name === spec.retain);
	if (!run || !artifact) continue;
	for (const command of spec.commands) {
		mustCatch(
			`omitted native action command ${command}`,
			MACOS_BOX,
			run.body,
			run.body.replace(command, '# omitted native command'),
			nativeActionProbeProblems
		);
	}
	for (const file of spec.files) {
		const path = '            ${{ runner.temp }}/' + spec.folder + '/' + file + '\n';
		mustCatch(
			`omitted native action receipt ${file}`,
			MACOS_BOX,
			artifact.body,
			artifact.body.replace(path, ''),
			nativeActionProbeProblems
		);
	}
	mustCatch(
		'recursive native action fixture upload',
		MACOS_BOX,
		artifact.body,
		artifact.body.replace(
			'          path: |\n',
			'          path: |\n            ${{ runner.temp }}/' + spec.folder + '/**\n'
		),
		nativeActionProbeProblems
	);
	mustCatch(
		'native action missing-file refusal',
		MACOS_BOX,
		artifact.body,
		artifact.body.replace('if-no-files-found: error', 'if-no-files-found: warn'),
		nativeActionProbeProblems
	);
}

mustCatch(
	'global switcher log receiver must exclude the metadata credential',
	MACOS_BOX,
	'2>&1 | env -u ERGOPTI_NATIVE_HS_METADATA_TOKEN tee "$RUNNER_TEMP/native-global-switcher-ci.log"',
	'2>&1 | tee "$RUNNER_TEMP/native-global-switcher-ci.log"',
	nativeActionProbeProblems
);

for (const condition of ['', 'false', 'success()']) {
	const head =
		'      - name: Retain native captures, source, provisioning and retirement receipts\n';
	mustCatch(
		'canvas retained evidence condition ' + condition,
		MACOS_BOX,
		macConditionalPrefix(head),
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing mandatory native canvas evidence upload',
	MACOS_BOX,
	'      - name: Retain native captures, source, provisioning and retirement receipts\n',
	'      - name: Omitted native canvas evidence upload\n',
	stepProblems
);
mustCatch(
	'native canvas diagnostic failure swallowed after its continued command',
	MACOS_BOX,
	'          --output "$RUNNER_TEMP/tooltip-canvas-evidence"\n',
	'          --output "$RUNNER_TEMP/tooltip-canvas-evidence" || true\n',
	stepProblems
);

for (const [name, expected] of [
	['Run manual official runtime and model acceptance', MANUAL_RUNTIME_IF],
	['Upload manual runtime acceptance evidence', MANUAL_RUNTIME_EVIDENCE_IF]
]) {
	const head = `      - name: ${name}\n`;
	const from = head + `        if: ${expected}\n`;
	for (const changed of ['', 'false', NOT_CANCELLED, "${{ github.event_name == 'push' }}"]) {
		mustCatch(
			`manual runtime qualification condition changed: ${name}: ${changed || 'missing'}`,
			LINUX_BOX,
			from,
			head + (changed ? `        if: ${changed}\n` : ''),
			stepProblems
		);
	}
	mustCatch(
		`manual runtime qualification step omitted: ${name}`,
		LINUX_BOX,
		head,
		`      - name: Omitted ${name}\n`,
		stepProblems
	);
}
errors.push(...stepProblems(pipeline.files()));
for (const name of [
	'Run signed Hammerspoon program provider inventory',
	'Retain native Hammerspoon provider inventory',
	'Observe native notification constructors',
	'Retain native notification constructor observations',
	'Observe native global application switcher',
	'Retain native global application switcher observations',
	'Observe native Apple Shortcuts discovery',
	'Retain native Apple Shortcuts observation'
]) {
	const head = `      - name: ${name}\n`;
	for (const condition of ['', 'false', 'success()']) {
		mustCatch(
			`native provider ${name} condition ${condition}`,
			MACOS_BOX,
			macConditionalPrefix(head),
			head + (condition ? `        if: ${condition}\n` : ''),
			stepProblems
		);
	}
	mustCatch(
		`missing mandatory ${name}`,
		MACOS_BOX,
		head,
		'      - name: Omitted native provider step\n',
		stepProblems
	);
}
for (const condition of ['', 'false', 'success()']) {
	const head = '      - name: Retain archive diagnostic session\n';
	const from = macConditionalPrefix(head);
	mustCatch(
		'archive retained evidence condition ' + condition,
		MACOS_BOX,
		from,
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing mandatory archive evidence upload',
	MACOS_BOX,
	'      - name: Retain archive diagnostic session\n',
	'      - name: Omitted archive evidence upload\n',
	stepProblems
);

for (const condition of ['', 'false', 'success()']) {
	const head = '      - name: Retain closed TIS diagnostic session\n';
	const from = macConditionalPrefix(head);
	mustCatch(
		'TIS retained evidence condition ' + condition,
		MACOS_BOX,
		from,
		head + (condition ? '        if: ' + condition + '\n' : ''),
		stepProblems
	);
}
mustCatch(
	'missing mandatory TIS evidence upload',
	MACOS_BOX,
	'      - name: Retain closed TIS diagnostic session\n',
	'      - name: Omitted TIS evidence upload\n',
	stepProblems
);
for (const condition of ['false', "env.INSTALL_KIND == 'deb'"]) {
	mustCatch(
		`an AppImage launch routed through ${condition}`,
		LINUX_BOX,
		"      - name: Launch it\n        if: env.INSTALL_KIND == 'appimage'\n",
		`      - name: Launch it\n        if: ${condition}\n`,
		stepProblems
	);
}
for (const [what, rel, from, to] of [
	[
		'if: false on the Swift XCTest step',
		MACOS_BOX,
		'      - name: Run Swift launcher tests on macOS 26\n',
		'      - name: Run Swift launcher tests on macOS 26\n        if: false\n'
	],
	[
		'a `- if: false` step head on the Hammerspoon suite',
		MACOS_BOX,
		'      - name: Run unit + meta tests\n',
		'      - if: false\n        name: Run unit + meta tests\n'
	],
	[
		'if: false on the Windows exe smoke',
		WINDOWS_BOX,
		'      - name: Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)\n',
		'      - name: Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)\n        if: false\n'
	],
	[
		'a harness condition outside test-linux',
		LINUX_BOX,
		'      - name: Launch the Flatpak\n',
		`      - name: Launch the Flatpak\n        if: ${NOT_CANCELLED}\n`
	],
	[
		'if: false on a test-linux harness',
		LINUX_BOX,
		`      - name: Round-trip real events through the kernel\n        if: ${linuxRow('Round-trip real events through the kernel', NOT_CANCELLED)}\n`,
		'      - name: Round-trip real events through the kernel\n        if: false\n'
	],
	[
		'a Linux harness moved to every matrix row',
		LINUX_BOX,
		`      - name: Round-trip real events through the kernel\n        if: ${linuxRow('Round-trip real events through the kernel', NOT_CANCELLED)}\n`,
		`      - name: Round-trip real events through the kernel\n        if: ${NOT_CANCELLED}\n`
	],
	[
		'a Linux harness moved to another matrix row',
		LINUX_BOX,
		`      - name: Round-trip real events through the kernel\n        if: ${linuxRow('Round-trip real events through the kernel', NOT_CANCELLED)}\n`,
		"      - name: Round-trip real events through the kernel\n        if: ${{ !cancelled() && matrix.shard == 'updater' }}\n"
	],
	[
		'if: false on the Linux evidence verdict',
		LINUX_BOX,
		'      - name: Assert all mandatory subjects ran and passed\n',
		'      - name: Assert all mandatory subjects ran and passed\n        if: false\n'
	],
	[
		'`|| true` after the Hammerspoon harness',
		MACOS_BOX,
		'run: lua5.4 tests/e2e/run_e2e.lua\n',
		'run: lua5.4 tests/e2e/run_e2e.lua || true\n'
	],
	[
		'`|| true` after the Linux unit suite',
		LINUX_BOX,
		'-- luajit tests/run.lua --module="$LINUX_UNIT_GROUP" 2>&1 | tee',
		'-- luajit tests/run.lua --module="$LINUX_UNIT_GROUP" || true 2>&1 | tee'
	],
	[
		'`|| true` after the continued evidence verdict',
		LINUX_BOX,
		'              --sha "$GITHUB_SHA"\n          echo "Linux mandatory evidence verified;',
		'              --sha "$GITHUB_SHA" || true\n          echo "Linux mandatory evidence verified;'
	],
	[
		'a `| tee` left without pipefail',
		LINUX_BOX,
		'          set -euo pipefail\n          luajit tests/e2e/run_e2e.lua | tee',
		'          luajit tests/e2e/run_e2e.lua | tee'
	]
]) {
	mustCatch(what, rel, from, to, stepProblems);
}

// =========================================
// =========================================
// ======= 7/ The Release Job ==============
// =========================================
// =========================================

const releaseSteps = pipeline.steps(pipeline.job('release'));
const indexOf = (name) => releaseSteps.findIndex((candidate) => candidate.name === name);
const releaseOrder = RELEASE_ORDER.map(indexOf);
if (releaseOrder.some((at, index) => at < 0 || (index > 0 && at <= releaseOrder[index - 1]))) {
	errors.push(
		`release must run ${RELEASE_ORDER.join(' < ')}; got: ${releaseSteps.map((candidate) => candidate.name).join(' | ')}`
	);
}
const preflightAt = indexOf(PREFLIGHT);
const firstEffectAt = releaseSteps.findIndex((candidate) =>
	SIDE_EFFECT.test(codeOf(candidate.body))
);
if (firstEffectAt < 0 || releaseSteps[firstEffectAt].name !== 'Create git tag') {
	errors.push(
		'the first release step that writes to GitHub must be "Create git tag"; re-derive the side-effect scan'
	);
} else if (!(preflightAt >= 0 && preflightAt < firstEffectAt)) {
	errors.push(
		`"${PREFLIGHT}" must run before "${releaseSteps[firstEffectAt].name}", the first side effect`
	);
}
if (preflightAt >= 0) {
	const preflight = releaseSteps[preflightAt].body;
	for (const key of ['if', 'continue-on-error']) {
		if (pipeline.stepField(preflight, key) !== null)
			errors.push(`"${PREFLIGHT}" must not set ${key}`);
	}
	for (const token of [
		'set -euo pipefail',
		'_ErgoptiPlus.app.zip.sig',
		'"appcast-${CHANNEL}.xml"',
		'taken=$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}")',
		'if [ "$tagged" = "$GITHUB_SHA" ]; then'
	]) {
		if (!preflight.includes(token)) errors.push(`"${PREFLIGHT}" is missing ${token}`);
	}
	if (/ls-remote[^\n]*\|/.test(codeOf(preflight))) {
		errors.push(
			`"${PREFLIGHT}" must capture ls-remote before testing it: piped, a network error reads as "tag free"`
		);
	}
}

// N5: under pipefail, `git ls-remote ... | grep -q` read a failing ls-remote as
// "tag free" and planned a release; the listing is captured first.
const planMeta = attempt(() => pipeline.step(plan, 'Compute tag and version'));
if (planMeta !== null) {
	if (
		!planMeta.includes('taken=$(git ls-remote --tags origin "refs/tags/$tag")') ||
		!planMeta.includes('if [ -n "$taken" ]; then')
	) {
		errors.push(
			'plan must capture `git ls-remote --tags origin "refs/tags/$tag"` into taken and test it'
		);
	}
	if (/ls-remote[^\n]*\|/.test(codeOf(planMeta))) {
		errors.push('plan must not pipe ls-remote: under pipefail a network error reads as "tag free"');
	}
}

// Each assets-* upload fails when a file is missing, and keeps what release
// publishes long enough for a re-run.
const retained = new Map();
for (const entry of pipeline.files()) {
	for (const candidate of pipeline.jobs(entry.rel)) {
		for (const found of pipeline.steps(candidate.body)) {
			if (!/^actions\/upload-artifact@/.test(pipeline.stepField(found.body, 'uses') ?? ''))
				continue;
			const name = /^ {10}name: (assets-\S+)$/m.exec(found.body)?.[1];
			if (!name) continue;
			if (isRetainedQualification(entry, candidate, found)) continue;
			retained.set(name, /^ {10}retention-days: (.+)$/m.exec(found.body)?.[1] ?? null);
			if (!/^ {10}if-no-files-found: error$/m.test(found.body)) {
				errors.push(
					`the ${name} upload must set if-no-files-found: error, so a missing file fails its box`
				);
			}
		}
	}
}
for (const [name, days] of ASSET_RETENTION) {
	if (retained.get(name) !== days) {
		errors.push(`the ${name} upload must keep retention-days: ${days}, got: ${retained.get(name)}`);
	}
}
// release attaches every file under release-assets: all assets-* artifacts,
// merged into that one folder, where the preflight looks for each file.
const download = releaseSteps.find(
	(candidate) => candidate.name === 'Download all build artifacts'
);
for (const line of [
	'          pattern: assets-*',
	'          path: release-assets',
	'          merge-multiple: true'
]) {
	if (!download || !download.body.split('\n').includes(line)) {
		errors.push(`"Download all build artifacts" must set ${line.trim()}`);
	}
}

/** Exercise the real workflow fields; unknown source reads must never inherit admission. */
function assertLotTransportControls() {
	let count = 0;
	for (const [rel, producer, consumer, matrix, metadata] of [
		[COMMON_BOX, null, 'shared-validation', 'matrix', 'metadata'],
		[COMMON_BOX, 'common-e2e', 'common-build', 'site_matrix', 'site_metadata'],
		[COMMON_BOX, 'common-build', 'common-testbuild', 'site_matrix', 'site_metadata'],
		[MACOS_BOX, 'test-hs', 'e2e-hs', 'e2e_matrix', 'e2e_metadata'],
		[MACOS_BOX, 'package-macos', 'launch', 'testbuild_matrix', 'testbuild_metadata'],
		[LINUX_BOX, 'package-linux', 'install-linux', 'install_matrix', 'install_metadata']
	]) {
		const source = pipeline.file(rel);
		const job = pipeline.jobsOfText(source, rel).find((item) => item.id === consumer);
		assert.ok(job, 'Actual human-lot consumer exists');
		const matrixLine =
			producer === null
				? '      matrix: ' + COMMON_MATRIX + '\n'
				: '      matrix: ${{ fromJSON(needs.' + producer + '.outputs.' + matrix + ') }}\n';
		const metadataRef =
			producer === null ? 'inputs.common_plan' : 'needs.' + producer + '.outputs.' + metadata;
		const metadataLine = job.body.split('\n').find((line) => line.includes(metadataRef));
		assert.ok(metadataLine, 'Actual metadata owner read exists');
		for (const [label, before, after] of [
			['missing matrix', matrixLine, ''],
			[
				'foreign matrix producer',
				matrixLine,
				producer === null
					? matrixLine.replace('inputs.common_plan', 'inputs.foreign')
					: matrixLine.replace(producer, 'foreign')
			],
			[
				'foreign matrix key',
				matrixLine,
				producer === null
					? matrixLine.replace(').matrix', ').foreign')
					: matrixLine.replace('.outputs.' + matrix, '.outputs.foreign')
			],
			[
				'foreign metadata producer',
				metadataLine,
				metadataLine.replace(metadataRef, 'needs.foreign.outputs.' + metadata)
			],
			[
				'foreign metadata key',
				metadataLine,
				metadataLine.replace(metadataRef, 'needs.' + producer + '.outputs.foreign')
			],
			[
				'unknown lot selector',
				metadataLine,
				metadataLine.includes('[matrix.lot]')
					? metadataLine.replace('[matrix.lot]', '[matrix.foreign]')
					: metadataLine.replace(metadataRef, metadataRef + '-foreign')
			],
			[
				'extra script reader',
				'    steps:\n',
				'    steps:\n      - name: Foreign metadata reader\n        run: echo "${{ ' +
					metadataRef +
					' }}"\n'
			]
		]) {
			assert.equal(job.body.split(before).length, 2, label + ' has exactly one real consumer seam');
			const altered = source.replace(job.body, job.body.replace(before, after));
			assert.notEqual(altered, source);
			const files = pipeline
				.files()
				.map((entry) => (entry.rel === rel ? { ...entry, text: altered } : entry));
			assert.ok(planReferenceProblems(files).length > 0, consumer + ': ' + label);
			count++;
		}
	}
	const common = pipeline.file(COMMON_BOX);
	const formatter = pipeline.step(pipeline.job('shared-validation'), COMMON_FORMAT_CHECKS[0][0]);
	for (const [label, changed] of [
		['missing mandatory TOML', ''],
		['duplicate mandatory TOML', formatter + '\n' + formatter],
		[
			'forgiven mandatory TOML',
			formatter.replace('        if:', '        continue-on-error: true\n        if:')
		],
		['JS-only TOML row', formatter.replace("'hotstrings-format'", "'js'")]
	]) {
		const files = pipeline
			.files()
			.map((entry) =>
				entry.rel === COMMON_BOX ? { ...entry, text: common.replace(formatter, changed) } : entry
			);
		assert.ok(rootProblems(files).length > 0, label);
		count++;
	}
	for (const owner of LUA_TIMING_RETENTION) {
		const source = pipeline.file(owner.file);
		const uploader = pipeline.step(pipeline.job(owner.job), owner.step);
		for (const changed of [
			uploader.replace(owner.path, '${{ runner.temp }}/foreign.json'),
			uploader.replace('if: ${{ !cancelled() }}', 'if: always()')
		]) {
			assert.notEqual(changed, uploader);
			const files = pipeline
				.files()
				.map((entry) =>
					entry.rel === owner.file ? { ...entry, text: source.replace(uploader, changed) } : entry
				);
			assert.ok(
				namingProblems(files).some((problem) => problem.includes(owner.step)),
				'Timing names cannot authorize altered evidence'
			);
			count++;
		}
	}
	assert.equal(count, 50, 'Closed human-lot and mandatory-format source refusal census');
	return count;
}
assertLotTransportControls();

/** Checks the names GitHub renders after flattening all four workflows. */
function namingProblems(files) {
	const problems = [];
	const admittedTiming = luaTimingRetentionProblems(files).length === 0;
	for (const entry of files) {
		for (const candidate of pipeline.jobsOfText(entry.text, entry.rel)) {
			const name = (pipeline.field(candidate.body, 'name') ?? '').replace(/^(['"])(.*)\1$/, '$2');
			const caller = pipeline.field(candidate.body, 'uses') !== null;
			const valid =
				entry.rel === ENTRY
					? caller
						? {
								core: 'YAML, shared code & web',
								macos: 'macOS',
								windows: 'Windows',
								linux: 'Linux',
								[PUBLICATION]: 'Release'
							}[candidate.id] === name
						: {
								'prepare-common': 'Check formatting and plan unit tests',
								validate: 'Release plan'
							}[candidate.id] === name
					: entry.rel === RELEASE_BOX
						? {
								// Rendered as 'Release / <name>' under ci.yml's Release caller.
								'publication-plan': 'Verify all lanes and original plan',
								release: 'Publish'
							}[candidate.id] === name
						: entry.rel === COMMON_BOX
							? {
									'shared-validation': 'Unit tests',
									'common-unit-verdict': 'Verdict',
									'common-e2e': 'E2E tests',
									'common-build': 'Build',
									'common-testbuild': 'Install and launch'
								}[candidate.id] === name
							: {
									'test-hs': 'Unit tests',
									'test-ahk': 'Unit tests',
									'test-linux': 'Unit tests',
									'e2e-hs': 'E2E tests',
									'e2e-ahk': 'E2E tests',
									'e2e-linux': 'E2E tests',
									// The macOS Build states the macOS version it runs on.
									'package-macos': 'Build (macOS 26)',
									'package-windows': 'Build',
									'package-linux': 'Build',
									'package-flatpak': 'Flatpak',
									launch: 'Install and launch',
									'launch-windows': 'Install and launch',
									'install-linux': 'Install and launch',
									'macos-ok': 'Verdict',
									'windows-ok': 'Verdict',
									'linux-ok': 'Verdict'
								}[candidate.id] === name;
			if (!valid)
				problems.push(`${entry.rel} job ${candidate.id} has an invalid display name: ${name}`);
			for (const found of pipeline.steps(candidate.body)) {
				if (found.name && !/^[A-Z]/.test(found.name)) {
					problems.push(`${entry.rel} job ${candidate.id} has a lowercase step: ${found.name}`);
				}
				if (
					entry.rel !== ENTRY &&
					entry.rel !== RELEASE_BOX &&
					// A macOS version ("macOS 26") states the cell's OS release, not the lane zone.
					/\b(?:macOS(?! \d)|Linux|Windows(?! Defender))\b/.test(found.name) &&
					!isRetainedQualification(entry, candidate, found) &&
					!(
						admittedTiming &&
						LUA_TIMING_RETENTION.some(
							(owner) =>
								owner.file === entry.rel && owner.job === candidate.id && owner.step === found.name
						)
					)
				) {
					problems.push(
						`${entry.rel} job ${candidate.id} repeats its zone in a step: ${found.name}`
					);
				}
			}
		}
	}
	return problems;
}

for (const owner of scoped.contract.retained_steps) {
	const entry = { rel: owner.file },
		candidate = { id: owner.job };
	assert.equal(
		isRetainedQualification(entry, candidate, { name: owner.name, body: owner.body }),
		true
	);
	for (const [before, after] of [
		['uses: actions/upload-artifact@v4', 'uses: unrelated/uploader@v4'],
		['path:', 'unrelated_path:'],
		['if-no-files-found:', 'continue-on-error: true\n          if-no-files-found:']
	]) {
		const body = owner.body.replace(before, after);
		assert.notEqual(body, owner.body);
		assert.throws(() => isRetainedQualification(entry, candidate, { name: owner.name, body }));
	}
	assert.equal(
		isRetainedQualification(entry, candidate, { name: owner.name + ' unknown', body: owner.body }),
		false
	);
}
for (const [before, after] of [
	['--publication-select', '--unknown-select'],
	['ERGOPTI_DEV_RELEASE_TAG: ${{ steps.meta.outputs.tag }}', 'ERGOPTI_DEV_RELEASE_TAG: fixed'],
	[
		'ERGOPTI_DEV_RELEASE_VERSION: ${{ steps.meta.outputs.version }}',
		'ERGOPTI_DEV_RELEASE_VERSION: fixed'
	]
])
	mustCatch('qualification owner ' + before, ENTRY, before, after, rootProblems);
errors.push(...namingProblems(pipeline.files()));
for (const [what, rel, from, to] of [
	['an incorrect Common caller name', ENTRY, "name: 'YAML, shared code & web'", "name: 'Linux'"],
	[
		'an incorrect Common matrix name',
		COMMON_BOX,
		"name: 'Unit tests'",
		"name: '${{ matrix.unknown }}'"
	],
	[
		'a matrix display name on an unknown Common job',
		COMMON_BOX,
		'  shared-validation:\n',
		'  unknown-validation:\n'
	],
	['an unqualified root name', ENTRY, "name: 'Release plan'", "name: 'Validate'"],
	['a doubled Release prefix', RELEASE_BOX, "name: 'Publish'", "name: 'Release / Publish'"],
	['an incorrect Release caller name', ENTRY, "name: 'Release'", "name: 'Publish'"],
	['a lowercase lane job', WINDOWS_BOX, "name: 'Unit tests'", "name: 'unit tests'"],
	[
		'a repeated lane prefix',
		MACOS_BOX,
		'  package-macos:\n    name: Build (macOS 26)\n',
		"  package-macos:\n    name: 'macOS / Build (macOS 26)'\n"
	],
	['a lowercase step', WINDOWS_BOX, 'name: Run AHK test suite', 'name: run AHK test suite'],
	['an extra root separator', ENTRY, "name: 'Release plan'", "name: 'Validate / Checks / Plan'"],
	[
		'a repeated step zone',
		LINUX_BOX,
		'name: Run the driver unit test suite',
		'name: Run Linux driver unit test suite'
	]
]) {
	mustCatch(what, rel, from, to, namingProblems);
}

// =============================================
// =============================================
// ======= 7b/ One Reusable Workflow Per Stage ==
// =============================================
// =============================================

// GitHub renders a stage job as 'Lane / Stage / Job': the lane caller's name in
// ci.yml, the stage caller's name in the lane, then the job's own name, which
// says what the job tests. Each lane stage runs in ci-<lane>-<stage>.yml.
const STAGE_LAYOUT = {
	[COMMON_BOX]: [
		['shared-validation', 'unit', 'Unit tests', '${{ matrix.lot }}'],
		['common-e2e', 'e2e', 'E2E tests', 'Shared UI rendering'],
		['common-build', 'build', 'Build', '${{ matrix.lot }}'],
		['common-testbuild', 'install', 'Install and launch', '${{ matrix.lot }}'],
		['common-unit-verdict', 'verdict', 'Verdict', 'Production site receipts']
	],
	[WINDOWS_BOX]: [
		['test-ahk', 'unit', 'Unit tests', '${{ matrix.module }}'],
		['e2e-ahk', 'e2e', 'E2E tests', 'Engine E2E corpus'],
		['package-windows', 'build', 'Build', 'ErgoptiPlus.exe and layout installer'],
		['launch-windows', 'install', 'Install and launch', 'Compiled ErgoptiPlus.exe'],
		['windows-ok', 'verdict', 'Verdict', 'Mandatory jobs and launch evidence']
	],
	[LINUX_BOX]: [
		['test-linux', 'unit', 'Unit tests', '${{ matrix.group }}'],
		['e2e-linux', 'e2e', 'E2E tests', '${{ matrix.shard }}'],
		['package-linux', 'build', 'Build', '.deb, .rpm, AppImage and archive'],
		['package-flatpak', 'flatpak', 'Flatpak', 'Build, install and launch'],
		['install-linux', 'install', 'Install and launch', '${{ matrix.lot }}'],
		['linux-ok', 'verdict', 'Verdict', 'Mandatory subjects']
	]
};
// The scripts that find a stage job by its rendered name, with the prefix
// each one composes.
const RENDERED_NAME_READERS = [
	['tools/ci/validate-js-feature-results.cjs', 'shared-validation'],
	['tools/ci/site-deploy-admission.cjs', 'common-build'],
	['tools/ci/site-deploy-admission.cjs', 'common-testbuild']
];

/** Lists how the real files could stop running one stage per reusable workflow. */
function stageLayoutProblems(files) {
	const problems = [];
	const real = pipeline.view(() => files);
	const unquote = (value) => (value ?? '').replace(/^(['"])(.*)\1$/, '$2');
	for (const [lane, stages] of Object.entries(STAGE_LAYOUT)) {
		const base = lane.replace(/\.yml$/, '');
		const callers = real.jobs(lane);
		if (JSON.stringify(callers.map((job) => job.id)) !== JSON.stringify(stages.map(([id]) => id)))
			problems.push(`${lane} must call exactly its stages, in order`);
		for (const [id, stage, stageName, jobName] of stages) {
			const rel = `${base}-${stage}.yml`;
			const caller = callers.find((job) => job.id === id);
			if (!caller || pipeline.field(caller.body, 'uses') !== `./${rel}`) {
				problems.push(`${lane} job ${id} must call ${rel}`);
				continue;
			}
			if (unquote(pipeline.field(caller.body, 'name')) !== stageName)
				problems.push(`${lane} job ${id} must be named for its stage: ${stageName}`);
			const entry = files.find((file) => file.rel === rel);
			if (!entry || !entry.text.startsWith(`# ${rel}\n`)) {
				problems.push(`${rel} must exist and open with its own path`);
				continue;
			}
			const inner = pipeline.jobsOfText(entry.text, rel);
			if (inner.length !== 1 || inner[0].id !== id) {
				problems.push(`${rel} must define ${id} as its only job`);
				continue;
			}
			if (unquote(pipeline.field(inner[0].body, 'name')) !== jobName)
				problems.push(`${rel} job ${id} must say what it tests: ${jobName}`);
		}
	}
	const laneName = (lane) =>
		unquote(
			pipeline.field(
				real.jobs(ENTRY).find((job) => pipeline.field(job.body, 'uses') === `./${lane}`).body,
				'name'
			)
		);
	for (const [script, id] of RENDERED_NAME_READERS) {
		const lane = Object.keys(STAGE_LAYOUT).find((rel) =>
			STAGE_LAYOUT[rel].some(([stage]) => stage === id)
		);
		const stageName = STAGE_LAYOUT[lane].find(([stage]) => stage === id)[2];
		const prefix = `${laneName(lane)} / ${stageName}`;
		const source = fs.readFileSync(path.resolve(__dirname, '../..', script), 'utf8');
		if (!source.includes(`'${prefix}'`) || !source.includes("' / '"))
			problems.push(`${script} must find ${id} as '${prefix} / <job>', the name GitHub renders`);
	}
	return problems;
}
errors.push(...stageLayoutProblems(pipeline.real().files()));
for (const [what, rel, from, to] of [
	[
		'a stage caller renamed away from its stage',
		COMMON_BOX,
		"  common-build:\n    name: 'Build'\n",
		"  common-build:\n    name: 'Site'\n"
	],
	[
		'a stage job named for its stage instead of its subject',
		'.github/workflows/ci-common-e2e.yml',
		"    name: 'Shared UI rendering'\n",
		"    name: 'E2E tests'\n"
	],
	[
		'a stage moved into another file name',
		COMMON_BOX,
		'    uses: ./.github/workflows/ci-common-verdict.yml\n',
		'    uses: ./.github/workflows/ci-common-gate.yml\n'
	]
]) {
	const files = pipeline.real().files();
	const source = files.find((file) => file.rel === rel).text;
	assert.equal(source.split(from).length, 2, what + ' has one real source seam');
	const changed = files.map((file) =>
		file.rel === rel ? { ...file, text: source.replace(from, () => to) } : file
	);
	assert.ok(stageLayoutProblems(changed).length > 0, what);
}

/** Keeps the approved root group as the pipeline's only concurrency owner. */
function concurrencyProblems(files) {
	const problems = [];
	const expected =
		"group: ci-${{ github.ref }}-${{ github.event_name == 'workflow_dispatch' && github.run_id || 'automatic' }}\n" +
		"  cancel-in-progress: ${{ github.ref != 'refs/heads/dev' || github.event_name != 'push' }}";
	for (const entry of files) {
		const text = codeOf(entry.text);
		// Top-level keys and job fields have fixed columns. Text inside run: |
		// remains more deeply indented and must never acquire YAML ownership.
		const roots = [...text.matchAll(/^(?:concurrency|'concurrency'|"concurrency")[ \t]*:/gm)];
		if (entry.rel === ENTRY) {
			const header = text.split('\njobs:')[0];
			const blocks = [...header.matchAll(/^concurrency:\n((?: {2}[^\n]*\n|[ \t]*\n)*)/gm)];
			if (roots.length !== 1 || blocks.length !== 1 || blocks[0][1].trim() !== expected)
				problems.push(
					'manual CI must have one unique run group; dev pushes must finish while other automatic runs supersede'
				);
		} else if (roots.length !== 0) {
			problems.push(`${entry.rel}: a called workflow must not add its own concurrency group`);
		}
		for (const job of pipeline.jobsOfText(entry.text, entry.rel)) {
			if (/^ {4}(?:concurrency|'concurrency'|"concurrency")[ \t]*:/m.test(codeOf(job.body)))
				problems.push(
					`${entry.rel} job ${job.id}: a job must not add a concurrency group that cancels an independent manual run`
				);
		}
	}
	return problems;
}

// A caller or called lane can otherwise cancel one OS of an independent run.
for (const [what, rel, from, to] of [
	[
		'Windows caller concurrency collision',
		ENTRY,
		"  windows:\n    name: 'Windows'",
		"  windows:\n    concurrency:\n      group: ci-windows-${{ github.ref }}\n      cancel-in-progress: true\n    name: 'Windows'"
	],
	[
		'called macOS workflow concurrency collision',
		MACOS_BOX,
		'jobs:\n',
		'concurrency:\n  group: ci-macos-${{ github.ref }}\n  cancel-in-progress: true\n\njobs:\n'
	],
	[
		'called Linux job concurrency collision',
		LINUX_BOX,
		'  linux-ok:\n',
		'  linux-ok:\n    concurrency:\n      group: ci-linux-${{ github.ref }}\n      cancel-in-progress: true\n'
	],
	[
		'quoted caller concurrency collision',
		ENTRY,
		"  windows:\n    name: 'Windows'",
		"  windows:\n    'concurrency':\n      group: ci-windows-${{ github.ref }}\n      cancel-in-progress: true\n    name: 'Windows'"
	]
]) {
	mustCatch(what, rel, from, to, concurrencyProblems);
}

const rootConcurrencyBlock = pipeline
	.file(ENTRY)
	.match(/^concurrency:\n(?: {2}[^\n]*\n|[ \t]*\n)*/m)?.[0];
if (rootConcurrencyBlock === undefined) {
	errors.push(
		'the approved root concurrency block is missing; self-check fixtures have no source owner'
	);
} else {
	mustCatch('missing root concurrency', ENTRY, rootConcurrencyBlock, '', concurrencyProblems);
	mustCatch(
		'duplicate root concurrency',
		ENTRY,
		rootConcurrencyBlock,
		rootConcurrencyBlock + rootConcurrencyBlock,
		concurrencyProblems
	);
}

// A shell body may legitimately print or write this text. Scan YAML fields,
// rather than interpreting a script's embedded content as another group.
const concurrencyScriptAnchor = '      - name: Install Lua 5.4 + luarocks\n        run: |\n';
const concurrencyScriptSource = pipeline.file(MACOS_BOX);
if (concurrencyScriptSource.split(concurrencyScriptAnchor).length - 1 !== 1) {
	errors.push('the actual macOS run block must uniquely own the script-text concurrency fixture');
} else {
	const scriptFixture = pipeline.files().map((entry) =>
		entry.rel === MACOS_BOX
			? {
					rel: entry.rel,
					text: entry.text.replace(
						concurrencyScriptAnchor,
						concurrencyScriptAnchor +
							'          concurrency:\n            group: literal-script-content\n            cancel-in-progress: true\n'
					)
				}
			: entry
	);
	if (concurrencyProblems(scriptFixture).length !== 0)
		errors.push('a run block containing concurrency text must not be scanned as a YAML group');
}

errors.push(...concurrencyProblems(pipeline.files()));
for (const [what, from, to] of [
	[
		'manual branch collision',
		"-${{ github.event_name == 'workflow_dispatch' && github.run_id || 'automatic' }}",
		''
	],
	['manual duplicate-SHA collision', '&& github.run_id', '&& github.sha'],
	['automatic runs never supersede', "|| 'automatic'", '|| github.run_id'],
	[
		'dev release starvation restored',
		"cancel-in-progress: ${{ github.ref != 'refs/heads/dev' || github.event_name != 'push' }}",
		'cancel-in-progress: true'
	],
	[
		'other automatic cancellation disabled',
		"cancel-in-progress: ${{ github.ref != 'refs/heads/dev' || github.event_name != 'push' }}",
		'cancel-in-progress: false'
	]
]) {
	mustCatch(what, ENTRY, from, to, concurrencyProblems);
}

// Evaluate the real GitHub expression, rather than trusting the pinned spelling.
const cancellationLine = rootConcurrencyBlock?.match(/^ {2}cancel-in-progress: (.+)$/m)?.[1];
function cancellationFor(value, github) {
	if (value === 'true' || value === 'false') return value === 'true';
	const expression = /^\$\{\{\s*(.*?)\s*\}\}$/.exec(value ?? '')?.[1];
	if (expression === undefined) throw new Error('The cancellation expression is unavailable.');
	const result = require('node:vm').runInNewContext(expression, { github }, { timeout: 100 });
	if (typeof result !== 'boolean') throw new Error('Cancellation must be a Boolean.');
	return result;
}
for (const [ref, event_name, expected] of [
	['refs/heads/dev', 'push', false],
	['refs/heads/main', 'push', true],
	['refs/pull/18/merge', 'pull_request', true],
	['refs/heads/dev', 'pull_request', true],
	['refs/heads/dev', 'workflow_dispatch', true],
	['refs/heads/main', 'workflow_dispatch', true]
]) {
	if (cancellationFor(cancellationLine, { ref, event_name }) !== expected) {
		errors.push(`the actual cancellation policy is wrong for ${ref} ${event_name}`);
	}
}
if (cancellationFor('true', { ref: 'refs/heads/dev', event_name: 'push' }) === false) {
	errors.push('the original unconditional cancellation must fail the dev-release control');
}

/** Requires real reporter subprocess regressions on each native host before product units. */
function reporterLifecycleProblems(files) {
	const problems = [];
	for (const [rel, id, host, product, shell] of [
		[WINDOWS_BOX, 'test-ahk', 'windows-', 'Run AHK test suite', 'pwsh'],
		[MACOS_BOX, 'package-macos', 'macos-', 'Build release launcher', null]
	]) {
		const entry = files.find((candidate) => candidate.rel === rel);
		const job =
			entry && pipeline.jobsOfText(entry.text, rel).find((candidate) => candidate.id === id);
		if (!job || !(pipeline.field(job.body, 'runs-on') ?? '').startsWith(host)) {
			problems.push(`${rel} ${id} must qualify the reporter on its actual native host`);
			continue;
		}
		const steps = pipeline.steps(job.body);
		const matches = steps.filter((candidate) => candidate.name === REPORTER_STEP);
		const nodes = steps.filter(
			(candidate) => pipeline.stepField(candidate.body, 'uses') === 'actions/setup-node@v4'
		);
		const node = nodes[0];
		const unit = steps.findIndex((candidate) => candidate.name === product);
		const report = steps.findIndex((candidate) => candidate.name === REPORTER_STEP);
		if (
			matches.length !== 1 ||
			nodes.length !== 1 ||
			unit < 0 ||
			report <= steps.indexOf(node) ||
			report >= unit
		) {
			problems.push(
				`${rel} ${id} must run exactly one reporter self-test after Node and before product units`
			);
			continue;
		}
		const condition =
			rel === MACOS_BOX ? "${{ steps.stage-admission.outcome == 'success' }}" : null;
		if (rel === MACOS_BOX) {
			const admissions = steps.filter(
				(step) => pipeline.stepField(step.body, 'id') === 'stage-admission'
			);
			const downloads = steps.filter((step) => step.name === 'Download exact prior stage receipts');
			const admission = admissions[0],
				download = downloads[0];
			const admissionAt = steps.indexOf(admission),
				downloadAt = steps.indexOf(download);
			if (
				JSON.stringify(pipeline.needsOf(job.body)) !== JSON.stringify(['test-hs']) ||
				pipeline.field(job.body, 'if') !== null ||
				pipeline.field(job.body, 'continue-on-error') !== null ||
				admissions.length !== 1 ||
				steps.filter((step) => step.name === 'Admit complete successful predecessor stage')
					.length !== 1 ||
				downloads.length !== 1 ||
				!(downloadAt >= 0 && downloadAt < admissionAt && admissionAt < steps.indexOf(node))
			) {
				problems.push(
					rel +
						' ' +
						id +
						' must admit its exact adjacent predecessor before Node, reporter and product'
				);
				continue;
			}
			if (
				admission.name !== 'Admit complete successful predecessor stage' ||
				(pipeline.runOf(admission.body) ?? []).join('\n').trim() !==
					'node tools/ci/macos-stage-roles.cjs admit build "$RUNNER_TEMP/macos-stage-inputs" "$RUNNER_TEMP/macos-stage-prior.json"' ||
				!/^        env:\n          MACOS_STAGE_NEEDS: \$\{\{ toJSON\(needs\) \}\}\n        run:/m.test(
					admission.body
				) ||
				['if', 'continue-on-error', 'shell', 'working-directory'].some(
					(key) => pipeline.stepField(admission.body, key) !== null
				) ||
				pipeline.stepField(download.body, 'uses') !== 'actions/download-artifact@v4' ||
				['if', 'continue-on-error'].some(
					(key) => pipeline.stepField(download.body, key) !== null
				) ||
				!/^          pattern: macos-stage-unit-\*-\$\{\{ github\.run_id \}\}$/m.test(
					download.body
				) ||
				!/^          path: \$\{\{ runner\.temp \}\}\/macos-stage-inputs$/m.test(download.body) ||
				pipeline.stepField(steps[unit].body, 'if') !== condition ||
				pipeline.stepField(steps[unit].body, 'continue-on-error') !== null
			)
				problems.push(
					rel +
						' ' +
						id +
						' reporter admission must retain the exact unconditional receipt gate and guarded product'
				);
		}
		if (
			!node.body.includes("          node-version-file: '.node-version'") ||
			pipeline.stepField(node.body, 'if') !== condition ||
			pipeline.stepField(node.body, 'continue-on-error') !== null
		) {
			problems.push(
				`${rel} ${id} must prepare the repository Node runtime under its exact native-stage condition`
			);
		}
		const test = matches[0];
		if (
			(pipeline.runOf(test.body) ?? []).join('\n').trim() !== REPORTER_COMMAND ||
			pipeline.stepField(test.body, 'if') !== condition ||
			pipeline.stepField(test.body, 'continue-on-error') !== null ||
			pipeline.stepField(test.body, 'shell') !== shell ||
			pipeline.stepField(test.body, 'working-directory') !== null
		) {
			problems.push(
				`${rel} ${id} reporter self-tests must run the exact command and propagate failure on every profile`
			);
		}
	}
	return problems;
}

const REPORTER_STEP = 'Run reporter lifecycle self-tests';
const REPORTER_COMMAND = 'node tools/test/test-report.cjs';
errors.push(...reporterLifecycleProblems(pipeline.files()));
for (const [rel, shell] of [
	[WINDOWS_BOX, '        shell: pwsh\n'],
	[MACOS_BOX, '']
]) {
	const condition =
		rel === MACOS_BOX ? "        if: ${{ steps.stage-admission.outcome == 'success' }}\n" : '';
	const block = `      - name: ${REPORTER_STEP}\n${shell}${condition}        run: ${REPORTER_COMMAND}\n`;
	for (const [what, replacement] of [
		['missing native reporter self-test', ''],
		[
			'manual-only native reporter self-test',
			block.replace(
				`${shell}${condition}        run:`,
				`${shell}        if: github.event_name == 'workflow_dispatch'\n        run:`
			)
		],
		[
			'forgiven native reporter self-test',
			block.replace('        run:', '        continue-on-error: true\n        run:')
		],
		[
			'swallowed native reporter exit',
			block.replace(REPORTER_COMMAND, REPORTER_COMMAND + ' || true')
		],
		['duplicate native reporter self-test', block + '\n' + block],
		[
			'renamed native reporter command',
			block.replace(REPORTER_COMMAND, 'node tools/test/report.cjs --help')
		]
	]) {
		mustCatch(what, rel, block, replacement, reporterLifecycleProblems);
	}
	const steps = pipeline.steps(
		pipeline
			.jobsOfText(pipeline.files().find((candidate) => candidate.rel === rel).text, rel)
			.find((candidate) => candidate.id === (rel === WINDOWS_BOX ? 'test-ahk' : 'package-macos'))
			.body
	);
	const node = steps.find(
		(candidate) => pipeline.stepField(candidate.body, 'uses') === 'actions/setup-node@v4'
	).body;
	mustCatch(
		'reporter before Node setup',
		rel,
		node + '\n\n' + block,
		block + '\n' + node + '\n',
		reporterLifecycleProblems
	);
}

// Mac reporter predicates are valid only behind the actual adjacent-stage receipt gate.
{
	const job = pipeline
		.jobsOfText(pipeline.file(MACOS_BOX), MACOS_BOX)
		.find((entry) => entry.id === 'package-macos');
	const admission = pipeline.step(job.body, 'Admit complete successful predecessor stage');
	const download = pipeline.step(job.body, 'Download exact prior stage receipts');
	const node = pipeline.step(
		job.body,
		'Prepare Node for native policy fixtures and XCTest evidence'
	);
	const product = pipeline.step(job.body, 'Build release launcher');
	const condition = "        if: ${{ steps.stage-admission.outcome == 'success' }}\n";
	for (const [what, mutate] of [
		['missing reporter admission', (body) => body.replace(admission, '')],
		[
			'duplicate reporter admission',
			(body) => body.replace(admission, admission + '\n' + admission)
		],
		[
			'duplicate reporter admission with foreign id',
			(body) =>
				body.replace(
					admission,
					admission + '\n' + admission.replace('id: stage-admission', 'id: foreign-admission')
				)
		],
		[
			'unknown reporter admission command',
			(body) => body.replace(admission, admission.replace(' admit build ', ' admit e2e '))
		],
		[
			'manual-only reporter admission',
			(body) =>
				body.replace(
					admission,
					admission.replace(
						'        id:',
						"        if: github.event_name == 'workflow_dispatch'\n        id:"
					)
				)
		],
		[
			'forgiven reporter admission',
			(body) =>
				body.replace(
					admission,
					admission.replace('        id:', '        continue-on-error: true\n        id:')
				)
		],
		[
			'foreign reporter admission id',
			(body) =>
				body.replace(admission, admission.replace('id: stage-admission', 'id: foreign-admission'))
		],
		[
			'wrong reporter predecessor',
			(body) => body.replace('    needs:\n      - test-hs', '    needs:\n      - e2e-hs')
		],
		[
			'transitive reporter predecessor',
			(body) =>
				body.replace('    needs:\n      - test-hs', '    needs:\n      - test-hs\n      - e2e-hs')
		],
		[
			'missing reporter predecessor metadata',
			(body) => body.replace(admission, admission.replace('toJSON(needs)', 'toJSON(matrix)'))
		],
		['missing reporter receipt download', (body) => body.replace(download, '')],
		[
			'foreign reporter receipt download',
			(body) => body.replace(download, download.replace('macos-stage-unit-*', 'macos-stage-e2e-*'))
		],
		[
			'forgiven reporter receipt download',
			(body) =>
				body.replace(
					download,
					download.replace('        uses:', '        continue-on-error: true\n        uses:')
				)
		],
		[
			'reporter admission after Node',
			(body) => body.replace(admission, '').replace(node, node + '\n' + admission)
		],
		['unconditional Mac reporter Node', (body) => body.replace(node, node.replace(condition, ''))],
		[
			'unknown Mac reporter Node predicate',
			(body) => body.replace(node, node.replace(condition, '        if: always()\n'))
		],
		[
			'unconditional Mac reporter product',
			(body) => body.replace(product, product.replace(condition, ''))
		],
		[
			'forgiven Mac reporter product',
			(body) =>
				body.replace(
					product,
					product.replace('        shell:', '        continue-on-error: true\n        shell:')
				)
		],
		[
			'unknown Mac reporter product predicate',
			(body) => body.replace(product, product.replace(condition, '        if: always()\n'))
		],
		[
			'manual-only Mac reporter job',
			(body) => "    if: github.event_name == 'workflow_dispatch'\n" + body
		],
		['forgiven Mac reporter job', (body) => '    continue-on-error: true\n' + body]
	]) {
		const changed = mutate(job.body);
		assert.notEqual(changed, job.body, 'reporter admission inverse must alter its real owner');
		mustCatch(what, MACOS_BOX, job.body, changed, reporterLifecycleProblems);
	}
}

// Diagnostic timing JSON is retained separately from all qualification and role receipts.

/** Binds each timing upload to its actual reporter file without granting qualification. */
function luaTimingRetentionProblems(files) {
	const problems = [];
	for (const owner of LUA_TIMING_RETENTION) {
		try {
			const entries = files.filter((entry) => entry.rel === owner.file);
			assert.equal(entries.length, 1, 'One timing source workflow.');
			const workflow = YAML.parse(entries[0].text, { uniqueKeys: true });
			const jobs = Object.entries(workflow.jobs);
			const uploads = jobs.flatMap(([id, job]) =>
				(job.steps ?? []).filter((step) => step.name === owner.step).map((step) => ({ id, step }))
			);
			assert.equal(uploads.length, 1, 'One timing diagnostic uploader.');
			assert.equal(uploads[0].id, owner.job, 'Timing bytes stay on their producer host.');
			const steps = workflow.jobs[owner.job].steps;
			const producers = steps.filter((step) => step.name === owner.producer);
			assert.equal(producers.length, 1, 'One actual Lua timing producer.');
			assert.equal(producers[0]['working-directory'], owner.directory);
			assert.equal(
				producers[0].run.split('\n').filter((line) => line.trim() === owner.command).length,
				1,
				'The real reporter writes the exact retained JSON.'
			);
			const preceding = steps.filter((step) => step.name === owner.after);
			assert.equal(preceding.length, 1, 'One exact diagnostic placement anchor.');
			assert.ok(steps.indexOf(preceding[0]) >= steps.indexOf(producers[0]));
			assert.equal(steps.indexOf(uploads[0].step), steps.indexOf(preceding[0]) + 1);
			assert.deepEqual(uploads[0].step, {
				name: owner.step,
				if: '${{ !cancelled() }}',
				uses: 'actions/upload-artifact@v4',
				with: {
					name: owner.artifact,
					path: owner.path,
					'if-no-files-found': 'warn',
					'retention-days': 7
				}
			});
		} catch (error) {
			problems.push(owner.file + ' Lua timing retention refused: ' + error.message);
		}
	}
	return problems;
}
errors.push(...luaTimingRetentionProblems(pipeline.files()));
for (const owner of LUA_TIMING_RETENTION) {
	const source = pipeline.file(owner.file);
	const job = pipeline.jobsOfText(source, owner.file).find((entry) => entry.id === owner.job);
	const upload = pipeline.step(job.body, owner.step);
	const producer = pipeline.step(job.body, owner.producer);
	for (const [what, mutate] of [
		['missing upload', (text) => text.replace(upload, '')],
		[
			'cancelled-run upload',
			(text) => text.replace(upload, upload.replace('if: ${{ !cancelled() }}', 'if: always()'))
		],
		[
			'foreign predicate',
			(text) =>
				text.replace(
					upload,
					upload.replace('if: ${{ !cancelled() }}', 'if: ${{ !cancelled() && env.FOREIGN }}')
				)
		],
		['duplicate upload', (text) => text.replace(upload, upload + '\n' + upload)],
		[
			'success-only upload',
			(text) => text.replace(upload, upload.replace('if: ${{ !cancelled() }}', 'if: success()'))
		],
		[
			'failure-only upload',
			(text) => text.replace(upload, upload.replace('if: ${{ !cancelled() }}', 'if: failure()'))
		],
		[
			'manual-only upload',
			(text) =>
				text.replace(
					upload,
					upload.replace('if: ${{ !cancelled() }}', "if: github.event_name == 'workflow_dispatch'")
				)
		],
		[
			'default-success upload',
			(text) => text.replace(upload, upload.replace('        if: ${{ !cancelled() }}\n', ''))
		],
		[
			'forgiven upload',
			(text) =>
				text.replace(
					upload,
					upload.replace('        uses:', '        continue-on-error: true\n        uses:')
				)
		],
		[
			'wrong uploader',
			(text) => text.replace(upload, upload.replace('upload-artifact@v4', 'download-artifact@v4'))
		],
		[
			'broad path',
			(text) => text.replace(upload, upload.replace(owner.path, '${{ runner.temp }}/*.json'))
		],
		[
			'extra member',
			(text) =>
				text.replace(
					upload,
					upload.replace(
						'path: ' + owner.path,
						'path: |\n            ' + owner.path + '\n            ${{ runner.temp }}/foreign.json'
					)
				)
		],
		[
			'role receipt directory',
			(text) =>
				text.replace(
					upload,
					upload.replace(owner.path, '${{ runner.temp }}/macos-stage-output/receipt.json')
				)
		],
		[
			'mandatory evidence directory',
			(text) =>
				text.replace(
					upload,
					upload.replace(owner.path, '${{ runner.temp }}/linux-ci-evidence/test-linux.json')
				)
		],
		[
			'qualification artifact namespace',
			(text) => text.replace(upload, upload.replace(owner.artifact, 'assets-qualification-lua'))
		],
		[
			'missing source identity',
			(text) => text.replace(upload, upload.replace('-${{ github.sha }}', ''))
		],
		[
			'missing run identity',
			(text) => text.replace(upload, upload.replace('-${{ github.run_id }}', ''))
		],
		[
			'missing attempt identity',
			(text) => text.replace(upload, upload.replace('-${{ github.run_attempt }}', ''))
		],
		[
			'silent missing files',
			(text) =>
				text.replace(upload, upload.replace('if-no-files-found: warn', 'if-no-files-found: ignore'))
		],
		[
			'missing member promoted to requirement',
			(text) =>
				text.replace(upload, upload.replace('if-no-files-found: warn', 'if-no-files-found: error'))
		],
		[
			'missing retention',
			(text) => text.replace(upload, upload.replace('          retention-days: 7', ''))
		],
		[
			'upload before producer',
			(text) => text.replace(upload, '').replace(producer, upload + '\n' + producer)
		],
		[
			'wrong producer path',
			(text) =>
				text.replace(producer, producer.replace(owner.path, '${{ runner.temp }}/foreign.json'))
		],
		[
			'comment-only producer',
			(text) => text.replace(producer, producer.replace(owner.command, '# ' + owner.command))
		],
		['missing producer', (text) => text.replace(producer, '')],
		['duplicate producer', (text) => text.replace(producer, producer + '\n' + producer)],
		['wrong owner', (text) => text.replace('  ' + owner.job + ':\n', '  foreign-lua-owner:\n')]
	]) {
		const changed = mutate(source);
		assert.ok(changed !== source, 'Timing retention inverse must change actual source: ' + what);
		mustCatch(
			owner.job + ' timing ' + what,
			owner.file,
			source,
			changed,
			luaTimingRetentionProblems
		);
	}
}

/** Pins the real workflow ports of the callable manual selector. */
function manualLaneProblems(files) {
	const problems = [];
	const text = files.find((entry) => entry.rel === ENTRY).text;
	const jobs = pipeline.jobsOfText(text, ENTRY);
	const root = jobs.find((job) => job.id === ROOT);
	const caller = jobs.find((job) => job.id === PUBLICATION);
	const releaseEntry = files.find((entry) => entry.rel === RELEASE_BOX);
	const verdict = releaseEntry
		? pipeline
				.jobsOfText(releaseEntry.text, RELEASE_BOX)
				.find((job) => job.id === 'publication-plan')
		: undefined;
	const expectedInput = `  workflow_dispatch:
    inputs:
      os_lanes:
        description: Native OS lanes to validate (shared checks always run)
        type: choice
        required: true
        default: all
        options:
          - all
          - windows
          - macos
          - linux
          - windows+macos
          - windows+linux
          - macos+linux
`;
	if (text.split(expectedInput).length !== 2)
		problems.push('manual CI must expose exactly seven validated choices with default all');
	const selects = root
		? pipeline.steps(root.body).filter((step) => step.name === 'Select native OS lanes')
		: [];
	if (
		selects.length !== 1 ||
		pipeline.stepField(selects[0].body, 'id') !== 'lanes' ||
		pipeline.stepField(selects[0].body, 'run') !==
			'node tools/ci/manual-ci-lanes.cjs select >> "$GITHUB_OUTPUT"' ||
		pipeline.stepField(selects[0].body, 'env') !==
			'CI_EVENT: ${{ github.event_name }} CI_OS_SELECTION: ${{ inputs.os_lanes }}'
	) {
		problems.push('the plan must call the actual selector with event and manual choice');
	}
	const steps = root ? pipeline.steps(root.body) : [];
	const selectedAt = steps.findIndex((step) => step.name === 'Select native OS lanes');
	const preparedAt = steps.findIndex((step) => step.name === VALIDATE_SETUP);
	const checkedAt = steps.findIndex((step) => step.name === DEEPEN_STEP);
	if (!(preparedAt >= 0 && selectedAt === preparedAt + 1 && checkedAt === selectedAt + 1)) {
		problems.push(
			'selection must run after the checked-out Node setup and before the existing checks'
		);
	}
	for (const os of ['windows', 'macos', 'linux']) {
		if (
			!root ||
			!root.body.includes('      lane_' + os + ': ${{ steps.lanes.outputs.lane_' + os + ' }}\n')
		) {
			problems.push(`the plan must forward the actual ${os} selection output`);
		}
		const lane = jobs.find((job) => job.id === os);
		if (!lane || pipeline.field(lane.body, 'if') !== LANE_IF(os))
			problems.push(`the ${os} caller must consume its exact selection`);
	}
	const check =
		verdict &&
		pipeline
			.steps(verdict.body)
			.filter((step) => step.name === 'Assert every required lane and the original plan');
	if (
		!check ||
		check.length !== 1 ||
		pipeline.stepField(check[0].body, 'run') !==
			'node tools/ci/publication-plan.cjs receive publication-plan/ci-publication-plan.json' ||
		pipeline.stepField(check[0].body, 'env') !==
			'CI_OS_SELECTION: ${{ inputs.os_lanes }} CI_JOB_RESULTS: ${{ inputs.lane_results }}'
	) {
		problems.push(
			'the manual verdict must pass the actual complete needs receipt to the same selector owner'
		);
	}
	if (
		!caller ||
		!caller.body.includes("      os_lanes: ${{ inputs.os_lanes || 'all' }}\n") ||
		!caller.body.includes('      lane_results: ${{ toJSON(needs) }}\n')
	)
		problems.push(
			'the Release caller must forward the actual selection and complete needs receipt'
		);
	if (!caller || pipeline.field(caller.body, 'if') !== MANUAL_VERDICT_IF)
		problems.push('manual verdict must run after failed or skipped dependencies only on dispatch');
	return problems;
}

errors.push(...manualLaneProblems(pipeline.files()));
for (const [from, to] of [
	['        default: all\n', '        default: linux\n'],
	['          - windows+linux\n', '          - windows+macos+linux\n'],
	['node tools/ci/manual-ci-lanes.cjs select', 'echo lane_windows=true'],
	['CI_EVENT: ${{ github.event_name }}', 'CI_EVENT: workflow_dispatch'],
	['lane_results: ${{ toJSON(needs) }}', 'lane_results: {}'],
	[`    if: ${MANUAL_VERDICT_IF}\n`, '    if: always()\n'],
	["    if: needs.validate.outputs.lane_windows == 'true'\n", ''],
	[
		"    if: needs.validate.outputs.lane_macos == 'true'\n",
		"    if: needs.validate.outputs.lane_linux == 'true'\n"
	]
]) {
	// The event binding belongs to two ports; mutate just the plan occurrence.
	const source = pipeline.file(ENTRY);
	const mutated = pipeline
		.files()
		.map((entry) =>
			entry.rel === ENTRY ? { ...entry, text: source.replace(from, () => to) } : entry
		);
	assert.ok(source.includes(from), 'the actual workflow owns each manual selection mutation');
	assert.ok(manualLaneProblems(mutated).length > 0, 'manual selection mutation must refuse');
}

// Expected masks are independently declared; no expected status is derived from the resolver.
const choices = [
	['all', [true, true, true]],
	['windows', [true, false, false]],
	['macos', [false, true, false]],
	['linux', [false, false, true]],
	['windows+macos', [true, true, false]],
	['windows+linux', [true, false, true]],
	['macos+linux', [false, true, true]]
];
const nativeKeys = ['windows', 'macos', 'linux'];
for (const [choice, mask] of choices) {
	assert.deepEqual(Object.values(manual.selectLanes('workflow_dispatch', choice)), mask);
	const jobs = {
		validate: { result: 'success', outputs: {} },
		core: { result: 'success' }
	};
	for (const [index, os] of nativeKeys.entries()) {
		jobs[os] = { result: mask[index] ? 'success' : 'skipped' };
		jobs.validate.outputs[`lane_${os}`] = String(mask[index]);
	}
	assert.equal(manual.verifyManualJobs('workflow_dispatch', choice, jobs), true);
	for (const job of ['validate', 'core', ...nativeKeys]) {
		for (const result of ['failure', 'cancelled', 'skipped', 'success', '', null, true, 0, {}]) {
			if (result === jobs[job].result) continue;
			const altered = structuredClone(jobs);
			altered[job].result = result;
			assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, altered));
		}
		const missing = structuredClone(jobs);
		delete missing[job];
		assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, missing));
	}
	for (const os of nativeKeys) {
		for (const value of [undefined, true, false, '', 'unknown', 'TRUE', 'false', 'true']) {
			if (value === jobs.validate.outputs[`lane_${os}`]) continue;
			const altered = structuredClone(jobs);
			altered.validate.outputs[`lane_${os}`] = value;
			assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, altered));
		}
	}
	const extra = structuredClone(jobs);
	extra.validate.outputs.lane_other = 'false';
	assert.throws(() => manual.verifyManualJobs('workflow_dispatch', choice, extra));
	const env = {
		...process.env,
		CI_EVENT: 'workflow_dispatch',
		CI_OS_SELECTION: choice,
		CI_JOB_RESULTS: JSON.stringify(jobs)
	};
	const selected = spawnSync(
		process.execPath,
		[require.resolve('../ci/manual-ci-lanes.cjs'), 'select'],
		{ env, encoding: 'utf8', timeout: 5000 }
	);
	assert.equal(selected.error, undefined);
	assert.equal(selected.signal, null);
	assert.equal(selected.status, 0);
	assert.equal(selected.stderr, '');
	assert.equal(
		selected.stdout,
		nativeKeys.map((os, index) => `lane_${os}=${mask[index]}\n`).join('')
	);
	const verified = spawnSync(
		process.execPath,
		[require.resolve('../ci/manual-ci-lanes.cjs'), 'verdict'],
		{ env, encoding: 'utf8', timeout: 5000 }
	);
	assert.equal(verified.error, undefined);
	assert.equal(verified.signal, null);
	assert.equal(verified.status, 0);
	assert.equal(verified.stderr, '');
	assert.equal(verified.stdout, '[OK] Shared checks and selected native OS lanes passed.\n');
}
assert.deepEqual(manual.selectLanes('workflow_dispatch'), {
	windows: true,
	macos: true,
	linux: true
});
for (const invalid of [
	'',
	'ALL',
	'windows,linux',
	'macos+windows',
	'all+linux',
	' windows',
	'linux\n',
	null,
	false,
	[],
	{},
	'__proto__'
]) {
	assert.throws(() => manual.selectLanes('workflow_dispatch', invalid));
	for (const event of ['push', 'pull_request']) {
		assert.deepEqual(manual.selectLanes(event, invalid), {
			windows: true,
			macos: true,
			linux: true
		});
	}
}
for (const event of ['push', 'pull_request'])
	assert.throws(() => manual.verifyManualJobs(event, 'all', {}));
for (const input of ['{', 'null', '[]', '{}']) {
	const result = spawnSync(
		process.execPath,
		[require.resolve('../ci/manual-ci-lanes.cjs'), 'verdict'],
		{
			env: {
				...process.env,
				CI_EVENT: 'workflow_dispatch',
				CI_OS_SELECTION: 'windows',
				CI_JOB_RESULTS: input
			},
			encoding: 'utf8',
			timeout: 5000
		}
	);
	assert.equal(result.error, undefined);
	assert.equal(result.signal, null);
	assert.equal(result.status, 1);
	assert.equal(result.stdout, '');
}

/** Requires native signing tools before XCTest without release-key access. */
function sparkleToolProblems(files) {
	const problems = [];
	const mac = files.find((entry) => entry.rel === MACOS_BOX);
	const job =
		mac && pipeline.jobsOfText(mac.text, MACOS_BOX).find((entry) => entry.id === 'package-macos');
	const steps = job ? pipeline.steps(job.body) : [];
	const tools = steps.filter((step) => step.name === 'Install Sparkle signing tool');
	const toolAt = steps.findIndex((step) => step.name === 'Install Sparkle signing tool');
	const nativeAt = steps.findIndex((step) => step.name === 'Run Swift launcher tests on macOS 26');
	if (tools.length !== 1 || toolAt < 0 || nativeAt <= toolAt) {
		problems.push('the actual pinned Sparkle tool installer must precede native XCTest');
	} else if (
		pipeline.stepField(tools[0].body, 'if') !== macRole.condition('package-macos') ||
		pipeline.stepField(tools[0].body, 'continue-on-error') !== null ||
		/\bsecrets\.|SPARKLE_ED_PRIVATE_KEY/.test(codeOf(tools[0].body))
	) {
		problems.push(
			'native fixture tool installation must be unconditional and cannot receive release secrets'
		);
	}
	return problems;
}
errors.push(...sparkleToolProblems(pipeline.files()));
const sparkleToolBody = pipeline.step(
	pipeline.job('package-macos'),
	'Install Sparkle signing tool'
);
const sparkleNativeBody = pipeline.step(
	pipeline.job('package-macos'),
	'Run Swift launcher tests on macOS 26'
);
for (const [what, from, to] of [
	['missing native Sparkle tools', sparkleToolBody, ''],
	[
		'release-only native Sparkle tools',
		sparkleToolBody,
		sparkleToolBody.replace(
			'        shell: bash',
			'        if: inputs.release\n        shell: bash'
		)
	],
	[
		'forgiven native Sparkle tools',
		sparkleToolBody,
		sparkleToolBody.replace(
			'        shell: bash',
			'        continue-on-error: true\n        shell: bash'
		)
	],
	[
		'release secret handed to native Sparkle tools',
		sparkleToolBody,
		sparkleToolBody.replace(
			"          SPARKLE_VERSION: '2.9.2'",
			"          SPARKLE_VERSION: '2.9.2'\n          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}"
		)
	]
]) {
	mustCatch(what, MACOS_BOX, from, to, sparkleToolProblems);
}
const swappedSparkleSteps = pipeline.files().map((entry) =>
	entry.rel === MACOS_BOX
		? {
				...entry,
				text: entry.text
					.replace(sparkleToolBody, '__OWNED_SPARKLE_TOOL_STEP__')
					.replace(sparkleNativeBody, sparkleToolBody)
					.replace('__OWNED_SPARKLE_TOOL_STEP__', sparkleNativeBody)
			}
		: entry
);
assert.ok(
	sparkleToolProblems(swappedSparkleSteps).length > 0,
	'native XCTest before Sparkle tool installation must refuse'
);

// This qualifies the shared renderer and recorded bridge, not physical input.
const DISTRO_UNIT_COMMAND =
	'bash "$GITHUB_WORKSPACE/tools/test/prepare-linux-distro-unit.sh" "${{ env.INSTALL_DISTRO }}"';
const DISTRO_UNIT_HELPER = fs.readFileSync(
	path.join(__dirname, 'prepare-linux-distro-unit.sh'),
	'utf8'
);
// Every module group runs at once under the ordinary user, each in its own TMPDIR.
const DISTRO_UNIT_SUITE =
	'\tsudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \\\n' +
	'\t\tLUA_CPATH="$native_root/modules/?.so;;" TMPDIR="$group_tmp" "$interpreter" tests/run.lua --module="$unit_group" \\\n' +
	'\t\t>"$unit_logs/$unit_group.log" 2>&1 &\n';
// A group's exit, its order and its header reach the workflow diagnostic.
const DISTRO_UNIT_GROUP_TAIL = [
	'wait "${unit_pids[$index]}" || group_status=$?',
	'if [ "$unit_status" -eq 0 ]; then unit_status="$group_status"; fi',
	'printf \'distro-unit-group %s\\n\' "${unit_groups[$index]}"',
	'cat "$unit_logs/${unit_groups[$index]}.log"',
	'exit "$unit_status"'
];

// The supervised form adds diagnostics around the same one actual helper call.
// Pin its shell ownership envelope separately from the existing direct form;
// a comment, unreachable call or extra helper cannot satisfy this contract.
const DISTRO_DIAGNOSTIC_COMMAND =
	'python3 - "$unit_log" "$unit_root/static/ergopti_plus/linux/tests/run.lua" \'${{ env.INSTALL_DISTRO }}\' "$native_status" <<\'PYTHON\'';
const DISTRO_DIAGNOSTIC_SHA256 = '2b5eacc87b0cdb4aa1f04c6ef95cc60248245cbbb2389757070db20f2ed1196d';
const DISTRO_LOGGED_ENVELOPE = [
	'set -euo pipefail',
	'case "${{ env.INSTALL_DISTRO }}" in',
	'debian) apt-get install -y --no-install-recommends curl ;;',
	'fedora) dnf install -y curl ;;',
	'arch) pacman -Sy --noconfirm curl ;;',
	'alpine) apk add --no-cache curl ;;',
	'opensuse) zypper --non-interactive install curl ;;',
	'*) echo "::error::unknown archive unit distribution"; exit 1 ;;',
	'esac',
	'command -v curl',
	'test "$(id -u ergopti-ci)" -ge 1000',
	'unit_root="$(mktemp -d)"',
	'readonly unit_root',
	'trap \'rm -rf -- "$unit_root"\' EXIT',
	'cp -a "$GITHUB_WORKSPACE/." "$unit_root/"',
	'chown -R ergopti-ci:ergopti-ci "$unit_root"',
	'unit_log_dir="$RUNNER_TEMP/linux-distro-unit-logs"',
	'mkdir -p "$unit_log_dir"',
	'unit_log="$unit_log_dir/${{ env.INSTALL_DISTRO }}.log"',
	'set +e',
	'(cd "$unit_root/static/ergopti_plus/linux" &&',
	'bash "$GITHUB_WORKSPACE/tools/test/prepare-linux-distro-unit.sh" "${{ env.INSTALL_DISTRO }}") 2>&1 | tee "$unit_log"',
	'unit_pipeline_status=("${PIPESTATUS[@]}")',
	'set -e',
	'native_status="${unit_pipeline_status[0]}"',
	'set +e',
	'python3 - "$unit_log" "$unit_root/static/ergopti_plus/linux/tests/run.lua" \'${{ env.INSTALL_DISTRO }}\' "$native_status" <<\'PYTHON\'',
	'PYTHON',
	'diagnostic_status=$?',
	'set -e',
	'if [[ "$native_status" -ne 0 ]]; then exit "$native_status"; fi',
	'if [[ "${unit_pipeline_status[1]}" -ne 0 ]]; then exit "${unit_pipeline_status[1]}"; fi',
	'exit "$diagnostic_status"'
];

/** Reads only the existing supervised diagnostic's single quoted heredoc. */
function distroUnitDiagnostic(body) {
	const script = pipeline.runOf(body) ?? [];
	const opening = script
		.map((line, index) =>
			line.trim() === "'${{ env.INSTALL_DISTRO }}' \"$native_status\" <<'PYTHON'" ? index : -1
		)
		.filter((index) => index >= 0);
	const closing = script
		.map((line, index) => (line === 'PYTHON' ? index : -1))
		.filter((index) => index >= 0);
	if (opening.length !== 1 || closing.length !== 1 || closing[0] <= opening[0]) return null;
	return script.slice(opening[0] + 1, closing[0]).join('\n') + '\n';
}

/** Admits one exact direct command or the actual source-owned logged wrapper. */
function distroUnitInvocationFits(body) {
	const lines = logicalLines(body).filter((line) => line !== '');
	if (JSON.stringify(lines) === JSON.stringify([DISTRO_UNIT_COMMAND])) return true;
	const normalized = lines.map((line) => line.replace(/[ \t]+/g, ' ').trim());
	const at = normalized.indexOf(DISTRO_DIAGNOSTIC_COMMAND);
	const close = normalized.indexOf('PYTHON');
	if (at < 0 || close <= at) return false;
	const envelope = [...normalized.slice(0, at + 1), ...normalized.slice(close)];
	const diagnostic = distroUnitDiagnostic(body);
	return (
		JSON.stringify(envelope) === JSON.stringify(DISTRO_LOGGED_ENVELOPE) &&
		diagnostic !== null &&
		require('node:crypto').createHash('sha256').update(diagnostic).digest('hex') ===
			DISTRO_DIAGNOSTIC_SHA256
	);
}

/** Rejects native distro suites whose wrapper omits their real prerequisites. */
function distroUnitProblems(files, helper = DISTRO_UNIT_HELPER) {
	const linux = files.find((entry) => entry.rel === LINUX_BOX);
	const job =
		linux && pipeline.jobsOfText(linux.text, LINUX_BOX).find((row) => row.id === 'install-linux');
	const steps = job ? pipeline.steps(job.body) : [];
	const units = steps.filter(
		(step) => step.name === "The unit suite on this distribution's LuaJIT"
	);
	const problems = [];
	if (
		units.length !== 1 ||
		pipeline.stepField(units[0].body, 'shell') !== 'bash' ||
		!distroUnitInvocationFits(units[0].body)
	) {
		problems.push('the distro unit step must execute its fail-closed native prerequisite wrapper');
	}
	const code = helper
		.split('\n')
		.filter((line) => !/^\s*(?:#|--)/.test(line))
		.join('\n');
	if (
		(code.match(/^\s*sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \\$/gm) || [])
			.length !== 4
	) {
		problems.push(
			'the two original native preflights, added write preflight and unchanged suite must use the ordinary installation user'
		);
	}
	if (!code.includes(DISTRO_UNIT_SUITE)) {
		problems.push('the unchanged distro suite must inherit the exact admitted native modules');
	}
	for (const line of DISTRO_UNIT_GROUP_TAIL) {
		if (!code.split('\n').some((row) => row.trim() === line))
			problems.push('every parallel distro group must keep its exit, order and header: ' + line);
	}
	const lua = code.match(/"\$interpreter" -e '\n([\s\S]*?)\n'/)?.[1] || '';
	for (const statement of [
		'assert(ffi.C.getuid() ~= 0)',
		'assert(jit.os == "Linux" and _VERSION == "Lua 5.1")',
		'local uv, lfs = require("luv"), require("lfs")',
		'assert(debug.getinfo(uv.fs_stat, "S").what == "C")',
		'assert(debug.getinfo(lfs.attributes, "S").what == "C")'
	]) {
		if (!lua.split('\n').includes(statement))
			problems.push('native distro admission omits ' + statement);
	}
	if (!code.includes("/usr/bin/python3 -c 'import os; assert(os.geteuid() != 0)'")) {
		problems.push('the actual Python filesystem fixture requires an ordinary-user preflight');
	}
	for (const distro of ['debian', 'fedora', 'arch', 'alpine', 'opensuse']) {
		const packages = code.match(new RegExp('^\\t' + distro + '\\) ([^\\n]+)$', 'm'))?.[1] || '';
		if (!packages.split(/\s+/).includes('curl')) {
			problems.push(distro + ' must install the actual curl executable for native timer fixtures');
		}
		if (distro === 'debian' && !packages.split(/\s+/).includes('libc6-dev')) {
			problems.push(
				'Debian native builds require libc startup objects without recommended packages'
			);
		}
	}
	const ownership = 'chown ergopti-ci "$unit_driver" "$unit_driver/tests"';
	const chowns = code.match(/^chown .+$/gm) || [];
	if (
		!code.includes('unit_driver="$(pwd -P)"') ||
		!code.includes('test -f "$unit_driver/tests/run.lua"') ||
		JSON.stringify(chowns) !== JSON.stringify(['chown ergopti-ci "$unit_tmp"', ownership]) ||
		code.indexOf(ownership) >= code.indexOf('sudo -H -u ergopti-ci env')
	) {
		problems.push(
			'only the actual driver and tests directories must become writable before admission'
		);
	}
	const python =
		code.match(
			/^sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \\\n\t\/usr\/bin\/python3 -c '\n([\s\S]*?)\n'/m
		)?.[1] || '';
	const expectedPython = [
		'import os',
		'from pathlib import Path',
		'import tempfile',
		'assert(os.geteuid() != 0)',
		'working = Path.cwd()',
		'for directory in (working, working / "tests"):',
		'    assert(directory.stat().st_uid == os.geteuid())',
		'    with tempfile.TemporaryFile(dir=directory) as receipt:',
		'        assert(receipt.write(b"ordinary fixture write") == 22)',
		'        receipt.seek(0)',
		'        assert(receipt.read() == b"ordinary fixture write")',
		'assert(Path.cwd() == working)',
		'print("Native ordinary-user fixture writes: 2 directories admitted")'
	].join('\n');
	if (python !== expectedPython) {
		problems.push('the added native directory write preflight must execute its exact closed body');
	}
	const pythonLines = python.split('\n').map((line) => line.trim());
	for (const statement of [
		'assert(os.geteuid() != 0)',
		'working = Path.cwd()',
		'for directory in (working, working / "tests"):',
		'assert(directory.stat().st_uid == os.geteuid())',
		'with tempfile.TemporaryFile(dir=directory) as receipt:',
		'assert(receipt.write(b"ordinary fixture write") == 22)',
		'receipt.seek(0)',
		'assert(receipt.read() == b"ordinary fixture write")',
		'assert(Path.cwd() == working)'
	]) {
		if (!pythonLines.includes(statement))
			problems.push('native Python fixture admission omits ' + statement);
	}
	if (!/^set -euo pipefail$/m.test(code) || /^\s*set \+e\b/m.test(code) || SWALLOWED.test(code)) {
		problems.push('native distro preparation and suite failures may not be swallowed');
	}
	return problems;
}
errors.push(...distroUnitProblems(pipeline.files()));
const distroUnitBody = pipeline.step(
	pipeline.job('install-linux'),
	"The unit suite on this distribution's LuaJIT"
);
for (const [what, changed] of [
	['missing native distro wrapper', ''],
	[
		'interpreter-only native distro setup',
		distroUnitBody.replace(DISTRO_UNIT_COMMAND, 'luajit tests/run.lua')
	]
]) {
	mustCatch(what, LINUX_BOX, distroUnitBody, changed, distroUnitProblems);
}
mustCatch(
	'swallowed native distro wrapper',
	LINUX_BOX,
	distroUnitBody,
	distroUnitBody.replace(DISTRO_UNIT_COMMAND, DISTRO_UNIT_COMMAND + ' || true'),
	stepProblems
);
for (const [what, from, to] of [
	[
		'root suite execution',
		DISTRO_UNIT_SUITE,
		DISTRO_UNIT_SUITE.replace('sudo -H -u ergopti-ci ', '')
	],
	['root Lua admission', 'sudo -H -u ergopti-ci env', 'env'],
	['missing ordinary UID admission', 'assert(ffi.C.getuid() ~= 0)', ''],
	['missing Linux LuaJIT admission', 'assert(jit.os == "Linux" and _VERSION == "Lua 5.1")', ''],
	['missing native modules', 'local uv, lfs = require("luv"), require("lfs")', ''],
	['missing luv C entry point', 'assert(debug.getinfo(uv.fs_stat, "S").what == "C")', ''],
	['missing lfs C entry point', 'assert(debug.getinfo(lfs.attributes, "S").what == "C")', ''],
	['missing Python preflight', "/usr/bin/python3 -c 'import os; assert(os.geteuid() != 0)'", ''],
	[
		'swallowed unchanged unit suite',
		'"$interpreter" tests/run.lua',
		'"$interpreter" tests/run.lua || true'
	],
	['swallowed group exit', 'group_status=$?', 'group_status=0'],
	[
		'later group exit wins',
		'if [ "$unit_status" -eq 0 ]; then unit_status="$group_status"; fi',
		'unit_status=0'
	],
	['missing group header', "printf 'distro-unit-group %s\\n'", "printf 'group %s\\n'"],
	['helper exits green', 'exit "$unit_status"', 'exit 0']
]) {
	const changed = DISTRO_UNIT_HELPER.replace(from, to);
	assert.notEqual(changed, DISTRO_UNIT_HELPER, what + ' must actually mutate the native wrapper');
	assert.ok(distroUnitProblems(pipeline.files(), changed).length > 0, what + ' must refuse');
}

for (const [what, from, to] of [
	[
		'missing added filesystem preflight',
		"/usr/bin/python3 -c '\n",
		"/usr/bin/python3 -c 'omitted\n"
	],
	['missing added ordinary UID acknowledgement', '\nassert(os.geteuid() != 0)\n', '\n'],
	['missing driver fixture admission', 'test -f "$unit_driver/tests/run.lua"', ''],
	['missing Debian C startup objects', 'gcc libc6-dev make', 'gcc make'],
	['missing actual driver path', 'unit_driver="$(pwd -P)"', 'unit_driver="/tmp"'],
	[
		'missing driver write ownership',
		'chown ergopti-ci "$unit_driver" "$unit_driver/tests"',
		'chown ergopti-ci "$unit_driver/tests"'
	],
	[
		'missing tests write ownership',
		'chown ergopti-ci "$unit_driver" "$unit_driver/tests"',
		'chown ergopti-ci "$unit_driver"'
	],
	[
		'recursive source ownership',
		'chown ergopti-ci "$unit_driver" "$unit_driver/tests"',
		'chown -R ergopti-ci "$unit_driver" "$unit_driver/tests"'
	],
	[
		'missing native ownership acknowledgement',
		'assert(directory.stat().st_uid == os.geteuid())',
		''
	],
	[
		'missing actual native directory writes',
		'assert(receipt.write(b"ordinary fixture write") == 22)',
		''
	],
	['missing actual native readback', 'assert(receipt.read() == b"ordinary fixture write")', ''],
	['missing unchanged CWD acknowledgement', 'assert(Path.cwd() == working)', '']
]) {
	const changed = DISTRO_UNIT_HELPER.replace(from, to);
	assert.notEqual(changed, DISTRO_UNIT_HELPER, what + ' must actually mutate the native wrapper');
	assert.ok(distroUnitProblems(pipeline.files(), changed).length > 0, what + ' must refuse');
}
for (const distro of ['debian', 'fedora', 'arch', 'alpine', 'opensuse']) {
	const changed = DISTRO_UNIT_HELPER.replace(
		new RegExp('^(\\t' + distro + '\\) [^\\n]*?) curl( ;;)$', 'm'),
		'$1$2'
	);
	assert.notEqual(changed, DISTRO_UNIT_HELPER, distro + ' must actually lose its curl executable');
	assert.ok(
		distroUnitProblems(pipeline.files(), changed).length > 0,
		distro + ' without curl must refuse'
	);
}

const activeWriteLoop =
	'for directory in (working, working / "tests"):\n    assert(directory.stat().st_uid == os.geteuid())\n    with tempfile.TemporaryFile(dir=directory) as receipt:\n        assert(receipt.write(b"ordinary fixture write") == 22)\n        receipt.seek(0)\n        assert(receipt.read() == b"ordinary fixture write")';
const skippedWriteLoop =
	'if False:\n' +
	activeWriteLoop
		.split('\n')
		.map((line) => '    ' + line)
		.join('\n');
const skippedWriteHelper = DISTRO_UNIT_HELPER.replace(activeWriteLoop, skippedWriteLoop);
assert.notEqual(
	skippedWriteHelper,
	DISTRO_UNIT_HELPER,
	'the skipped-write control must actually change the native wrapper'
);
assert.ok(
	distroUnitProblems(pipeline.files(), skippedWriteHelper).length > 0,
	'disabled native directory writes must refuse'
);

// Preserve the incoming direct-command contract as a separately valid form.
const directDistroUnitStep =
	"      - name: The unit suite on this distribution's LuaJIT\n" +
	"        if: env.INSTALL_KIND == 'install'\n" +
	'        working-directory: static/ergopti_plus/linux\n' +
	'        shell: bash\n        run: |\n          ' +
	DISTRO_UNIT_COMMAND +
	'\n';
const directDistroFiles = pipeline.files().map((entry) =>
	entry.rel === LINUX_BOX
		? {
				...entry,
				text: entry.text.replace(distroUnitBody, directDistroUnitStep)
			}
		: entry
);
assert.deepEqual(
	distroUnitProblems(directDistroFiles),
	[],
	'the original exact one-command form remains admitted'
);
assert.equal(
	distroUnitInvocationFits(distroUnitBody),
	true,
	'the actual supervised form remains admitted'
);
for (const [what, from, to] of [
	['comment-only helper', DISTRO_UNIT_COMMAND, '# ' + DISTRO_UNIT_COMMAND],
	['unreachable helper', DISTRO_UNIT_COMMAND, 'if false; then ' + DISTRO_UNIT_COMMAND + '; fi'],
	['duplicated helper', DISTRO_UNIT_COMMAND, DISTRO_UNIT_COMMAND + '; ' + DISTRO_UNIT_COMMAND],
	[
		'helper redirected to a copy',
		DISTRO_UNIT_COMMAND,
		DISTRO_UNIT_COMMAND.replace('$GITHUB_WORKSPACE', '$unit_root')
	],
	['missing supervised curl', '          command -v curl\n', ''],
	['root private-copy admission', '          test "$(id -u ergopti-ci)" -ge 1000\n', ''],
	['missing private source copy', '          cp -a "$GITHUB_WORKSPACE/." "$unit_root/"\n', ''],
	[
		'suite runs in shared checkout',
		'(cd "$unit_root/static/ergopti_plus/linux" &&',
		'(cd "$GITHUB_WORKSPACE/static/ergopti_plus/linux" &&'
	],
	['missing raw log capture', '2>&1 | tee "$unit_log"', '2>&1'],
	[
		'late pipeline status capture',
		'unit_pipeline_status=("${PIPESTATUS[@]}")',
		'echo ignored\n          unit_pipeline_status=("${PIPESTATUS[@]}")'
	],
	[
		'tee mistaken for native exit',
		'native_status="${unit_pipeline_status[0]}"',
		'native_status="${unit_pipeline_status[1]}"'
	],
	['native exit fabricated green', 'native_status="${unit_pipeline_status[0]}"', 'native_status=0'],
	['diagnostic exit fabricated green', 'diagnostic_status=$?', 'diagnostic_status=0'],
	[
		'native failure swallowed',
		'if [[ "$native_status" -ne 0 ]]; then exit "$native_status"; fi',
		'if [[ "$native_status" -ne 0 ]]; then exit 0; fi'
	],
	[
		'tee failure swallowed',
		'if [[ "${unit_pipeline_status[1]}" -ne 0 ]]; then exit "${unit_pipeline_status[1]}"; fi',
		'true'
	],
	['diagnostic failure swallowed', 'exit "$diagnostic_status"', 'exit 0'],
	['zero tests accepted', 'passed + failed <= 0', 'passed + failed < 0'],
	['duplicate summaries accepted', 'len(frames) != 1', 'len(frames) < 1'],
	['contradictory native summary accepted', '(native_status == "0" and failed != 0)', 'False']
]) {
	const changed = distroUnitBody.replace(from, to);
	assert.notEqual(changed, distroUnitBody, what + ' must actually mutate the supervised source');
	mustCatch(what, LINUX_BOX, distroUnitBody, changed, distroUnitProblems);
}

// Execute the actual diagnostic and Bash exit tail with handwritten status/log
// controls. These certify this transport, not a distro suite or native modules.
const distroControlBash = bashExecutable();
const distroControlPython = process.platform === 'win32' ? 'python' : 'python3';
const distroControlWorkspace = path.resolve(__dirname, '../..').replaceAll('\\', '/');
const distroControlRoot = fs.mkdtempSync(
	path.join(require('node:os').tmpdir(), 'ergopti-distro wrapper-')
);
try {
	const log = path.join(distroControlRoot, 'unit.log');
	const runner = path.resolve(__dirname, '../../static/ergopti_plus/linux/tests/run.lua');
	const diagnostic = distroUnitDiagnostic(distroUnitBody);
	assert.notEqual(diagnostic, null, 'the current supervised diagnostic must be present');
	const footer = (pipeline.runOf(distroUnitBody) ?? []).slice(-3).join('\n');
	assert.equal(
		footer,
		DISTRO_LOGGED_ENVELOPE.slice(-3).join('\n'),
		'execute the actual native/tee/diagnostic exit tail'
	);
	const frame = (modules, passed, failed) =>
		'='.repeat(40) +
		'\nOVERALL RESULTS:\n' +
		'Total modules: ' +
		modules +
		'\nPassed tests:  ' +
		passed +
		'\nFailed tests:  ' +
		failed +
		'\n' +
		'='.repeat(40) +
		'\n';
	// One log per module group, under the header the parallel helper prints.
	const groups = [
		...fs
			.readFileSync(path.join(path.dirname(runner), 'support', 'module_groups.lua'), 'utf8')
			.matchAll(/\{ name = "([a-z_]+)"/g)
	].map((match) => match[1]);
	assert(groups.length > 1, 'the controls cover more than one module group');
	const grouped = (last, order = groups) =>
		order
			.map(
				(name, index) =>
					'distro-unit-group ' + name + '\n' + (index === order.length - 1 ? last : frame(1, 7, 0))
			)
			.join('');
	for (const [what, text, native, expected] of [
		['complete successful native log', grouped(frame(1, 7, 0)), '0', 0],
		['complete refused native log', grouped(frame(1, 6, 1)), '17', 0],
		['missing native summary', 'no terminal frame\n', '0', 2],
		['ungrouped native summary', frame(1, 7, 0), '0', 2],
		['duplicate native summaries', grouped(frame(1, 7, 0) + frame(1, 7, 0)), '0', 2],
		['missing native group', grouped(frame(1, 7, 0), groups.slice(0, -1)), '0', 2],
		['reordered native groups', grouped(frame(1, 7, 0), [...groups].reverse()), '0', 2],
		['zero native modules', grouped(frame(0, 7, 0)), '0', 2],
		['zero native cases', grouped(frame(1, 0, 0)), '0', 2],
		['green native exit with failed cases', grouped(frame(1, 6, 1)), '0', 2],
		['partial native frame', grouped(frame(1, 7, 0).slice(0, -42)), '0', 2]
	]) {
		fs.writeFileSync(log, text);
		const result = spawnSync(distroControlPython, ['-', log, runner, 'debian', native], {
			input: diagnostic,
			encoding: 'utf8',
			timeout: 5000
		});
		assert.equal(result.error, undefined, what);
		assert.equal(result.signal, null, what);
		assert.equal(result.status, expected, what);
		assert.equal(result.stderr, '', what);
		const propagated = spawnSync(
			distroControlBash,
			[
				'-c',
				'set -euo pipefail\nnative_status="$1"\nunit_pipeline_status=("$1" 0)\ndiagnostic_status="$2"\n' +
					footer,
				'distro-diagnostic-transport',
				native,
				String(result.status)
			],
			{ encoding: 'utf8', timeout: 5000 }
		);
		assert.equal(propagated.error, undefined, what);
		assert.equal(propagated.signal, null, what);
		assert.equal(
			propagated.status,
			native === '0' ? expected : 17,
			what + ': the actual Python outcome propagates through the real Bash tail'
		);
	}
	for (const [native, tee, diagnosticStatus, expected] of [
		[0, 0, 0, 0],
		[17, 23, 31, 17],
		[0, 23, 31, 23],
		[0, 0, 31, 31],
		[0, 23, 0, 23]
	]) {
		const result = spawnSync(
			distroControlBash,
			[
				'-c',
				'set -euo pipefail\nnative_status="$1"\nunit_pipeline_status=("$1" "$2")\ndiagnostic_status="$3"\n' +
					footer,
				'distro-transport',
				String(native),
				String(tee),
				String(diagnosticStatus)
			],
			{ encoding: 'utf8', timeout: 5000 }
		);
		assert.equal(result.error, undefined);
		assert.equal(result.signal, null);
		assert.equal(
			result.status,
			expected,
			'actual Bash tail preserves native/tee/diagnostic failure precedence'
		);
	}
	// The genuine helper's unsupported-distro branch refuses before installs or
	// native module builds. Trace proves one real call through the actual pipe;
	// no fake helper or successful native-suite certificate is substituted.
	const lines = pipeline.runOf(distroUnitBody) ?? [];
	const start = lines.findIndex((line) => line === 'set +e');
	const end = lines.findIndex(
		(line, index) => index > start && line === 'native_status="${unit_pipeline_status[0]}"'
	);
	assert(start >= 0 && end > start, 'the actual supervised pipeline must be present');
	const pipe = lines
		.slice(start, end + 1)
		.join('\n')
		.replaceAll('${{ env.INSTALL_DISTRO }}', '__guard_unsupported__');
	const quote = (value) => "'" + value.replaceAll("'", "'\"'\"'") + "'";
	const script =
		'set -euo pipefail\nunit_root=' +
		quote(distroControlWorkspace) +
		'\nunit_log=' +
		quote(log.replaceAll('\\', '/')) +
		'\n' +
		'unset BASH_XTRACEFD\nPS4="+ "\nset -x\n: "$GITHUB_WORKSPACE/tools/test/prepare-linux-distro-unit.sh"\n' +
		pipe +
		'\ndiagnostic_status=0\n' +
		footer;
	const result = spawnSync(distroControlBash, ['-c', script], {
		encoding: 'utf8',
		timeout: 5000,
		env: { ...process.env, GITHUB_WORKSPACE: distroControlWorkspace },
		stdio: ['pipe', 'pipe', 'pipe']
	});
	assert.equal(result.error, undefined, 'the genuine prerequisite helper refuses promptly');
	assert.equal(result.signal, null);
	assert.equal(
		result.status,
		1,
		'the real helper refusal propagates through tee and the actual native exit tail'
	);
	assert.match(fs.readFileSync(log, 'utf8'), /Unsupported mandatory unit distribution\./);
	// The real Bash renderer quotes this independently supplied exact path. Use
	// that primitive's spelling to handle spaces and apostrophes without admitting
	// a different helper, a guessed quote grammar, or an arbitrary helper suffix.
	// Bash 3.2 has no BASH_XTRACEFD. Ordinary stderr carries the outer trace;
	// the genuine pipeline's 2>&1 carries its helper trace into the raw log.
	// Do not also include stdout: tee copies the same raw log there.
	const traceLines = (result.stderr + fs.readFileSync(log, 'utf8')).split('\n');
	const helperPathRenderings = traceLines.filter((line) => line.startsWith('+ : '));
	assert.equal(helperPathRenderings.length, 1, 'the exact helper path has one Bash rendering');
	const helperPathRendering = helperPathRenderings[0].slice('+ : '.length);
	const calls = traceLines.filter(
		(line) => line.replace(/^\++ /, '') === 'bash ' + helperPathRendering + ' __guard_unsupported__'
	);
	assert.equal(calls.length, 1, 'the actual wrapped prerequisite helper executes exactly once');

	// Qualify a real tee write refusal independently of native-suite execution.
	// A controlled printf child supplies transport bytes; it is not a fake helper.
	const refusedLog = path.join(distroControlRoot, 'refused-log');
	fs.mkdirSync(refusedLog);
	const teePipe = pipe.replace(
		DISTRO_UNIT_COMMAND.replaceAll('${{ env.INSTALL_DISTRO }}', '__guard_unsupported__'),
		'printf "%s\\n" "controlled transport"'
	);
	assert.notEqual(teePipe, pipe, 'the transport-only producer replacement must be exact');
	const teeScript =
		'set -euo pipefail\nunit_root=' +
		quote(distroControlWorkspace) +
		'\nunit_log=' +
		quote(refusedLog.replaceAll('\\', '/')) +
		'\n' +
		'unset BASH_XTRACEFD\nPS4="+ "\nset -x\n' +
		teePipe +
		'\ndiagnostic_status=0\n' +
		footer;
	const refusedTee = spawnSync(distroControlBash, ['-c', teeScript], {
		encoding: 'utf8',
		timeout: 5000,
		stdio: ['pipe', 'pipe', 'pipe']
	});
	assert.equal(refusedTee.error, undefined);
	assert.equal(refusedTee.signal, null);
	assert.equal(
		refusedTee.status,
		1,
		'a real tee filesystem refusal cannot turn a successful producer green'
	);
	assert.match(
		refusedTee.stderr,
		/^\+ native_status=0$/m,
		'the actual PIPESTATUS source is successful'
	);
	assert.match(
		refusedTee.stderr,
		/^\+ exit 1$/m,
		'the genuine tee refusal reaches the actual Bash exit tail'
	);
} finally {
	fs.rmSync(distroControlRoot, { recursive: true, force: true });
}

const PHYSICAL_BROWSER_STEP = 'Test shared physical shortcut rendering';
const PHYSICAL_BROWSER_ALIAS = 'test:browser:physical-shortcuts';
const PHYSICAL_BROWSER_COMMAND = 'node ./tools/test/browser/physical-shortcuts.playwright.cjs';
const PHYSICAL_BROWSER_SCRIPTS = require('../../package.json').scripts;

/** Requires the recorded-bridge browser gate immediately after layer rendering. */
function physicalBrowserProblems(files, scripts = PHYSICAL_BROWSER_SCRIPTS) {
	const problems = [];
	const entry = files.find((file) => file.rel === COMMON_BOX);
	const core =
		entry && pipeline.jobsOfText(entry.text, COMMON_BOX).find((job) => job.id === 'common-e2e');
	const steps = core ? pipeline.steps(core.body) : [];
	const physical = steps.filter((step) => step.name === PHYSICAL_BROWSER_STEP);
	const at = steps.findIndex((step) => step.name === PHYSICAL_BROWSER_STEP);
	const layerAt = steps.findIndex((step) => step.name === 'Test shared layer editor rendering');
	const installAt = steps.findIndex((step) => step.name === 'Install shared UI browsers');
	if (
		physical.length !== 1 ||
		at !== layerAt + 1 ||
		layerAt < 0 ||
		installAt < 0 ||
		installAt >= layerAt
	) {
		problems.push(
			'physical shortcut renderer needs one gate immediately after layer rendering and browser installation'
		);
	} else if (
		pipeline.stepField(physical[0].body, 'if') !== null ||
		pipeline.stepField(physical[0].body, 'run') !== `npm run ${PHYSICAL_BROWSER_ALIAS}`
	) {
		problems.push('physical shortcut renderer must run its exact command on the shared JS lane');
	}
	if (scripts[PHYSICAL_BROWSER_ALIAS] !== PHYSICAL_BROWSER_COMMAND) {
		problems.push(
			'physical shortcut browser alias must execute the existing recorded-bridge fixture'
		);
	}
	return problems;
}
errors.push(...physicalBrowserProblems(pipeline.files()));
const physicalBrowserBody = pipeline.step(pipeline.job('common-e2e'), PHYSICAL_BROWSER_STEP);
for (const [what, changed] of [
	['missing physical browser step', ''],
	[
		'disabled formerly conditional physical browser gate',
		physicalBrowserBody.replace('        run:', '        if: false\n        run:')
	],
	[
		'disabled physical browser condition',
		physicalBrowserBody.replace(
			'        run:',
			"        if: steps.common-lot.outputs.suite == 'never'\n        run:"
		)
	],
	[
		'wrong physical browser lane',
		physicalBrowserBody.replace(
			'        run:',
			"        if: steps.common-lot.outputs.suite == 'properties'\n        run:"
		)
	],
	[
		'wrong physical browser command',
		physicalBrowserBody.replace(
			`npm run ${PHYSICAL_BROWSER_ALIAS}`,
			'npm run test:browser:layer-editor'
		)
	]
]) {
	mustCatch(what, COMMON_BOX, physicalBrowserBody, changed, physicalBrowserProblems);
}
const layerBrowserBody = pipeline.step(
	pipeline.job('common-e2e'),
	'Test shared layer editor rendering'
);
const misplacedPhysicalBrowser = pipeline.files().map((entry) =>
	entry.rel === COMMON_BOX
		? {
				...entry,
				text: entry.text
					.replace(physicalBrowserBody, '')
					.replace(layerBrowserBody, physicalBrowserBody + layerBrowserBody)
			}
		: entry
);
assert.ok(
	physicalBrowserProblems(misplacedPhysicalBrowser).length > 0,
	'physical renderer before layer renderer must refuse'
);
for (const changed of [undefined, 'node ./tools/test/browser/layer-editor.playwright.cjs']) {
	const scripts = {
		...PHYSICAL_BROWSER_SCRIPTS,
		[PHYSICAL_BROWSER_ALIAS]: changed
	};
	assert.ok(
		physicalBrowserProblems(pipeline.files(), scripts).length > 0,
		'missing or redirected physical browser alias must refuse'
	);
}

// Package downloads have a separate clock from the unchanged native audio gate.
const LINUX_AUDIO_SETUP = 'Install native virtual audio locale prerequisites';
const LINUX_AUDIO_NATIVE = 'Parse native virtual audio state independently of user locale';
const LINUX_AUDIO_INSTALL =
	'sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends pulseaudio pulseaudio-utils locales language-pack-fr language-pack-de';
const LINUX_AUDIO_LOCALES = 'sudo locale-gen fr_FR.UTF-8 de_DE.UTF-8';
const LINUX_AUDIO_COMMANDS = [
	'python3 tests/hardware/run_system_audio_locale_receipts.py',
	'ERGOPTI_SYSTEM_TEST_LUA=lua5.4 python3 tests/hardware/run_system_audio_locale_receipts.py'
];

/** Keeps exact locale prerequisites outside the unchanged two-minute native budget. */
function linuxAudioPrerequisiteProblems(files) {
	const steps = files
		.filter((entry) => entry.rel === LINUX_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'e2e-linux')
		.flatMap((job) => pipeline.steps(job.body));
	const setup = steps.filter((step) => step.name === LINUX_AUDIO_SETUP);
	const native = steps.filter((step) => step.name === LINUX_AUDIO_NATIVE);
	const setupAt = steps.findIndex((step) => step.name === LINUX_AUDIO_SETUP);
	const nativeAt = steps.findIndex((step) => step.name === LINUX_AUDIO_NATIVE);
	if (setup.length !== 1 || native.length !== 1 || setupAt + 1 !== nativeAt) {
		return ['native audio needs one prerequisite step immediately before its native gate'];
	}
	const problems = [];
	for (const step of [setup[0], native[0]]) {
		if (
			pipeline.stepField(step.body, 'if') !== linuxRow(step.name, NOT_CANCELLED) ||
			pipeline.stepField(step.body, 'working-directory') !== 'static/ergopti_plus/linux' ||
			pipeline.stepField(step.body, 'continue-on-error') !== null
		) {
			problems.push(`${step.name} must remain an unforgiven Linux harness under !cancelled()`);
		}
	}
	if (
		pipeline.stepField(setup[0].body, 'timeout-minutes') !== '10' ||
		JSON.stringify(logicalLines(setup[0].body)) !==
			JSON.stringify([LINUX_AUDIO_INSTALL, LINUX_AUDIO_LOCALES])
	) {
		problems.push(
			'native audio setup must install the exact packages/locales with its separate budget'
		);
	}
	if (
		pipeline.stepField(native[0].body, 'timeout-minutes') !== '2' ||
		JSON.stringify(logicalLines(native[0].body)) !== JSON.stringify(LINUX_AUDIO_COMMANDS)
	) {
		problems.push(
			'native audio must retain both exact interpreter invocations and its two-minute budget'
		);
	}
	return problems;
}

errors.push(...linuxAudioPrerequisiteProblems(pipeline.files()));
const linuxAudioSetupBody = pipeline.step(pipeline.job('e2e-linux'), LINUX_AUDIO_SETUP);
const linuxAudioNativeBody = pipeline.step(pipeline.job('e2e-linux'), LINUX_AUDIO_NATIVE);
for (const [what, from, to] of [
	['missing audio prerequisites', linuxAudioSetupBody, ''],
	...['pulseaudio', 'pulseaudio-utils', 'locales', 'language-pack-fr', 'language-pack-de'].map(
		(name) => [
			`missing native audio package ${name}`,
			LINUX_AUDIO_INSTALL,
			LINUX_AUDIO_INSTALL.split(' ')
				.filter((word) => word !== name)
				.join(' ')
		]
	),
	['missing native audio locale generation', LINUX_AUDIO_LOCALES, 'true'],
	...LINUX_AUDIO_COMMANDS.map((command) => [
		`missing native audio interpreter ${command}`,
		linuxAudioNativeBody,
		linuxAudioNativeBody.replace(`          ${command}\n`, '')
	]),
	[
		'changed native audio budget',
		linuxAudioNativeBody,
		linuxAudioNativeBody.replace('timeout-minutes: 2', 'timeout-minutes: 10')
	],
	[
		'shared audio setup/native clock',
		linuxAudioSetupBody,
		linuxAudioSetupBody.replace('timeout-minutes: 10', 'timeout-minutes: 2')
	],
	[
		'APT returned to native audio clock',
		linuxAudioNativeBody,
		linuxAudioNativeBody.replace(
			'        run: |\n',
			`        run: |\n          ${LINUX_AUDIO_INSTALL}\n`
		)
	],
	[
		'disabled audio setup',
		linuxAudioSetupBody,
		linuxAudioSetupBody.replace(linuxRow(LINUX_AUDIO_SETUP, NOT_CANCELLED), 'false')
	],
	[
		'forgiven audio setup',
		linuxAudioSetupBody,
		linuxAudioSetupBody + '\n        continue-on-error: true'
	],
	[
		'audio prerequisites after native execution',
		linuxAudioSetupBody + '\n\n' + linuxAudioNativeBody,
		linuxAudioNativeBody + '\n\n' + linuxAudioSetupBody
	]
]) {
	mustCatch(what, LINUX_BOX, from, to, linuxAudioPrerequisiteProblems);
}

// A disjoint mandatory cohort; literal ownership is narrower than a generic Swift filter.
const PAC_SOURCE_STEP = retainedManagedStep(
	'      - name: Qualify actual native PAC source ownership XCTest controls\n        if: ${{ !cancelled() && matrix.scenario != \'runtime\' }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          test -n "$ERGOPTI_NATIVE_HTTP_PYTHON"\n          test -x "$ERGOPTI_NATIVE_HTTP_PYTHON"\n          test -z "${ERGOPTI_DEV_QUALIFICATION_PROFILE:-}"\n          transcript="$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-xctest.log"\n          source_receipt="$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-inputs.json"\n          node tools/diagnostics/native_pac_source_evidence.cjs begin "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE" "$source_receipt"\n          set +e\n          swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])ManagedPACSourceTests([/.]|$)\' 2>&1 | tee "$transcript"\n          source_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#source_statuses[@]}" -eq 2\n          node tools/diagnostics/native_pac_source_evidence.cjs judge "$transcript" "${source_statuses[0]}" "${source_statuses[1]}" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE" "$source_receipt" "$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-verdict.json"\n        timeout-minutes: 10\n'
);
function nativePacSourceProblems(files) {
	const mac = files.find((file) => file.rel === MACOS_BOX)?.text ?? '';
	const jobs = [[macRole.body(mac, 'managed-ollama-native')]];
	const problems = [];
	if (jobs.length !== 1) return ['native-source-job'];
	const job = jobs[0][0];
	if (mac.split(PAC_SOURCE_STEP).length !== 2 || job.split(PAC_SOURCE_STEP).length !== 2)
		problems.push('native-source-exact-step');
	const sdk = job.indexOf(
		'      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n'
	);
	const source = job.indexOf(PAC_SOURCE_STEP);
	const pac = job.indexOf('      - name: Qualify actual native PAC and WPAD XCTest controls\n');
	if (sdk < 0 || source <= sdk || pac <= source) problems.push('native-source-order');
	for (const name of [
		'native-pac-source-xctest.log',
		'native-pac-source-inputs.json',
		'native-pac-source-verdict.json'
	]) {
		const line = `            \${{ env.ERGOPTI_OLLAMA_BUILD_ROOT }}/${name}`;
		if (job.split('\n').filter((actual) => actual === line).length !== 1)
			problems.push('native-source-retained-' + name);
	}
	return problems;
}
errors.push(...nativePacSourceProblems(pipeline.files()));
// The actual raw Source10 condition remains mandatory after the retired fast route.
const rawSourceFiles = require('./ci-pipeline.cjs').real().files();
const rawSourceStep = PAC_SOURCE_STEP;
assert.doesNotThrow(() => pipeline.validateRaw(rawSourceFiles));
for (const [replacement, error] of [
	[
		'',
		/\[ci-pipeline\] no step named 'Qualify actual native PAC source ownership XCTest controls'/
	],
	[
		rawSourceStep + rawSourceStep,
		/\[ci-pipeline\] step 'Qualify actual native PAC source ownership XCTest controls' appears 2 times in one job/
	],
	[
		rawSourceStep.replace(
			'if: ' +
				macRole.condition(
					'managed-ollama-native',
					"${{ !cancelled() && matrix.scenario != 'runtime' }}"
				),
			'if: false'
		),
		/\[ci-full-default\].*full step condition/
	],
	[
		rawSourceStep.replace(
			'if: ' +
				macRole.condition(
					'managed-ollama-native',
					"${{ !cancelled() && matrix.scenario != 'runtime' }}"
				),
			'if: ${{ success() }}'
		),
		/\[ci-full-default\].*full step condition/
	]
]) {
	const changed = rawSourceFiles.map((file) =>
		file.rel === MACOS_BOX ? { ...file, text: file.text.replace(rawSourceStep, replacement) } : file
	);
	assert.notDeepEqual(changed, rawSourceFiles);
	assert.throws(() => pipeline.fromFiles(changed), error);
}
console.log('PASS: exact Source10 raw condition controls=5; native execution unqualified.');
for (const [name, changed] of [
	['missing source step', ''],
	['duplicate source step', PAC_SOURCE_STEP + PAC_SOURCE_STEP],
	[
		'skipped source step',
		PAC_SOURCE_STEP.replace(
			'if: ' +
				macRole.condition(
					'managed-ollama-native',
					"${{ !cancelled() && matrix.scenario != 'runtime' }}"
				),
			'if: false'
		)
	],
	['ignored source child status', PAC_SOURCE_STEP.replace('"${source_statuses[0]}"', '"0"')],
	['ignored source capture status', PAC_SOURCE_STEP.replace('"${source_statuses[1]}"', '"0"')],
	['foreign source run', PAC_SOURCE_STEP.replace('"$GITHUB_RUN_ID"', '"foreign"')],
	['foreign source attempt', PAC_SOURCE_STEP.replace('"$GITHUB_RUN_ATTEMPT"', '"1"')],
	[
		'source verdict before capture closure',
		PAC_SOURCE_STEP.replace('source_statuses=("${PIPESTATUS[@]}")', 'source_statuses=(0 0)')
	]
])
	mustCatch(name, MACOS_BOX, PAC_SOURCE_STEP, changed, nativePacSourceProblems);
for (const name of [
	'native-pac-source-xctest.log',
	'native-pac-source-inputs.json',
	'native-pac-source-verdict.json'
]) {
	const line = `            \${{ env.ERGOPTI_OLLAMA_BUILD_ROOT }}/${name}\n`;
	mustCatch('missing retained ' + name, MACOS_BOX, line, '', nativePacSourceProblems);
}

// Actual begin/judge over a private tracked checkout. These are constructed
// XCTest frames, not an execution or a qualification of native Swift controls.
function checkNativePacSourceReceipts() {
	const os = require('node:os');
	const reader = require('../diagnostics/native_pac_source_evidence.cjs');
	const repository = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-source-receipt-'));
	const root = path.resolve(__dirname, '../..');
	const git = (args) => {
		const result = spawnSync('git', args, { cwd: repository, encoding: 'utf8' });
		assert.equal(result.status, 0, result.stderr);
		return result.stdout.trim();
	};
	const write = (relative, bytes) => {
		const file = path.join(repository, relative);
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, bytes);
	};
	const methods = [
		'testStrictUTF8AndBOMAdmission',
		'testStrictUTF16RejectsMalformedSurrogatesAndNUL',
		'testAuthorityScopeIncludesCanonicalSchemeHostEffectivePort',
		'testBindingEscapesRequestDataAndRefusesInvalidSource',
		'testRealPACSourceDecodersRetireEverySession',
		'testRealPACSourceStatusSizeAndEncodingRefusalsRetire',
		'testRealPACSourceRedirectsHaveFreshCredentialFreeOwners',
		'testRealPACSourceTrustAnchorsPreserveHostnameAndDowngradeRefusal',
		'testRealPACSourceDeadlineRefusesAndRetiresBeforeReplacement',
		'testOriginalLookupBudgetIncludesSettingsPreparation'
	];
	let count = 0;
	try {
		const tests = 'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/';
		for (const suite of [
			'ManagedPACSourceTests',
			'ReleaseArchiveStagingTests',
			'SparkleArchiveUpdateAcceptanceTests',
			'HomebrewArchiveAcceptanceTests'
		]) {
			const relative = tests + suite + '.swift';
			write(relative, fs.readFileSync(path.join(root, relative)));
		}
		for (const relative of [
			'static/ergopti_plus/_shared/modules/network/proxy_policy.json',
			'static/ergopti_plus/macos/tests/support/native_pac_source_fixture.py',
			'tools/diagnostics/native_pac_source_evidence.cjs',
			'tools/diagnostics/swift_xctest_evidence.cjs'
		])
			write(relative, fs.readFileSync(path.join(root, relative)));
		git(['init', '-q']);
		git(['add', '--', '.']);
		git([
			'-c',
			'user.name=Source receipt control',
			'-c',
			'user.email=source-control@example.invalid',
			'commit',
			'-qm',
			'Private source-receipt control'
		]);
		const candidate = git(['rev-parse', 'HEAD']);
		const epoch = [candidate, '123', '2', 'arm64'];
		const before = path.join(repository, 'before.json'),
			capture = path.join(repository, 'capture.log');
		assert.equal(reader.main(['begin', ...epoch, before], repository), 0);
		count++;
		const lines = [
			"Test Suite 'Selected tests' started at 2026-10-09",
			"Test Suite 'ErgoptiPlusPackageTests.xctest' started at 2026-10-09",
			"Test Suite 'ManagedPACSourceTests' started at 2026-10-09"
		];
		for (const method of methods) {
			lines.push(
				`Test Case '-[ErgoptiPlusTests.ManagedPACSourceTests ${method}]' started.`,
				`Test Case '-[ErgoptiPlusTests.ManagedPACSourceTests ${method}]' passed (0.1 seconds).`
			);
		}
		for (const suite of [
			'ManagedPACSourceTests',
			'ErgoptiPlusPackageTests.xctest',
			'Selected tests'
		])
			lines.push(
				`Test Suite '${suite}' passed at 2026-10-09`,
				'Executed 10 tests, with 0 failures (0 unexpected) in 1 seconds'
			);
		const transcript = lines.join('\n') + '\n';
		write('capture.log', transcript);
		let serial = 0;
		const judge = (fields = epoch, statuses = ['0', '0']) =>
			reader.main(
				[
					'judge',
					capture,
					...statuses,
					...fields,
					before,
					path.join(repository, `verdict-${serial++}.json`)
				],
				repository
			);
		assert.equal(judge(), 0);
		count++;
		for (const [index, value] of [
			[0, '0'.repeat(40)],
			[1, '124'],
			[2, '3'],
			[3, 'amd64']
		]) {
			const changed = [...epoch];
			changed[index] = value;
			assert.notEqual(judge(changed), 0);
			count++;
		}
		for (const statuses of [
			['1', '0'],
			['0', '1']
		]) {
			assert.notEqual(judge(epoch, statuses), 0);
			count++;
		}
		for (const method of methods) {
			write('capture.log', transcript.replace(` ${method}]' passed`, ` ${method}]' skipped`));
			assert.notEqual(judge(), 0);
			count++;
		}
		write('capture.log', transcript);
		const policy = 'static/ergopti_plus/_shared/modules/network/proxy_policy.json';
		const original = fs.readFileSync(path.join(repository, policy));
		write(policy, Buffer.concat([original, Buffer.from('\n')]));
		assert.notEqual(judge(), 0);
		count++;
		write(policy, original);
		const unbound = 'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/Unbound.swift';
		write(unbound, '// unbound\n');
		assert.notEqual(judge(), 0);
		count++;
		fs.unlinkSync(path.join(repository, unbound));
		fs.unlinkSync(capture);
		const symlinkCaseRuns = canRunSymlinkCase(
			'native PAC source receipt refuses a symlinked capture'
		);
		if (symlinkCaseRuns) {
			fs.symlinkSync(before, capture);
			assert.notEqual(judge(), 0);
			count++;
			fs.unlinkSync(capture);
		}
		write('capture.log', Buffer.from([0xff]));
		assert.notEqual(judge(), 0);
		count++;
		const expected = symlinkCaseRuns ? 22 : 21;
		assert.equal(count, expected);
		console.log(
			`PASS: native PAC source receipt controls=${expected}; constructed transcripts/native execution unqualified.`
		);
	} finally {
		fs.rmSync(repository, { recursive: true, force: true });
	}
}
checkNativePacSourceReceipts();

// Saved simultaneous actions must follow both unchanged kernel prerequisites.
const LINUX_SIMULTANEOUS_HARNESS = 'static/ergopti_plus/linux/tests/hardware/run_daemon_live.sh';
const LINUX_SIMULTANEOUS_COMMAND =
	'python3 tests/hardware/run_native_subreaper.py luajit tests/hardware/run_simultaneous_configuration_real.lua';
const LINUX_SIMULTANEOUS_ENVELOPE = [
	'luajit tests/hardware/run_modifier_custody.lua',
	'CUSTODY=$?',
	'if [ "${CUSTODY}" = "0" ]; then',
	'python3 tests/hardware/run_native_subreaper.py luajit tests/hardware/run_input_owner_real.lua',
	'CUSTODY=$?',
	'fi',
	'if [ "${CUSTODY}" = "0" ]; then',
	'if [ "${GITHUB_ACTIONS:-}" = true ]; then',
	'mode=full',
	'if [ -z "${RUNNER_TEMP:-}" ]; then CUSTODY=2; fi',
	'receipt="${RUNNER_TEMP:-}/stable-linux-simultaneous-native.json"',
	'if [ "$CUSTODY" = "0" ]; then',
	'node ../../../tools/ci/dev-release-qualification.cjs --scope linux-simultaneous-native --receipt "$receipt" || CUSTODY=$?',
	'fi',
	'if [ "$CUSTODY" = "0" ]; then',
	'mode="$(node ../../../tools/ci/dev-release-qualification.cjs --scope linux-simultaneous-native --validate-scope-receipt "$receipt")" || CUSTODY=$?',
	'fi',
	'else',
	'mode=full',
	'fi',
	'if [ "$CUSTODY" != "0" ]; then',
	': # The existing owned-host failure enclosure below performs cleanup.',
	'elif [ "$mode" = deferred ]; then',
	"echo '[DEFERRED] linux-simultaneous-native: qualified=false; saved-configuration supplement not executed.'",
	'elif [ "$mode" = full ]; then',
	LINUX_SIMULTANEOUS_COMMAND,
	'CUSTODY=$?',
	'else',
	'CUSTODY=2',
	'fi',
	'fi',
	'if [ "${CUSTODY}" != "0" ]; then',
	'kill ${PIDS} 2>/dev/null',
	'exit "${CUSTODY}"',
	'fi'
];

const LINUX_SIMULTANEOUS_STEP = 'The whole daemon, live — a trigger typed, a tray shown';
const LINUX_SIMULTANEOUS_ENV = [
	'GITHUB_ACTIONS',
	'GITHUB_REPOSITORY',
	'GITHUB_EVENT_NAME',
	'GITHUB_REF',
	'GITHUB_SHA',
	'RUNNER_TEMP',
	'ERGOPTI_DEV_RELEASE_RELEASE',
	'ERGOPTI_DEV_RELEASE_PRERELEASE',
	'ERGOPTI_DEV_RELEASE_CHANNEL',
	'ERGOPTI_DEV_RELEASE_TAG',
	'ERGOPTI_DEV_RELEASE_VERSION'
];
const LINUX_SIMULTANEOUS_SOURCE_ENTRY =
	'sudo env \\\n' +
	LINUX_SIMULTANEOUS_ENV.map((key) => '            ' + key + '="$' + key + '" \\\n').join('') +
	`            bash ${LINUX_SIMULTANEOUS_HARNESS}`;
const LINUX_SIMULTANEOUS_ENTRY = `bash ${LINUX_SIMULTANEOUS_HARNESS}`;
const LINUX_SIMULTANEOUS_NATIVE_WORKFLOW = [
	'sudo modprobe uinput',
	'sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends at-spi2-core openbox python3-gi gir1.2-gtk-3.0 \\',
	'  dbus-x11 xvfb x11-xkb-utils libayatana-appindicator3-1 lua-luv xclip',
	'sudo env \\',
	'  GITHUB_ACTIONS="$GITHUB_ACTIONS" \\',
	'  GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \\',
	'  GITHUB_EVENT_NAME="$GITHUB_EVENT_NAME" \\',
	'  GITHUB_REF="$GITHUB_REF" \\',
	'  GITHUB_SHA="$GITHUB_SHA" \\',
	'  RUNNER_TEMP="$RUNNER_TEMP" \\',
	'  ERGOPTI_DEV_RELEASE_RELEASE="$ERGOPTI_DEV_RELEASE_RELEASE" \\',
	'  ERGOPTI_DEV_RELEASE_PRERELEASE="$ERGOPTI_DEV_RELEASE_PRERELEASE" \\',
	'  ERGOPTI_DEV_RELEASE_CHANNEL="$ERGOPTI_DEV_RELEASE_CHANNEL" \\',
	'  ERGOPTI_DEV_RELEASE_TAG="$ERGOPTI_DEV_RELEASE_TAG" \\',
	'  ERGOPTI_DEV_RELEASE_VERSION="$ERGOPTI_DEV_RELEASE_VERSION" \\',
	`  ${LINUX_SIMULTANEOUS_ENTRY}`
];

/** Binds the inspected harness to its mandatory existing native workflow call. */
function linuxSimultaneousWorkflowProblems(files) {
	try {
		pipeline.fromFiles(files);
	} catch {
		return ['Linux raw workflow admission refused'];
	}
	const steps = files
		.filter((entry) => entry.rel === LINUX_E2E_BOX)
		.flatMap((entry) => pipeline.jobsOfText(entry.text, entry.rel))
		.filter((job) => job.id === 'e2e-linux')
		.flatMap((job) => pipeline.steps(job.body))
		.filter((step) => step.name === LINUX_SIMULTANEOUS_STEP);
	if (steps.length !== 1) return ['Linux needs exactly one whole-daemon native step'];
	const step = steps[0];
	let wrapperFits = true;
	try {
		require('./ci-linux-qualified-run.cjs').assertLinuxQualifiedRun(
			(pipeline.runOf(step.body) ?? []).filter((line) => !line.trimStart().startsWith('#')),
			LINUX_SIMULTANEOUS_NATIVE_WORKFLOW
		);
	} catch {
		wrapperFits = false;
	}
	if (
		pipeline.stepField(step.body, 'if') !== linuxRow(step.name, NOT_CANCELLED) ||
		pipeline.stepField(step.body, 'timeout-minutes') !== '6' ||
		pipeline.stepField(step.body, 'continue-on-error') !== null ||
		!wrapperFits
	) {
		return [
			'Linux whole-daemon enrollment must retain its prerequisites, exact call and failure budget'
		];
	}
	return [];
}

// Inspect the raw wrapper only after the strict full graph admits it.
const linuxSimultaneousRawFiles = pipeline.rawFiles();
errors.push(...linuxSimultaneousWorkflowProblems(linuxSimultaneousRawFiles));
const linuxSimultaneousRawJob = pipeline
	.jobsOfText(
		linuxSimultaneousRawFiles.find((file) => file.rel === LINUX_E2E_BOX).text,
		LINUX_E2E_BOX
	)
	.find((job) => job.id === 'e2e-linux');
const linuxSimultaneousStepBody = pipeline.step(
	linuxSimultaneousRawJob.body,
	LINUX_SIMULTANEOUS_STEP
);
let linuxSimultaneousWorkflowRefusals = 0;
for (const [what, from, to] of [
	['omitted live harness', LINUX_SIMULTANEOUS_SOURCE_ENTRY, 'true'],
	[
		'redirected live harness',
		LINUX_SIMULTANEOUS_SOURCE_ENTRY,
		`${LINUX_SIMULTANEOUS_SOURCE_ENTRY} --skip`
	],
	[
		'forgiven live harness',
		LINUX_SIMULTANEOUS_SOURCE_ENTRY,
		`${LINUX_SIMULTANEOUS_SOURCE_ENTRY} || true`
	],
	['disabled live step', linuxRow(LINUX_SIMULTANEOUS_STEP, NOT_CANCELLED), '${{ false }}'],
	['every matrix row', linuxRow(LINUX_SIMULTANEOUS_STEP, NOT_CANCELLED), NOT_CANCELLED],
	['changed live budget', 'timeout-minutes: 6', 'timeout-minutes: 12'],
	[
		'forgiven live step',
		'timeout-minutes: 6',
		'timeout-minutes: 6\n        continue-on-error: true'
	],
	['missing native uinput prerequisite', 'sudo modprobe uinput', 'true'],
	[
		'missing native dependencies',
		'--no-install-recommends at-spi2-core',
		'--no-install-recommends'
	],
	['missing X11 clipboard prerequisite', 'lua-luv xclip', 'lua-luv'],
	['missing strict wrapper status', 'set -euo pipefail', 'set +e'],
	[
		'wrong workflow selection scope',
		'--scope linux-e2e-suite --receipt',
		'--scope linux-simultaneous-native --receipt'
	],
	[
		'fabricated workflow disposition',
		'mode="$(node tools/ci/dev-release-qualification.cjs --scope linux-e2e-suite --validate-scope-receipt "$receipt")"',
		'mode=deferred'
	],
	['false workflow native credit', 'qualified=false', 'qualified=true'],
	['workflow full branch disabled', 'elif [ "$mode" = full ]; then', 'elif false; then'],
	['unknown workflow mode forgiven', 'exit 1', 'exit 0'],
	['sudo environment omitted', 'sudo env \\', 'sudo \\'],
	['sudo current source omitted', 'GITHUB_SHA="$GITHUB_SHA"', 'GITHUB_SHA=unbound'],
	[
		'sudo policy context omitted',
		'ERGOPTI_DEV_RELEASE_VERSION="$ERGOPTI_DEV_RELEASE_VERSION"',
		'ERGOPTI_DEV_RELEASE_VERSION=unbound'
	],
	['sudo receipt root omitted', 'RUNNER_TEMP="$RUNNER_TEMP"', 'RUNNER_TEMP=/unrelated']
]) {
	assert.ok(linuxSimultaneousStepBody.includes(from), `${what}: causal preimage must exist`);
	assert.equal(linuxSimultaneousStepBody.split(from).length, 2, `${what}: one step-local target`);
	const changed = linuxSimultaneousRawFiles.map((entry) => ({
		...entry,
		text:
			entry.rel === LINUX_E2E_BOX
				? entry.text.replace(linuxSimultaneousStepBody, linuxSimultaneousStepBody.replace(from, to))
				: entry.text
	}));
	assert.ok(
		linuxSimultaneousWorkflowProblems(changed).length > 0,
		`${what} must refuse enrollment`
	);
	linuxSimultaneousWorkflowRefusals++;
}
assert.equal(linuxSimultaneousWorkflowRefusals, 20);

/** Retains exact ordered native calls, status admission and failing teardown. */
function linuxSimultaneousEnrollmentProblems(source) {
	const body = `        run: |\n${source
		.split('\n')
		.map((line) => `          ${line}`)
		.join('\n')}`;
	const lines = logicalLines(body).filter((line) => line !== '');
	const first = LINUX_SIMULTANEOUS_ENVELOPE[0];
	const phase = 'LLM_READY="$(mktemp -u)"';
	const at = lines.indexOf(first);
	const end = lines.indexOf(phase);
	if (
		at < 0 ||
		end <= at ||
		lines.filter((line) => line === phase).length !== 1 ||
		JSON.stringify(lines.slice(at, end)) !== JSON.stringify(LINUX_SIMULTANEOUS_ENVELOPE)
	) {
		return ['Linux simultaneous configuration needs the complete ordered native custody envelope'];
	}
	for (const command of [first, LINUX_SIMULTANEOUS_ENVELOPE[3], LINUX_SIMULTANEOUS_COMMAND]) {
		if (lines.filter((line) => line === command).length !== 1) {
			return ['each mandatory Linux native command must execute exactly once in its envelope'];
		}
	}
	// A closed prefix prevents an enclosing function, false branch or quote from
	// turning the otherwise exact sequence into unexecuted source text.
	const raw = source.split('\n');
	const start = raw.findIndex((line) => line.trim() === first);
	for (const input of [source, `${raw.slice(0, start).join('\n')}\n`]) {
		const syntax = spawnSync(bashExecutable(), ['-n'], { input, encoding: 'utf8' });
		if (syntax.error || syntax.signal || syntax.status !== 0) {
			return ['Linux native envelope needs valid shell syntax and a closed top-level prefix'];
		}
	}
	return [];
}

// This enrollment guard owns the raw saved-selection protocol. Its full
// projection is inspected separately below; projection cannot replace policy
// admission and its failure/cleanup assertions with the native command alone.
const linuxSimultaneousHarness = fs.readFileSync(
	path.resolve(__dirname, '../..', LINUX_SIMULTANEOUS_HARNESS),
	'utf8'
);
errors.push(...linuxSimultaneousEnrollmentProblems(linuxSimultaneousHarness));
const linuxSimultaneousBlock = LINUX_SIMULTANEOUS_ENVELOPE.slice(6, -4).join('\n');
const linuxSimultaneousNormalized = linuxSimultaneousHarness
	.split('\n')
	.map((line) => line.trim())
	.join('\n');
assert.equal(
	linuxSimultaneousEnrollmentProblems(
		linuxSimultaneousHarness + '\n# A separate owner may add post-native setup here.\n'
	).length,
	0,
	'additive owner work outside the executable native envelope must remain permitted'
);
let linuxSimultaneousEnvelopeRefusals = 0;
for (const [what, from, to] of [
	['old harness omits the supplement', linuxSimultaneousBlock, ''],
	[
		'duplicate supplement',
		linuxSimultaneousBlock,
		`${linuxSimultaneousBlock}\n${linuxSimultaneousBlock}`
	],
	['disabled supplement', linuxSimultaneousBlock, linuxSimultaneousBlock.replace('= "0"', '= "1"')],
	[
		'wrong native helper',
		LINUX_SIMULTANEOUS_COMMAND,
		LINUX_SIMULTANEOUS_COMMAND.replace('run_simultaneous_configuration_real', 'run_daemon_live')
	],
	['broadened native command', LINUX_SIMULTANEOUS_COMMAND, `${LINUX_SIMULTANEOUS_COMMAND} --skip`],
	['forgiven native failure', LINUX_SIMULTANEOUS_COMMAND, `${LINUX_SIMULTANEOUS_COMMAND} || true`],
	[
		'uncaptured supplement status',
		linuxSimultaneousBlock,
		linuxSimultaneousBlock.replace(
			`${LINUX_SIMULTANEOUS_COMMAND}\nCUSTODY=$?`,
			`${LINUX_SIMULTANEOUS_COMMAND}\nCUSTODY=0`
		)
	],
	['missing old input owner', LINUX_SIMULTANEOUS_ENVELOPE[3], 'true'],
	[
		'changed native deadline wrapper',
		LINUX_SIMULTANEOUS_COMMAND,
		LINUX_SIMULTANEOUS_COMMAND.replace(
			'run_native_subreaper.py',
			'run_native_subreaper.py --timeout 80'
		)
	],
	['supplement before old input owner', LINUX_SIMULTANEOUS_ENVELOPE[3], LINUX_SIMULTANEOUS_COMMAND],
	['forgiven final failure', 'exit "${CUSTODY}"', 'exit 0'],
	['missing failure cleanup', 'kill ${PIDS} 2>/dev/null', 'true'],
	[
		'hidden in a false branch',
		LINUX_SIMULTANEOUS_ENVELOPE[0],
		`if false; then\n${LINUX_SIMULTANEOUS_ENVELOPE[0]}`
	],
	['only a commented supplement', LINUX_SIMULTANEOUS_COMMAND, `# ${LINUX_SIMULTANEOUS_COMMAND}`],
	['missing CI identity gate', '${GITHUB_ACTIONS:-}', '${UNBOUND_ACTIONS:-}'],
	['missing receipt root refusal', 'if [ -z "${RUNNER_TEMP:-}" ]; then CUSTODY=2; fi', 'true'],
	[
		'wrong saved selection scope',
		'--scope linux-simultaneous-native --receipt',
		'--scope linux-e2e-suite --receipt'
	],
	[
		'forgiven saved selection failure',
		'--receipt "$receipt" || CUSTODY=$?',
		'--receipt "$receipt" || true'
	],
	[
		'fabricated saved disposition',
		'mode="$(node ../../../tools/ci/dev-release-qualification.cjs --scope linux-simultaneous-native --validate-scope-receipt "$receipt")" || CUSTODY=$?',
		'mode=deferred'
	],
	[
		'forgiven saved receipt failure',
		'--validate-scope-receipt "$receipt")" || CUSTODY=$?',
		'--validate-scope-receipt "$receipt")" || true'
	],
	['false saved native credit', 'qualified=false', 'qualified=true'],
	['saved full branch disabled', 'elif [ "$mode" = full ]; then', 'elif false; then'],
	['unknown saved mode forgiven', 'else\nCUSTODY=2\nfi', 'else\nCUSTODY=0\nfi']
]) {
	assert.ok(linuxSimultaneousNormalized.includes(from), `${what}: causal preimage must exist`);
	assert.ok(
		linuxSimultaneousEnrollmentProblems(linuxSimultaneousNormalized.replace(from, to)).length > 0,
		`${what} must refuse native qualification`
	);
	linuxSimultaneousEnvelopeRefusals++;
}
assert.equal(linuxSimultaneousEnvelopeRefusals, 23);
console.log(
	`PASS: Linux simultaneous wiring ${linuxSimultaneousWorkflowRefusals} workflow and ${linuxSimultaneousEnvelopeRefusals} custody-envelope refusals; native execution unqualified.`
);

// The separate full projection must preserve every executable native command
// and its failing custody status after strict raw scope admission.
const linuxSimultaneousProjected =
	require('./fixtures/ci-scoped-full-branches.cjs').projectLinuxHarness(linuxSimultaneousHarness);
const LINUX_SIMULTANEOUS_FULL_ENVELOPE = [
	LINUX_SIMULTANEOUS_ENVELOPE[0],
	'CUSTODY=$?',
	'if [ "${CUSTODY}" = "0" ]; then',
	LINUX_SIMULTANEOUS_ENVELOPE[3],
	'CUSTODY=$?',
	'fi',
	'if [ "${CUSTODY}" = "0" ]; then',
	LINUX_SIMULTANEOUS_COMMAND,
	'CUSTODY=$?',
	'fi',
	'if [ "${CUSTODY}" != "0" ]; then',
	'kill ${PIDS} 2>/dev/null',
	'exit "${CUSTODY}"',
	'fi'
];
function linuxSimultaneousProjectedProblems(source) {
	const lines = logicalLines(
		`        run: |\n${source
			.split('\n')
			.map((line) => `          ${line}`)
			.join('\n')}`
	).filter((line) => line !== '');
	const at = lines.indexOf(LINUX_SIMULTANEOUS_ENVELOPE[0]);
	const end = lines.indexOf('LLM_READY="$(mktemp -u)"');
	return at >= 0 &&
		end > at &&
		JSON.stringify(lines.slice(at, end)) === JSON.stringify(LINUX_SIMULTANEOUS_FULL_ENVELOPE)
		? []
		: ['full native projection must preserve the ordered custody commands and failure cleanup'];
}
assert.equal(linuxSimultaneousProjectedProblems(linuxSimultaneousProjected).length, 0);
for (const [name, from, to] of [
	['missing full native command', LINUX_SIMULTANEOUS_COMMAND, 'true'],
	[
		'forgiven full native command',
		LINUX_SIMULTANEOUS_COMMAND,
		`${LINUX_SIMULTANEOUS_COMMAND} || true`
	],
	['forgiven full custody status', 'exit "${CUSTODY}"', 'exit 0']
]) {
	assert.ok(linuxSimultaneousProjected.includes(from), `${name}: causal preimage exists`);
	assert.ok(
		linuxSimultaneousProjectedProblems(linuxSimultaneousProjected.replace(from, to)).length > 0,
		`${name} must refuse full native qualification`
	);
}

// The temporary Mac exception still requires closed context and retained gates.
require('./test-macos-dev-qualification-deferral.cjs').run({ includeLeafControls: false });

// GitHub Pages reads the domain from the deployed root after each replacement.
const siteRoot = path.resolve(__dirname, '../..');
assert.equal(fs.readFileSync(path.join(siteRoot, 'static/CNAME'), 'utf8'), 'ergopti.fr\n');
const siteWorkflow = fs.readFileSync(
	path.join(siteRoot, '.github/workflows/deploy-site.yml'),
	'utf8'
);
assert.deepEqual(
	siteDeploymentProblems(siteWorkflow),
	[],
	'only tested production bytes reach Pages'
);
// actions/download-artifact v4/src/download-artifact.ts:42,162–165.
// ID selection does not set the named single-artifact flag.
for (const job of Object.values(YAML.parse(siteWorkflow).jobs)) {
	for (const step of job.steps.filter((row) => row.with?.['artifact-ids'])) {
		const inputs = { name: step.with.name, mergeMultiple: step.with['merge-multiple'] };
		const resolvedPath = step.with.path;
		const artifact = { name: 'selected-artifact' };
		const isSingleArtifactDownload = !!inputs.name;
		const destination =
			isSingleArtifactDownload || inputs.mergeMultiple
				? resolvedPath
				: path.join(resolvedPath, artifact.name);
		assert.equal(
			destination,
			resolvedPath,
			'one admitted ID must extract exactly where verify reads'
		);
		assert.notEqual(path.join(resolvedPath, artifact.name), resolvedPath);
	}
}
for (const [label, from, to] of SITE_DEPLOY_REFUSALS) {
	assert.equal(siteWorkflow.split(from).length, 2, label + ' has one real source seam');
	assert.ok(siteDeploymentProblems(siteWorkflow.replace(from, () => to)).length > 0, label);
}

// Current read-only number-row cohort is mandatory independently of full package prerequisites.
const NUMBER_ROW_NATIVE_STEP = retainedManagedStep(
	'      - name: Qualify actual selected number-row Carbon XCTest controls\n        if: ${{ !cancelled() && matrix.scenario != \'runtime\' }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          evidence="$RUNNER_TEMP/number-row-source-evidence"\n          mkdir "$evidence"\n          transcript="$evidence/number-row-xctest.log"\n          source="static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"\n          producer="static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"\n          test "$(git rev-parse HEAD)" = "$GITHUB_SHA"\n          git show "$GITHUB_SHA:$source" | cmp - "$source"\n          git show "$GITHUB_SHA:$producer" | cmp - "$producer"\n          cp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          printf \'%s\\n\' "$GITHUB_SHA" > "$evidence/tested-sha.txt"\n          export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"\n          export ERGOPTI_TIS_EVIDENCE_SESSION="$(node -e \'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))\')"\n          set +e\n          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])NumberRowSourceProbeTests([/.]|$)\' 2>&1 | tee "$transcript"\n          number_row_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#number_row_statuses[@]}" -eq 2\n          set +e\n          python3 tools/diagnostics/keyboard_geometry_xctest_receipt.py \\\n            --class NumberRowSourceProbeTests --source "$evidence/NumberRowSourceProbeTests.swift" \\\n            --log "$transcript" --receipt "$evidence/number-row-verdict.json" \\\n            --test-exit "${number_row_statuses[0]}" --capture-exit "${number_row_statuses[1]}"\n          number_row_receipt_status=$?\n          node - "$evidence/number-row-verdict.json" "$ERGOPTI_TIS_EVIDENCE_DIR" "$ERGOPTI_TIS_EVIDENCE_SESSION" <<\'NODE\'\n          const fs = require(\'node:fs\');\n          const transport = require(\'./tools/diagnostics/tis_evidence_transport.cjs\');\n          const receipt = JSON.parse(fs.readFileSync(process.argv[2], \'utf8\'));\n          if (!receipt.passed || receipt.scope !== \'NumberRowSourceProbeTests\' || receipt.expected_count !== 12 || receipt.received_count !== 12) throw new Error(\'exact twelve-case number-row receiving refused\');\n          const session = transport.validate(process.argv[3], process.argv[4]);\n          const expectedSources = {\n            testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations: \'com.apple.keylayout.US\',\n            testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor: \'com.apple.keylayout.French\',\n            testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage: \'com.apple.keylayout.US\',\n            testActualUSCapsMaskChangesAnIndependentLetterExpectation: \'com.apple.keylayout.US\',\n            testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI: \'com.apple.keylayout.French\',\n            testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead: \'com.apple.keylayout.US\',\n            testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject: \'com.apple.keylayout.US\'\n          };\n          const expected = Object.keys(expectedSources).sort();\n          const observed = session.receipts.map((row) => {\n            if (row.test.state !== \'present\' || row.omittedEvents !== 0) throw new Error(\'native diagnostic identity refused\');\n            const match = /^(?:(?:\\w+\\.)?NumberRowSourceProbeTests\\.|-\\[(?:\\w+\\.)?NumberRowSourceProbeTests )(test\\w+)(?:\\])?:(com\\.apple\\.keylayout\\.(?:US|French))$/.exec(row.test.value);\n            if (!match || !Object.hasOwn(expectedSources, match[1]) || match[2] !== expectedSources[match[1]]) throw new Error(\'foreign native method fixture\');\n            const captures = row.events.filter((event) => event.phase === \'original.capture\');\n            if (captures.length !== 1 || captures[0].original?.id?.state !== \'present\' || typeof captures[0].original.id.value !== \'string\' || captures[0].original.id.value.length === 0) throw new Error(\'captured original source unavailable\');\n            const originalID = captures[0].original.id.value;\n            for (const phase of [\'restore.inner.after\', \'restore.outer.after\']) {\n              const events = row.events.filter((event) => event.phase === phase);\n              if (events.length !== 1 || events[0].status !== 0) throw new Error(\'native source restoration refused\');\n              if (events[0].original?.id?.state !== \'present\' || events[0].original.id.value !== originalID || events[0].current?.id?.state !== \'present\' || events[0].current.id.value !== originalID) throw new Error(\'sampled selected source restoration refused\');\n            }\n            return match[1];\n          }).sort();\n          if (!session.complete || JSON.stringify(observed) !== JSON.stringify(expected)) throw new Error(\'exact seven native diagnostic closures refused\');\n          NODE\n          number_row_tis_status=$?\n          set -e\n          cmp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cmp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          test "$number_row_receipt_status" -eq 0\n          test "$number_row_tis_status" -eq 0\n        timeout-minutes: 10\n'
);
const NUMBER_ROW_NATIVE_RETENTION = retainedManagedStep(
	"      - name: Retain selected number-row Carbon XCTest diagnostics\n        if: ${{ always() && matrix.scenario != 'runtime' }}\n        uses: actions/upload-artifact@v4\n        with:\n          name: number-row-carbon-${{ env.MACOS_STAGE_ARCHITECTURE }}-${{ github.run_id }}-${{ github.run_attempt }}\n          if-no-files-found: error\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n            ${{ runner.temp }}/number-row-source-evidence/number-row-verdict.json\n            ${{ runner.temp }}/number-row-source-evidence/tested-sha.txt\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbe.swift\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbeTests.swift\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/start.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/manifest.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/record-*.dat\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/refusal.json\n"
);
function numberRowNativeReceivingProblems(files) {
	const mac = files.find((entry) => entry.rel === MACOS_BOX)?.text ?? '';
	const jobs = [[macRole.body(mac, 'managed-ollama-native')]];
	if (jobs.length !== 1) return ['number-row native owner job missing or duplicated'];
	const job = jobs[0][0];
	const problems = [];
	for (const [label, step] of [
		['cohort', NUMBER_ROW_NATIVE_STEP],
		['retention', NUMBER_ROW_NATIVE_RETENTION]
	]) {
		if (mac.split(step).length !== 2 || job.split(step).length !== 2)
			problems.push('number-row exact mandatory ' + label);
	}
	const sdk = job.indexOf('      - name: Retain independent native SDK XCTest diagnostics\n');
	const selected = job.indexOf(NUMBER_ROW_NATIVE_STEP);
	const retained = job.indexOf(NUMBER_ROW_NATIVE_RETENTION);
	const next = job.indexOf(
		'      - name: Qualify actual native PAC source ownership XCTest controls\n'
	);
	if (sdk < 0 || selected <= sdk || retained <= selected || next <= retained)
		problems.push('number-row bounded early SDK receiving order');
	return problems;
}
errors.push(...numberRowNativeReceivingProblems(pipeline.files()));
mustCatch(
	'missing selected native cohort',
	MACOS_BOX,
	NUMBER_ROW_NATIVE_STEP,
	'',
	numberRowNativeReceivingProblems
);
for (const [label, before, after] of [
	[
		'partial or foreign selected class',
		'NumberRowSourceProbeTests([/.]|$)',
		'KeyboardSourceProbeTests([/.]|$)'
	],
	['missing actual receipt judge', 'keyboard_geometry_xctest_receipt.py', 'missing_receipt.py'],
	['captured native process status substituted', '${number_row_statuses[0]}', '0'],
	[
		'different registered source accepted',
		'--source "$evidence/NumberRowSourceProbeTests.swift"',
		'--source "$evidence/foreign.swift"'
	],
	[
		'twelve native cases weakened',
		'receipt.expected_count !== 12',
		'receipt.expected_count !== 11'
	],
	['native source restoration not checked', "['restore.inner.after', 'restore.outer.after']", '[]'],
	[
		'capture failure forgiven',
		'test "$number_row_receipt_status" -eq 0',
		': "$number_row_receipt_status"'
	]
]) {
	mustCatch(
		label,
		MACOS_BOX,
		NUMBER_ROW_NATIVE_STEP,
		NUMBER_ROW_NATIVE_STEP.replace(before, after),
		numberRowNativeReceivingProblems
	);
}
for (const [label, before, after] of [
	[
		'skipped retention',
		'if: ' +
			macRole.condition('managed-ollama-native', "${{ always() && matrix.scenario != 'runtime' }}"),
		'if: false'
	],
	[
		'missing native raw log retention',
		'            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n',
		''
	]
]) {
	mustCatch(
		label,
		MACOS_BOX,
		NUMBER_ROW_NATIVE_RETENTION,
		NUMBER_ROW_NATIVE_RETENTION.replace(before, after),
		numberRowNativeReceivingProblems
	);
}

// The Darwin receiver is mandatory raw work, never a deferred qualification alias.
{
	const files = require('./ci-pipeline.cjs').real().files();
	const name = 'Receive selected-release shell corpus and native guardian cancellation';
	const head = `      - name: ${name}\n`;
	const body = pipeline.step(macRole.body(pipeline.file(MACOS_BOX), 'managed-ollama-native'), name);
	// Runtime receiving: the Intel XCTest cell skips it.
	const runtimeOnly = macRole.condition(
		'managed-ollama-native',
		"${{ matrix.scenario != 'xctest' }}"
	);
	assert.equal(pipeline.stepField(body, 'if'), runtimeOnly);
	assert.doesNotThrow(() => pipeline.validateRaw(files));
	const mutants = [
		['deleted receiver', '', /no step named/],
		['renamed receiver', body.replace(name, 'Omitted selected-release receiving'), /no step named/],
		['duplicate receiver', body + body, /appears 2 times/],
		[
			'forgiven receiver',
			body.replace(head, head + '        continue-on-error: true\n'),
			/failure must remain fatal/
		],
		[
			'missing receiver command',
			body.replace('node tools/diagnostics/macos_release_stage_native_receiving.cjs', 'echo'),
			/receiver exact command/
		],
		[
			'foreign receiver command',
			body.replace('macos_release_stage_native_receiving.cjs', 'foreign_receiving.cjs'),
			/receiver exact command/
		],
		[
			'modified receiver output',
			body.replace('native-selected-release-', 'foreign-output-'),
			/receiver exact command/
		],
		[
			'forgiven command',
			body.replace('        run: |', '        run: |\n          true'),
			/receiver exact command/
		],
		[
			'foreign shell',
			body.replace('        shell: bash', '        shell: sh'),
			/receiver exact shell/
		]
	];
	for (const condition of [
		'false',
		'success()',
		'always()',
		'${{ !cancelled() }}',
		'${{ env.ERGOPTI_DEV_QUALIFICATION_PROFILE }}'
	])
		mutants.push([
			`conditional receiver ${condition}`,
			body.replace('        if: ' + runtimeOnly + '\n', `        if: ${condition}\n`),
			/full step condition/
		]);
	for (const [label, replacement, error] of mutants) {
		const changed = files.map((file) => {
			if (file.rel !== MACOS_BOX) return file;
			assert.equal(file.text.split(body).length, 2, label + ': genuine mutation seam');
			return { ...file, text: file.text.replace(body, () => replacement) };
		});
		assert.notDeepEqual(changed, files, label);
		assert.throws(() => pipeline.fromFiles(changed), error, label);
	}
	assert.equal(mutants.length, 14);
	mustCatch(
		'selected-release artifact condition spelling remains exact',
		MACOS_BOX,
		macConditionalPrefix('      - name: Retain selected-release native ownership receiving\n'),
		'      - name: Retain selected-release native ownership receiving\n        if: ${{ always() }}\n',
		stepProblems
	);
	mustCatch(
		'unknown conditional receiver alias remains refused',
		MACOS_BOX,
		head,
		'      - name: Invented selected-release deferred alias\n        if: always()\n',
		stepProblems
	);
	console.log(
		'PASS: selected-release exact raw receiver controls=14; Darwin native receiving UNRUN by source models.'
	);
}

// Producer diagnostics run after earlier refusals, but never after cancellation.
// The existing condition loop also rejects removal, false, success and missing steps.
for (const name of [
	'Prepare genuine pinned Go toolchain',
	'Acquire and verify genuine pinned upstream inputs',
	'Build and admit the actual native source asset'
]) {
	const head = `      - name: ${name}\n`;
	for (const changed of ['always()', 'failure()', '${{ !cancelled() && false }}']) {
		mustCatch(
			`native producer diagnostic ${name}: invalid condition ${changed}`,
			MACOS_BOX,
			macConditionalPrefix(head, 'e2e-hs'),
			head + `        if: ${changed}\n`,
			stepProblems
		);
	}
	const from = macConditionalPrefix(head, 'e2e-hs');
	const source = rawSourceFiles.find((file) => file.rel === MACOS_BOX).text;
	assert.equal(source.split(from).length - 1, 1, 'one exact native producer diagnostic step');
	const swallowed = rawSourceFiles.map((file) =>
		file.rel === MACOS_BOX
			? { ...file, text: file.text.replace(from, from + '        continue-on-error: true\n') }
			: file
	);
	assert.notDeepEqual(swallowed, rawSourceFiles);
	assert.throws(
		() => pipeline.validateRaw(swallowed),
		/\[ci-full-default\].*failure must remain fatal/
	);
}

// Model receiving owns one successful admission of the parallel clean build,
// independently of earlier refusals.
{
	const files = pipeline.rawFiles();
	const source = files.find((file) => file.rel === MACOS_BOX);
	const jobs = pipeline.jobsOfText(source.text, MACOS_BOX).filter((job) => job.id === 'e2e-hs');
	assert.equal(jobs.length, 1, 'one current native model receiving job');
	const owner = jobs[0];
	const buildName = 'Receive and admit the clean native source asset from its build cell';
	const modelName = 'Receive actual native model create, pull, inference and retirement';
	const build = pipeline.step(owner.body, buildName);
	const model = pipeline.step(owner.body, modelName);
	const id = '        id: ollama-native-build\n';
	const condition =
		'        if: ' +
		macRole.condition(
			'managed-ollama-native',
			"${{ !cancelled() && steps.ollama-native-build.outcome == 'success' && matrix.scenario != 'xctest' }}"
		) +
		'\n';
	assert.doesNotThrow(() => pipeline.validateRaw(files));
	function refuses(label, before, after, pattern) {
		assert.equal(owner.body.split(before).length - 1, 1, label + ': exact current owner span');
		const changed = owner.body.replace(before, () => after);
		assert.notEqual(changed, owner.body, label + ': real source mutation');
		const mutated = files.map((file) =>
			file.rel === MACOS_BOX
				? { ...file, text: file.text.replace(owner.body, () => changed) }
				: file
		);
		assert.throws(() => pipeline.validateRaw(mutated), pattern, label);
	}
	for (const [label, replacement, pattern] of [
		['missing producer id', '', /native admission build id/],
		['foreign producer id', '        id: unrelated-native-build\n', /native admission build id/],
		['duplicate producer id field', id + id, /step key 'id'.*appears 2 times/]
	])
		refuses(label, id.trimEnd(), replacement.trimEnd(), pattern);
	refuses('missing producer step', build, '', /no step named/);
	refuses(
		'renamed producer step',
		build,
		build.replace(buildName, 'Omitted native source build'),
		/no step named/
	);
	const modelId = '        id: managed-ollama-model-receiving\n';
	assert.equal(model.split(modelId).length - 1, 1, 'one actual model receiver id');
	refuses(
		'producer id stolen by model receiver',
		model,
		model.replace(modelId, id),
		/native admission unique build id/
	);
	const together = build + '\n' + model;
	refuses(
		'receiver precedes producer',
		together,
		model + '\n' + build,
		/native admission precedes model receiving/
	);
	for (const changed of [
		'',
		'success()',
		'always()',
		'${{ !cancelled() }}',
		"${{ !cancelled() && steps.ollama-native-build.outcome != 'failure' }}",
		"${{ !cancelled() && steps.ollama-native-build.conclusion == 'success' }}",
		"${{ !cancelled() && steps.unrelated-native-build.outcome == 'success' }}",
		"${{ !cancelled() && steps.ollama-native-build.outcome == 'success' && env.MACOS_STAGE_ARCHITECTURE == 'arm64' }}"
	])
		refuses(
			`model dependency condition ${changed || '(missing)'}`,
			condition.trimEnd(),
			changed ? `        if: ${changed}` : '',
			/full step condition/
		);
	refuses(
		'forgiven model receiving',
		model,
		model.replace(condition, condition + '        continue-on-error: true\n'),
		/failure must remain fatal/
	);
}

// The final manual SDK diagnostic cannot suppress any earlier native script.
const SHORTCUTS_INDEPENDENT_OBSERVER = retainedManagedStep(
	[
		'      - name: Observe independent native Apple Shortcuts SDK preflight and discovery',
		"        if: ${{ !cancelled() && github.event_name == 'workflow_dispatch' && !inputs.release && matrix.scenario != 'xctest' }}",
		'        shell: bash',
		'        run: |',
		'          set -euo pipefail',
		'          python3 tools/diagnostics/apple_shortcuts_probe/run_probe.py \\',
		'            --source-root "$GITHUB_WORKSPACE" \\',
		'            --source-sha "$GITHUB_SHA" \\',
		'            --output "$RUNNER_TEMP/group3-apple-shortcuts-probe-independent-${{ env.MACOS_STAGE_ARCHITECTURE }}"',
		'        timeout-minutes: 2'
	].join('\n')
);
const SHORTCUTS_INDEPENDENT_RETENTION = retainedManagedStep(
	[
		'      - name: Retain independent native Apple Shortcuts SDK observation',
		"        if: ${{ always() && github.event_name == 'workflow_dispatch' && !inputs.release && matrix.scenario != 'xctest' }}",
		'        uses: actions/upload-artifact@v4',
		'        with:',
		'          name: native-apple-shortcuts-independent-${{ env.MACOS_STAGE_ARCHITECTURE }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}',
		'          retention-days: 7',
		'          if-no-files-found: error',
		'          path: ${{ runner.temp }}/group3-apple-shortcuts-probe-independent-${{ env.MACOS_STAGE_ARCHITECTURE }}'
	].join('\n')
);
function shortcutsIndependentReceivingProblems(files) {
	const jobs = files.flatMap((file) => pipeline.jobsOfText(file.text, file.rel));
	const owners = jobs.filter((job) => job.file === MACOS_BOX && job.id === 'e2e-hs');
	if (owners.length !== 1) return ['independent Shortcuts owner job missing or duplicated'];
	const owned = owners[0];
	const members = macRole.selected(owned.body, 'managed-ollama-native');
	const problems = [];
	for (const [name, expected] of [
		[
			'Observe independent native Apple Shortcuts SDK preflight and discovery',
			SHORTCUTS_INDEPENDENT_OBSERVER
		],
		['Retain independent native Apple Shortcuts SDK observation', SHORTCUTS_INDEPENDENT_RETENTION]
	]) {
		const matches = jobs.flatMap((job) =>
			pipeline
				.steps(job.body)
				.filter((step) => step.name === name)
				.map((step) => ({ job, step }))
		);
		if (matches.length !== 1 || matches[0].job !== owned || matches[0].step.body !== expected)
			problems.push('independent Shortcuts exact unique owner/body: ' + name);
	}
	const python = members.findIndex((step) =>
		/^actions\/setup-python@v[1-9][0-9]*$/.test(pipeline.stepField(step.body, 'uses') ?? '')
	);
	const observer = members.findIndex(
		(step) => step.name === 'Observe independent native Apple Shortcuts SDK preflight and discovery'
	);
	const retention = members.findIndex(
		(step) => step.name === 'Retain independent native Apple Shortcuts SDK observation'
	);
	const installed = members.findIndex(
		(step) => step.name === 'Retain installed Shortcuts Events metadata diagnostic'
	);
	if (
		python < 0 ||
		observer <= python ||
		installed < 0 ||
		installed >= observer ||
		retention !== observer + 1 ||
		retention !== members.length - 1
	)
		problems.push(
			'independent Shortcuts must be the final adjacent pair after installed metadata retention'
		);
	return problems;
}
const shortcutsIndependentFiles = pipeline.files();
assert.deepEqual(
	shortcutsIndependentReceivingProblems(shortcutsIndependentFiles),
	[],
	'actual independent SDK observation remains enrolled'
);
const shortcutsIndependentMutations = [
	['missing observer', SHORTCUTS_INDEPENDENT_OBSERVER, ''],
	[
		'duplicate observer',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER + '\n' + SHORTCUTS_INDEPENDENT_OBSERVER
	],
	[
		'implicit success observer',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace('!cancelled() && ', '')
	],
	[
		'push-only observer',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace("'workflow_dispatch'", "'push'")
	],
	[
		'release observer',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace('!inputs.release', 'inputs.release')
	],
	[
		'extended observer budget',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace('timeout-minutes: 2', 'timeout-minutes: 3')
	],
	[
		'foreign observer SHA',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace('$GITHUB_SHA', '$GITHUB_RUN_ID')
	],
	[
		'foreign observer source root',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace('$GITHUB_WORKSPACE', '$RUNNER_TEMP')
	],
	[
		'forgiven observer status',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace(
			'"\n        timeout-minutes: 2',
			'" || true\n        timeout-minutes: 2'
		)
	],
	[
		'continue-on-error observer',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace(
			'        run: |',
			'        continue-on-error: true\n        run: |'
		)
	],
	[
		'foreign observer output',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.replace(
			'group3-apple-shortcuts-probe-independent-',
			'group3-foreign-probe-'
		)
	],
	[
		'comment-only observer decoy',
		SHORTCUTS_INDEPENDENT_OBSERVER,
		SHORTCUTS_INDEPENDENT_OBSERVER.split('\n')
			.map((line) => '      # ' + line.trimStart())
			.join('\n')
	],
	['missing retention', SHORTCUTS_INDEPENDENT_RETENTION, ''],
	[
		'duplicate retention',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION + '\n' + SHORTCUTS_INDEPENDENT_RETENTION
	],
	[
		'success-only retention',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace('always()', 'success()')
	],
	[
		'release-wide retention',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace(' && !inputs.release', '')
	],
	[
		'foreign retention uploader',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace('upload-artifact@v4', 'upload-artifact@v3')
	],
	[
		'warn-only missing evidence',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace('if-no-files-found: error', 'if-no-files-found: warn')
	],
	[
		'shortened evidence retention',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace('retention-days: 7', 'retention-days: 1')
	],
	[
		'unbound artifact architecture',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace(
			'native-apple-shortcuts-independent-${{ env.MACOS_STAGE_ARCHITECTURE }}-',
			'native-apple-shortcuts-independent-'
		)
	],
	[
		'unbound artifact source',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace('-${{ github.sha }}-', '-')
	],
	[
		'unbound artifact run',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace('-${{ github.run_id }}-', '-')
	],
	[
		'unbound artifact attempt',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION.replace('-${{ github.run_attempt }}', '')
	],
	[
		'extra quoted artifact input',
		SHORTCUTS_INDEPENDENT_RETENTION,
		SHORTCUTS_INDEPENDENT_RETENTION + "\n          'overwrite': true"
	]
];
assert.equal(shortcutsIndependentMutations.length, 24, 'independently declared SDK inverse census');
for (const [label, before, after] of shortcutsIndependentMutations) {
	assert.notEqual(before, after, label + ' changes actual source');
	mustCatch(
		'independent SDK: ' + label,
		MACOS_BOX,
		before,
		after,
		shortcutsIndependentReceivingProblems
	);
}
const shortcutsIndependentPair =
	SHORTCUTS_INDEPENDENT_OBSERVER + '\n\n' + SHORTCUTS_INDEPENDENT_RETENTION;
const shortcutsIndependentGuardJob = macRole.body(
	pipeline.file(MACOS_BOX),
	'managed-ollama-native'
);
const shortcutsIndependentGuardian = pipeline.step(
	shortcutsIndependentGuardJob,
	'Receive selected-release shell corpus and native guardian cancellation'
);
const shortcutsIndependentPackage = '      - name: Observe native Apple Shortcuts discovery\n';
const shortcutsIndependentFixtureCondition =
	'        if: ' + macRole.condition('managed-ollama-native') + '\n';
const shortcutsIndependentLaterFixture =
	'      - name: Later gate fixture\n' +
	shortcutsIndependentFixtureCondition +
	'        run: echo later';
for (const [label, transform] of [
	[
		'observer moved after native guardian',
		(text) =>
			text
				.replace(shortcutsIndependentPair, '')
				.replace(
					shortcutsIndependentGuardian,
					shortcutsIndependentGuardian + '\n' + shortcutsIndependentPair
				)
	],
	[
		'observer moved into dependent package',
		(text) =>
			text
				.replace(shortcutsIndependentPair, '')
				.replace(
					shortcutsIndependentPackage,
					shortcutsIndependentPair + '\n' + shortcutsIndependentPackage
				)
	],
	[
		'later original-style gate after observer',
		(text) =>
			text.replace(
				shortcutsIndependentPair,
				shortcutsIndependentPair + '\n\n' + shortcutsIndependentLaterFixture
			)
	]
]) {
	const mutated = shortcutsIndependentFiles.map((file) =>
		file.rel === MACOS_BOX ? { ...file, text: transform(file.text) } : file
	);
	assert.notDeepEqual(mutated, shortcutsIndependentFiles, label + ' changes actual source');
	if (label === 'later original-style gate after observer')
		assert.ok(
			macRole
				.body(mutated.find((file) => file.rel === MACOS_BOX).text, 'managed-ollama-native')
				.includes(shortcutsIndependentLaterFixture),
			'the later fixture must reach the actual role member guard'
		);
	assert.ok(shortcutsIndependentReceivingProblems(mutated).length > 0, label + ' refuses');
}
// An unguarded later step is refused by the closed stage contract, outside any role.
const shortcutsIndependentUnguarded = pipeline
	.file(MACOS_BOX)
	.replace(
		shortcutsIndependentPair,
		shortcutsIndependentPair + '\n\n      - name: Later gate fixture\n        run: echo later'
	);
assert.notEqual(shortcutsIndependentUnguarded, pipeline.file(MACOS_BOX));
assert.ok(
	macStageProblems(shortcutsIndependentUnguarded).length > 0,
	'an unguarded later gate remains refused by the actual stage contract'
);
const shortcutsIndependentHarmless =
	'      - name: Independent SDK guard harmless fixture\n' +
	shortcutsIndependentFixtureCondition +
	'        run: echo harmless';
for (const name of [
	'Independent SDK guard harmless fixture',
	'Independent SDK guard renamed harmless fixture'
]) {
	const positive = shortcutsIndependentFiles.map((file) =>
		file.rel === MACOS_BOX
			? {
					...file,
					text: file.text.replace(
						shortcutsIndependentPair,
						shortcutsIndependentHarmless.replace('Independent SDK guard harmless fixture', name) +
							'\n\n' +
							shortcutsIndependentPair
					)
				}
			: file
	);
	assert.notDeepEqual(positive, shortcutsIndependentFiles, 'positive changes actual source');
	assert.ok(
		macRole
			.body(positive.find((file) => file.rel === MACOS_BOX).text, 'managed-ollama-native')
			.includes(
				shortcutsIndependentHarmless.replace('Independent SDK guard harmless fixture', name)
			),
		'the positive fixture must reach the actual role member guard: ' + name
	);
	assert.deepEqual(
		shortcutsIndependentReceivingProblems(positive),
		[],
		'unrelated own fixture remains editable: ' + name
	);
}
console.log('PASS: independent Shortcuts SDK source controls=3 positive/28 refusal; native UNRUN.');

if (errors.length > 0) {
	console.error(
		'[FAIL] the CI pipeline wiring can skip a gate, publish a wrong or partial release, or draw a tangled graph:'
	);
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`[OK] one root (${ROOT}) with ${planOutputs.size} plan outputs, ${callers.length} lane callers with ` +
		`three mandatory macOS entries plus one manual diagnostic, one Windows/Linux entry and the declared exits, and ${gatedSecrets} release-only secrets are wired as designed, ` +
		`${CONDITIONS.size} conditional steps are the only ones, and the release preflight runs before any side effect.`
);
