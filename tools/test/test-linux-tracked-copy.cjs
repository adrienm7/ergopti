// tools/test/test-linux-tracked-copy.cjs

/** Exercises the real bundle copy entry point against a private tracked inventory. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tracked-copy-'));
const subject = fs.readFileSync(path.join(ROOT, 'tools/build/build-linux-driver.sh'), 'utf8');
const start = subject.indexOf('copy_tree() {');
const end = subject.indexOf('\nLINUX_SRC=', start);
assert.ok(start >= 0 && end > start, 'the real copy entry point must exist');

function git(...args) {
	const result = spawnSync('git', ['-C', scratch, ...args], { encoding: 'utf8' });
	assert.equal(result.status, 0, result.stderr);
}

try {
	git('init', '--quiet');
	const names = ['space name.txt', 'caf\u00e9.txt', '-leading.txt'];
	for (let index = 0; index < 120; index++) names.push(`nested/part-${index}.bin`);
	for (const name of [...names, 'corpus/excluded.txt', 'vendor/excluded.txt']) {
		const filename = path.join(scratch, 'source', name);
		fs.mkdirSync(path.dirname(filename), { recursive: true });
		fs.writeFileSync(filename, Buffer.from(`payload\0${name}\n`, 'utf8'));
	}
	git('add', '--', 'source');
	fs.writeFileSync(path.join(scratch, 'source', 'private-cache.json'), 'private runtime data');
	// Copies must use live tracked bytes, including a not-yet-committed edit.
	fs.writeFileSync(path.join(scratch, 'source', names[0]), 'changed working bytes');
	const stamp = new Date('2024-01-02T03:04:05Z');
	fs.utimesSync(path.join(scratch, 'source', names[0]), stamp, stamp);
	fs.chmodSync(path.join(scratch, 'source', names[1]), 0o755);
	const script = 'set -euo pipefail\nREPO_ROOT="$1"\nSCRIPT_DIR="$2"\n'
		+ subject.slice(start, end)
		+ '\ncopy_tree "${REPO_ROOT}/source/" "${REPO_ROOT}/output/" --exclude corpus --exclude vendor\n';
	const began = performance.now();
	const result = spawnSync('bash', ['-x', '-s', '--', scratch.replaceAll('\\', '/'),
		path.join(ROOT, 'tools/build').replaceAll('\\', '/')], {
		input: script, encoding: 'utf8', timeout: 60000,
	});
	const elapsed = performance.now() - began;
	assert.equal(result.status, 0, result.stderr || result.error?.message);
	const actual = fs.readdirSync(path.join(scratch, 'output'), { recursive: true })
		.filter((name) => fs.lstatSync(path.join(scratch, 'output', name)).isFile())
		.map((name) => name.replaceAll('\\', '/')).sort();
	assert.deepEqual(actual, [...names].sort(), 'only tracked, non-excluded files may ship');
	for (const name of names) {
		assert.deepEqual(fs.readFileSync(path.join(scratch, 'output', name)),
			fs.readFileSync(path.join(scratch, 'source', name)), `copy bytes differ: ${name}`);
	}
	assert.equal(fs.statSync(path.join(scratch, 'output', names[0])).mtimeMs, stamp.getTime());
	if (process.platform !== 'win32') {
		assert.equal(fs.statSync(path.join(scratch, 'output', names[1])).mode & 0o777, 0o755);
	}
	const perFileProcesses = (result.stderr.match(/^\++ (?:dirname|mkdir|cp) /gm) || []).length;
	console.log(`tracked copy: ${names.length} files, ${elapsed.toFixed(1)} ms, ${perFileProcesses} per-file shell processes`);
	assert.equal(perFileProcesses, 0, 'tracked-copy-perf: copying must not spawn a process per file');
	const helper = path.join(ROOT, 'tools/build/copy-tracked-tree.cjs');
	const escaped = spawnSync(process.execPath, [helper, scratch, path.dirname(scratch),
		path.join(scratch, 'escaped')], { encoding: 'utf8' });
	assert.notEqual(escaped.status, 0, 'an out-of-repository source must fail');
	assert.match(escaped.stderr, /not strictly inside/);
	assert.equal(fs.existsSync(path.join(scratch, 'escaped')), false);
	const absent = spawnSync(process.execPath, [helper, scratch, path.join(scratch, 'empty'),
		path.join(scratch, 'empty-output')], { encoding: 'utf8' });
	assert.notEqual(absent.status, 0, 'empty inventories must not report a successful copy');
	assert.match(absent.stderr, /No tracked files/);
	if (process.platform !== 'win32') {
		fs.symlinkSync(names[0], path.join(scratch, 'source', 'relative-link'));
		git('add', '--', 'source/relative-link');
		const linked = spawnSync(process.execPath, [helper, scratch, path.join(scratch, 'source'),
			path.join(scratch, 'linked-output'), '--exclude', 'corpus', '--exclude', 'vendor'], { encoding: 'utf8' });
		assert.equal(linked.status, 0, linked.stderr);
		assert.equal(fs.readlinkSync(path.join(scratch, 'linked-output', 'relative-link')), names[0]);
	}
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
