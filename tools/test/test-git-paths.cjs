// tools/test/test-git-paths.cjs

/**
 * ==============================================================================
 * MODULE: Large Git Path Inventory Regression
 * DESCRIPTION:
 * A real private Git index exceeds the default child-process capture ceiling.
 * The complete path set and its trailing sentinel must survive, including
 * whitespace, Unicode and newline names. Refusals must never return a prefix
 * or leave the helper's temporary capture behind.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { gitPaths } = require('../lib/git-paths.cjs');

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-git-path-regression-'));
const root = path.join(temporary, 'repository');
const captures = path.join(temporary, 'captures');
const env = { ...process.env };

/** Run actual Git against this fixture, never the enclosing repository index. */
function git(args, input) {
	return execFileSync('git', args, {
		cwd: root,
		env,
		input,
		encoding: 'utf8',
		stdio: ['pipe', 'pipe', 'pipe']
	});
}

/** Assert cleanup on every actual success or refusal boundary. */
function inventory(args, directory = root) {
	try {
		return gitPaths(directory, args, { env, temporaryRoot: captures });
	} finally {
		assert.deepEqual(fs.readdirSync(captures), [], 'every private capture must retire');
	}
}

try {
	fs.mkdirSync(root);
	fs.mkdirSync(captures);
	for (const name of execFileSync('git', ['rev-parse', '--local-env-vars'], { encoding: 'utf8' })
		.trim()
		.split(/\r?\n/))
		delete env[name];
	git(['init', '--quiet']);
	assert.deepEqual(inventory(['ls-files', '--cached', '-z']), []);
	const blob = git(['hash-object', '-w', '--stdin'], 'Private immutable fixture blob.\n').trim();
	const names = Array.from(
		{ length: 10000 },
		(_, index) => `files/${String(index).padStart(5, '0')}-${'runtime-path-'.repeat(10)}.lua`
	);
	names.push('names/with space.lua', 'names/été-😀.lua');
	const sentinel = 'zzzz-trailing-sentinel.lua';
	names.push(sentinel);
	git(
		['update-index', '-z', '--index-info'],
		names.map((name) => `100644 ${blob}\t${name}\0`).join('')
	);
	const bytes = Buffer.byteLength(names.join('\0') + '\0');
	assert.ok(bytes > 1024 * 1024, 'the real inventory must exceed the old capture ceiling');
	assert.throws(
		() => git(['ls-files', '--cached', '-z']),
		(error) => error.code === 'ENOBUFS',
		'the original default-buffer reader must fail on these exact real index entries'
	);
	const indexBefore = fs.readFileSync(path.join(root, '.git', 'index'));
	const actual = inventory(['ls-files', '--cached', '-z']);
	assert.equal(actual.length, names.length, 'no path can be dropped or duplicated');
	assert.deepEqual(new Set(actual), new Set(names), 'all exact filenames must survive');
	assert.equal(actual.at(-1), sentinel, 'the path beyond the old limit must be present');
	assert.ok(
		Buffer.byteLength(actual.slice(0, -1).join('\0')) > 1024 * 1024,
		'the sentinel must actually occur after the old ceiling'
	);
	assert.deepEqual(fs.readFileSync(path.join(root, '.git', 'index')), indexBefore);
	console.log(
		`[OK] complete ${actual.length}-path, ${bytes}-byte real inventory; old reader ENOBUFS`
	);
	// Tree objects retain newline names even on hosts whose working filesystem
	// cannot create them. No checkout or platform-specific filename skip is needed.
	const newlineName = 'line\nbreak.lua';
	const tree = git(['mktree', '-z'], `100644 blob ${blob}\t${newlineName}\0`).trim();
	assert.deepEqual(inventory(['ls-tree', '-r', '--name-only', '-z', tree]), [newlineName]);

	const untracked = 'untracked-é with space.txt';
	fs.writeFileSync(path.join(root, untracked), 'Private untracked fixture.\n');
	assert.deepEqual(new Set(inventory(['ls-files', '--cached', '-z'])), new Set(names));
	const combined = inventory([
		'ls-files',
		'-z',
		'--cached',
		'--others',
		'--exclude-standard',
		'--'
	]);
	assert.equal(combined.length, names.length + 1);
	assert.deepEqual(new Set(combined), new Set([...names, untracked]));
	assert.deepEqual(fs.readFileSync(path.join(root, '.git', 'index')), indexBefore);
	assert.throws(() => inventory(['not-a-real-git-path-command', '-z']), /inventory refused/);
	assert.throws(
		() => inventory(['ls-files', '-z'], path.join(temporary, 'missing-repository')),
		/inventory could not run/
	);
	assert.throws(() => inventory(['ls-files']), /NUL-delimited/);
	console.log(
		'[OK] empty, Unicode/space names, newline Git tree, untracked policy, refusal and cleanup'
	);
} finally {
	fs.rmSync(temporary, { recursive: true, force: true });
}
assert.equal(fs.existsSync(temporary), false, 'the private Git fixture must retire');
