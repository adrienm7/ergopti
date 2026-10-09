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
const workflow = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-macos.yml'), 'utf8');
const caller = fs.readFileSync(path.join(ROOT, '.github/workflows/ci.yml'), 'utf8');
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
	if (steps.length !== 1 || steps[0][0] !== PAC_STEP_SOURCE || job.split(PAC_FILTER).length !== 2)
		return null;
	const before = job.indexOf(`      - name: ${SDK_STEP_NAME}\n`);
	const after = job.indexOf(
		'      - name: Receive actual independent managed HTTP native clients\n'
	);
	if (before < 0 || before >= steps[0].index || after <= steps[0].index) return null;
	const position = jobs[0].index + steps[0].index + steps[0][0].indexOf(PAC_FILTER);
	return admitItem36Selector(mac.slice(0, position) + mac.slice(position + PAC_FILTER.length));
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
	return mac.slice(0, position) + mac.slice(position + ITEM36_FILTER.length);
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
	requireText(pkg, '.github/ci/dev_release_qualification_exceptions.json', 'canonical-policy');
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
		configuration.version
	])
		if (pkg.includes(value)) errors.push('duplicated-policy');
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
assert.equal(passed, 52);
console.log(
	'PASS: Mac qualification deferral source/typed-receipt controls=52; Swift/native execution unqualified.'
);

require('./test-item36-native-qualification.cjs')({
	workflow,
	admitItem36Selector,
	ITEM36_FILTER
});

require('./test-macos-native-pac-qualification.cjs')({
	workflow,
	admitNativePacSelector,
	PAC_FILTER
});
