// tools/test/fixtures/linux-install-source.cjs

/** Bind Linux source guards to the actual authored plan and adjacent workflow transport. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const yaml = require('yaml');
const pipeline = require('../ci-pipeline.cjs');
const { loadPlan } = require('../../ci/linux-install-matrix.cjs');

/** Require one genuine producer/consumer before exposing any canonical metadata row. */
function admit(source, plan) {
	const document = yaml.parseDocument(source, { uniqueKeys: true });
	assert.deepEqual(document.errors, [], 'Linux install source must have unique valid YAML keys');
	const workflow = document.toJS();
	const jobs = pipeline.jobsOfText(source, '.github/workflows/ci-linux.yml');
	const bodies = (id) => {
		const found = jobs.filter((job) => job.id === id);
		assert.equal(found.length, 1, 'Linux install source has exactly one ' + id);
		return found[0].body;
	};
	const buildBody = bodies('package-linux');
	const job = bodies('install-linux');
	const build = workflow.jobs['package-linux'];
	const install = workflow.jobs['install-linux'];
	assert.equal(build['continue-on-error'], undefined);
	assert.equal(install['continue-on-error'], undefined);
	assert.deepEqual(build.needs, ['e2e-linux']);
	assert.deepEqual(install.needs, ['package-linux']);
	assert.equal(build.outputs.install_matrix, '${{ steps.install-plan.outputs.matrix }}');
	assert.equal(build.outputs.install_metadata, '${{ steps.install-plan.outputs.metadata }}');
	const producers = build.steps.filter((step) => step.id === 'install-plan');
	assert.equal(producers.length, 1, 'The install plan producer must be unique');
	assert.deepEqual(producers[0], {
		name: 'Plan every authored installation lot',
		id: 'install-plan',
		run: 'node tools/ci/linux-install-matrix.cjs'
	});
	const writer = pipeline.step(buildBody, producers[0].name);
	assert.equal(build.steps.filter((value) => value.uses === 'actions/checkout@v4').length, 1);
	assert.ok(buildBody.indexOf('uses: actions/checkout@v4') < buildBody.indexOf(writer));
	assert.equal(install['runs-on'], 'ubuntu-latest');
	assert.equal(install.strategy['fail-fast'], false);
	assert.equal(
		install.strategy.matrix,
		'${{ fromJSON(needs.package-linux.outputs.install_matrix) }}'
	);
	assert.equal(
		install.container,
		'${{ fromJSON(needs.package-linux.outputs.install_metadata)[matrix.lot].container }}'
	);
	assert.deepEqual(
		install.env,
		Object.fromEntries(
			['id', 'kind', 'distro', 'image', 'prep', 'known'].map((field) => [
				'INSTALL_' + field.toUpperCase(),
				'${{ fromJSON(needs.package-linux.outputs.install_metadata)[matrix.lot].' + field + ' }}'
			])
		)
	);
	const step = (name) => {
		const found = install.steps.filter((value) => value.name === name);
		assert.equal(found.length, 1, 'Linux installation step must be unique: ' + name);
		return found[0];
	};
	const admission = step('Require a declared installation lot');
	assert.equal(install.steps[0], admission);
	assert.deepEqual(admission, {
		name: 'Require a declared installation lot',
		shell: 'sh',
		run: 'set -eu\ntest -n "$INSTALL_ID"\ncase "$INSTALL_KIND" in\n  install|first|deb|rpm|appimage) ;;\n  *) exit 1 ;;\nesac\n'
	});
	assert.deepEqual(step('Prepare the container'), {
		name: 'Prepare the container',
		if: "env.INSTALL_KIND == 'install'",
		shell: 'sh',
		run: '${{ env.INSTALL_PREP }}'
	});
	const first = step('Install on ${{ env.INSTALL_IMAGE }} and verify the first run');
	assert.deepEqual(
		Object.keys(first).sort(),
		['name', 'if', 'timeout-minutes', 'shell', 'env', 'run'].sort()
	);
	assert.equal(first.if, "env.INSTALL_KIND == 'first'");
	assert.equal(first['timeout-minutes'], 25);
	assert.equal(first.shell, 'bash');
	assert.deepEqual(first.env, { ERGOPTI_E2E_PREP: "${{ env.INSTALL_PREP || '' }}" });
	assert.equal(
		first.run,
		[
			'set -euo pipefail',
			'export ERGOPTI_E2E_DOCKER_ARGS="-e ERGOPTI_E2E_PREP -e ERGOPTI_E2E_KNOWN_LIMITATIONS=${{ env.INSTALL_KNOWN || \'\' }}"',
			"bash static/ergopti_plus/linux/tests/distro/run_in_docker.sh '${{ env.INSTALL_IMAGE }}' \\",
			'  | tee "$RUNNER_TEMP/first-install.log"',
			''
		].join('\n')
	);
	assert.deepEqual(Object.keys(plan).sort(), ['matrix', 'metadata']);
	assert.deepEqual(plan.matrix, { lot: Object.keys(plan.metadata) });
	return { job, plan, firstScript: first.run.trimEnd() };
}

/** Read through the production canonical loader; a detached metadata file is not sufficient. */
function read(
	root,
	source = require('../ci-pipeline.cjs').inlineLaneAt(root, '.github/workflows/ci-linux.yml')
) {
	return admit(source, loadPlan(root));
}

/** Select one mandatory subject by its stable ID rather than its human display title. */
function row(plan, id) {
	const matches = Object.values(plan.metadata).filter((cell) => cell.id === id);
	assert.equal(matches.length, 1, 'Expected exactly one canonical Linux row: ' + id);
	return matches[0];
}

module.exports = { admit, read, row };
