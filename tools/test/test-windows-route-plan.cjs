// tools/test/test-windows-route-plan.cjs

/**
 * ==============================================================================
 * MODULE: Windows Route Plan Vector Replay
 * DESCRIPTION:
 * Replays _shared/tests/corpus/network/route_plan_vectors.json through the
 * Windows PowerShell twin (windows/vendor/ergopti_route_plan.ps1), which the
 * Lua, Go and shell twins already answer. PowerShell 7 runs it off Windows;
 * the module keeps Windows PowerShell 5.1 syntax, which the Windows CI lane
 * runs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MODULE = path.join(ROOT, 'static/ergopti_plus/windows/vendor/ergopti_route_plan.ps1');
const VECTORS = path.join(
	ROOT,
	'static/ergopti_plus/_shared/tests/corpus/network/route_plan_vectors.json'
);
const ORIGINS = path.join(ROOT, 'static/ergopti_plus/_shared/modules/network/route_origins.json');

const runtime =
	process.platform === 'win32'
		? path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe')
		: 'pwsh';

// The replay runs in the module's own host and prints one JSON answer per
// vector; the assertions stay here so a silent host cannot pass them.
const REPLAY = `
$ErrorActionPreference = 'Stop'
. $env:ERGOPTI_ROUTE_PLAN_MODULE
$Corpus = Get-Content -LiteralPath $env:ERGOPTI_ROUTE_PLAN_VECTORS -Raw -Encoding UTF8 | ConvertFrom-Json
$Answers = New-Object System.Collections.ArrayList
foreach ($Case in $Corpus.plans) {
	$Plan = New-ErgoptiRoutePlan @($Case.entries)
	if ($Plan.Ok) { [void]$Answers.Add(@{ proxy = $Plan.Proxy; no_proxy = $Plan.NoProxy }) }
	else { [void]$Answers.Add(@{ reason = $Plan.Reason }) }
}
$Settled = New-ErgoptiRoutePlan @($Corpus.redirects.plan)
if (-not $Settled.Ok) { throw 'The redirect plan was refused.' }
$Redirects = New-Object System.Collections.ArrayList
foreach ($Target in $Corpus.redirects.targets) {
	$Answer = Resolve-ErgoptiRoutePlanRedirect $Settled $Target.url
	if ($Answer.Ok) { [void]$Redirects.Add(@{ route = $Answer.Route }) }
	else { [void]$Redirects.Add(@{ reason = $Answer.Reason }) }
}
$Reasons = @($script:ErgoptiRoutePlanEmpty, $script:ErgoptiRoutePlanInvalid,
	$script:ErgoptiRoutePlanConflict, $script:ErgoptiRoutePlanUnplannedHost)
@{ plans = @($Answers); redirects = @($Redirects); reasons = $Reasons } | ConvertTo-Json -Depth 4 -Compress
`;

// -EncodedCommand: a script on stdin makes the host echo terminal controls.
const encoded = Buffer.from(REPLAY, 'utf16le').toString('base64');
const child = spawnSync(runtime, ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], {
	cwd: ROOT,
	env: {
		...process.env,
		ERGOPTI_ROUTE_PLAN_MODULE: MODULE,
		ERGOPTI_ROUTE_PLAN_VECTORS: VECTORS
	},
	encoding: 'utf8',
	windowsHide: true,
	timeout: 60000
});
assert.equal(child.error, undefined, `PowerShell must run: ${child.error?.message}`);
assert.equal(child.status, 0, `the replay failed:\n${child.stdout}\n${child.stderr}`);
const answers = JSON.parse(child.stdout.trim());
const corpus = JSON.parse(fs.readFileSync(VECTORS, 'utf8'));

assert.ok(corpus.plans.length >= 20, 'the plan corpus shrank below its reviewed size');
assert.ok(
	corpus.redirects.targets.length >= 7,
	'the redirect corpus shrank below its reviewed size'
);
assert.equal(answers.plans.length, corpus.plans.length, 'every plan vector has an answer');
assert.equal(
	answers.redirects.length,
	corpus.redirects.targets.length,
	'every redirect vector has an answer'
);
// route_origins.json owns the closed refusal enum the twins answer with.
assert.deepEqual(
	[...answers.reasons].sort(),
	[...JSON.parse(fs.readFileSync(ORIGINS, 'utf8')).refusals].sort(),
	'the module refuses with exactly the reasons of route_origins.json'
);
corpus.plans.forEach((vector, index) => {
	assert.deepEqual(answers.plans[index], vector.expect, `plan: ${vector.name}`);
});
corpus.redirects.targets.forEach((vector, index) => {
	assert.deepEqual(answers.redirects[index], vector.expect, `redirect: ${vector.name}`);
});

console.log(
	`[OK] Windows route plan: ${corpus.plans.length} plan and ${corpus.redirects.targets.length} redirect vectors replayed.`
);
