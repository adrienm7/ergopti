// tools/test/test-agent-skills-sync.cjs

/**
 * Behavioral coverage for the portable Agent Skills mirror. The test exercises
 * the real CLI in an isolated repository-shaped directory so a green result
 * proves bootstrap, drift detection, stale-file cleanup, and regeneration.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(ROOT, 'tools', 'agents', 'sync-skills.cjs');
const { compareTrees } = require(SCRIPT);
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-agent-skills-'));

function write(relative, content) {
	const absolute = path.join(temporaryRoot, relative);
	fs.mkdirSync(path.dirname(absolute), { recursive: true });
	fs.writeFileSync(absolute, content, 'utf8');
}

function run(command) {
	return spawnSync(process.execPath, [SCRIPT, command, '--root', temporaryRoot], {
		encoding: 'utf8',
	});
}

try {
	const repositoryMirror = compareTrees(path.join(ROOT, '.agents', 'skills'), path.join(ROOT, '.claude', 'skills'));
	assert.equal(repositoryMirror.sourceFiles.length > 0, true, 'the canonical repository skill tree must not be empty');
	assert.deepEqual(repositoryMirror.missing, [], 'the repository Claude mirror is missing canonical skill files');
	assert.deepEqual(repositoryMirror.stale, [], 'the repository Claude mirror contains stale files');
	assert.deepEqual(repositoryMirror.changed, [], 'the repository Claude mirror contains hand-edited copies');

	write('.claude/skills/example/SKILL.md', 'legacy\n');
	let result = run('bootstrap-from-claude');
	assert.equal(result.status, 0, result.stderr);
	assert.equal(fs.readFileSync(path.join(temporaryRoot, '.agents/skills/example/SKILL.md'), 'utf8'), 'legacy\n');

	write('.agents/skills/example/SKILL.md', 'canonical\n');
	write('.agents/skills/example/references/detail.md', 'detail\n');
	write('.claude/skills/stale/SKILL.md', 'stale\n');
	result = run('check');
	assert.notEqual(result.status, 0, 'check must detect a changed and stale mirror');

	result = run('write');
	assert.equal(result.status, 0, result.stderr);
	assert.equal(fs.existsSync(path.join(temporaryRoot, '.claude/skills/stale/SKILL.md')), false);
	assert.equal(fs.readFileSync(path.join(temporaryRoot, '.claude/skills/example/SKILL.md'), 'utf8'), 'canonical\n');
	assert.equal(fs.readFileSync(path.join(temporaryRoot, '.claude/skills/example/references/detail.md'), 'utf8'), 'detail\n');

	result = run('check');
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /"files":2/);

	result = run('bootstrap-from-claude');
	assert.notEqual(result.status, 0, 'bootstrap must never overwrite a non-empty canonical tree');
	console.log('agent skill mirror: ok');
} finally {
	fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
