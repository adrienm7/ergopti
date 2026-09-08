// tools/test/test-verify-change-git-paths.cjs

/**
 * ==============================================================================
 * MODULE: Git Change Path Regression Tests
 * DESCRIPTION:
 * Exercises the real Git boundary and gate selection with quoted filenames,
 * deletions and cross-driver renames. One small owned repository serves all
 * scenarios; no driver suite or project Git state is modified.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { changedFiles, parseChangedPaths, selectGates } = require('./verify-change.cjs');

const scratch = path.resolve(__dirname, '../../.rtk');
fs.mkdirSync(scratch, { recursive: true });
const root = fs.mkdtempSync(path.join(scratch, 'verify-git-paths-'));
const macos = 'static/ergopti_plus/macos/';
const names = ['plain.lua', 'with space.lua', 'été.lua'];
if (process.platform !== 'win32') names.push('literal -> arrow.lua', 'tab\tname.lua', 'line\nbreak.lua', 'back\\slash.lua', 'quote"name.lua');
const files = names.map((name) => macos + name);
const failures = [];
let checks = 0;

function git(args, input) {
	return execFileSync('git', args, {
		cwd: root, encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'],
		env: { ...process.env, GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
			GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' },
	});
}

function write(relative, content) {
	const target = path.join(root, relative);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, content);
}

function commit(parent) {
	const tree = git(['write-tree']).trim();
	const revision = git(['commit-tree', tree, ...(parent ? ['-p', parent] : [])], 'Fixture\n').trim();
	git(['update-ref', 'HEAD', revision]);
	return revision;
}

function check(label, range, expected) {
	checks += 1;
	try {
		const actual = changedFiles(range, root);
		assert.deepEqual([...actual].sort(), [...expected].sort(), `${label}: exact paths, without duplicates`);
		for (const file of actual) {
			const gates = selectGates([file]);
			const driver = file.startsWith(macos) ? 'hs' : 'linux';
			assert(gates.has(driver) && gates.has(`${driver}-e2e`), `${label}: missing gates for ${JSON.stringify(file)}`);
		}
		assert(!selectGates(actual).has('ahk-suite'), `${label}: unrelated Windows suite selected`);
	} catch (error) {
		failures.push(`${label}: ${error.message}`);
	}
}

try {
	git(['init', '--quiet']);
	git(['config', 'core.quotePath', 'true']);
	git(['config', 'core.autocrlf', 'false']);
	git(['config', 'diff.renames', 'true']);
	check('empty repository', null, []);
	for (const file of files) write(file, '-- initial fixture\n');
	check('untracked quoted paths', null, files);
	git(['add', '--', ...files]);
	check('staged quoted paths', null, files);
	write(files[0], '-- staged and unstaged fixture\n');
	check('one path changed in both index and worktree', null, files);
	git(['add', '--', files[0]]);
	const initial = commit();
	check('clean committed repository', null, []);
	check('empty commit range', `${initial}..${initial}`, []);
	write(files[1], '-- edited fixture\n');
	fs.unlinkSync(path.join(root, files[2]));
	check('unstaged modification and deletion', null, [files[1], files[2]]);
	git(['add', '--', files[1], files[2]]);
	check('staged modification and deletion', null, [files[1], files[2]]);
	const edited = commit(initial);
	check('committed modification and deletion', `${initial}..${edited}`, [files[1], files[2]]);
	const destination = 'static/ergopti_plus/linux/moved with space.lua';
	fs.mkdirSync(path.dirname(path.join(root, destination)), { recursive: true });
	git(['mv', '--', files[1], destination]);
	check('cross-driver staged rename retains both endpoints', null, [files[1], destination]);
	check('cross-driver range to index retains both endpoints', 'HEAD', [files[1], destination]);
	const renamed = commit(edited);
	check('cross-driver committed rename retains both endpoints', `${edited}..${renamed}`, [files[1], destination]);
	check('clean after rename', null, []);
	assert.throws(() => changedFiles('missing-revision..HEAD', root), /missing-revision/,
		'invalid revision must fail instead of reporting no changes');
	assert.throws(() => changedFiles('HEAD --name-only', root), /HEAD --name-only/,
		'a range is one revision argument, never a shell command or additional options');
} finally {
	assert.equal(path.dirname(root), scratch, 'cleanup must stay inside the owned scratch directory');
	fs.rmSync(root, { recursive: true, force: true });
}

assert.deepEqual(failures, [], 'Git change discovery must preserve every affected driver');

// These bytes are legal Git paths even on hosts unable to create them locally.
const special = `${macos} leading\tline\nback\\slash" -> name.lua `;
assert.deepEqual(parseChangedPaths(`?? ${special}\0`, true), [special]);
assert.deepEqual(parseChangedPaths(`${special}\0`, false), [special]);
assert.deepEqual(parseChangedPaths('?? \nleading.lua\0', true), ['\nleading.lua']);
for (const status of ['R ', ' R', 'C ', ' C']) {
	assert.deepEqual(parseChangedPaths(`${status} destination.lua\0${special}\0`, true), ['destination.lua', special]);
}
assert.deepEqual(parseChangedPaths('same.lua\0same.lua\0', false), ['same.lua']);
for (const [raw, status, diagnostic] of [
	['path.lua', false, /terminal NUL/],
	['\0', false, /empty path/],
	['?? \0', true, /status or path/],
	['not a status\0', true, /status or path/],
	['R  destination.lua\0', true, /original path/],
	[' C destination.lua\0\0', true, /original path/],
]) assert.throws(() => parseChangedPaths(raw, status), diagnostic);
console.log(`verify-change Git paths: ${checks} real-repository scenarios passed.`);
