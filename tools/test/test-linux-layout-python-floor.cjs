// tools/test/test-linux-layout-python-floor.cjs

/**
 * The « Installer tests on Python 3.8 » job of linux-layout.yml proves the
 * installers still run on the oldest interpreter Ubuntu 20.04 and Debian 11
 * ship. actions/setup-python has no 3.8 build for Ubuntu 26.04, so once
 * ubuntu-latest moved there the job stopped before any test. The job must name
 * an Ubuntu release that setup-python serves 3.8 for.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const pipeline = require('./ci-pipeline.cjs');

const REL = '.github/workflows/linux-layout.yml';
// actions/python-versions versions-manifest.json, read on 2026-11-14: the
// releases holding the last 3.8 build (3.8.18) for linux x64.
const RELEASES_WITH_PYTHON_38 = new Set(['20.04', '22.04', '24.04']);

/**
 * Problems of the python-floor job in one workflow text.
 * @param {string} text Workflow text.
 * @returns {string[]}
 */
function problems(text) {
	const job = pipeline.jobsOfText(text, REL).find((candidate) => candidate.id === 'python-floor');
	if (!job) return ['no python-floor job'];
	const errors = [];
	if (!/python-version:\s*'3\.8'/.test(job.body)) errors.push('the floor is not Python 3.8');
	const runner = pipeline.field(job.body, 'runs-on');
	const release = /^ubuntu-(\d+\.\d+)$/.exec(runner || '');
	if (!release || !RELEASES_WITH_PYTHON_38.has(release[1]))
		errors.push(`runner ${runner} has no setup-python 3.8 build`);
	return errors;
}

const workflow = fs.readFileSync(path.join(pipeline.ROOT, REL), 'utf8');
assert.deepEqual(problems(workflow), []);
const floating = workflow.replace(/runs-on: ubuntu-24\.04\b/, 'runs-on: ubuntu-latest');
assert.notEqual(floating, workflow, 'the runner mutation changes the workflow');
assert.deepEqual(problems(floating), ['runner ubuntu-latest has no setup-python 3.8 build']);
console.log('[OK] Linux layout Python floor: the 3.8 job names a runner setup-python serves.');
