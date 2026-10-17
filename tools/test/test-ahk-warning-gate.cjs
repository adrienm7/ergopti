// tools/test/test-ahk-warning-gate.cjs

/**
 * MODULE: AHK compiler-warning gate
 * DESCRIPTION:
 * The Windows unit job loads the whole AHK suite with --dry-run and must fail
 * on any load-time warning or error. AutoHotkey with /ErrorStdOut prints
 * "<file> (<line>) : ==> Warning: ..." and "<file> (<line>) : ==> <error>",
 * so a gate matching "^Warning:" silently passed with thousands of warnings.
 * This test replays the gate's own PowerShell classification against both
 * real output shapes and checks the runner keeps the driver's #Warn policy.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const pipeline = require('./ci-full-default.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const step = pipeline.step(pipeline.job('test-ahk'), 'Check for AHK compiler warnings');
const run = pipeline.runOf(step).join('\n');

// The classification must use the real /ErrorStdOut markers and the exit code.
const warningPattern = run.match(
	/\$warnings = @\(\$output \| Where-Object \{ \$_ -match "([^"]+)" \}\)/
);
assert.ok(warningPattern, 'the gate classifies warnings from the captured output');
const errorPattern = run.match(
	/\$errors {3}= @\(\$output \| Where-Object \{ \$_ -match "([^"]+)" -and \$_ -notmatch "([^"]+)" \}\)/
);
assert.ok(errorPattern, 'the gate classifies load errors from the captured output');
assert.match(run, /\$loadExit = \$LASTEXITCODE/, 'the gate reads the loader exit code');
assert.match(run, /if \(\$loadExit -ne 0\) \{ \$errors \+= /, 'a failed load is an error');
assert.match(run, /if \(\$errors\) \{[\s\S]*?exit 1/);
assert.match(run, /if \(\$warnings\) \{[\s\S]*?exit 1/);

const isWarning = (line) => new RegExp(warningPattern[1]).test(line);
const isError = (line) =>
	new RegExp(errorPattern[1]).test(line) && !new RegExp(errorPattern[2]).test(line);
const warning =
	'D:\\a\\ergopti\\static\\ergopti_plus\\windows\\tests\\unit\\test_x.ahk (55) : ==> Warning: This variable appears to never be assigned a value.';
const loadError =
	'D:\\a\\ergopti\\static\\ergopti_plus\\windows\\tests\\run_all.ahk (12) : ==> Missing ")"';
assert.ok(isWarning(warning), 'a real /ErrorStdOut warning line fails the gate');
assert.ok(!isError(warning), 'a warning is not double-counted as an error');
assert.ok(isError(loadError), 'a real /ErrorStdOut load error fails the gate');
assert.ok(!isWarning('ok 1 - Warning: in a test name'), 'ordinary text is not a warning');
assert.ok(!isError('# 1..12 plan line'), 'ordinary text is not an error');

// The runner mirrors the driver's #Warn policy, so the gate sees every other class.
const runner = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/windows/tests/run_all.ahk'),
	'utf8'
);
const driver = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/windows/ErgoptiPlus.ahk'),
	'utf8'
);
const policy = (source) =>
	source
		.match(/^#Warn .*$/gm)
		.filter((line) => line !== '#Warn All' && line !== '#Warn All, StdOut');
assert.deepEqual(
	policy(runner),
	policy(driver),
	'the runner disables exactly the warning classes the driver disables'
);

console.log('AHK compiler-warning gate: OK');
