// tools/test/test-macos-tis-cache-probe.cjs

/**
 * ==============================================================================
 * MODULE: macOS TIS Cache Probe Workflow
 * DESCRIPTION:
 * .github/workflows/probe-macos-tis-cache.yml runs
 * tools/diagnostics/macos_tis_cache_probe.swift, which changes the input source
 * of the runner it runs on, so it must stay a manual probe: dispatched by hand
 * only, read-only token, on the hosted macOS images the refusals were seen on.
 * This test holds the workflow to that, and to the probe itself: every run-loop
 * mode the probe accepts is run, each in its own process, with and without the
 * body the refused cases ran; the evidence is uploaded even when a step fails;
 * and no other workflow runs the probe.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const YAML = require('yaml');
const { REPO_ROOT } = require('../lib/paths.cjs');

const WORKFLOWS = path.join(REPO_ROOT, '.github', 'workflows');
const WORKFLOW = path.join(WORKFLOWS, 'probe-macos-tis-cache.yml');
const PROBE = 'tools/diagnostics/macos_tis_cache_probe.swift';
let checks = 0;

const text = fs.readFileSync(WORKFLOW, 'utf8');
const workflow = YAML.parse(text);
const probe = fs.readFileSync(path.join(REPO_ROOT, PROBE), 'utf8');

// A manual probe: no push, pull request or schedule, and a read-only token.
assert.deepEqual(Object.keys(workflow.on), ['workflow_dispatch']);
assert.deepEqual(workflow.permissions, { contents: 'read' });
assert.equal(workflow.on.workflow_dispatch.inputs.cycles.default, '30');
checks++;

// The hosted images the refusals ran on, each in its own job.
const job = workflow.jobs.probe;
assert.deepEqual(job.strategy.matrix.runner, ['macos-15', 'macos-15-intel', 'macos-26']);
assert.equal(job.strategy['fail-fast'], false);
assert.equal(job['runs-on'], '${{ matrix.runner }}');
checks++;

// The probe is built from the repository, then every mode it accepts runs.
const steps = job.steps;
const build = steps.find((step) => step.name === 'Build the probe');
assert.match(build.run, new RegExp(`swiftc -O -o "\\$RUNNER_TEMP/tis-cache-probe" ${PROBE}$`));
const modes = JSON.parse(/^let MODES = (\[[^\]]+\])$/m.exec(probe)[1]);
assert.deepEqual(modes, ['default', 'tracking', 'nsapp', 'none']);
const run = steps.find(
	(step) => step.name === 'Run each run-loop mode in its own long-lived process'
);
const variants = /for variant in (.+); do/
	.exec(run.run)[1]
	.match(/"[^"]+"/g)
	.map((v) => v.slice(1, -1));
assert.deepEqual(
	[...new Set(variants.map((variant) => variant.split(' ')[0]))].sort(),
	[...modes].sort(),
	'every mode the probe accepts runs'
);
assert(variants.includes('default --body'), 'the refused cases ran a body between the selections');
assert.deepEqual(
	variants.slice(0, 2),
	['default --toggle', 'default --toggle --body'],
	'the fixture-shaped variants run first, while the target is still disabled'
);
assert.match(run.run, /--cycles "\$CYCLES"/);
assert.match(run.run, /macos_text_input_agents\.sh "\$evidence\/text-input-agents\.txt" before/);
assert.match(run.run, /macos_text_input_agents\.sh "\$evidence\/text-input-agents\.txt" after/);
assert.match(run.run, /grep -h '\^SUMMARY ' "\$evidence"\/\*\.jsonl/);
checks++;

// The evidence survives a failed step.
const upload = steps.find((step) => step.uses === 'actions/upload-artifact@v4');
assert.equal(upload.if, 'always()');
assert.equal(upload.with.path, '${{ runner.temp }}/tis-cache-evidence');
assert.equal(upload.with['if-no-files-found'], 'error');
checks++;

// The probe's own contract: what a stale cache means, and that it cleans up.
for (const needle of [
	'TISCopyCurrentKeyboardInputSource',
	'kTISNotifySelectedKeyboardInputSourceChanged',
	'"--read-current"',
	'let stale = systemSelected == true && fresh == id',
	'if !targetWasEnabled && targetEnabledNow && originalCurrent',
	'"AppleCurrentKeyboardLayoutInputSourceID"',
	'case "--toggle": options.toggle = true',
	'print("SUMMARY "'
])
	assert(probe.includes(needle), `the probe holds ${needle}`);
checks++;

// No other workflow runs it: it changes the runner's input source.
for (const file of fs.readdirSync(WORKFLOWS))
	if (file !== path.basename(WORKFLOW))
		assert(
			!fs.readFileSync(path.join(WORKFLOWS, file), 'utf8').includes('macos_tis_cache_probe'),
			`${file} must not run the probe`
		);
checks++;

console.log(
	`[OK] macOS TIS cache probe workflow: ${checks} checks (manual, images, modes, evidence)`
);
