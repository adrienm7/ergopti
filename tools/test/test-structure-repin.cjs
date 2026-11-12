// tools/test/test-structure-repin.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Content Pins
 * DESCRIPTION:
 * About a hundred SHA-256 pins across eighteen files pin files that the first
 * structure step moves or rewrites: behavior owner reviews, generated-source
 * hashes, vendor digests, the Windows cohort input manifests and the receipts
 * that pin those. The first application of S01 left all of them stale, and
 * the feature inventory generator refused the step. repin.cjs re-pins each
 * value that equals a changed file's pre-step hash, follows the step's own
 * moves, settles chains of pins, refuses an ambiguous hash and leaves
 * history alone. This exercises it on a scratch repository.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { repin, deriveAll } = require('../audit/structure/repin.cjs');

const sha = (text) => crypto.createHash('sha256').update(text).digest('hex');

/** A scratch repository holding `files`, committed. */
function scratch(files) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-repin-'));
	const git = (...args) =>
		execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: root });
	git('init', '-q');
	for (const [file, text] of Object.entries(files)) {
		fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
		fs.writeFileSync(path.join(root, file), text);
	}
	git('add', '-A');
	git('commit', '-q', '-m', 'base');
	return { root, git, write: (f, t) => fs.writeFileSync(path.join(root, f), t) };
}

function run() {
	const pins = (a, b) => `{ "a": "${a}", "b": "${b}" }\n`;
	const repo = scratch({
		'a.txt': 'alpha\n',
		'b.txt': 'beta\n',
		'pins.json': pins(sha('alpha\n'), sha('beta\n')),
		'docs/audits/receipt.md': `a was ${sha('alpha\n')}\n`
	});
	repo.write(
		'chain.txt',
		`pins.json is ${sha(fs.readFileSync(path.join(repo.root, 'pins.json')))}\n`
	);
	repo.git('add', 'chain.txt');
	repo.git('commit', '-q', '-m', 'chain');

	// The step rewrites a.txt and moves b.txt with a rewrite.
	repo.write('a.txt', 'alpha moved\n');
	fs.mkdirSync(path.join(repo.root, 'c'));
	repo.git('mv', 'b.txt', 'c/b.txt');
	repo.write('c/b.txt', 'beta moved\n');
	const edits = repin({ root: repo.root, moves: new Map([['b.txt', 'c/b.txt']]), derived: [] });
	const read = (f) => fs.readFileSync(path.join(repo.root, f), 'utf8');
	assert.equal(read('pins.json'), pins(sha('alpha moved\n'), sha('beta moved\n')));
	assert.equal(
		read('chain.txt'),
		`pins.json is ${sha(read('pins.json'))}\n`,
		'a pin of a re-pinned file follows'
	);
	assert.equal(
		read('docs/audits/receipt.md'),
		`a was ${sha('alpha\n')}\n`,
		'history keeps its hashes'
	);
	assert.deepEqual(edits.map((e) => e.file).sort(), ['chain.txt', 'pins.json']);
	assert.deepEqual(
		repin({ root: repo.root, moves: new Map([['b.txt', 'c/b.txt']]), derived: [] }),
		[],
		'settled'
	);

	// Two files equal before the step and different after it: a pin of their
	// hash names neither, and the step stops.
	const twin = scratch({ 'x.txt': 'same\n', 'y.txt': 'same\n', 'p.txt': `${sha('same\n')}\n` });
	twin.write('x.txt', 'one\n');
	twin.write('y.txt', 'two\n');
	assert.throws(
		() => repin({ root: twin.root, derived: [] }),
		/p\.txt pins .* shared by files the step made different/
	);

	// --check mode rewrites nothing.
	const checked = scratch({ 'a.txt': 'alpha\n', 'p.txt': `${sha('alpha\n')}\n` });
	checked.write('a.txt', 'changed\n');
	assert.equal(repin({ root: checked.root, write: false, derived: [] }).length, 1);
	assert.equal(fs.readFileSync(path.join(checked.root, 'p.txt'), 'utf8'), `${sha('alpha\n')}\n`);

	// A derived pin follows its source, each value computed by the tree it
	// measures; a derivation that no longer reproduces its pin stops the step.
	const upper = (text) => sha(text.toUpperCase());
	const derivedRepo = scratch({ 'src.txt': 'beta\n', 'holder.txt': `${upper('beta\n')}\n` });
	const entry = { file: 'holder.txt', source: 'src.txt', derive: (source) => upper(source) };
	const derivedBefore = deriveAll({ root: derivedRepo.root, entries: [entry], pinned: true });
	derivedRepo.write('src.txt', 'gamma\n');
	repin({ root: derivedRepo.root, derived: [entry], derivedBefore });
	assert.equal(
		fs.readFileSync(path.join(derivedRepo.root, 'holder.txt'), 'utf8'),
		`${upper('gamma\n')}\n`
	);
	assert.throws(
		() => deriveAll({ root: derivedRepo.root, entries: [{ ...entry, derive: sha }], pinned: true }),
		/no longer reproduces its pin/
	);
	// The listed derivations reproduce their pins on the tree as it stands.
	deriveAll({ pinned: true });

	for (const r of [repo, twin, checked, derivedRepo])
		fs.rmSync(r.root, { recursive: true, force: true });
	console.log('[OK] a structure step re-pins every hash of a file it changed, and only those.');
}

run();
