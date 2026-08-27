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
 * XCTest could go red, while `macos-ok` still reported success. The aggregate
 * also treated `skipped` as green and repeated dependency names outside `needs`,
 * so adding a job at only one of those sites created another false green.
 * Later, `swift test` began running XCTest followed by an empty swift-testing
 * runner. A dead XCTest process omitted its suite summary, but the second runner
 * supplied exit 0. The workflow therefore needs an independent XCTest verdict.
 *
 * FEATURES & RATIONALE:
 * 1. Requires release compilation and XCTest execution on `macos-*`; an Ubuntu
 *    source grep cannot substitute for Darwin process and signal semantics.
 * 2. Requires `macos-ok` to consume `toJSON(needs)` and accept only `success`,
 *    so every declared dependency is gated and skipped work is never green.
 * 3. Requires the test step to capture line-buffered XCTest output and reject a
 *    missing successful suite summary, even when `swift test` itself exits 0.
 * 4. Floors the dependency count and checks Package.swift's test target, which
 *    prevents a syntactically present but vacuous `swift test` step.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WORKFLOW = fs.readFileSync(path.join(ROOT, '.github', 'workflows', 'ci.yml'), 'utf8');
const PACKAGE = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'launcher', 'Package.swift'),
	'utf8'
);
const SWIFT_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'launcher');
const MAIN_SWIFT = fs.readFileSync(
	path.join(SWIFT_ROOT, 'Sources', 'ErgoptiPlus', 'main.swift'),
	'utf8'
);
const POSIX_SHIM = fs.readFileSync(
	path.join(SWIFT_ROOT, 'Sources', 'CPOSIXCompatibility', 'CPOSIXCompatibility.c'),
	'utf8'
);

function readSwiftTree(directory) {
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const entryPath = path.join(directory, entry.name);
		if (entry.isDirectory()) return readSwiftTree(entryPath);
		return entry.isFile() && entry.name.endsWith('.swift')
			? [fs.readFileSync(entryPath, 'utf8')]
			: [];
	}).join('\n');
}

const SWIFT_SOURCES = readSwiftTree(SWIFT_ROOT);

const failures = [];

function check(condition, message) {
	if (!condition) failures.push(message);
}

function escapeRegExp(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function jobBody(name) {
	const marker = new RegExp(`^  ${escapeRegExp(name)}:\\s*\\r?$`, 'm');
	const match = marker.exec(WORKFLOW);
	if (!match) return '';
	const rest = WORKFLOW.slice(match.index + match[0].length);
	const nextJob = /\r?\n  [A-Za-z0-9][A-Za-z0-9_-]*:\s*(?:\r?\n|$)/.exec(rest);
	return nextJob ? rest.slice(0, nextJob.index) : rest;
}

function stepBody(job, name) {
	const marker = new RegExp(`^      - name:\\s*['\"]?${escapeRegExp(name)}['\"]?\\s*\\r?$`, 'm');
	const match = marker.exec(job);
	if (!match) return '';
	const rest = job.slice(match.index + match[0].length);
	const nextStep = /\r?\n      -\s+/.exec(rest);
	return nextStep ? rest.slice(0, nextStep.index) : rest;
}

function withoutFullLineComments(source) {
	return source.replace(/^\s*#.*$/gm, '');
}

check(WORKFLOW.length > 10000, 'ci.yml is missing or truncated; refusing to inspect an empty workflow');
check(
	(WORKFLOW.match(/^  test-swift-launcher:\s*$/gm) || []).length === 1,
	'ci.yml must define exactly one `test-swift-launcher` job'
);

const swiftJob = withoutFullLineComments(jobBody('test-swift-launcher'));
check(swiftJob.length > 100, '`test-swift-launcher` is absent or empty');
check(/^\s+runs-on:\s*macos-[A-Za-z0-9._-]+\s*$/m.test(swiftJob),
	'`test-swift-launcher` must run on a real macOS runner');
check(!/^\s+continue-on-error:\s*true\s*$/m.test(swiftJob),
	'`test-swift-launcher` must be gating, not continue-on-error');

const plistLintLine = swiftJob.split(/\r?\n/).find((line) =>
	/\brun:\s*plutil\s+-lint\b/.test(line)) || '';
check(plistLintLine.includes(
	'static/ergopti_plus/macos/launcher/com.ergoptiplus.remap-guardian.plist'
), 'the macOS job must plutil-lint the exact bundled guardian LaunchAgent');
check(!plistLintLine.includes('|| true'),
	'the guardian plist lint step must not swallow malformed XML');

const buildLine = swiftJob.split(/\r?\n/).find((line) => /\brun:\s*swift build\b/.test(line)) || '';
check(buildLine.includes('--package-path static/ergopti_plus/macos/launcher'),
	'the Swift build step must compile the packaged launcher directory');
check(/(?:^|\s)(?:-c|--configuration)\s+release(?:\s|$)/.test(buildLine),
	'the Swift build step must compile the release configuration that ships');
check(/(?:^|\s)--product\s+ErgoptiPlus(?:\s|$)/.test(buildLine),
	'the Swift build step must compile the ErgoptiPlus executable product');
check(!buildLine.includes('|| true'), 'the Swift build step must not swallow compilation failure');

const testStep = stepBody(swiftJob, 'Run Swift launcher tests');
check(testStep.length > 100,
	'`Run Swift launcher tests` is absent or too small to enforce a trustworthy XCTest verdict');
check(/script -q \/dev\/null swift test\b/.test(testStep),
	'the Swift test step must use a pseudo-terminal so the last completed XCTest is visible');
check(testStep.includes('--package-path static/ergopti_plus/macos/launcher'),
	'the Swift test step must execute the packaged launcher test target');
check(!testStep.includes('|| true'), 'the Swift test step must not swallow XCTest failure');
check(/set -euo pipefail/.test(testStep),
	'the Swift test step must propagate failures through its log-capture pipeline');
const logVariable = /\b([A-Za-z_][A-Za-z0-9_]*)=["']?\$\(mktemp\)["']?/.exec(testStep)?.[1] || '';
check(logVariable.length > 0,
	'the Swift test step must allocate one transcript file with mktemp');
check(
	logVariable.length > 0 && new RegExp(`\\btee\\s+["']?\\$${escapeRegExp(logVariable)}\\b`).test(testStep),
	'the Swift test step must capture the complete pseudo-terminal transcript'
);
check(
	logVariable.length > 0 && new RegExp(
		`grep\\s+-Fq\\s+["']Test Suite 'All tests' passed["']\\s+["']?\\$${escapeRegExp(logVariable)}\\b`
	).test(testStep),
	'(macos-xctest-summary-required-2026-08-27) the Swift test step must require the successful summary from that transcript'
);
check(/::error::[^\n]*XCTest[^\n]*summary/.test(testStep) && /\bexit 1\b/.test(testStep),
	'(macos-xctest-summary-required-2026-08-27) a missing XCTest summary must fail the job explicitly');
check(
	/\.testTarget\s*\(\s*name:\s*"ErgoptiPlusTests"/s.test(PACKAGE),
	'Package.swift must register the ErgoptiPlusTests target that CI claims to run'
);
check(!/\bDarwin\.flock\s*\(/.test(SWIFT_SOURCES),
	'Swift 6.3 resolves `Darwin.flock(...)` as the struct; use ergoptiFlock instead');
check(!/\b_NSGetEnviron\s*\(/.test(SWIFT_SOURCES),
	'the current macOS SDK does not expose `_NSGetEnviron`; use duplicateProcessEnvironment');
check(!/\bDarwin\.fork\s*\(/.test(SWIFT_SOURCES),
	'Swift 6.3 marks `Darwin.fork()` unavailable; use the posix_spawn test helper');
check(/ergopti_flock_compat\s*\(/.test(SWIFT_SOURCES),
	'the Swift launcher must retain its C ABI flock compatibility shim');
check(/return flock\s*\(descriptor, operation\)/.test(POSIX_SHIM),
	'the C compatibility target must call the real BSD flock function');
check(/"CPOSIXCompatibility"/.test(PACKAGE),
	'Package.swift must link the explicit C POSIX compatibility target');
check(/SWIFT_BACKTRACE:\s*enable=yes/.test(swiftJob),
	'the Swift XCTest job must emit an actionable backtrace after a native crash');
check(/func duplicateProcessEnvironment\s*\(/.test(SWIFT_SOURCES),
	'the Swift launcher must retain its owned posix_spawn environment builder');
check(/let kPOSIXTestHelperFlag\s*=\s*"--posix-test-helper"/.test(SWIFT_SOURCES),
	'the cross-process POSIX tests must retain their debug-only helper role');
check(/func runPOSIXTestHelper\s*\(/.test(SWIFT_SOURCES),
	'the real launcher must implement the cross-process POSIX test helper');
check(!/^let k[A-Za-z0-9_]*\s*(?::[^=]+)?=/m.test(MAIN_SWIFT),
	'shared constants must not live in executable main.swift globals');

const macosGate = withoutFullLineComments(jobBody('macos-ok'));
check(macosGate.length > 100, '`macos-ok` is absent or empty');
check(/\bneeds\s*:[\s\S]*?\btest-swift-launcher\b/.test(macosGate),
	'`macos-ok.needs` must include `test-swift-launcher`');
check(/^\s+if:\s*always\(\)\s*$/m.test(macosGate),
	'`macos-ok` must run under `always()` so it can reject failed, cancelled, or skipped dependencies');
check(/NEEDS:\s*\$\{\{\s*toJSON\(needs\)\s*\}\}/.test(macosGate),
	'`macos-ok` must derive its verdict from `toJSON(needs)`, not a second hardcoded job list');
check(/to_entries\[\]/.test(macosGate),
	'`macos-ok` must iterate every entry in the GitHub `needs` object');
check(/if \[ "\$total" -lt 3 \]/.test(macosGate),
	'`macos-ok` must fail closed if fewer than its three current dependencies are visible');
check(
	/case\s+"\$result"\s+in[\s\S]*?success\)\s*;;[\s\S]*?\*\)\s*failed=1\s*;;[\s\S]*?esac/.test(macosGate),
	'`macos-ok` must accept only success; failure, cancelled, skipped, and unknown results must fail'
);
check(!/failure\|cancelled/.test(macosGate),
	'`macos-ok` must not use the old failure|cancelled allow-list that treated skipped as green');
check(!/passed \(or skipped\)/i.test(macosGate),
	'`macos-ok` must not describe skipped native verification as a passing macOS gate');

if (failures.length > 0) {
	console.error('[FAIL] macOS Swift launcher CI coverage:');
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}

console.log('[OK] macOS CI requires a completed XCTest summary and gates every dependency success-only.');
