// tools/test/test-macos-dev-qualification-deferral.cjs
'use strict';

/** Source and typed-receipt controls; these do not execute Swift or native Mac APIs. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ROOT = path.resolve(__dirname, '../..');
const policy = require('../ci/dev-release-qualification.cjs');
const configuration = JSON.parse(fs.readFileSync(policy.POLICY_PATH, 'utf8'));
const fullDefault = require('./ci-full-default.cjs');
const workflow = fullDefault.file('.github/workflows/ci-macos.yml');
const caller = fullDefault.file('.github/workflows/ci.yml');
// Wrapper assertions inspect validated raw source, independently of full-branch projection.
const rawWorkflow = fullDefault
	.rawFiles()
	.find((entry) => entry.rel === '.github/workflows/ci-macos.yml').text;
const packageSource = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/macos/launcher/Package.swift'),
	'utf8'
);
const brew = configuration.scopes['macos-brew-archive'];
const brewSource = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/macos/launcher', brew.path),
	'utf8'
);
const consentFile = 'HomebrewAutomationConsentTests.swift';
const consentSource = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests', consentFile),
	'utf8'
);
const stableConfiguration = JSON.parse(
	fs.readFileSync(path.join(ROOT, '.github/ci/stable_release_qualification_exception.json'), 'utf8')
);
const policySelector =
	'\tlet policyFilename: String\n' +
	'\tif selected == "' +
	stableConfiguration.id +
	'" {\n' +
	'\t\tpolicyFilename = "stable_release_qualification_exception.json"\n' +
	'\t} else if selected == "' +
	configuration.id +
	'" {\n' +
	'\t\tpolicyFilename = "dev_release_qualification_exceptions.json"\n' +
	'\t} else { fatalError("Unknown native qualification profile.") }';
const clock = new Date('2026-10-08T20:00:00Z');
const sha = '0123456789abcdef0123456789abcdef01234567';
const context = {
	github_actions: 'true',
	repository: configuration.repository,
	event_name: configuration.event_name,
	ref: configuration.ref,
	release: configuration.release,
	prerelease: configuration.prerelease,
	channel: configuration.channel,
	tag: configuration.tag,
	version: configuration.version
};
const environment = {
	GITHUB_ACTIONS: 'true',
	GITHUB_REPOSITORY: context.repository,
	GITHUB_EVENT_NAME: context.event_name,
	GITHUB_REF: context.ref,
	GITHUB_SHA: sha,
	ERGOPTI_DEV_RELEASE_RELEASE: 'true',
	ERGOPTI_DEV_RELEASE_PRERELEASE: context.prerelease,
	ERGOPTI_DEV_RELEASE_CHANNEL: context.channel,
	ERGOPTI_DEV_RELEASE_TAG: context.tag,
	ERGOPTI_DEV_RELEASE_VERSION: context.version
};
let passed = 0;
function check(name, callback) {
	callback();
	passed++;
}
// Admit only the independent native SDK receiving selector; the full package
// suite and every other job keep the blanket exclusion refusal.
const SDK_STEP_NAME = 'Qualify actual SDK accepted-owner and deadline XCTest controls';
const SDK_FILTER =
	"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|ManagedImageAliasTests|OwnedSuspendedImageTests|ManagedListenerPathIdentityTests|ManagedNetworkBootstrapTests'";
function admitNativeSdkSelector(mac) {
	const jobs = [
		...mac.matchAll(/^  managed-ollama-native:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)
	];
	if (jobs.length !== 1) return null;
	const steps = [
		...jobs[0][0].matchAll(
			/^      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n[\s\S]*?(?=^      - |(?![\s\S]))/gm
		)
	];
	if (steps.length !== 1) return null;
	const step = steps[0][0];
	if (!step.startsWith(`      - name: ${SDK_STEP_NAME}\n        shell: bash\n        run: |\n`))
		return null;
	if (/^        (?:if|continue-on-error):/m.test(step)) return null;
	const command =
		'          swift test --package-path static/ergopti_plus/macos/launcher \\\n' +
		'            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n' +
		`            ${SDK_FILTER} 2>&1 | tee "$transcript"\n`;
	if (step.split(command).length !== 2 || step.split(SDK_FILTER).length !== 2) return null;
	for (const line of [
		'          set -euo pipefail',
		'          statuses=("${PIPESTATUS[@]}")',
		'          test "${statuses[0]}" -eq 0',
		'          test "${statuses[1]}" -eq 0',
		'          grep -Fq "Test Suite \'ManagedOllamaAPIWorkerTests\' passed" "$transcript"',
		'          grep -Fq \'Executed 12 tests, with 0 failures\' "$transcript"',
		'          grep -Fq "Test Suite \'ManagedPTYWorkerTests\' passed" "$transcript"',
		'          grep -Fq \'Executed 11 tests, with 0 failures\' "$transcript"',
		'          grep -Fq "Test Suite \'ManagedImageAliasTests\' passed" "$transcript"',
		'          grep -Fq \'Executed 4 tests, with 0 failures\' "$transcript"',
		'          grep -Fq "Test Suite \'OwnedSuspendedImageTests\' passed" "$transcript"',
		'          grep -Fq \'Executed 6 tests, with 0 failures\' "$transcript"',
		'          grep -Fq "Test Suite \'ManagedListenerPathIdentityTests\' passed" "$transcript"',
		'          grep -Fq \'Executed 2 tests, with 0 failures\' "$transcript"',
		'          grep -Fq "Test Suite \'ManagedNetworkBootstrapTests\' passed" "$transcript"',
		'          test "$(grep -Fc \'Executed 6 tests, with 0 failures\' "$transcript")" -eq 2',
		'          grep -Fq \'Executed 41 tests, with 0 failures\' "$transcript"',
		'        timeout-minutes: 10'
	]) {
		if (step.split('\n').filter((actual) => actual === line).length !== 1) return null;
	}
	const skippedRefusal =
		'          if grep -Eq "^Test Case.* skipped|with [1-9][0-9]* tests? skipped" "$transcript"; then\n' +
		'            echo "::error::native XCTest skipped a mandatory receiving case"\n' +
		'            exit 1\n          fi\n';
	if (step.split(skippedRefusal).length !== 2) return null;
	const position = jobs[0].index + steps[0].index + step.indexOf(SDK_FILTER);
	return admitNativePacSelector(mac.slice(0, position) + mac.slice(position + SDK_FILTER.length));
}
// Only the exact existing PAC/WPAD receiving cohort may use this selector.
const PAC_STEP_NAME = 'Qualify actual native PAC and WPAD XCTest controls';
const PAC_FILTER =
	"--filter 'ManagedHTTPWorkerTests|ManagedHTTPWireTests|ManagedHTTPWPADWireTests'";
const PAC_STEP_SOURCE =
	'      - name: Qualify actual native PAC and WPAD XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          test -n "$ERGOPTI_NATIVE_HTTP_PYTHON"\n          test -x "$ERGOPTI_NATIVE_HTTP_PYTHON"\n          transcript="$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-xctest.log"\n          set +e\n          swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'ManagedHTTPWorkerTests|ManagedHTTPWireTests|ManagedHTTPWPADWireTests\' 2>&1 | tee "$transcript"\n          pac_statuses=("${PIPESTATUS[@]}")\n          set -e\n          node tools/diagnostics/managed_http_pac_xctest_evidence.cjs "$transcript" "${pac_statuses[0]}" "${pac_statuses[1]}" "$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-verdict.json"\n        timeout-minutes: 10\n';
const PAC_RAW_STEP_SOURCE =
	'      - name: Qualify actual native PAC and WPAD XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          receipt="$RUNNER_TEMP/stable-macos-native-pac-${{ matrix.architecture }}.json"\n          mkdir -p "$(dirname "$receipt")"\n          node tools/ci/dev-release-qualification.cjs --scope macos-native-pac --receipt "$receipt"\n          mode="$(node tools/ci/dev-release-qualification.cjs --scope macos-native-pac --validate-scope-receipt "$receipt")"\n          if [ "$mode" = deferred ]; then\n              echo "[DEFERRED] macos-native-pac: qualified=false; original command not executed."\n          elif [ "$mode" = full ]; then\n              set -euo pipefail\n              test -n "$ERGOPTI_NATIVE_HTTP_PYTHON"\n              test -x "$ERGOPTI_NATIVE_HTTP_PYTHON"\n              transcript="$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-xctest.log"\n              set +e\n              swift test --package-path static/ergopti_plus/macos/launcher \\\n                --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n                --filter \'ManagedHTTPWorkerTests|ManagedHTTPWireTests|ManagedHTTPWPADWireTests\' 2>&1 | tee "$transcript"\n              pac_statuses=("${PIPESTATUS[@]}")\n              set -e\n              node tools/diagnostics/managed_http_pac_xctest_evidence.cjs "$transcript" "${pac_statuses[0]}" "${pac_statuses[1]}" "$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-verdict.json"\n          else\n              echo "Invalid command qualification disposition" >&2\n              exit 1\n          fi\n        timeout-minutes: 10\n\n';
function admitNativePacSelector(mac) {
	if (mac.split(PAC_FILTER).length !== 2) return null;
	const jobs = [
		...mac.matchAll(/^  managed-ollama-native:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)
	];
	if (jobs.length !== 1) return null;
	const job = jobs[0][0];
	const steps = [
		...job.matchAll(
			/^      - name: Qualify actual native PAC and WPAD XCTest controls\n[\s\S]*?(?=^      - |(?![\s\S]))/gm
		)
	];
	if (
		steps.length !== 1 ||
		steps[0][0].replace(/\n+$/, '\n') !== PAC_STEP_SOURCE ||
		job.split(PAC_FILTER).length !== 2
	)
		return null;
	const before = job.indexOf(`      - name: ${SDK_STEP_NAME}\n`);
	const after = job.indexOf(
		'      - name: Receive actual independent managed HTTP native clients\n'
	);
	if (before < 0 || before >= steps[0].index || after <= steps[0].index) return null;
	const position = jobs[0].index + steps[0].index + steps[0][0].indexOf(PAC_FILTER);
	return admitNativeSourceSelector(
		mac.slice(0, position) + mac.slice(position + PAC_FILTER.length)
	);
}
// Admit only the exact source-owner cohort with unchanged source/run/attempt receipts.
const SOURCE_STEP_NAME = 'Qualify actual native PAC source ownership XCTest controls';
const SOURCE_FILTER = "--filter '(^|[.])ManagedPACSourceTests([/.]|$)'";
const SOURCE_STEP_SOURCE =
	'      - name: Qualify actual native PAC source ownership XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          test -n "$ERGOPTI_NATIVE_HTTP_PYTHON"\n          test -x "$ERGOPTI_NATIVE_HTTP_PYTHON"\n          test -z "${ERGOPTI_DEV_QUALIFICATION_PROFILE:-}"\n          transcript="$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-xctest.log"\n          source_receipt="$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-inputs.json"\n          node tools/diagnostics/native_pac_source_evidence.cjs begin "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE" "$source_receipt"\n          set +e\n          swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])ManagedPACSourceTests([/.]|$)\' 2>&1 | tee "$transcript"\n          source_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#source_statuses[@]}" -eq 2\n          node tools/diagnostics/native_pac_source_evidence.cjs judge "$transcript" "${source_statuses[0]}" "${source_statuses[1]}" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE" "$source_receipt" "$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-verdict.json"\n        timeout-minutes: 10\n';
function admitNativeSourceSelector(mac) {
	if (mac.split(SOURCE_FILTER).length !== 2) return null;
	const jobs = [
		...mac.matchAll(/^  managed-ollama-native:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)
	];
	if (jobs.length !== 1) return null;
	const job = jobs[0][0];
	const steps = [
		...job.matchAll(
			/^      - name: Qualify actual native PAC source ownership XCTest controls\n[\s\S]*?(?=^      - |(?![\s\S]))/gm
		)
	];
	if (
		steps.length !== 1 ||
		steps[0][0] !== SOURCE_STEP_SOURCE ||
		job.split(SOURCE_FILTER).length !== 2
	)
		return null;
	const sdk = job.indexOf(`      - name: ${SDK_STEP_NAME}\n`);
	const pac = job.indexOf(`      - name: ${PAC_STEP_NAME}\n`);
	if (sdk < 0 || sdk >= steps[0].index || pac <= steps[0].index) return null;
	const position = jobs[0].index + steps[0].index + steps[0][0].indexOf(SOURCE_FILTER);
	return admitItem36Selector(mac.slice(0, position) + mac.slice(position + SOURCE_FILTER.length));
}

function admitRawNativePacSelector(mac) {
	if (mac.split(PAC_RAW_STEP_SOURCE).length !== 2) return null;
	const projected = admitRawWorkflow(mac);
	return projected === null ? null : admitNativePacSelector(projected);
}
function admitRawNativeSdkSelector(mac) {
	if (mac.split(PAC_RAW_STEP_SOURCE).length !== 2) return null;
	const projected = admitRawWorkflow(mac);
	return projected === null ? null : admitNativeSdkSelector(projected);
}
// The same strict owner admits every retained wrapper, including the package
// PAC arguments. A malformed wrapper refuses before any selector is inspected.
function admitRawWorkflow(mac) {
	try {
		return fullDefault
			.fromFiles(
				fullDefault
					.rawFiles()
					.map((file) =>
						file.rel === '.github/workflows/ci-macos.yml' ? { ...file, text: mac } : file
					)
			)
			.file('.github/workflows/ci-macos.yml');
	} catch {
		return null;
	}
}
// Admit only the additional manual diagnostic selector and its exact source owner.
const ITEM36_FILTER =
	"--filter 'ReleaseArchiveStagingTests|SparkleArchiveUpdateAcceptanceTests|HomebrewArchiveAcceptanceTests|HomebrewAutomationConsentTests'";
function admitItem36Selector(mac) {
	const jobs = [...mac.matchAll(/^  item36-native:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)];
	if (jobs.length !== 1) return null;
	const job = jobs[0][0];
	for (const line of [
		"    if: ${{ github.event_name == 'workflow_dispatch' && !inputs.release }}",
		'    runs-on: macos-latest',
		'    timeout-minutes: 25',
		"          python-version: '3.13'",
		"          node-version-file: '.node-version'"
	])
		if (job.split('\n').filter((actual) => actual === line).length !== 1) return null;
	if (/^    (?:needs|continue-on-error|outputs|secrets):/m.test(job)) return null;
	const steps = [
		...job.matchAll(
			/^      - name: Qualify scoped item 36 native archive XCTest controls\n[\s\S]*?(?=^      - |(?![\s\S]))/gm
		)
	];
	if (steps.length !== 1) return null;
	const step = steps[0][0];
	if (
		!step.startsWith(
			'      - name: Qualify scoped item 36 native archive XCTest controls\n        shell: bash\n        env:\n'
		) ||
		/^        (?:if|continue-on-error):/m.test(step)
	)
		return null;
	const command =
		'          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n' +
		'            --scratch-path "$RUNNER_TEMP/swift-launcher-ci" \\\n' +
		`            ${ITEM36_FILTER} 2>&1 | tee "$transcript"\n`;
	if (step.split(command).length !== 2 || job.split(ITEM36_FILTER).length !== 2) return null;
	for (const line of [
		"          ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT: '1'",
		"          ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI: '1'",
		'          set -euo pipefail',
		'          test -z "${ERGOPTI_DEV_QUALIFICATION_PROFILE:-}"',
		'          export ERGOPTI_ARCHIVE_EVIDENCE_DIR="$(mktemp -d "$evidence/archive-session.XXXXXX")"',
		'          node tools/diagnostics/item36_xctest_evidence.cjs begin "$GITHUB_SHA" "$source_receipt"',
		'          item36_statuses=("${PIPESTATUS[@]}")',
		'          node tools/diagnostics/item36_xctest_evidence.cjs judge "$transcript" "${item36_statuses[0]}" "${item36_statuses[1]}" "$GITHUB_SHA" "$source_receipt" "$evidence/item36-verdict.json"',
		'        timeout-minutes: 20'
	])
		if (step.split('\n').filter((actual) => actual === line).length !== 1) return null;
	const packages = [
		...mac.matchAll(/^  package-macos:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)
	];
	if (
		packages.length !== 1 ||
		!packages[0][0].includes(
			'          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher --scratch-path "$RUNNER_TEMP/swift-launcher-ci" 2>&1 | tee "$xctest_log"\n'
		)
	)
		return null;
	const position = jobs[0].index + steps[0].index + step.indexOf(ITEM36_FILTER);
	return admitPermissionObservationSelector(
		mac.slice(0, position) + mac.slice(position + ITEM36_FILTER.length)
	);
}

// Only the independent no-prompt permission metadata case can use this selector.
const PERMISSION_FILTER =
	"--filter 'OwnedAutomationQueryWorkerTests.testActualNoPromptPermissionAPIOnlyPublishesRetiredMetadata'";
const PERMISSION_STEP_SOURCE =
	'      - name: Observe the actual no-prompt SDK permission API independently\n        if: ${{ !cancelled() }}\n        shell: bash\n        env:\n          SWIFT_BACKTRACE: enable=yes\n        run: |\n          set -euo pipefail\n          node tools/test/test-macos-swift-launcher-ci.cjs\n          evidence="$RUNNER_TEMP/swift-launcher-evidence"\n          transcript="$evidence/sdk-permission-xctest.log"\n          source_receipt="$evidence/sdk-permission-source.json"\n          node tools/diagnostics/sdk_permission_xctest_evidence.cjs begin "$GITHUB_SHA" "$source_receipt"\n          set +e\n          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$RUNNER_TEMP/swift-launcher-ci" \\\n            --filter \'OwnedAutomationQueryWorkerTests.testActualNoPromptPermissionAPIOnlyPublishesRetiredMetadata\' 2>&1 | tee "$transcript"\n          sdk_statuses=("${PIPESTATUS[@]}")\n          set -e\n          node tools/diagnostics/sdk_permission_xctest_evidence.cjs judge "$transcript" "${sdk_statuses[0]}" "${sdk_statuses[1]}" "$GITHUB_SHA" "$source_receipt" "$evidence/sdk-permission-verdict.json"\n        timeout-minutes: 3\n';
function admitPermissionObservationSelector(mac) {
	const jobs = [...mac.matchAll(/^  item36-native:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)];
	if (jobs.length !== 1 || mac.split(PERMISSION_FILTER).length !== 2) return null;
	const job = jobs[0][0];
	if (job.split(PERMISSION_STEP_SOURCE).length !== 2) return null;
	const archive = job.indexOf(
		'      - name: Qualify scoped item 36 native archive XCTest controls\n'
	);
	const observation = job.indexOf(PERMISSION_STEP_SOURCE);
	const retention = job.indexOf('      - name: Retain scoped item 36 native diagnostics\n');
	if (archive < 0 || archive >= observation || retention <= observation) return null;
	const position = jobs[0].index + observation + PERMISSION_STEP_SOURCE.indexOf(PERMISSION_FILTER);
	const admitted = admitNativeNumberRowSelector(
		mac.slice(0, position) + mac.slice(position + PERMISSION_FILTER.length)
	);
	return admitted === null ? null : admitLease165Selector(admitted);
}

// Strip only the exact independently admitted manual job, never arbitrary filters.
function admitLease165Selector(mac) {
	const jobs = fullDefault
		.jobsOfText(mac, '.github/workflows/ci-macos.yml')
		.filter((job) => job.id === 'lease165-native');
	if (
		jobs.length !== 1 ||
		require('node:crypto').createHash('sha256').update(jobs[0].body.trimEnd()).digest('hex') !==
			'724f6560de5871aa08d5cb1287657a1a760aedc8aa30bdcdfabce0bd2adf2352'
	)
		return null;
	return mac.replace(jobs[0].body, '');
}
// Only this complete read-only cohort may add the NumberRow selector.
// Source/producer copies, test+tee status, twelve cases, seven TIS closures and
// sampled restoration are received by the exact step; no native pass is inferred.
const NUMBER_ROW_FILTER = "--filter '(^|[.])NumberRowSourceProbeTests([/.]|$)'";
const NUMBER_ROW_STEP_SOURCE =
	'      - name: Qualify actual selected number-row Carbon XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          evidence="$RUNNER_TEMP/number-row-source-evidence"\n          mkdir "$evidence"\n          transcript="$evidence/number-row-xctest.log"\n          source="static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"\n          producer="static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"\n          test "$(git rev-parse HEAD)" = "$GITHUB_SHA"\n          git show "$GITHUB_SHA:$source" | cmp - "$source"\n          git show "$GITHUB_SHA:$producer" | cmp - "$producer"\n          cp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          printf \'%s\\n\' "$GITHUB_SHA" > "$evidence/tested-sha.txt"\n          export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"\n          export ERGOPTI_TIS_EVIDENCE_SESSION="$(node -e \'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))\')"\n          set +e\n          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])NumberRowSourceProbeTests([/.]|$)\' 2>&1 | tee "$transcript"\n          number_row_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#number_row_statuses[@]}" -eq 2\n          set +e\n          python3 tools/diagnostics/keyboard_geometry_xctest_receipt.py \\\n            --class NumberRowSourceProbeTests --source "$evidence/NumberRowSourceProbeTests.swift" \\\n            --log "$transcript" --receipt "$evidence/number-row-verdict.json" \\\n            --test-exit "${number_row_statuses[0]}" --capture-exit "${number_row_statuses[1]}"\n          number_row_receipt_status=$?\n          node - "$evidence/number-row-verdict.json" "$ERGOPTI_TIS_EVIDENCE_DIR" "$ERGOPTI_TIS_EVIDENCE_SESSION" <<\'NODE\'\n          const fs = require(\'node:fs\');\n          const transport = require(\'./tools/diagnostics/tis_evidence_transport.cjs\');\n          const receipt = JSON.parse(fs.readFileSync(process.argv[2], \'utf8\'));\n          if (!receipt.passed || receipt.scope !== \'NumberRowSourceProbeTests\' || receipt.expected_count !== 12 || receipt.received_count !== 12) throw new Error(\'exact twelve-case number-row receiving refused\');\n          const session = transport.validate(process.argv[3], process.argv[4]);\n          const expectedSources = {\n            testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations: \'com.apple.keylayout.US\',\n            testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor: \'com.apple.keylayout.French\',\n            testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage: \'com.apple.keylayout.US\',\n            testActualUSCapsMaskChangesAnIndependentLetterExpectation: \'com.apple.keylayout.US\',\n            testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI: \'com.apple.keylayout.French\',\n            testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead: \'com.apple.keylayout.US\',\n            testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject: \'com.apple.keylayout.US\'\n          };\n          const expected = Object.keys(expectedSources).sort();\n          const observed = session.receipts.map((row) => {\n            if (row.test.state !== \'present\' || row.omittedEvents !== 0) throw new Error(\'native diagnostic identity refused\');\n            const match = /^(?:(?:\\w+\\.)?NumberRowSourceProbeTests\\.|-\\[(?:\\w+\\.)?NumberRowSourceProbeTests )(test\\w+)(?:\\])?:(com\\.apple\\.keylayout\\.(?:US|French))$/.exec(row.test.value);\n            if (!match || !Object.hasOwn(expectedSources, match[1]) || match[2] !== expectedSources[match[1]]) throw new Error(\'foreign native method fixture\');\n            const captures = row.events.filter((event) => event.phase === \'original.capture\');\n            if (captures.length !== 1 || captures[0].original?.id?.state !== \'present\' || typeof captures[0].original.id.value !== \'string\' || captures[0].original.id.value.length === 0) throw new Error(\'captured original source unavailable\');\n            const originalID = captures[0].original.id.value;\n            for (const phase of [\'restore.inner.after\', \'restore.outer.after\']) {\n              const events = row.events.filter((event) => event.phase === phase);\n              if (events.length !== 1 || events[0].status !== 0) throw new Error(\'native source restoration refused\');\n              if (events[0].original?.id?.state !== \'present\' || events[0].original.id.value !== originalID || events[0].current?.id?.state !== \'present\' || events[0].current.id.value !== originalID) throw new Error(\'sampled selected source restoration refused\');\n            }\n            return match[1];\n          }).sort();\n          if (!session.complete || JSON.stringify(observed) !== JSON.stringify(expected)) throw new Error(\'exact seven native diagnostic closures refused\');\n          NODE\n          number_row_tis_status=$?\n          set -e\n          cmp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cmp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          test "$number_row_receipt_status" -eq 0\n          test "$number_row_tis_status" -eq 0\n        timeout-minutes: 10\n';
const NUMBER_ROW_RETENTION_SOURCE =
	'      - name: Retain selected number-row Carbon XCTest diagnostics\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: number-row-carbon-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}\n          if-no-files-found: error\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n            ${{ runner.temp }}/number-row-source-evidence/number-row-verdict.json\n            ${{ runner.temp }}/number-row-source-evidence/tested-sha.txt\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbe.swift\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbeTests.swift\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/start.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/manifest.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/record-*.dat\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/refusal.json\n';
function admitNativeNumberRowSelector(mac) {
	if (typeof mac !== 'string' || mac.split(NUMBER_ROW_FILTER).length !== 2) return null;
	const jobs = [
		...mac.matchAll(/^  managed-ollama-native:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)
	];
	if (jobs.length !== 1) return null;
	const job = jobs[0][0];
	for (const expected of [NUMBER_ROW_STEP_SOURCE, NUMBER_ROW_RETENTION_SOURCE]) {
		const heading = expected.slice(0, expected.indexOf('\n') + 1);
		if (
			mac.split(heading).length !== 2 ||
			mac.split(expected).length !== 2 ||
			job.split(expected).length !== 2
		)
			return null;
	}
	const sdk = job.indexOf('      - name: Retain independent native SDK XCTest diagnostics\n');
	const selected = job.indexOf(NUMBER_ROW_STEP_SOURCE);
	const retained = job.indexOf(NUMBER_ROW_RETENTION_SOURCE);
	const next = job.indexOf(
		'      - name: Qualify actual native PAC source ownership XCTest controls\n'
	);
	if (
		sdk < 0 ||
		selected <= sdk ||
		retained !== selected + NUMBER_ROW_STEP_SOURCE.length ||
		next <= retained
	)
		return null;
	const position = jobs[0].index + selected + NUMBER_ROW_STEP_SOURCE.indexOf(NUMBER_ROW_FILTER);
	return mac.slice(0, position) + mac.slice(position + NUMBER_ROW_FILTER.length);
}

function sourceProblems(pkg, mac, rootCaller) {
	const errors = consentSourceProblems(brewSource, consentSource, pkg);
	const requireText = (value, token, name) => {
		if (!value.includes(token)) errors.push(name);
	};
	requireText(
		pkg,
		'guard let selected = environment["ERGOPTI_DEV_QUALIFICATION_PROFILE"], !selected.isEmpty else {\n\t\treturn []',
		'full-default'
	);
	requireText(
		pkg,
		'repository.appendingPathComponent(".github/ci/" + policyFilename)',
		'canonical-policy'
	);
	if (pkg.split(policySelector).length !== 2) errors.push('closed-policy-selector');
	const outsideSelector = pkg.replace(policySelector, '');
	requireText(pkg, 'profile == selected', 'profile-identity');
	requireText(pkg, 'Date() < expiry', 'expiry');
	requireText(
		pkg,
		'CFGetTypeID(release) == CFBooleanGetTypeID(), release.boolValue',
		'typed-release'
	);
	requireText(pkg, 'environment["GITHUB_ACTIONS"] == "true"', 'github-actions');
	requireText(pkg, 'environment["ERGOPTI_DEV_RELEASE_RELEASE"] == "true"', 'release-context');
	for (const key of [
		'GITHUB_REPOSITORY',
		'GITHUB_EVENT_NAME',
		'GITHUB_REF',
		'ERGOPTI_DEV_RELEASE_PRERELEASE',
		'ERGOPTI_DEV_RELEASE_CHANNEL',
		'ERGOPTI_DEV_RELEASE_TAG',
		'ERGOPTI_DEV_RELEASE_VERSION'
	])
		requireText(pkg, `("${key}",`, 'context-' + key);
	requireText(pkg, 'environment[variable] == expected', 'context-comparison');
	requireText(pkg, 'scopes["macos-brew-archive"]', 'brew-only-scope');
	requireText(pkg, 'brew["kind"] as? String == "swift_test_file"', 'test-file-kind');
	requireText(
		pkg,
		'testSource.components(separatedBy: "\\n\\tfunc test").count == 2',
		'single-test-file'
	);
	requireText(pkg, 'exclude: deferredDevReleaseTestFiles()', 'conditional-exclusion');
	const admittedMac = admitNativeSdkSelector(mac);
	if (admittedMac === null) errors.push('native-sdk-receiving-selector');
	if (
		(pkg.match(/exclude:/g) || []).length !== 1 ||
		/--skip|--filter|XCTSkip/.test((admittedMac ?? mac) + pkg)
	)
		errors.push('no-other-exclusion');
	for (const value of [
		configuration.id,
		configuration.expires_at,
		brew.path,
		configuration.tag,
		configuration.version,
		stableConfiguration.id,
		stableConfiguration.expires_at,
		stableConfiguration.tag,
		stableConfiguration.version
	])
		if (outsideSelector.includes(value)) errors.push('duplicated-policy');
	requireText(
		mac,
		'python3 -m unittest discover -s tools/diagnostics -p macos_brew_archive_acceptance_test.py -v',
		'portable-brew'
	);
	requireText(
		mac,
		'python3 -m unittest discover -s tools/diagnostics/apple_shortcuts_probe -p test_probe.py -v',
		'portable-shortcuts'
	);
	requireText(mac, 'node tools/diagnostics/apple_shortcuts_probe/test_probe.cjs', 'portable-jxa');
	requireText(
		mac,
		'if [ "$shortcuts_mode" = full ]; then\n            python3 tools/diagnostics/apple_shortcuts_probe/run_probe.py',
		'full-native-command'
	);
	requireText(
		mac,
		"policy.validateQualificationReceipt(receipt, 'macos-shortcuts-discovery', process.env.GITHUB_SHA, context)",
		'fresh-typed-receipt'
	);
	requireText(mac, 'receipt.qualified !== false', 'unqualified-receipt');
	requireText(mac, 'macos-brew-archive.json', 'brew-artifact');
	requireText(mac, 'macos-shortcuts-discovery.json', 'shortcuts-artifact');
	requireText(mac, 'script -q /dev/null swift test --package-path', 'swift-unfiltered');
	requireText(mac, "Test Suite 'All tests' passed", 'strict-all-tests');
	requireText(mac, 'node tools/test/desktop-ci-evidence.cjs verify macos', 'desktop-verdict');
	for (const name of [
		'Install Sparkle signing tool',
		'Build ErgoptiPlus.app',
		'Smoke test built ErgoptiPlus.app',
		'Sign declared archives with Sparkle EdDSA key',
		'Generate Sparkle appcast',
		'Install the package the way a user does',
		'Launch over the user state and judge it'
	])
		requireText(mac, name, 'preserved-' + name);
	const callerStart = rootCaller.indexOf('    uses: ./.github/workflows/ci-macos.yml\n');
	const callerEnd = rootCaller.indexOf('    secrets:\n', callerStart);
	const macCaller =
		callerStart >= 0 && callerEnd > callerStart ? rootCaller.slice(callerStart, callerEnd) : '';
	requireText(
		macCaller,
		'      tag: ${{ needs.validate.outputs.tag }}\n      prerelease: ${{ needs.validate.outputs.prerelease }}\n      channel:',
		'exact-plan-forwarding'
	);
	for (const field of ['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION'])
		requireText(
			mac,
			`ERGOPTI_DEV_RELEASE_${field}: \${{ inputs.${field.toLowerCase()} }}`,
			'plan-env-' + field
		);
	requireText(rootCaller, 'needs: [validate, core, macos, windows, linux]', 'release-needs');
	return errors;
}
function consentSourceProblems(native, portable, pkg) {
	const errors = [];
	const method = 'func testAutomationConsentArgumentsRequireBothExplicitOptIns() throws';
	if (native.includes(method) || portable.split(method).length !== 2)
		errors.push('portable-consent-method-always-included');
	if (
		portable.split('enum HomebrewAutomationConsent {').length !== 2 ||
		portable.split('static func arguments(').length !== 2 ||
		native.includes('func enabled(')
	)
		errors.push('consent-helper-single-owner');
	for (const source of [native, portable])
		if (!source.includes('return try HomebrewAutomationConsent.arguments(environment)'))
			errors.push('consent-wrapper-forwards');
	for (const token of [
		'guard value == "0" || value == "1" else {',
		'let request = try enabled("ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT")',
		'let approve = try enabled("ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI")',
		'guard !approve || request else {',
		'ConsentError.refused(-1, "Malformed owned Automation consent opt-in")',
		'ConsentError.refused(-1, "Owned consent UI requires an explicit permission request")'
	])
		if (!portable.includes(token)) errors.push('consent-explicit-opt-in-guards');
	if (pkg.includes(consentFile) || !pkg.includes('path: launcherTestTargetPath,'))
		errors.push('portable-consent-file-not-excluded');
	return errors;
}
check('complete-source-guard', () =>
	assert.deepEqual(sourceProblems(packageSource, workflow, caller), [])
);
for (const [name, before, after] of [
	['missing-selector', policySelector, ''],
	[
		'foreign-stable-file',
		'policyFilename = "stable_release_qualification_exception.json"',
		'policyFilename = "foreign.json"'
	],
	[
		'foreign-dev-file',
		'policyFilename = "dev_release_qualification_exceptions.json"',
		'policyFilename = "foreign.json"'
	],
	[
		'unknown-profile-admitted',
		'else { fatalError("Unknown native qualification profile.") }',
		'else { policyFilename = "dev_release_qualification_exceptions.json" }'
	],
	['duplicate-selector', policySelector, policySelector + '\n' + policySelector],
	[
		'duplicate-policy-outside-selector',
		policySelector,
		policySelector + '\nlet duplicatedProfile = "' + configuration.id + '"'
	]
])
	check(name, () => {
		assert.equal(packageSource.split(before).length, 2, 'exact actual selector mutation preimage');
		assert.ok(
			sourceProblems(packageSource.replace(before, after), workflow, caller).length > 0,
			'the admitted selector cannot hide a different policy or duplicated policy data'
		);
	});
for (const [name, token, replacement, target] of [
	['default-must-be-full', 'return []', 'return ["other.swift"]', 'package'],
	['expired-profile-refuses', 'Date() < expiry', 'Date() >= expiry', 'package'],
	['github-context-required', 'environment["GITHUB_ACTIONS"] == "true"', 'true', 'package'],
	['only-brew-file-selected', 'exclude: deferredDevReleaseTestFiles()', 'exclude: []', 'package'],
	[
		'portable-shortcuts-remains',
		'node tools/diagnostics/apple_shortcuts_probe/test_probe.cjs',
		'echo disabled',
		'workflow'
	],
	['native-full-remains', 'if [ "$shortcuts_mode" = full ]; then', 'if false; then', 'workflow'],
	[
		'typed-receipt-required',
		"policy.validateQualificationReceipt(receipt, 'macos-shortcuts-discovery', process.env.GITHUB_SHA, context)",
		'void receipt',
		'workflow'
	],
	[
		'strict-xctest-collector-remains',
		"Test Suite 'All tests' passed",
		'Selected tests',
		'workflow'
	],
	[
		'release-needs-remain',
		'needs: [validate, core, macos, windows, linux]',
		'needs: [validate, core]',
		'caller'
	]
]) {
	check(name, () => {
		const text = target === 'package' ? packageSource : target === 'workflow' ? workflow : caller;
		assert.ok(text.includes(token));
		const changed = text.replace(token, replacement);
		assert.ok(
			sourceProblems(
				target === 'package' ? changed : packageSource,
				target === 'workflow' ? changed : workflow,
				target === 'caller' ? changed : caller
			).length > 0
		);
	});
}
check('declared-sdk-selector-keeps-full-package-unfiltered', () => {
	assert.ok(admitNativeSdkSelector(workflow));
	assert.ok(!/--skip|--filter|XCTSkip/.test(admitNativeSdkSelector(workflow)));
	assert.ok(workflow.includes('script -q /dev/null swift test --package-path'));
});
for (const [name, token, replacement] of [
	['sdk-wrong-selector-is-red', SDK_FILTER, "--filter 'ManagedOllamaAPIWorkerTests'"],
	['sdk-foreign-job-is-red', '  managed-ollama-native:\n', '  foreign-native-job:\n'],
	[
		'sdk-foreign-step-is-red',
		`      - name: ${SDK_STEP_NAME}\n`,
		'      - name: Foreign SDK tests\n'
	],
	[
		'sdk-missing-api-transcript-is-red',
		'Executed 12 tests, with 0 failures',
		'Executed 10 tests, with 0 failures'
	],
	[
		'sdk-missing-pty-transcript-is-red',
		'Executed 11 tests, with 0 failures',
		'Executed 10 tests, with 0 failures'
	],
	[
		'sdk-missing-alias-suite-is-red',
		"Test Suite 'ManagedImageAliasTests' passed",
		"Test Suite 'ManagedImageAliasTests' unavailable"
	],
	[
		'sdk-wrong-alias-census-is-red',
		'Executed 4 tests, with 0 failures',
		'Executed 3 tests, with 0 failures'
	],
	[
		'sdk-missing-alias-selector-is-red',
		"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|ManagedImageAliasTests|OwnedSuspendedImageTests|ManagedListenerPathIdentityTests|ManagedNetworkBootstrapTests'",
		"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|OwnedSuspendedImageTests|ManagedListenerPathIdentityTests|ManagedNetworkBootstrapTests'"
	],
	[
		'sdk-missing-suspended-suite-is-red',
		"Test Suite 'OwnedSuspendedImageTests' passed",
		"Test Suite 'OwnedSuspendedImageTests' unavailable"
	],
	[
		'sdk-wrong-suspended-census-is-red',
		'Executed 6 tests, with 0 failures',
		'Executed 5 tests, with 0 failures'
	],
	[
		'sdk-missing-suspended-selector-is-red',
		"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|ManagedImageAliasTests|OwnedSuspendedImageTests|ManagedListenerPathIdentityTests|ManagedNetworkBootstrapTests'",
		"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|ManagedImageAliasTests|ManagedListenerPathIdentityTests|ManagedNetworkBootstrapTests'"
	],
	[
		'sdk-missing-physical-path-suite-is-red',
		"Test Suite 'ManagedListenerPathIdentityTests' passed",
		"Test Suite 'ManagedListenerPathIdentityTests' unavailable"
	],
	[
		'sdk-wrong-physical-path-census-is-red',
		'Executed 2 tests, with 0 failures',
		'Executed 1 tests, with 0 failures'
	],
	[
		'sdk-missing-physical-path-selector-is-red',
		"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|ManagedImageAliasTests|OwnedSuspendedImageTests|ManagedListenerPathIdentityTests|ManagedNetworkBootstrapTests'",
		"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|ManagedImageAliasTests|OwnedSuspendedImageTests|ManagedNetworkBootstrapTests'"
	],
	[
		'sdk-missing-network-bootstrap-suite-is-red',
		"Test Suite 'ManagedNetworkBootstrapTests' passed",
		"Test Suite 'ManagedNetworkBootstrapTests' unavailable"
	],
	[
		'sdk-missing-network-bootstrap-selector-is-red',
		SDK_FILTER,
		"--filter 'ManagedOllamaAPIWorkerTests|ManagedPTYWorkerTests|ManagedImageAliasTests|OwnedSuspendedImageTests|ManagedListenerPathIdentityTests'"
	],
	[
		'sdk-incomplete-network-bootstrap-census-is-red',
		'          test "$(grep -Fc \'Executed 6 tests, with 0 failures\' "$transcript")" -eq 2',
		'          true'
	],
	[
		'sdk-incomplete-total-is-red',
		'Executed 41 tests, with 0 failures',
		'Executed 34 tests, with 0 failures'
	],
	['sdk-ignored-swift-status-is-red', '          test "${statuses[0]}" -eq 0', '          true'],
	['sdk-ignored-tee-status-is-red', '          test "${statuses[1]}" -eq 0', '          true'],
	[
		'sdk-skipped-receiving-refusal-is-red',
		'            echo "::error::native XCTest skipped a mandatory receiving case"\n            exit 1',
		'            echo skipped'
	],
	[
		'sdk-disabled-step-is-red',
		`      - name: ${SDK_STEP_NAME}\n`,
		`      - name: ${SDK_STEP_NAME}\n        if: false\n`
	]
]) {
	check(name, () => {
		assert.ok(workflow.includes(token));
		assert.ok(
			sourceProblems(packageSource, workflow.replace(token, replacement), caller).length > 0
		);
	});
}
check('sdk-selector-moved-to-package-is-red', () => {
	const moved = workflow
		.replace(SDK_FILTER, '')
		.replace(
			'script -q /dev/null swift test --package-path',
			`script -q /dev/null swift test ${SDK_FILTER} --package-path`
		);
	assert.ok(sourceProblems(packageSource, moved, caller).length > 0);
});
check('second-selector-outside-sdk-is-red', () => {
	const extra = workflow.replace(
		'script -q /dev/null swift test --package-path',
		`script -q /dev/null swift test ${SDK_FILTER} --package-path`
	);
	assert.ok(sourceProblems(packageSource, extra, caller).includes('no-other-exclusion'));
});
check('skip-and-package-exclusions-outside-sdk-stay-red', () => {
	for (const [pkg, mac] of [
		[packageSource, workflow + '\n# --skip OtherTests\n'],
		[packageSource + '\n// XCTSkip\n', workflow],
		[packageSource + '\n// exclude: []\n', workflow]
	])
		assert.ok(sourceProblems(pkg, mac, caller).includes('no-other-exclusion'));
});
check('canonical-file-contains-only-declared-method', () => {
	assert.equal(brewSource.split('func ' + brew.name + '() throws').length - 1, 1);
	assert.equal((brewSource.match(/\n\tfunc test/g) || []).length, 1);
});
check('portable-consent-file-and-helper-remain-included', () => {
	assert.deepEqual(consentSourceProblems(brewSource, consentSource, packageSource), []);
	assert.equal((consentSource.match(/\n\tfunc test/g) || []).length, 1);
});
check('portable-consent-file-exclusion-is-red', () => {
	assert.ok(
		consentSourceProblems(
			brewSource,
			consentSource,
			packageSource.replace('exclude: deferredDevReleaseTestFiles()', `exclude: ["${consentFile}"]`)
		).length > 0
	);
	assert.throws(
		() =>
			validateSwiftExclusionDump(
				{
					targets: [
						{
							name: 'ErgoptiPlusTests',
							path: path.posix.dirname(brew.path),
							exclude: [consentFile]
						}
					]
				},
				policy.resolveQualificationProfile(context, clock)
			),
		/Swift target join must identify the canonical declared Brew file/
	);
});
check('portable-consent-method-removal-is-red', () => {
	assert.ok(
		consentSourceProblems(
			brewSource,
			consentSource.replace(
				'func testAutomationConsentArgumentsRequireBothExplicitOptIns() throws',
				'func removed() throws'
			),
			packageSource
		).length > 0
	);
});
check('consent-helper-moved-into-deferred-file-is-red', () => {
	assert.ok(
		consentSourceProblems(
			brewSource + '\nfunc enabled(',
			consentSource.replace('enum HomebrewAutomationConsent {', 'enum ForeignConsent {'),
			packageSource
		).length > 0
	);
});
check('consent-guard-or-wrapper-bypass-is-red', () => {
	for (const changed of [
		consentSource.replace('guard !approve || request else {', 'guard true else {'),
		consentSource.replace(
			'return try HomebrewAutomationConsent.arguments(environment)',
			'return []'
		)
	])
		assert.ok(consentSourceProblems(brewSource, changed, packageSource).length > 0);
});
check('actual-helper-rejects-main-pr-version-clock', () => {
	for (const changed of [
		{ ...context, ref: 'refs/heads/main' },
		{ ...context, event_name: 'pull_request' },
		{ ...context, version: '0.0.0-dev.156' },
		{ ...context, version: '0.0.0-dev.158' }
	])
		assert.equal(policy.resolveQualificationProfile(changed, clock), null);
	assert.equal(
		policy.resolveQualificationProfile(context, new Date(configuration.expires_at)),
		null
	);
	assert.throws(() => policy.authorizeQualificationProfile('unknown', context, clock));
});
const readerStart = workflow.indexOf(
	"          const fs = require('node:fs');\n          const policy = require('./tools/ci/dev-release-qualification.cjs');"
);
const readerEnd = workflow.indexOf('\n          NODE', readerStart);
assert.ok(readerStart > 0 && readerEnd > readerStart);
const reader = workflow
	.slice(readerStart, readerEnd)
	.split('\n')
	.map((line) => line.slice(10))
	.join('\n');
function receive(receipt, env) {
	let output = '';
	const actualClockPort = {
		environmentContext: () => policy.environmentContext(env),
		resolveQualificationProfile: (c) => policy.resolveQualificationProfile(c, clock),
		validateQualificationReceipt: (r, s, h, c) =>
			policy.validateQualificationReceipt(r, s, h, c, clock)
	};
	vm.runInNewContext(reader, {
		require: (name) =>
			name === 'node:fs' ? { readFileSync: () => JSON.stringify(receipt) } : actualClockPort,
		process: {
			argv: ['node', '-', 'owned-receipt.json'],
			env,
			stdout: {
				write: (value) => {
					output += value;
				}
			}
		}
	});
	return output;
}
const profile = policy.resolveQualificationProfile(context, clock);
const deferred = policy.qualificationReceipt(profile, 'macos-shortcuts-discovery', {
	source_sha: sha
});
check('actual-receipt-reader-deferred-without-feature-claim', () => {
	assert.equal(receive(deferred, environment), 'deferred');
	assert.equal(deferred.qualified, false);
	assert.ok(!('ownership' in deferred) && !('passed' in deferred));
});
const full = {
	schema: 1,
	profile_id: null,
	scope: 'macos-shortcuts-discovery',
	status: 'full',
	qualified: false,
	source_sha: sha
};
check('actual-receipt-reader-full-outside-profile', () =>
	assert.equal(receive(full, { ...environment, GITHUB_REF: 'refs/heads/main' }), 'full')
);
check('full-cannot-bypass-active-policy', () => assert.throws(() => receive(full, environment)));
check('deferred-cannot-bypass-context-or-foreign-sha', () => {
	assert.throws(() => receive(deferred, { ...environment, GITHUB_EVENT_NAME: 'pull_request' }));
	assert.throws(() => receive({ ...deferred, source_sha: 'f'.repeat(40) }, environment));
});
check('unknown-fields-and-status-never-hide-native-work', () => {
	for (const changed of [
		{ ...deferred, passed: 0 },
		{ ...deferred, status: 'PASS' },
		{ ...deferred, qualified: true },
		{ ...full, ownership: { closed: true } }
	])
		assert.throws(() =>
			receive(
				changed,
				changed.profile_id === null
					? { ...environment, GITHUB_REF: 'refs/heads/main' }
					: environment
			)
		);
});
/** Validate actual SwiftPM output using its documented target-relative semantics. */
function validateSwiftExclusionDump(dump, selectedProfile) {
	policy.deferredScopes(selectedProfile);
	assert.ok(dump && Array.isArray(dump.targets), 'Actual Swift target dump is required.');
	const targets = dump.targets.filter((target) => target.name === 'ErgoptiPlusTests');
	assert.equal(targets.length, 1, 'The exact test target must occur once.');
	const target = targets[0];
	assert.equal(typeof target.path, 'string');
	assert.ok(Array.isArray(target.exclude));
	assert.ok(target.exclude.every((value) => typeof value === 'string'));
	if (selectedProfile === null) {
		assert.deepEqual(target.exclude, [], 'Inactive policy must retain every test source.');
		return 'full';
	}
	assert.equal(target.exclude.length, 1, 'Only the declared Brew file may be excluded.');
	const produced = target.exclude[0];
	assert.ok(
		produced && !produced.includes('/') && !produced.includes('\\'),
		'Swift exclusion must be one target-relative filename.'
	);
	assert.equal(
		path.posix.join(target.path, produced),
		brew.path,
		'Swift target join must identify the canonical declared Brew file.'
	);
	return 'deferred';
}
check('source-produced-target-relative-exclusion', () => {
	const target = /let launcherTestTargetPath = "([^"\n]+)"/.exec(packageSource);
	assert.ok(target, 'The actual shared target path must be present.');
	assert.ok(packageSource.includes('path: launcherTestTargetPath,'));
	assert.ok(packageSource.includes('let targetPrefix = launcherTestTargetPath + "/"'));
	assert.ok(packageSource.includes('guard path.hasPrefix(targetPrefix)'));
	assert.ok(packageSource.includes('let exclusion = String(path.dropFirst(targetPrefix.count))'));
	assert.ok(packageSource.includes('return [exclusion]'));
	assert.ok(!packageSource.includes('return [path]'));
	const producedRelative = brew.path.slice((target[1] + '/').length);
	assert.equal(path.posix.join(target[1], producedRelative), brew.path);
	assert.ok(workflow.includes('swift package dump-package --package-path'));
	assert.ok(
		workflow.includes('--package-dump "$RUNNER_TEMP/dev-release-qualification/swift-package.json"')
	);
});
const targetPath = path.posix.dirname(brew.path);
const relativeFile = path.posix.basename(brew.path);
check('produced-relative-dump-binds-canonical-file', () => {
	assert.equal(
		validateSwiftExclusionDump(
			{
				targets: [
					{
						name: 'ErgoptiPlusTests',
						path: targetPath,
						exclude: [relativeFile]
					}
				]
			},
			profile
		),
		'deferred'
	);
});
check('old-fullpath-dump-is-red', () => {
	assert.throws(
		() =>
			validateSwiftExclusionDump(
				{
					targets: [
						{
							name: 'ErgoptiPlusTests',
							path: targetPath,
							exclude: [brew.path]
						}
					]
				},
				profile
			),
		/target-relative filename/
	);
});
check('inactive-dump-full-and-foreign-target-refusal', () => {
	assert.equal(
		validateSwiftExclusionDump(
			{
				targets: [{ name: 'ErgoptiPlusTests', path: targetPath, exclude: [] }]
			},
			null
		),
		'full'
	);
	assert.throws(() =>
		validateSwiftExclusionDump(
			{
				targets: [
					{
						name: 'ErgoptiPlusTests',
						path: targetPath,
						exclude: [relativeFile]
					}
				]
			},
			null
		)
	);
	assert.throws(() =>
		validateSwiftExclusionDump(
			{
				targets: [
					{
						name: 'ErgoptiPlusTests',
						path: 'Tests/Foreign',
						exclude: [relativeFile]
					}
				]
			},
			profile
		)
	);
});
if (process.argv[2] === '--package-dump') {
	assert.equal(process.argv.length, 4, 'One actual Swift manifest dump is required.');
	const selected = process.env.ERGOPTI_DEV_QUALIFICATION_PROFILE
		? policy.authorizeQualificationProfile(
				process.env.ERGOPTI_DEV_QUALIFICATION_PROFILE,
				policy.environmentContext()
			)
		: null;
	const mode = validateSwiftExclusionDump(
		JSON.parse(fs.readFileSync(process.argv[3], 'utf8')),
		selected
	);
	console.log(
		'SwiftPM target exclusion binding verified: ' + mode + '; native/feature qualified=false.'
	);
}
// These new source-only controls leave all original selector controls in place.
check('source owner admission is exact and disjoint', () => {
	const admitted = admitNativeSdkSelector(workflow);
	assert.notEqual(admitted, null);
	assert.equal(/--filter|--skip|XCTSkip/.test(admitted), false);
});
for (const [name, from, to] of [
	['missing source cohort', SOURCE_STEP_SOURCE, ''],
	['duplicate source cohort', SOURCE_STEP_SOURCE, SOURCE_STEP_SOURCE + SOURCE_STEP_SOURCE],
	['disabled source cohort', 'if: ${{ !cancelled() }}', 'if: false'],
	['source selector prefix expansion', SOURCE_FILTER, "--filter 'ManagedPACSourceTests'"],
	['source context missing candidate', 'begin "$GITHUB_SHA"', 'begin "foreign"'],
	['source context missing attempt', '"$GITHUB_RUN_ATTEMPT"', '"1"'],
	['source pipeline status ignored', '"${source_statuses[0]}"', '"0"'],
	['source capture status ignored', '"${source_statuses[1]}"', '"0"'],
	[
		'source before receipt omitted',
		'"$source_receipt" "$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-verdict.json"',
		'"foreign" "$ERGOPTI_OLLAMA_BUILD_ROOT/native-pac-source-verdict.json"'
	],
	['source profile activated', 'test -z "${ERGOPTI_DEV_QUALIFICATION_PROFILE:-}"', 'true']
])
	check(name, () => {
		assert.ok(SOURCE_STEP_SOURCE.includes(from));
		const changed = workflow.replace(SOURCE_STEP_SOURCE, SOURCE_STEP_SOURCE.replace(from, to));
		assert.equal(admitNativeSdkSelector(changed), null);
	});
check('source cohort must precede PAC receiving', () => {
	assert.equal(
		admitNativeSdkSelector(
			workflow
				.replace(SOURCE_STEP_SOURCE, '')
				.replace(PAC_STEP_SOURCE, PAC_STEP_SOURCE + SOURCE_STEP_SOURCE)
		),
		null
	);
});

// The approved receipt wrapper retains the strict full command and an explicit refusal.
check('raw PAC wrapper and projected full source agree', () => {
	assert.notEqual(admitRawNativeSdkSelector(rawWorkflow), null);
	assert.notEqual(admitNativeSdkSelector(workflow), null);
	const optionalArguments = '${pac_skip_args[@]+"${pac_skip_args[@]}"}';
	assert.equal(rawWorkflow.split(optionalArguments).length, 2);
	const changed = rawWorkflow.replace(optionalArguments, '"${pac_skip_args[@]}"');
	assert.notEqual(changed, rawWorkflow);
	assert.equal(admitRawNativeSdkSelector(changed), null);
});
for (const [name, from, to] of [
	['PAC policy scope', '--scope macos-native-pac --receipt', '--scope macos-native-http --receipt'],
	[
		'PAC receipt validation',
		'--validate-scope-receipt "$receipt"',
		'--validate-scope-receipt "foreign"'
	],
	['PAC receipt generation', '--receipt "$receipt"', '--receipt "foreign"'],
	[
		'PAC deferred status',
		'qualified=false; original command not executed.',
		'qualified=true; command passed.'
	],
	['PAC full disposition', 'elif [ "$mode" = full ]; then', 'elif [ "$mode" = deferred ]; then'],
	[
		'PAC unknown disposition',
		'              exit 1\n          fi',
		'              exit 0\n          fi'
	],
	['PAC original command status', '"${pac_statuses[0]}"', '"0"'],
	['PAC capture command status', '"${pac_statuses[1]}"', '"0"']
])
	check(name, () => {
		assert.ok(PAC_RAW_STEP_SOURCE.includes(from));
		assert.ok(rawWorkflow.includes(PAC_RAW_STEP_SOURCE));
		const changed = rawWorkflow.replace(PAC_RAW_STEP_SOURCE, PAC_RAW_STEP_SOURCE.replace(from, to));
		assert.notEqual(changed, rawWorkflow);
		assert.equal(admitRawNativeSdkSelector(changed), null);
	});

const lease165Job = fullDefault
	.jobsOfText(workflow, '.github/workflows/ci-macos.yml')
	.find((job) => job.id === 'lease165-native');
assert.ok(lease165Job);
assert.notEqual(admitLease165Selector(workflow), null);
let lease165Supplement = 1;
for (const [old, next] of [
	['    steps:', '    continue-on-error: true\n    steps:'],
	['architecture: x86_64', 'architecture: arm64'],
	['          lease_statuses=("${PIPESTATUS[@]}")', '          lease_statuses=(0 0)'],
	[
		"--filter 'KarabinerLeaseWorkerTests|LeaseDiagnosticNextObservationTests'",
		"--filter 'LeaseDiagnosticNextObservationTests'"
	],
	[
		"--filter 'KarabinerLeaseWorkerTests|LeaseDiagnosticNextObservationTests'",
		"--filter 'KarabinerLeaseWorkerTests|LeaseDiagnosticNextObservationTests|Foreign'"
	],
	['    runs-on: ${{ matrix.runner }}', '    runs-on: macos-latest'],
	["github.event_name == 'workflow_dispatch'", "github.event_name == 'push'"],
	["github.event_name == 'workflow_dispatch'", "github.event_name == 'pull_request'"],
	['!inputs.release', 'inputs.release']
]) {
	assert.ok(lease165Job.body.includes(old));
	const changed = workflow.replace(lease165Job.body, lease165Job.body.replace(old, next));
	assert.equal(admitLease165Selector(changed), null);
	assert.ok(sourceProblems(packageSource, changed, caller).includes('no-other-exclusion'));
	lease165Supplement++;
}
assert.equal(
	admitLease165Selector(workflow.replace('  lease165-native:', '  foreign-native:')),
	null
);
lease165Supplement++;
assert.equal(
	admitLease165Selector(
		workflow.replace(lease165Job.body, lease165Job.body + '\n' + lease165Job.body)
	),
	null
);
lease165Supplement++;
assert.ok(
	sourceProblems(packageSource, workflow + '\n# --filter foreign\n', caller).includes(
		'no-other-exclusion'
	)
);
lease165Supplement++;
assert.equal(lease165Supplement, 13);
console.log('PASS: manual lease165 exact-job selector controls=13; native execution unrun.');

assert.equal(passed, 79);
console.log(
	'PASS: Mac qualification deferral source/typed-receipt controls=79; Swift/native execution unqualified.'
);

require('./test-item36-native-qualification.cjs')({
	workflow,
	admitItem36Selector,
	ITEM36_FILTER
});

require('./test-macos-native-pac-qualification.cjs')({
	workflow: rawWorkflow,
	admitNativePacSelector: admitRawNativePacSelector,
	PAC_FILTER
});

// Additive NumberRow source controls have their own census; the old79 stays exact.
let numberRowSelectorChecks = 0;
const numberRowSelectorNames = [];
function numberRowSelectorCheck(name, action) {
	action();
	numberRowSelectorChecks++;
	numberRowSelectorNames.push(name);
}
numberRowSelectorCheck('exact-step-removes-only-its-selector', () => {
	const admitted = admitNativeNumberRowSelector(workflow);
	assert.notEqual(admitted, null);
	assert.equal(admitted, workflow.replace(NUMBER_ROW_FILTER, ''));
});
numberRowSelectorCheck('existing-chain-keeps-full-package-unfiltered', () => {
	assert.notEqual(admitNativeSdkSelector(workflow), null);
	assert.equal(/--filter|--skip|XCTSkip/.test(admitNativeSdkSelector(workflow)), false);
});
for (const [name, owner, from, to] of [
	[
		'missing-cohort',
		'step',
		'      - name: Qualify actual selected number-row Carbon XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          evidence="$RUNNER_TEMP/number-row-source-evidence"\n          mkdir "$evidence"\n          transcript="$evidence/number-row-xctest.log"\n          source="static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"\n          producer="static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"\n          test "$(git rev-parse HEAD)" = "$GITHUB_SHA"\n          git show "$GITHUB_SHA:$source" | cmp - "$source"\n          git show "$GITHUB_SHA:$producer" | cmp - "$producer"\n          cp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          printf \'%s\\n\' "$GITHUB_SHA" > "$evidence/tested-sha.txt"\n          export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"\n          export ERGOPTI_TIS_EVIDENCE_SESSION="$(node -e \'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))\')"\n          set +e\n          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])NumberRowSourceProbeTests([/.]|$)\' 2>&1 | tee "$transcript"\n          number_row_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#number_row_statuses[@]}" -eq 2\n          set +e\n          python3 tools/diagnostics/keyboard_geometry_xctest_receipt.py \\\n            --class NumberRowSourceProbeTests --source "$evidence/NumberRowSourceProbeTests.swift" \\\n            --log "$transcript" --receipt "$evidence/number-row-verdict.json" \\\n            --test-exit "${number_row_statuses[0]}" --capture-exit "${number_row_statuses[1]}"\n          number_row_receipt_status=$?\n          node - "$evidence/number-row-verdict.json" "$ERGOPTI_TIS_EVIDENCE_DIR" "$ERGOPTI_TIS_EVIDENCE_SESSION" <<\'NODE\'\n          const fs = require(\'node:fs\');\n          const transport = require(\'./tools/diagnostics/tis_evidence_transport.cjs\');\n          const receipt = JSON.parse(fs.readFileSync(process.argv[2], \'utf8\'));\n          if (!receipt.passed || receipt.scope !== \'NumberRowSourceProbeTests\' || receipt.expected_count !== 12 || receipt.received_count !== 12) throw new Error(\'exact twelve-case number-row receiving refused\');\n          const session = transport.validate(process.argv[3], process.argv[4]);\n          const expectedSources = {\n            testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations: \'com.apple.keylayout.US\',\n            testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor: \'com.apple.keylayout.French\',\n            testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage: \'com.apple.keylayout.US\',\n            testActualUSCapsMaskChangesAnIndependentLetterExpectation: \'com.apple.keylayout.US\',\n            testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI: \'com.apple.keylayout.French\',\n            testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead: \'com.apple.keylayout.US\',\n            testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject: \'com.apple.keylayout.US\'\n          };\n          const expected = Object.keys(expectedSources).sort();\n          const observed = session.receipts.map((row) => {\n            if (row.test.state !== \'present\' || row.omittedEvents !== 0) throw new Error(\'native diagnostic identity refused\');\n            const match = /^(?:(?:\\w+\\.)?NumberRowSourceProbeTests\\.|-\\[(?:\\w+\\.)?NumberRowSourceProbeTests )(test\\w+)(?:\\])?:(com\\.apple\\.keylayout\\.(?:US|French))$/.exec(row.test.value);\n            if (!match || !Object.hasOwn(expectedSources, match[1]) || match[2] !== expectedSources[match[1]]) throw new Error(\'foreign native method fixture\');\n            const captures = row.events.filter((event) => event.phase === \'original.capture\');\n            if (captures.length !== 1 || captures[0].original?.id?.state !== \'present\' || typeof captures[0].original.id.value !== \'string\' || captures[0].original.id.value.length === 0) throw new Error(\'captured original source unavailable\');\n            const originalID = captures[0].original.id.value;\n            for (const phase of [\'restore.inner.after\', \'restore.outer.after\']) {\n              const events = row.events.filter((event) => event.phase === phase);\n              if (events.length !== 1 || events[0].status !== 0) throw new Error(\'native source restoration refused\');\n              if (events[0].original?.id?.state !== \'present\' || events[0].original.id.value !== originalID || events[0].current?.id?.state !== \'present\' || events[0].current.id.value !== originalID) throw new Error(\'sampled selected source restoration refused\');\n            }\n            return match[1];\n          }).sort();\n          if (!session.complete || JSON.stringify(observed) !== JSON.stringify(expected)) throw new Error(\'exact seven native diagnostic closures refused\');\n          NODE\n          number_row_tis_status=$?\n          set -e\n          cmp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cmp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          test "$number_row_receipt_status" -eq 0\n          test "$number_row_tis_status" -eq 0\n        timeout-minutes: 10\n',
		''
	],
	[
		'duplicate-cohort',
		'step',
		'      - name: Qualify actual selected number-row Carbon XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          evidence="$RUNNER_TEMP/number-row-source-evidence"\n          mkdir "$evidence"\n          transcript="$evidence/number-row-xctest.log"\n          source="static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"\n          producer="static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"\n          test "$(git rev-parse HEAD)" = "$GITHUB_SHA"\n          git show "$GITHUB_SHA:$source" | cmp - "$source"\n          git show "$GITHUB_SHA:$producer" | cmp - "$producer"\n          cp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          printf \'%s\\n\' "$GITHUB_SHA" > "$evidence/tested-sha.txt"\n          export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"\n          export ERGOPTI_TIS_EVIDENCE_SESSION="$(node -e \'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))\')"\n          set +e\n          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])NumberRowSourceProbeTests([/.]|$)\' 2>&1 | tee "$transcript"\n          number_row_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#number_row_statuses[@]}" -eq 2\n          set +e\n          python3 tools/diagnostics/keyboard_geometry_xctest_receipt.py \\\n            --class NumberRowSourceProbeTests --source "$evidence/NumberRowSourceProbeTests.swift" \\\n            --log "$transcript" --receipt "$evidence/number-row-verdict.json" \\\n            --test-exit "${number_row_statuses[0]}" --capture-exit "${number_row_statuses[1]}"\n          number_row_receipt_status=$?\n          node - "$evidence/number-row-verdict.json" "$ERGOPTI_TIS_EVIDENCE_DIR" "$ERGOPTI_TIS_EVIDENCE_SESSION" <<\'NODE\'\n          const fs = require(\'node:fs\');\n          const transport = require(\'./tools/diagnostics/tis_evidence_transport.cjs\');\n          const receipt = JSON.parse(fs.readFileSync(process.argv[2], \'utf8\'));\n          if (!receipt.passed || receipt.scope !== \'NumberRowSourceProbeTests\' || receipt.expected_count !== 12 || receipt.received_count !== 12) throw new Error(\'exact twelve-case number-row receiving refused\');\n          const session = transport.validate(process.argv[3], process.argv[4]);\n          const expectedSources = {\n            testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations: \'com.apple.keylayout.US\',\n            testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor: \'com.apple.keylayout.French\',\n            testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage: \'com.apple.keylayout.US\',\n            testActualUSCapsMaskChangesAnIndependentLetterExpectation: \'com.apple.keylayout.US\',\n            testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI: \'com.apple.keylayout.French\',\n            testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead: \'com.apple.keylayout.US\',\n            testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject: \'com.apple.keylayout.US\'\n          };\n          const expected = Object.keys(expectedSources).sort();\n          const observed = session.receipts.map((row) => {\n            if (row.test.state !== \'present\' || row.omittedEvents !== 0) throw new Error(\'native diagnostic identity refused\');\n            const match = /^(?:(?:\\w+\\.)?NumberRowSourceProbeTests\\.|-\\[(?:\\w+\\.)?NumberRowSourceProbeTests )(test\\w+)(?:\\])?:(com\\.apple\\.keylayout\\.(?:US|French))$/.exec(row.test.value);\n            if (!match || !Object.hasOwn(expectedSources, match[1]) || match[2] !== expectedSources[match[1]]) throw new Error(\'foreign native method fixture\');\n            const captures = row.events.filter((event) => event.phase === \'original.capture\');\n            if (captures.length !== 1 || captures[0].original?.id?.state !== \'present\' || typeof captures[0].original.id.value !== \'string\' || captures[0].original.id.value.length === 0) throw new Error(\'captured original source unavailable\');\n            const originalID = captures[0].original.id.value;\n            for (const phase of [\'restore.inner.after\', \'restore.outer.after\']) {\n              const events = row.events.filter((event) => event.phase === phase);\n              if (events.length !== 1 || events[0].status !== 0) throw new Error(\'native source restoration refused\');\n              if (events[0].original?.id?.state !== \'present\' || events[0].original.id.value !== originalID || events[0].current?.id?.state !== \'present\' || events[0].current.id.value !== originalID) throw new Error(\'sampled selected source restoration refused\');\n            }\n            return match[1];\n          }).sort();\n          if (!session.complete || JSON.stringify(observed) !== JSON.stringify(expected)) throw new Error(\'exact seven native diagnostic closures refused\');\n          NODE\n          number_row_tis_status=$?\n          set -e\n          cmp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cmp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          test "$number_row_receipt_status" -eq 0\n          test "$number_row_tis_status" -eq 0\n        timeout-minutes: 10\n',
		'      - name: Qualify actual selected number-row Carbon XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          evidence="$RUNNER_TEMP/number-row-source-evidence"\n          mkdir "$evidence"\n          transcript="$evidence/number-row-xctest.log"\n          source="static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"\n          producer="static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"\n          test "$(git rev-parse HEAD)" = "$GITHUB_SHA"\n          git show "$GITHUB_SHA:$source" | cmp - "$source"\n          git show "$GITHUB_SHA:$producer" | cmp - "$producer"\n          cp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          printf \'%s\\n\' "$GITHUB_SHA" > "$evidence/tested-sha.txt"\n          export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"\n          export ERGOPTI_TIS_EVIDENCE_SESSION="$(node -e \'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))\')"\n          set +e\n          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])NumberRowSourceProbeTests([/.]|$)\' 2>&1 | tee "$transcript"\n          number_row_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#number_row_statuses[@]}" -eq 2\n          set +e\n          python3 tools/diagnostics/keyboard_geometry_xctest_receipt.py \\\n            --class NumberRowSourceProbeTests --source "$evidence/NumberRowSourceProbeTests.swift" \\\n            --log "$transcript" --receipt "$evidence/number-row-verdict.json" \\\n            --test-exit "${number_row_statuses[0]}" --capture-exit "${number_row_statuses[1]}"\n          number_row_receipt_status=$?\n          node - "$evidence/number-row-verdict.json" "$ERGOPTI_TIS_EVIDENCE_DIR" "$ERGOPTI_TIS_EVIDENCE_SESSION" <<\'NODE\'\n          const fs = require(\'node:fs\');\n          const transport = require(\'./tools/diagnostics/tis_evidence_transport.cjs\');\n          const receipt = JSON.parse(fs.readFileSync(process.argv[2], \'utf8\'));\n          if (!receipt.passed || receipt.scope !== \'NumberRowSourceProbeTests\' || receipt.expected_count !== 12 || receipt.received_count !== 12) throw new Error(\'exact twelve-case number-row receiving refused\');\n          const session = transport.validate(process.argv[3], process.argv[4]);\n          const expectedSources = {\n            testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations: \'com.apple.keylayout.US\',\n            testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor: \'com.apple.keylayout.French\',\n            testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage: \'com.apple.keylayout.US\',\n            testActualUSCapsMaskChangesAnIndependentLetterExpectation: \'com.apple.keylayout.US\',\n            testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI: \'com.apple.keylayout.French\',\n            testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead: \'com.apple.keylayout.US\',\n            testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject: \'com.apple.keylayout.US\'\n          };\n          const expected = Object.keys(expectedSources).sort();\n          const observed = session.receipts.map((row) => {\n            if (row.test.state !== \'present\' || row.omittedEvents !== 0) throw new Error(\'native diagnostic identity refused\');\n            const match = /^(?:(?:\\w+\\.)?NumberRowSourceProbeTests\\.|-\\[(?:\\w+\\.)?NumberRowSourceProbeTests )(test\\w+)(?:\\])?:(com\\.apple\\.keylayout\\.(?:US|French))$/.exec(row.test.value);\n            if (!match || !Object.hasOwn(expectedSources, match[1]) || match[2] !== expectedSources[match[1]]) throw new Error(\'foreign native method fixture\');\n            const captures = row.events.filter((event) => event.phase === \'original.capture\');\n            if (captures.length !== 1 || captures[0].original?.id?.state !== \'present\' || typeof captures[0].original.id.value !== \'string\' || captures[0].original.id.value.length === 0) throw new Error(\'captured original source unavailable\');\n            const originalID = captures[0].original.id.value;\n            for (const phase of [\'restore.inner.after\', \'restore.outer.after\']) {\n              const events = row.events.filter((event) => event.phase === phase);\n              if (events.length !== 1 || events[0].status !== 0) throw new Error(\'native source restoration refused\');\n              if (events[0].original?.id?.state !== \'present\' || events[0].original.id.value !== originalID || events[0].current?.id?.state !== \'present\' || events[0].current.id.value !== originalID) throw new Error(\'sampled selected source restoration refused\');\n            }\n            return match[1];\n          }).sort();\n          if (!session.complete || JSON.stringify(observed) !== JSON.stringify(expected)) throw new Error(\'exact seven native diagnostic closures refused\');\n          NODE\n          number_row_tis_status=$?\n          set -e\n          cmp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cmp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          test "$number_row_receipt_status" -eq 0\n          test "$number_row_tis_status" -eq 0\n        timeout-minutes: 10\n      - name: Qualify actual selected number-row Carbon XCTest controls\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          evidence="$RUNNER_TEMP/number-row-source-evidence"\n          mkdir "$evidence"\n          transcript="$evidence/number-row-xctest.log"\n          source="static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift"\n          producer="static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/NumberRowSourceProbe.swift"\n          test "$(git rev-parse HEAD)" = "$GITHUB_SHA"\n          git show "$GITHUB_SHA:$source" | cmp - "$source"\n          git show "$GITHUB_SHA:$producer" | cmp - "$producer"\n          cp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          printf \'%s\\n\' "$GITHUB_SHA" > "$evidence/tested-sha.txt"\n          export ERGOPTI_TIS_EVIDENCE_DIR="$(mktemp -d "$evidence/tis-session.XXXXXX")"\n          export ERGOPTI_TIS_EVIDENCE_SESSION="$(node -e \'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))\')"\n          set +e\n          script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher \\\n            --scratch-path "$ERGOPTI_OLLAMA_BUILD_ROOT/swift" \\\n            --filter \'(^|[.])NumberRowSourceProbeTests([/.]|$)\' 2>&1 | tee "$transcript"\n          number_row_statuses=("${PIPESTATUS[@]}")\n          set -e\n          test "${#number_row_statuses[@]}" -eq 2\n          set +e\n          python3 tools/diagnostics/keyboard_geometry_xctest_receipt.py \\\n            --class NumberRowSourceProbeTests --source "$evidence/NumberRowSourceProbeTests.swift" \\\n            --log "$transcript" --receipt "$evidence/number-row-verdict.json" \\\n            --test-exit "${number_row_statuses[0]}" --capture-exit "${number_row_statuses[1]}"\n          number_row_receipt_status=$?\n          node - "$evidence/number-row-verdict.json" "$ERGOPTI_TIS_EVIDENCE_DIR" "$ERGOPTI_TIS_EVIDENCE_SESSION" <<\'NODE\'\n          const fs = require(\'node:fs\');\n          const transport = require(\'./tools/diagnostics/tis_evidence_transport.cjs\');\n          const receipt = JSON.parse(fs.readFileSync(process.argv[2], \'utf8\'));\n          if (!receipt.passed || receipt.scope !== \'NumberRowSourceProbeTests\' || receipt.expected_count !== 12 || receipt.received_count !== 12) throw new Error(\'exact twelve-case number-row receiving refused\');\n          const session = transport.validate(process.argv[3], process.argv[4]);\n          const expectedSources = {\n            testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations: \'com.apple.keylayout.US\',\n            testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor: \'com.apple.keylayout.French\',\n            testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage: \'com.apple.keylayout.US\',\n            testActualUSCapsMaskChangesAnIndependentLetterExpectation: \'com.apple.keylayout.US\',\n            testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI: \'com.apple.keylayout.French\',\n            testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead: \'com.apple.keylayout.US\',\n            testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject: \'com.apple.keylayout.US\'\n          };\n          const expected = Object.keys(expectedSources).sort();\n          const observed = session.receipts.map((row) => {\n            if (row.test.state !== \'present\' || row.omittedEvents !== 0) throw new Error(\'native diagnostic identity refused\');\n            const match = /^(?:(?:\\w+\\.)?NumberRowSourceProbeTests\\.|-\\[(?:\\w+\\.)?NumberRowSourceProbeTests )(test\\w+)(?:\\])?:(com\\.apple\\.keylayout\\.(?:US|French))$/.exec(row.test.value);\n            if (!match || !Object.hasOwn(expectedSources, match[1]) || match[2] !== expectedSources[match[1]]) throw new Error(\'foreign native method fixture\');\n            const captures = row.events.filter((event) => event.phase === \'original.capture\');\n            if (captures.length !== 1 || captures[0].original?.id?.state !== \'present\' || typeof captures[0].original.id.value !== \'string\' || captures[0].original.id.value.length === 0) throw new Error(\'captured original source unavailable\');\n            const originalID = captures[0].original.id.value;\n            for (const phase of [\'restore.inner.after\', \'restore.outer.after\']) {\n              const events = row.events.filter((event) => event.phase === phase);\n              if (events.length !== 1 || events[0].status !== 0) throw new Error(\'native source restoration refused\');\n              if (events[0].original?.id?.state !== \'present\' || events[0].original.id.value !== originalID || events[0].current?.id?.state !== \'present\' || events[0].current.id.value !== originalID) throw new Error(\'sampled selected source restoration refused\');\n            }\n            return match[1];\n          }).sort();\n          if (!session.complete || JSON.stringify(observed) !== JSON.stringify(expected)) throw new Error(\'exact seven native diagnostic closures refused\');\n          NODE\n          number_row_tis_status=$?\n          set -e\n          cmp "$source" "$evidence/NumberRowSourceProbeTests.swift"\n          cmp "$producer" "$evidence/NumberRowSourceProbe.swift"\n          test "$number_row_receipt_status" -eq 0\n          test "$number_row_tis_status" -eq 0\n        timeout-minutes: 10\n'
	],
	['foreign-job', 'whole', '  managed-ollama-native:\n', '  foreign-number-row-native:\n'],
	[
		'foreign-step',
		'step',
		'Qualify actual selected number-row Carbon XCTest controls',
		'Qualify foreign NumberRow tests'
	],
	[
		'foreign-selector',
		'step',
		"--filter '(^|[.])NumberRowSourceProbeTests([/.]|$)'",
		"--filter 'NumberRowSourceProbeTests'"
	],
	[
		'duplicate-selector',
		'step',
		"--filter '(^|[.])NumberRowSourceProbeTests([/.]|$)'",
		"--filter '(^|[.])NumberRowSourceProbeTests([/.]|$)' --filter '(^|[.])NumberRowSourceProbeTests([/.]|$)'"
	],
	['missing-judge', 'step', 'keyboard_geometry_xctest_receipt.py', 'missing_receipt.py'],
	['ignored-process-status', 'step', '${number_row_statuses[0]}', '0'],
	['ignored-capture-status', 'step', '${number_row_statuses[1]}', '0'],
	[
		'foreign-source',
		'step',
		'--source "$evidence/NumberRowSourceProbeTests.swift"',
		'--source "$evidence/foreign.swift"'
	],
	[
		'missing-producer-copy',
		'step',
		'cp "$producer" "$evidence/NumberRowSourceProbe.swift"',
		': "$producer"'
	],
	[
		'changed-expected-twelve',
		'step',
		'receipt.expected_count !== 12',
		'receipt.expected_count !== 11'
	],
	[
		'changed-received-twelve',
		'step',
		'receipt.received_count !== 12',
		'receipt.received_count !== 11'
	],
	[
		'foreign-native-method-fixture',
		'step',
		"testActualUSCapsMaskChangesAnIndependentLetterExpectation: 'com.apple.keylayout.US'",
		"testActualUSCapsMaskChangesAnIndependentLetterExpectation: 'com.apple.keylayout.French'"
	],
	['missing-restoration-phases', 'step', "['restore.inner.after', 'restore.outer.after']", '[]'],
	['ignored-sampled-current-source', 'step', 'events[0].current.id.value !== originalID', 'false'],
	['disabled-cohort', 'step', 'if: ${{ !cancelled() }}', 'if: false'],
	[
		'forgiven-cohort',
		'step',
		'        shell: bash\n',
		'        continue-on-error: true\n        shell: bash\n'
	],
	[
		'missing-retention',
		'retention',
		'      - name: Retain selected number-row Carbon XCTest diagnostics\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: number-row-carbon-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}\n          if-no-files-found: error\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n            ${{ runner.temp }}/number-row-source-evidence/number-row-verdict.json\n            ${{ runner.temp }}/number-row-source-evidence/tested-sha.txt\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbe.swift\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbeTests.swift\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/start.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/manifest.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/record-*.dat\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/refusal.json\n',
		''
	],
	[
		'duplicate-retention',
		'retention',
		'      - name: Retain selected number-row Carbon XCTest diagnostics\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: number-row-carbon-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}\n          if-no-files-found: error\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n            ${{ runner.temp }}/number-row-source-evidence/number-row-verdict.json\n            ${{ runner.temp }}/number-row-source-evidence/tested-sha.txt\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbe.swift\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbeTests.swift\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/start.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/manifest.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/record-*.dat\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/refusal.json\n',
		'      - name: Retain selected number-row Carbon XCTest diagnostics\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: number-row-carbon-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}\n          if-no-files-found: error\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n            ${{ runner.temp }}/number-row-source-evidence/number-row-verdict.json\n            ${{ runner.temp }}/number-row-source-evidence/tested-sha.txt\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbe.swift\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbeTests.swift\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/start.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/manifest.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/record-*.dat\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/refusal.json\n      - name: Retain selected number-row Carbon XCTest diagnostics\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: number-row-carbon-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}\n          if-no-files-found: error\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n            ${{ runner.temp }}/number-row-source-evidence/number-row-verdict.json\n            ${{ runner.temp }}/number-row-source-evidence/tested-sha.txt\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbe.swift\n            ${{ runner.temp }}/number-row-source-evidence/NumberRowSourceProbeTests.swift\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/start.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/manifest.json\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/record-*.dat\n            ${{ runner.temp }}/number-row-source-evidence/tis-session.*/refusal.json\n'
	],
	['skipped-retention', 'retention', 'if: always()', 'if: false'],
	[
		'foreign-retention-action',
		'retention',
		'actions/upload-artifact@v4',
		'actions/upload-artifact@v3'
	],
	[
		'missing-raw-retention',
		'retention',
		'            ${{ runner.temp }}/number-row-source-evidence/number-row-xctest.log\n',
		''
	]
]) {
	numberRowSelectorCheck(name, () => {
		const owned =
			owner === 'whole'
				? workflow
				: owner === 'step'
					? NUMBER_ROW_STEP_SOURCE
					: NUMBER_ROW_RETENTION_SOURCE;
		assert.equal(owned.split(from).length, 2, 'one actual NumberRow mutation seam');
		const changed =
			owner === 'whole'
				? workflow.replace(from, () => to)
				: workflow.replace(owned, () => owned.replace(from, () => to));
		assert.notEqual(changed, workflow);
		assert.equal(admitNativeNumberRowSelector(changed), null);
		assert.equal(admitNativeSdkSelector(changed), null);
	});
}
numberRowSelectorCheck('selector-moved-to-full-package-is-refused', () => {
	const packageCommand =
		'script -q /dev/null swift test --package-path static/ergopti_plus/macos/launcher --scratch-path "$RUNNER_TEMP/swift-launcher-ci"';
	assert.equal(workflow.split(packageCommand).length, 2);
	const changed = workflow
		.replace(NUMBER_ROW_FILTER, '')
		.replace(packageCommand, () =>
			packageCommand.replace('swift test', 'swift test ' + NUMBER_ROW_FILTER)
		);
	assert.equal(admitNativeSdkSelector(changed), null);
});
for (const token of ['--filter ForeignTests', '--skip ForeignTests', 'XCTSkip']) {
	numberRowSelectorCheck('foreign-exclusion-remains-refused:' + token, () => {
		assert.ok(
			sourceProblems(packageSource, workflow + '\n# ' + token + '\n', caller).includes(
				'no-other-exclusion'
			)
		);
	});
}
numberRowSelectorCheck('foreign-package-exclusion-remains-refused', () => {
	assert.ok(
		sourceProblems(packageSource + '\n// exclude: []\n', workflow, caller).includes(
			'no-other-exclusion'
		)
	);
});
assert.equal(numberRowSelectorChecks, 30);
assert.equal(new Set(numberRowSelectorNames).size, 30);
console.log(
	JSON.stringify({
		scope: 'NumberRow-exact-selector-source-controls',
		controls: numberRowSelectorChecks,
		names: numberRowSelectorNames,
		native: 'UNRUN'
	})
);
