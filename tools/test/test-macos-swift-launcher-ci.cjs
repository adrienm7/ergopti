// tools/test/test-macos-swift-launcher-ci.cjs

/**
 * ==============================================================================
 * MODULE: macOS Swift Launcher CI Guard
 * DESCRIPTION:
 * Proves that the native ErgoptiPlus launcher is built and its XCTest target is
 * executed to an explicit XCTest verdict on a real macOS runner, and that this
 * result participates in the required macOS aggregate gate.
 *
 * ROOT CAUSE ENCODED:
 * The Hammerspoon unit and virtual-keyboard jobs both run on Ubuntu. The native
 * Swift lease guardian could therefore fail to compile, or every process-level
 * XCTest could go red, while the macOS aggregate job still reported success. It
 * also treated `skipped` as green and repeated dependency names outside `needs`,
 * so adding a job at only one of those sites created another false green.
 * Later, `swift test` began running XCTest followed by an empty swift-testing
 * runner. A dead XCTest process omitted its suite summary, but the second runner
 * supplied exit 0. XCTest-created guardian runtimes also inherited the production
 * `Darwin.exit` boundary, so asynchronous cleanup could kill the whole runner.
 * The workflow needs an independent verdict and tests need explicit termination.
 * Since the pipeline became one reusable workflow per OS, the macOS lane's own
 * result replaces that aggregate job: it fails as soon as any of its jobs fails,
 * and Release runs only when every lane succeeded. The launcher build and its
 * XCTest then moved into the package job, before the app build, so the lane
 * uses one macOS runner before its launch legs; the tests append to the real
 * ~/Library/Logs/ergopti_plus/launcher.log, which the release smoke refuses to
 * launch over, and the app that ships must not build in their cached tree.
 *
 * FEATURES & RATIONALE:
 * 1. Requires release compilation and XCTest execution on `macos-*`, in the
 *    package job after the Hammerspoon suites and before the app build; an
 *    Ubuntu source grep cannot substitute for Darwin process and signal
 *    semantics. The launcher log the tests leave is removed before the app is
 *    built, and the tests build in a scratch path of their own, the only
 *    SwiftPM tree the cache restores.
 * 2. Requires every job of an OS lane to gate its lane: only exact pinned
 *    verdict/diagnostic conditions and no `continue-on-error`, the release
 *    job waiting on the three lanes through its implicit `success()` (no status
 *    function), and ci.yml calling the lane that holds the Swift steps. No step
 *    of the pipeline may set `continue-on-error` beyond the report-only AHK
 *    annotator, and the launch verdict step must run the gate script.
 * 3. Requires the test step to capture line-buffered XCTest output and reject a
 *    missing successful suite summary, even when `swift test` itself exits 0.
 * 4. Reads the workflows through tools/test/ci-pipeline.cjs, which throws on a
 *    missing job, and checks Package.swift's test target, which prevents a
 *    syntactically present but vacuous `swift test` step.
 * 5. Pins the launch profile and runners exactly per run kind, and keeps the
 *    private Sparkle key in the signing step alone. That no gating step of
 *    the box can be skipped is pinned pipeline-wide by
 *    tools/test/test-ci-pipeline-wiring.cjs.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const pipeline = require('./ci-pipeline.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS_BOX = '.github/workflows/ci-macos.yml';
const PIPELINE = pipeline.text();
const PACKAGE = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'launcher', 'Package.swift'),
	'utf8'
);
const SWIFT_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'launcher');
const MAIN_SWIFT = fs.readFileSync(
	path.join(SWIFT_ROOT, 'Sources', 'ErgoptiPlus', 'main.swift'),
	'utf8'
);
const LEASE_WORKER_TESTS = fs.readFileSync(
	path.join(SWIFT_ROOT, 'Tests', 'ErgoptiPlusTests', 'RemapLeaseWorkerTests.swift'),
	'utf8'
);
const POSIX_SHIM = fs.readFileSync(
	path.join(SWIFT_ROOT, 'Sources', 'CPOSIXCompatibility', 'CPOSIXCompatibility.c'),
	'utf8'
);

function readSwiftTree(directory) {
	return fs
		.readdirSync(directory, { withFileTypes: true })
		.flatMap((entry) => {
			const entryPath = path.join(directory, entry.name);
			if (entry.isDirectory()) return readSwiftTree(entryPath);
			return entry.isFile() && entry.name.endsWith('.swift')
				? [fs.readFileSync(entryPath, 'utf8')]
				: [];
		})
		.join('\n');
}

const SWIFT_SOURCES = readSwiftTree(SWIFT_ROOT);

const sparklePackagePin =
	/\.package\(\s*url:\s*"https:\/\/github\.com\/sparkle-project\/Sparkle",\s*exact:\s*"([^"]+)"\s*\)/.exec(
		PACKAGE
	);
const sparkleSigningToolPin = /^\s*SPARKLE_VERSION:\s*'([^']+)'\s*$/m.exec(PIPELINE);

const failures = [];

function check(condition, message) {
	if (!condition) failures.push(message);
}

function escapeRegExp(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function withoutFullLineComments(source) {
	return source.replace(/^\s*#.*$/gm, '');
}

check(
	PIPELINE.length > 10000,
	'the CI pipeline is missing or truncated; refusing to inspect an empty workflow'
);
// locate() throws unless exactly one `package-macos` job exists.
check(
	pipeline.locate('package-macos').file === MACOS_BOX,
	`the \`package-macos\` job, which builds and tests the launcher, must live in the macOS lane, ${MACOS_BOX}`
);
check(
	!/^ {2}test-swift-launcher:/m.test(pipeline.file(MACOS_BOX)),
	'the launcher build and XCTest live in package-macos; a second macOS job for them would add a second lane entry'
);

const swiftJob = withoutFullLineComments(pipeline.job('package-macos'));
check(swiftJob.length > 100, '`package-macos` is absent or empty');
check(
	/^\s+runs-on:\s*macos-[A-Za-z0-9._-]+\s*$/m.test(swiftJob),
	'`package-macos` must run the launcher build and XCTest on a real macOS runner'
);
check(
	!/^\s+continue-on-error:\s*true\s*$/m.test(swiftJob),
	'`package-macos` must be gating, not continue-on-error'
);
// Fail fast: a red Hammerspoon suite spends no macOS minutes.
check(
	JSON.stringify(pipeline.needsOf(pipeline.job('package-macos'))) ===
		JSON.stringify(['e2e-hs', 'managed-ollama-native']),
	`package-macos must need e2e-hs and both native producers, got [${pipeline.needsOf(pipeline.job('package-macos')).join(', ')}]`
);

// The launcher build and XCTest precede the app build. LauncherLogTests append
// to the real ~/Library/Logs/ergopti_plus/launcher.log, and the release smoke
// refuses a launcher log it did not start fresh, so the log goes in between.
const PACKAGE_ORDER = [
	'Build release launcher',
	'Run Swift launcher tests',
	'Remove the launcher log the Swift tests wrote',
	'Build ErgoptiPlus.app',
	'Smoke test built ErgoptiPlus.app (crash-on-launch guard)'
];
const packageStepNames = pipeline
	.steps(pipeline.job('package-macos'))
	.map((candidate) => candidate.name);
const packageOrder = PACKAGE_ORDER.map((name) => packageStepNames.indexOf(name));
check(
	!packageOrder.some((at, index) => at < 0 || (index > 0 && at <= packageOrder[index - 1])),
	`package-macos must run ${PACKAGE_ORDER.join(' < ')}; got: ${packageStepNames.join(' | ')}`
);
const logCleanup = pipeline.step(
	pipeline.job('package-macos'),
	'Remove the launcher log the Swift tests wrote'
);
check(
	pipeline.stepField(logCleanup, 'run') === 'rm -rf -- "$HOME/Library/Logs/ergopti_plus"' &&
		pipeline.stepField(logCleanup, 'if') === null,
	'package-macos must always remove ~/Library/Logs/ergopti_plus, the log the launcher tests write, before the app build'
);
check(
	/if launcher_log\.exists\(\):\s*\n\s*raise RuntimeError\("Release launch requires a fresh launcher log"\)/.test(
		fs.readFileSync(path.join(ROOT, 'tools', 'diagnostics', 'macos-release-launch.py'), 'utf8')
	),
	'the release smoke no longer refuses a stale launcher log; re-derive why package-macos removes it'
);

// The tests build in a scratch path of their own, the only SwiftPM tree the
// cache restores, so the app build resolves its dependencies into a clean
// .build as it did on a runner of its own: no cached tree reaches a shipped app.
const SWIFT_SCRATCH = '--scratch-path "$RUNNER_TEMP/swift-launcher-ci"';
const swiftCache = pipeline.step(pipeline.job('package-macos'), 'Cache SwiftPM dependencies');
const cacheLines = swiftCache.split('\n');
const pathAt = cacheLines.indexOf('          path: |');
const pathEnd = cacheLines.findIndex((line, index) => index > pathAt && !/^ {12}\S/.test(line));
const cachedPaths =
	pathAt < 0
		? []
		: cacheLines.slice(pathAt + 1, pathEnd < 0 ? undefined : pathEnd).map((line) => line.trim());
check(
	cachedPaths.length === 3 &&
		cachedPaths.every((line) =>
			/^\$\{\{ runner\.temp \}\}\/swift-launcher-ci\/(?:artifacts|checkouts|repositories)$/.test(
				line
			)
		),
	`the SwiftPM cache must restore only the launcher tests' scratch path, got: ${cachedPaths.join(', ')}`
);

const plistLintLine =
	swiftJob.split(/\r?\n/).find((line) => /\brun:\s*plutil\s+-lint\b/.test(line)) || '';
check(
	plistLintLine.includes('static/ergopti_plus/macos/launcher/com.ergoptiplus.remap-guardian.plist'),
	'the macOS job must plutil-lint the exact bundled guardian LaunchAgent'
);
check(
	!plistLintLine.includes('|| true'),
	'the guardian plist lint step must not swallow malformed XML'
);

// Read the exact package step, independently of native bootstrap jobs and
// whether YAML represents its run as one line or a literal block. A piped build
// is admitted only with the exact original errexit/pipefail owner and log sink.
function releaseBuildInvocation(step) {
	const lines = (pipeline.runOf(step) || []).map((line) => line.trim()).filter(Boolean);
	const commands = lines.filter((line) => /^swift build\b/.test(line));
	if (commands.length !== 1) return '';
	const command = commands[0];
	const capture = ' 2>&1 | tee "$RUNNER_TEMP/macos-release-launcher-build.log"';
	if (command.endsWith(capture)) {
		if (lines.length !== 2 || lines[0] !== 'set -euo pipefail') return '';
		return command.slice(0, -capture.length);
	}
	return lines.length === 1 ? command : '';
}
const releaseBuildStep = pipeline.step(swiftJob, 'Build release launcher');
const buildLine = releaseBuildInvocation(releaseBuildStep);
check(
	buildLine.includes('--package-path static/ergopti_plus/macos/launcher'),
	'the Swift build step must compile the packaged launcher directory'
);
check(
	buildLine.endsWith(SWIFT_SCRATCH),
	`the Swift build step must build in the tests' own scratch path, ${SWIFT_SCRATCH}`
);
check(
	/(?:^|\s)(?:-c|--configuration)\s+release(?:\s|$)/.test(buildLine),
	'the Swift build step must compile the release configuration that ships'
);
check(
	/(?:^|\s)--product\s+ErgoptiPlus(?:\s|$)/.test(buildLine),
	'the Swift build step must compile the ErgoptiPlus executable product'
);
check(!buildLine.includes('|| true'), 'the Swift build step must not swallow compilation failure');

const literalBuild =
	'swift build -c release --product ErgoptiPlus --package-path static/ergopti_plus/macos/launcher --scratch-path "$RUNNER_TEMP/swift-launcher-ci"';
const literalCapture = ' 2>&1 | tee "$RUNNER_TEMP/macos-release-launcher-build.log"';
const inlineBuildFixture = [
	'      - name: Build release launcher',
	`        run: ${literalBuild}`
].join('\n');
const blockBuildFixture = [
	'      - name: Build release launcher',
	'        shell: bash',
	'        run: |',
	'          set -euo pipefail',
	`          ${literalBuild}${literalCapture}`
].join('\n');
check(
	releaseBuildInvocation(inlineBuildFixture) === literalBuild &&
		releaseBuildInvocation(blockBuildFixture) === literalBuild,
	'the exact package build receiver must admit both inline and captured literal scripts'
);
for (const refusedBuild of [
	blockBuildFixture.replace('set -euo pipefail', 'set -eu'),
	blockBuildFixture.replace('set -euo pipefail', 'set +e'),
	blockBuildFixture.replace('set -euo pipefail', 'set -euo pipefail\n          set +e'),
	blockBuildFixture.replace(literalCapture, ' || true'),
	blockBuildFixture.replace(literalCapture, literalCapture + ' || true'),
	blockBuildFixture + `\n          ${literalBuild}`
]) {
	check(
		releaseBuildInvocation(refusedBuild) === '',
		'the literal package build receiver must reject swallowed pipeline failure or duplicate compilation'
	);
}
const independentBuildFixture = [
	'    steps:',
	'      - name: Build the actual launcher native transport roles',
	'        run: swift build -c debug --product ForeignProduct --package-path unrelated',
	blockBuildFixture
].join('\n');
check(
	releaseBuildInvocation(pipeline.step(independentBuildFixture, 'Build release launcher')) ===
		literalBuild,
	'a preceding independent native build must not replace the exact package launcher build'
);

const testStep = pipeline.step(swiftJob, 'Run Swift launcher tests');
check(
	testStep.length > 100,
	'`Run Swift launcher tests` is absent or too small to enforce a trustworthy XCTest verdict'
);
check(
	/script -q \/dev\/null swift test\b/.test(testStep),
	'the Swift test step must use a pseudo-terminal so the last completed XCTest is visible'
);
check(
	testStep.includes('--package-path static/ergopti_plus/macos/launcher'),
	'the Swift test step must execute the packaged launcher test target'
);
check(
	testStep.includes(
		`swift test --package-path static/ergopti_plus/macos/launcher ${SWIFT_SCRATCH} `
	),
	`the Swift test step must build in the tests' own scratch path, ${SWIFT_SCRATCH}`
);
check(!testStep.includes('|| true'), 'the Swift test step must not swallow XCTest failure');
check(
	/set -euo pipefail/.test(testStep),
	'the Swift test step must propagate failures through its log-capture pipeline'
);
const logVariable =
	/\b([A-Za-z_][A-Za-z0-9_]*)="\$\(mktemp "\$RUNNER_TEMP\/swift-launcher-evidence\/xctest\.log\.XXXXXX"\)"/.exec(
		testStep
	)?.[1] || '';
check(
	logVariable.length > 0,
	'the Swift test step must allocate its exact uploaded private transcript with mktemp'
);
check(
	logVariable.length > 0 &&
		new RegExp(`\\btee\\s+["']?\\$${escapeRegExp(logVariable)}\\b`).test(testStep),
	'the Swift test step must capture the complete pseudo-terminal transcript'
);
check(
	logVariable.length > 0 &&
		new RegExp(
			`grep\\s+-Fq\\s+["']Test Suite 'All tests' passed["']\\s+["']?\\$${escapeRegExp(logVariable)}\\b`
		).test(testStep),
	'(macos-xctest-summary-required-2026-08-27) the Swift test step must require the successful summary from that transcript'
);
check(
	/::error::[^\n]*XCTest[^\n]*summary/.test(testStep) && /\bexit 1\b/.test(testStep),
	'(macos-xctest-summary-required-2026-08-27) a missing XCTest summary must fail the job explicitly'
);
const nodeSetup = pipeline.step(
	swiftJob,
	'Prepare Node for native policy fixtures and XCTest evidence'
);
check(
	/uses:\s*actions\/setup-node@v4/.test(nodeSetup) &&
		/node-version-file:\s*'\.node-version'/.test(nodeSetup) &&
		packageStepNames.indexOf('Prepare Node for native policy fixtures and XCTest evidence') <
			packageStepNames.indexOf('Run Swift launcher tests'),
	'native generated-policy probes and XCTest evidence require the repository-owned Node version before XCTest'
);
check(
	testStep.includes('swift_pipeline_status=("${PIPESTATUS[@]}")') &&
		/set \+e\s*\n\s*script -q/.test(testStep) &&
		/swift_pipeline_status=\([^\n]+\)\s*\n\s*node tools\/diagnostics\/swift_xctest_evidence\.cjs/.test(
			testStep
		) &&
		/xctest_evidence_status=\$\?\s*\n\s*node tools\/diagnostics\/owned_program_xctest_notice\.cjs "\$RUNNER_TEMP\/swift-launcher-evidence\/verdict\.json" "\$xctest_log" "\$\(git rev-parse HEAD\)"\s*\n\s*owned_program_evidence_status=\$\?\s*\n\s*node tools\/diagnostics\/tis_evidence_transport\.cjs[^\n]+\n\s*tis_evidence_status=\$\?\s*\n\s*set -e/.test(
			testStep
		) &&
		testStep.includes(
			'if [ "$xctest_evidence_status" -ne 0 ]; then exit "$xctest_evidence_status"; fi'
		) &&
		testStep.includes(
			'if [ "$tis_evidence_status" -ne 0 ]; then exit "$tis_evidence_status"; fi'
		) &&
		testStep.includes(
			'if [ "$owned_program_evidence_status" -ne 0 ]; then exit "$owned_program_evidence_status"; fi'
		) &&
		testStep.indexOf('if [ "$xctest_evidence_status" -ne 0 ]') <
			testStep.indexOf('if [ "$tis_evidence_status" -ne 0 ]') &&
		testStep.indexOf('if [ "$tis_evidence_status" -ne 0 ]') <
			testStep.indexOf('if [ "$owned_program_evidence_status" -ne 0 ]') &&
		testStep.indexOf('if [ "$owned_program_evidence_status" -ne 0 ]') <
			testStep.indexOf('if ! grep -Fq') &&
		testStep.includes('"${swift_pipeline_status[0]}" "${swift_pipeline_status[1]}"') &&
		!/trap[^\n]*rm[^\n]*xctest_log/.test(testStep),
	'the XCTest evidence owner receives both real pipeline statuses before errexit, and retains the transcript on failure'
);
const ownedPolicyStep = pipeline.step(
	swiftJob,
	'Run owned program XCTest notice constructed-policy controls'
);
check(
	pipeline.stepField(ownedPolicyStep, 'run') ===
		'node tools/test/test-owned-program-xctest-notice.cjs' &&
		pipeline.stepField(ownedPolicyStep, 'if') === null &&
		pipeline.stepField(ownedPolicyStep, 'continue-on-error') === null &&
		packageStepNames.indexOf('Run owned program XCTest notice constructed-policy controls') >
			packageStepNames.indexOf('Prepare Node for native policy fixtures and XCTest evidence') &&
		packageStepNames.indexOf('Run owned program XCTest notice constructed-policy controls') <
			packageStepNames.indexOf('Run Swift launcher tests'),
	'the independently authored owned-program policy corpus runs unconditionally before native XCTest'
);
const transcriptUpload = pipeline.step(swiftJob, 'Upload Swift launcher failure transcript');
check(
	/uses:\s*actions\/upload-artifact@v4/.test(transcriptUpload) &&
		pipeline.stepField(transcriptUpload, 'if') ===
			"${{ failure() && steps.swift-launcher-tests.outcome == 'failure' }}" &&
		/path:\s*\$\{\{ runner\.temp \}\}\/swift-launcher-evidence/.test(transcriptUpload) &&
		/if-no-files-found:\s*error/.test(transcriptUpload) &&
		packageStepNames.indexOf('Upload Swift launcher failure transcript') >
			packageStepNames.indexOf('Run Swift launcher tests'),
	'a failed native XCTest step must upload the retained transcript and exact verdict'
);
check(
	/\.testTarget\s*\(\s*name:\s*"ErgoptiPlusTests"/s.test(PACKAGE),
	'Package.swift must register the ErgoptiPlusTests target that CI claims to run'
);
check(
	!/\bDarwin\.flock\s*\(/.test(SWIFT_SOURCES),
	'Swift 6.3 resolves `Darwin.flock(...)` as the struct; use ergoptiFlock instead'
);
check(
	!/\b_NSGetEnviron\s*\(/.test(SWIFT_SOURCES),
	'the current macOS SDK does not expose `_NSGetEnviron`; use duplicateProcessEnvironment'
);
check(
	!/\bDarwin\.fork\s*\(/.test(SWIFT_SOURCES),
	'Swift 6.3 marks `Darwin.fork()` unavailable; use the posix_spawn test helper'
);
check(
	/ergopti_flock_compat\s*\(/.test(SWIFT_SOURCES),
	'the Swift launcher must retain its C ABI flock compatibility shim'
);
check(
	/return flock\s*\(descriptor, operation\)/.test(POSIX_SHIM),
	'the C compatibility target must call the real BSD flock function'
);
check(
	/"CPOSIXCompatibility"/.test(PACKAGE),
	'Package.swift must link the explicit C POSIX compatibility target'
);
check(
	sparklePackagePin !== null,
	'Package.swift must pin Sparkle with `exact:` so clean builds cannot float to a new release'
);
check(
	sparklePackagePin !== null &&
		sparkleSigningToolPin !== null &&
		sparklePackagePin[1] === sparkleSigningToolPin[1],
	'the launcher and release signing tool must use the same exact Sparkle version'
);
check(
	!/hashFiles\([^\r\n)]*Package\.resolved/.test(PIPELINE),
	'the SwiftPM cache key must not pretend an ignored Package.resolved is tracked input'
);
check(
	/SWIFT_BACKTRACE:\s*enable=yes/.test(testStep),
	'the Swift XCTest step must emit an actionable backtrace after a native crash'
);
check(
	/func duplicateProcessEnvironment\s*\(/.test(SWIFT_SOURCES),
	'the Swift launcher must retain its owned posix_spawn environment builder'
);
check(
	/let kPOSIXTestHelperFlag\s*=\s*"--posix-test-helper"/.test(SWIFT_SOURCES),
	'the cross-process POSIX tests must retain their debug-only helper role'
);
check(
	/func runPOSIXTestHelper\s*\(/.test(SWIFT_SOURCES),
	'the real launcher must implement the cross-process POSIX test helper'
);
check(
	!/^let k[A-Za-z0-9_]*\s*(?::[^=]+)?=/m.test(MAIN_SWIFT),
	'shared constants must not live in executable main.swift globals'
);
check(
	!/terminateProcess:\s*@escaping\s*\(Int32\)\s*->\s*Void\s*=\s*\{\s*Darwin\.exit/s.test(
		SWIFT_SOURCES
	),
	'(macos-xctest-explicit-termination-2026-08-27) guardian runtimes must choose process termination explicitly'
);
const guardianRuntimeTestCalls = (LEASE_WORKER_TESTS.match(/RemapLeaseGuardianRuntime\s*\(/g) || [])
	.length;
const explicitTestTerminations = (LEASE_WORKER_TESTS.match(/terminateProcess\s*:/g) || []).length;
check(
	guardianRuntimeTestCalls >= 25,
	'the guardian-runtime termination guard must cover the complete XCTest call-site class'
);
check(
	explicitTestTerminations === guardianRuntimeTestCalls,
	'(macos-xctest-explicit-termination-2026-08-27) every XCTest guardian runtime must replace process exit'
);

// The lane result is the aggregate gate. A job-level `if:` or `continue-on-error`
// is how a job becomes skipped or ignored while its lane still reports success,
// which is what the old aggregate's "skipped counts as green" bug did. Only
// exact verdict conditions and scoped manual qualification jobs are allowed.
// The latter retains ordinary admission and adds diagnostic receiving after a
// manual E2E failure; every mandatory failure still rejects the lane verdict.
const BOX_FILES = {
	macos: MACOS_BOX,
	windows: '.github/workflows/ci-windows.yml',
	linux: '.github/workflows/ci-linux.yml'
};
const ALLOWED_JOB_IFS = {
	'windows-ok': 'always()',
	'macos-ok': 'always()',
	'linux-ok': 'always()',
	'package-linux':
		"${{ !cancelled() && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}"
};
for (const rel of Object.values(BOX_FILES)) {
	for (const boxJob of pipeline.jobs(rel)) {
		const condition = pipeline.field(boxJob.body, 'if');
		const manualArchiveQualification =
			rel === MACOS_BOX &&
			boxJob.id === 'item36-native' &&
			condition === "${{ github.event_name == 'workflow_dispatch' && !inputs.release }}";
		check(
			condition === null || ALLOWED_JOB_IFS[boxJob.id] === condition || manualArchiveQualification,
			`${rel}: job \`${boxJob.id}\` has job-level \`if: ${condition}\`; only ` +
				`${Object.entries(ALLOWED_JOB_IFS)
					.map(([id, value]) => `${id} (${value})`)
					.join(' and ')} may`
		);
		check(
			pipeline.field(boxJob.body, 'continue-on-error') === null,
			`${rel}: job \`${boxJob.id}\` must not set continue-on-error; its failure must fail the box`
		);
	}
}
for (const [id, condition] of Object.entries(ALLOWED_JOB_IFS)) {
	check(
		pipeline.field(pipeline.job(id), 'if') === condition,
		`the allow-listed job \`${id}\` must keep exactly \`if: ${condition}\``
	);
}
// The same holds one level down: a gating step with continue-on-error turns its
// own failure green, and its job then gates nothing. Only the report-only AHK
// annotator may set it; the step before it remains the gate.
const ALLOWED_STEP_CONTINUE_ON_ERROR = { 'Annotate AHK results': 'true' };
for (const entry of pipeline.files()) {
	for (const pipelineJob of pipeline.jobs(entry.rel)) {
		for (const pipelineStep of pipeline.steps(pipelineJob.body)) {
			const value = pipeline.stepField(pipelineStep.body, 'continue-on-error');
			check(
				value === null || ALLOWED_STEP_CONTINUE_ON_ERROR[pipelineStep.name] === value,
				`${entry.rel}: step "${pipelineStep.name}" of job \`${pipelineJob.id}\` sets continue-on-error: ${value}; ` +
					'only the report-only "Annotate AHK results" may'
			);
		}
	}
}
for (const [name, value] of Object.entries(ALLOWED_STEP_CONTINUE_ON_ERROR)) {
	check(
		pipeline.stepField(pipeline.findStep(name).body, 'continue-on-error') === value,
		`the allow-listed step "${name}" must keep exactly continue-on-error: ${value}`
	);
}

// ci.yml calls each lane by its file, and release waits on all three and on
// the root, where it reads the plan.
const callers = pipeline.calls();
check(
	JSON.stringify(callers.map((call) => [call.id, call.uses]).sort()) ===
		JSON.stringify(
			Object.entries(BOX_FILES)
				.map(([id, rel]) => [id, `./${rel}`])
				.sort()
		),
	`ci.yml must call exactly the three OS lanes, got ${JSON.stringify(callers)}`
);
const release = pipeline.job('release');
const releaseNeeds = pipeline.needsOf(release);
for (const needed of ['validate', ...Object.keys(BOX_FILES)]) {
	check(
		releaseNeeds.includes(needed),
		`release must need \`${needed}\`, got [${releaseNeeds.join(', ')}]`
	);
	// locate() throws when the needed job no longer exists under that id.
	check(
		pipeline.locate(needed).file === pipeline.ENTRY_REL,
		`release's need \`${needed}\` must be a job of ${pipeline.ENTRY_REL}`
	);
}
// No status function: the implicit success() over needs is the "all three OS
// are green" gate. The event test keeps a regression in the plan script alone
// from publishing a pull request or a dispatch run, where PAT_ERGOPTI is read.
const releaseIf = pipeline.field(release, 'if');
check(
	!/\b(?:always|success|failure|cancelled)\s*\(/.test(releaseIf || ''),
	`release.if must hold no status function, got: ${releaseIf}`
);
check(
	releaseIf === "github.event_name == 'push' && needs.validate.outputs.release == 'true'",
	`release.if must be exactly github.event_name == 'push' && needs.validate.outputs.release == 'true', got: ${releaseIf}`
);

// Forks receive no secrets: without a stand-in key their package opens a
// Sparkle error and the launch gate fails every outside contribution. A
// release refuses that fallback before it is reached: a throwaway public key
// matches no private key, so installed copies could never update again.
const packageJob = pipeline.job('package-macos');
const packageBuild = withoutFullLineComments(pipeline.step(packageJob, 'Build ErgoptiPlus.app'));
check(
	/^\s+ERGOPTI_RELEASE:\s*\$\{\{\s*inputs\.release\s*\}\}\s*$/m.test(packageBuild),
	'(fork-sparkle-key) the package build must know whether it builds the release'
);
check(
	/if \[ -z "\$SPARKLE_PUBLIC_KEY" \]; then[\s\S]*?\/dev\/urandom[\s\S]*?fi[\s\S]*?build_macos_app\.sh/.test(
		packageBuild
	),
	'(fork-sparkle-key) the unreleased package must substitute a throwaway Sparkle key when the secret is absent'
);
check(
	/if \[ -z "\$SPARKLE_PUBLIC_KEY" \]; then\s*if \[ "\$ERGOPTI_RELEASE" = true \]; then[^\n]*\n\s*echo "::error::[^\n]*\n\s*exit 1\s*\n\s*fi[\s\S]*?\/dev\/urandom/.test(
		packageBuild
	),
	'(fork-sparkle-key) a release build must fail with ::error:: before the throwaway Sparkle key is generated'
);
check(
	!/\/dev\/urandom/.test(pipeline.textWithout('package-macos')),
	'(fork-sparkle-key) only the package-macos build may generate a throwaway Sparkle key'
);

// Every push/PR launches the packaged app over user states; a release run
// launches the release archive itself on Apple silicon and Intel.
const launch = withoutFullLineComments(pipeline.job('launch'));
check(pipeline.locate('launch').file === MACOS_BOX, `the launch gate must live in ${MACOS_BOX}`);
check(
	pipeline.needsOf(launch).includes('package-macos'),
	'(symlinked-config-dir) the launch gate must wait for the package it launches'
);
check(
	/^\s+name:\s*assets-macos\s*$/m.test(
		pipeline.step(launch, 'Download the package built by this run')
	),
	'(symlinked-config-dir) the launch gate must install the assets-macos archive that release publishes'
);
check(
	/^\s+scenario:\s*\$\{\{\s*fromJSON\(needs\.package-macos\.outputs\.scenarios\)\s*\}\}\s*$/m.test(
		launch
	),
	'(symlinked-config-dir) the launch scenarios must come from the profile package-macos resolved'
);
// Exact, not a shape: a release run launching on Intel only, or a CI run
// launching nowhere, kept a looser pattern green.
check(
	launch
		.split('\n')
		.includes(
			'        runner: ${{ fromJSON(inputs.release && \'["macos-15","macos-15-intel"]\' || \'["macos-15"]\') }}'
		),
	'(symlinked-config-dir) a release run must launch on macos-15 and macos-15-intel, any other run on macos-15'
);
// The release profile adds the release-only scenarios (source_logs,
// symlink_config_documents); a profile stuck on ci drops them from every
// release without a failure.
const profileStep = pipeline.step(packageJob, 'Resolve the launch-gate scenario profile');
check(
	profileStep.split('\n').includes("          PROFILE: ${{ inputs.release && 'release' || 'ci' }}"),
	'(symlinked-config-dir) a release run must resolve the release scenario profile, any other run the ci one'
);
check(
	pipeline.stepField(profileStep, 'run') ===
		'python3 tools/diagnostics/macos_launch_gate.py --print-matrix "$PROFILE" >> "$GITHUB_OUTPUT"',
	'(symlinked-config-dir) the scenario profile must come from macos_launch_gate.py, the one scenario list'
);
// The private Sparkle key reaches one step: the one that signs. Anywhere else,
// a build script or a job-level env could read or log it.
const privateKeyReads =
	withoutFullLineComments(pipeline.file(MACOS_BOX)).match(/secrets\.SPARKLE_ED_PRIVATE_KEY\b/g) ??
	[];
check(
	privateKeyReads.length === 1 &&
		/secrets\.SPARKLE_ED_PRIVATE_KEY\b/.test(
			pipeline.step(packageJob, 'Sign declared archives with Sparkle EdDSA key')
		),
	`only "Sign declared archives with Sparkle EdDSA key" may read secrets.SPARKLE_ED_PRIVATE_KEY in ${MACOS_BOX}, found ${privateKeyReads.length} read(s)`
);
// The code-signing .p12 and its password reach the one step that signs the
// bundle: the build. An ad hoc release must say so on the run, because every
// installed copy then loses its TCC and Login Items grants at the update.
for (const secret of ['MACOS_SIGNING_CERTIFICATE_BASE64', 'MACOS_SIGNING_CERTIFICATE_PASSWORD']) {
	const reads =
		withoutFullLineComments(pipeline.file(MACOS_BOX)).match(
			new RegExp(`secrets\\.${secret}\\b`, 'g')
		) ?? [];
	check(
		reads.length === 1 &&
			packageBuild.split('\n').includes(`          ${secret}: \${{ secrets.${secret} }}`),
		`(stable-signing-identity) only "Build ErgoptiPlus.app" may read secrets.${secret} in ${MACOS_BOX}, found ${reads.length} read(s)`
	);
}
check(
	/if \[ "\$ERGOPTI_RELEASE" = true \] && \[ -z "\$MACOS_SIGNING_CERTIFICATE_BASE64" \]; then\s*echo "::warning[^\n]*\n\s*fi[\s\S]*?build_macos_app\.sh/.test(
		packageBuild
	),
	'(stable-signing-identity) an ad hoc release build must emit a ::warning:: before build_macos_app.sh runs'
);
// The judge is the gate itself: it must run the verdict script on the installed
// app for this leg's scenario, and neither skip nor forgive a red verdict.
const judge = pipeline.step(launch, 'Launch over the user state and judge it');
check(
	pipeline.stepField(judge, 'if') === null &&
		pipeline.stepField(judge, 'continue-on-error') === null,
	'(symlinked-config-dir) the launch verdict step must set neither if nor continue-on-error'
);
const JUDGE_RUN =
	/^python3 tools\/diagnostics\/macos_launch_gate\.py \/Applications\/ErgoptiPlus\.app "\$RUNNER_TEMP\/launch-gate" "\$\{\{ matrix\.scenario \}\}"(?:\s|$)/;
check(
	JUDGE_RUN.test(pipeline.stepField(judge, 'run') ?? ''),
	'(symlinked-config-dir) the launch verdict step must run macos_launch_gate.py on the installed app for the matrix scenario'
);
check(
	!fs.existsSync(path.join(ROOT, '.github', 'workflows', 'macos-launch-gate.yml')),
	'macos-launch-gate.yml was inlined as the launch job; a second copy of the gate must not come back'
);

if (failures.length > 0) {
	console.error('[FAIL] macOS Swift launcher CI coverage:');
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}

console.log(
	'[OK] macOS CI requires a completed XCTest summary before the app build, and every OS lane gates the release success-only.'
);
