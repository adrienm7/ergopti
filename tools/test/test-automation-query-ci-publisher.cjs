// tools/test/test-automation-query-ci-publisher.cjs
// Portable provenance controls; SDK compilation/signing/service evidence is CI-only.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const build = fs.readFileSync(path.join(ROOT, 'tools/build/build_macos_app.sh'), 'utf8');
const sign = build.match(/^codesign_native_runtime\(\) \{[\s\S]*?^\}/m)[0];
const copied = sign.indexOf('automation_query_ci_publisher.py" copied');
const nested = sign.indexOf('sign_code --identifier "$BUNDLE_ID.automation-query"');
const seal = sign.indexOf('automation_query_ci_publisher.py" seal');
const outer = sign.indexOf('"$APP_PATH"', seal + 'automation_query_ci_publisher.py" seal'.length);
const outerCall = sign.indexOf(
	'\n\tsign_code \\\n\t\t--identifier "$BUNDLE_ID" \\\n\t\t"$APP_PATH"',
	seal
);
const verify = sign.indexOf('automation_query_ci_publisher.py" verify');
assert(
	copied >= 0 &&
		nested > copied &&
		seal > nested &&
		outer >= seal &&
		outerCall > seal &&
		verify > outerCall,
	'actual build verifies copy, signs nested helper, seals receipt, signs outer app, then verifies unchanged bytes'
);
assert(
	!sign.slice(outerCall, verify).includes('--deep'),
	'outer signing must retain separately signed nested executable'
);
assert(
	build.includes('cp "$launcher_bin" "$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery"'),
	'nested helper comes from same compiler product'
);
const native = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/macos/adapters/apple_shortcuts_native.lua'),
	'utf8'
);
assert(native.includes('"ErgoptiAutomationQuery"'), 'runtime resolves fixed bundle sibling');
assert(
	native.includes('current.token ~= captured_helper.token'),
	'runtime rechecks nested helper before activation'
);
assert(
	native.includes('current_helper.token == captured_helper.token'),
	'runtime rechecks nested helper before data publication'
);
const observer = fs.readFileSync(
	path.join(ROOT, 'tools/diagnostics/program_actions/run_signed_query_probe.py'),
	'utf8'
);
assert(
	observer.includes('app / "Contents/MacOS/ErgoptiAutomationQuery"'),
	'native observer executes the actual nested product'
);
// Replay the shipped signing function with controlled tools. This exercises the
// actual optional branch order, without claiming any macOS codesign execution.
const os = require('node:os');
const { bashExecutable } = require('../lib/git-bash.cjs');
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'query-ci-signing-order-'));
try {
	for (const relative of [
		'launcher/ErgoptiPlus.entitlements',
		'app/Contents/MacOS/ErgoptiPlus',
		'app/Contents/MacOS/ErgoptiAutomationQuery',
		'app/Contents/MacOS/SystemSwitcherState'
	]) {
		fs.mkdirSync(path.dirname(path.join(fixture, relative)), { recursive: true });
		fs.writeFileSync(path.join(fixture, relative), 'controlled product');
	}
	const replay = spawnSync(
		bashExecutable(),
		[
			'-c',
			`
set -e
REPO_ROOT="$1/repo" LAUNCHER_DIR="$1/launcher" APP_PATH="$1/app" BUILD_DIR="$1/build"
BUNDLE_ID=com.ergoptiplus.app
ERGOPTI_AUTOMATION_QUERY_CI_PUBLISH=1
fail() { exit 1; }
python3() { printf 'publisher:%s\n' "$2"; }
sign_code() { for argument in "$@"; do :; done; printf 'sign:%s\n' "$argument"; }
shasum() { printf 'fixedsignedswitcher\n'; }
${sign}
codesign_native_runtime
`,
			'controlled',
			fixture.replaceAll('\\', '/')
		],
		{ encoding: 'utf8', timeout: 10000 }
	);
	assert(
		!replay.error && replay.status === 0,
		replay.stderr || 'actual signing function replay failed'
	);
	const events = replay.stdout.trim().split(/\r?\n/);
	assert(events[0] === 'publisher:copied');
	assert(events[1].endsWith('/Contents/Frameworks/Sparkle.framework'));
	assert(events[2].endsWith('/Contents/MacOS/ErgoptiPlus'));
	assert(events[3].endsWith('/Contents/MacOS/ErgoptiAutomationQuery'));
	assert(events[4].endsWith('/Contents/MacOS/SystemSwitcherState'));
	assert(events[5] === 'publisher:seal');
	assert(events[6].endsWith('/app'));
	assert(events[7] === 'publisher:verify' && events.length === 8);
} finally {
	fs.rmSync(fixture, { recursive: true, force: true });
}
const result = spawnSync(
	process.platform === 'win32' ? 'python' : 'python3',
	[
		'-B',
		'-m',
		'unittest',
		'tools.test.test_automation_query_ci_publisher.PublisherTests',
		'tools.test.test_automation_query_ci_publisher.CompilerCustodyTests'
	],
	{
		cwd: ROOT,
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	}
);
assert(
	!result.error && result.signal === null && result.status === 0,
	result.stderr || 'publisher controls failed'
);
assert(
	/Ran 18 tests in /.test(result.stderr) && /\nOK\s*$/.test(result.stderr),
	'all 18 independent controlled publisher cases execute'
);
console.log(
	'[OK] query CI publisher keeps complete compiler provenance and immutable nested signature; native CI unrun'
);

// SDK diagnostic metadata executes only the existing admitted signed observer.
for (const relative of [
	'tools/diagnostics/program_actions/permission_observation.py',
	'tools/diagnostics/program_actions/test_permission_observation.py'
]) {
	assert(observer.includes('"' + relative + '"'), 'source receipt must enroll ' + relative);
}
const diagnostic = spawnSync(
	process.platform === 'win32' ? 'python' : 'python3',
	['-B', '-m', 'unittest', 'test_permission_observation.PermissionObservationControls', '-v'],
	{
		cwd: path.join(ROOT, 'tools/diagnostics/program_actions'),
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	}
);
assert(
	!diagnostic.error && diagnostic.signal === null && diagnostic.status === 0,
	diagnostic.stderr
);
assert(
	/Ran 10 tests in /.test(diagnostic.stderr) && /\nOK\s*$/.test(diagnostic.stderr),
	'all ten independent SDK metadata controls execute'
);
const enrollment = spawnSync(
	process.platform === 'win32' ? 'python' : 'python3',
	[
		'-B',
		'-m',
		'unittest',
		'tools.test.test_automation_query_ci_publisher.PermissionPublisherEnrollmentTests',
		'-v'
	],
	{
		cwd: ROOT,
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	}
);
assert(
	!enrollment.error && enrollment.signal === null && enrollment.status === 0,
	enrollment.stderr
);
assert(
	/Ran 3 tests in /.test(enrollment.stderr) && /\nOK\s*$/.test(enrollment.stderr),
	'all three additional publisher enrollment controls execute'
);

const admission = spawnSync(
	process.platform === 'win32' ? 'python' : 'python3',
	[
		'-B',
		'-m',
		'unittest',
		'test_permission_observation.PermissionAdmissionControls',
		'test_permission_observation.PermissionMainAdmissionControls',
		'-v'
	],
	{
		cwd: path.join(ROOT, 'tools/diagnostics/program_actions'),
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	}
);
assert(!admission.error && admission.signal === null && admission.status === 0, admission.stderr);
assert(
	/Ran 12 tests in /.test(admission.stderr) && /\nOK\s*$/.test(admission.stderr),
	'all twelve additional decoder and main authentication controls execute'
);
