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
const { repin, deriveAll, requalificationSection } = require('../audit/structure/repin.cjs');

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
	// An immutable receipt is re-pinned only as a named requalification: each
	// old→new pin with the move that justifies it, for the step's commit body.
	const frame = scratch({ 'w/a.txt': 'a\n', 'frame.json': `{ "w/a.txt": "${sha('a\n')}" }\n` });
	fs.mkdirSync(path.join(frame.root, 'x'));
	frame.git('mv', 'w/a.txt', 'x/a.txt');
	frame.write('x/a.txt', 'a moved\n');
	const records = [];
	repin({
		root: frame.root,
		moves: new Map([['w/a.txt', 'x/a.txt']]),
		derived: [],
		requalify: [{ file: 'frame.json' }],
		requalifications: records
	});
	assert.deepEqual(records, [
		{
			file: 'frame.json',
			from: sha('a\n'),
			to: sha('a moved\n'),
			oldPath: 'w/a.txt',
			newPath: 'x/a.txt'
		}
	]);
	assert.match(
		requalificationSection(records),
		/frame\.json: [0-9a-f]{64} -> [0-9a-f]{64} \(w\/a\.txt -> x\/a\.txt\)/
	);
	assert.equal(requalificationSection([]), '');
	// A pin re-pinned in one round follows its file again when a later round
	// (after a generator) changes the file once more.
	const rounds = scratch({ 'f.txt': 'one\n', 'p.txt': `${sha('one\n')}\n` });
	const history = {};
	rounds.write('f.txt', 'two\n');
	repin({ root: rounds.root, derived: [], history });
	rounds.write('f.txt', 'three\n');
	repin({ root: rounds.root, derived: [], history });
	assert.equal(fs.readFileSync(path.join(rounds.root, 'p.txt'), 'utf8'), `${sha('three\n')}\n`);
	fs.rmSync(rounds.root, { recursive: true, force: true });
	// A requalified pin of a file the step removed names nothing: the step stops.
	const orphan = scratch({ 'gone.txt': 'g\n', 'frame.json': `"${sha('g\n')}"\n` });
	orphan.git('rm', '-q', 'gone.txt');
	assert.throws(
		() => repin({ root: orphan.root, derived: [], requalify: [{ file: 'frame.json' }] }),
		/which the step removed: no file accounts for it/
	);
	fs.rmSync(orphan.root, { recursive: true, force: true });
	assert.throws(
		() =>
			repin({
				root: derivedRepo.root,
				derived: [entry],
				derivedBefore,
				requalify: [{ file: 'holder.txt' }]
			}),
		/requalified, not re-derived/
	);

	// The listed derivations reproduce their pins on the tree as it stands.
	deriveAll({ pinned: true });

	for (const r of [repo, twin, checked, derivedRepo, frame])
		fs.rmSync(r.root, { recursive: true, force: true });
	console.log('[OK] a structure step re-pins every hash of a file it changed, and only those.');
}

run();
