// tools/audit/structure/run-phase2.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Phase 2 Runner
 * DESCRIPTION:
 * Applies the steps of docs/design/structure-plan.md in order, one commit per
 * step, so the day of phase 2 is one mechanical command. Each step:
 *   1. apply-step.cjs <step> --apply, in a fresh process: the tools themselves
 *      name moved paths, so a step may rewrite the rules the next one reads;
 *   2. the mechanical follow-ups no rewrite can do: banner widths
 *      (lint-conventions --fix-banners), the formatter (format.cjs --write),
 *      the generated outputs (npm run gen, then npm run codegen) and the
 *      folder-bounds baseline;
 *   3. the step's gates: the strict format and convention lint, then every
 *      --gate command given, run from the repository root;
 *   4. one commit, `refactor(structure): move <step> into its feature folder`.
 * A step that fails a gate stops the run with the tree as the step left it,
 * staged and uncommitted, for the person reading its receipt.
 *
 * SAFETY:
 * Needs ERGOPTI_STRUCTURE_PHASE=2 (the coordinator's go) and a clean tree:
 * every staged path is one this run wrote. It never pushes.
 *
 * USAGE:
 *   ERGOPTI_STRUCTURE_PHASE=2 node tools/audit/structure/run-phase2.cjs
 *     [--from <step>] [--to <step>] [--gate "<command>"]... [--receipt <file>]
 *     [--no-commit]
 *   <step> is a step key (_shared, core/logger, gestures, …) as --list prints.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync, execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const APPLY = path.join('tools', 'audit', 'structure', 'apply-step.cjs');

/** Runs a command from the repository root; returns its status and output tail. */
function run(cmd, args, options = {}) {
	const started = Date.now();
	const result = spawnSync(cmd, args, {
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 256 * 1024 * 1024,
		shell: options.shell || false,
		env: { ...process.env, ...(options.env || {}) }
	});
	const output = `${result.stdout || ''}${result.stderr || ''}`;
	return {
		command: options.shell ? cmd : [cmd, ...args].join(' '),
		status: result.status === null ? -1 : result.status,
		seconds: Math.round((Date.now() - started) / 100) / 10,
		tail: output.split('\n').slice(-40).join('\n'),
		...(options.full ? { output } : {})
	};
}

function git(...args) {
	return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
}

/** The step keys of today's index, in order. */
function stepKeys() {
	const out = run(process.execPath, [APPLY, '--list']);
	if (out.status !== 0) throw new Error(`apply-step --list failed:\n${out.tail}`);
	return out.tail
		.split('\n')
		.filter(Boolean)
		.map((line) => line.split('\t')[1]);
}

/** Paths changed in the work tree and not staged, plus new untracked files. */
function unstagedPaths() {
	const changed = git('diff', '--name-only', '-z').split('\0').filter(Boolean);
	const added = git('ls-files', '--others', '--exclude-standard', '-z').split('\0').filter(Boolean);
	return { changed, added };
}

function parseArgs(argv) {
	const opts = { gates: [], from: null, to: null, receipt: null, commit: true };
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === '--from') opts.from = argv[++i];
		else if (a === '--to') opts.to = argv[++i];
		else if (a === '--gate') opts.gates.push(argv[++i]);
		else if (a === '--receipt') opts.receipt = argv[++i];
		else if (a === '--no-commit') opts.commit = false;
		else throw new Error(`unknown argument ${a}`);
	}
	return opts;
}

/** The generator scripts an `npm run gen` output reports as failed. */
function failedGenerators(output) {
	// eslint-disable-next-line no-control-regex
	const plain = output.replace(/\x1b\[[0-9;]*m/g, '');
	return [...plain.matchAll(/^\s*FAILED\s+(\S+)/gm)].map((m) => m[1]).sort();
}

/**
 * Runs every registered generator (npm run gen) on the step's tree. One that
 * already failed on the tree before the step (a host it refuses, such as a
 * Node version a qualified projection does not admit) is reported; one the
 * step broke stops it.
 * @param {string[]} before The generators that failed before the step.
 * @param {object} [io] The command, replaced in the runner's test.
 */
function runGenerators(key, receipt, before, io = {}) {
	const gen = io.gen || (() => run('npm', ['run', '--silent', 'gen'], { full: true }));
	const { output, ...result } = gen();
	const failed = failedGenerators(output);
	receipt.actions.push({ label: 'gen', ...result, failed });
	const broken = failed.filter((g) => !before.includes(g));
	if (result.status !== 0 && failed.length === 0)
		throw Object.assign(new Error(`${key}: npm run gen failed:\n${result.tail}`), { receipt });
	if (broken.length > 0)
		throw Object.assign(
			new Error(`${key}: the step broke generator(s) ${broken.join(', ')}:\n${result.tail}`),
			{ receipt }
		);
}

/**
 * Runs the generators on the step's tree and stages what they wrote.
 * Generators whose inputs or outputs moved write their new bytes; a generator
 * that still writes an old path leaves an untracked file. The drift check of
 * a first run compares against HEAD, so a failed first run is repeated on the
 * staged tree, and a run that still fails stops the step.
 * @param {object} [io] The commands, replaced in the runner's test.
 */
function settleCodegen(key, receipt, io = {}) {
	const codegen = io.codegen || (() => run('npm', ['run', '--silent', 'codegen']));
	const unstaged = io.unstaged || unstagedPaths;
	const stage = io.stage || ((paths) => git('add', '--', ...paths));
	const fail = (message) => Object.assign(new Error(`${key}: ${message}`), { receipt });
	const first = codegen();
	receipt.actions.push({ label: 'codegen', ...first });
	const { changed, added } = unstaged();
	if (added.length > 0)
		throw fail(
			`the step left ${added.length} new untracked file(s), e.g. ${added.slice(0, 5).join(', ')}: ` +
				'a generator or a fixture still writes an old path'
		);
	if (changed.length > 0) stage(changed);
	receipt.followUps = changed;
	if (first.status === 0) return;
	const again = codegen();
	receipt.actions.push({ label: 'codegen (after staging)', ...again });
	const left = unstaged();
	if (left.changed.length > 0) stage(left.changed);
	if (again.status !== 0 || left.changed.length > 0 || left.added.length > 0)
		throw fail(`codegen does not settle:\n${again.tail}`);
}

/**
 * Applies one step and its follow-ups, runs its gates and commits it.
 * @returns {object} The step's receipt.
 */
function runStep(key, opts) {
	const receipt = { key, started: new Date().toISOString(), actions: [], gates: [] };
	const action = (label, cmd, args, options) => {
		const r = run(cmd, args, options);
		receipt.actions.push({ label, ...r });
		if (r.status !== 0)
			throw Object.assign(new Error(`${key}: ${label} failed:\n${r.tail}`), { receipt });
		return r;
	};
	// The generators that fail on the tree before the step, by the host alone.
	const baseGen = run('npm', ['run', '--silent', 'gen'], { full: true });
	receipt.baseGenerators = failedGenerators(baseGen.output);
	if (git('status', '--porcelain').trim() !== '')
		throw Object.assign(new Error(`${key}: npm run gen changes the tree before the step`), {
			receipt
		});
	action('apply', process.execPath, [APPLY, key, '--apply'], {
		env: { ERGOPTI_STRUCTURE_PHASE: '2' }
	});
	receipt.summary = receipt.actions[0].tail.split('\n').find((l) => l.startsWith('S')) || '';
	// A rewritten path changes the width of a section title, and the
	// formatter re-wraps what a longer path pushed over the line.
	action('banners', process.execPath, [
		'tools/lint/lint-conventions.js',
		'--fix-banners',
		'--warn-only'
	]);
	action('format', process.execPath, ['tools/lint/format.cjs', '--write']);
	// Every leaf generator, then the domain build with its drift check.
	runGenerators(key, receipt, receipt.baseGenerators);
	settleCodegen(key, receipt);
	// The bounds only fall as the plan lands; a step lowers the ratchet.
	action('folder bounds', process.execPath, [
		'tools/test/test-structure-folder-bounds.cjs',
		'--update-baseline'
	]);
	const after = unstagedPaths();
	if (after.changed.length > 0) git('add', '--', ...after.changed);
	for (const [label, cmd, args] of [
		['format check', process.execPath, ['tools/lint/format.cjs', '--check']],
		[
			'convention lint',
			process.execPath,
			['tools/lint/lint-conventions.js', '--fail-on-violations']
		]
	]) {
		const r = run(cmd, args);
		receipt.gates.push({ label, ...r });
	}
	for (const gate of opts.gates)
		receipt.gates.push({ label: gate, ...run(gate, [], { shell: true }) });
	const red = receipt.gates.filter((g) => g.status !== 0);
	if (red.length > 0)
		throw Object.assign(
			new Error(`${key}: ${red.length} gate(s) red: ${red.map((g) => g.label).join(', ')}`),
			{ receipt }
		);
	if (opts.commit) {
		const message = `refactor(structure): move ${key} into its feature folder\n\n${receipt.summary}`;
		action('commit', 'git', ['commit', '-q', '-m', message]);
		receipt.commit = git('rev-parse', 'HEAD').trim();
	}
	receipt.finished = new Date().toISOString();
	return receipt;
}

function main() {
	const opts = parseArgs(process.argv.slice(2));
	if (process.env.ERGOPTI_STRUCTURE_PHASE !== '2')
		throw new Error(
			"refusing: phase 2 of the structure plan needs ERGOPTI_STRUCTURE_PHASE=2 (the coordinator's go)"
		);
	if (git('status', '--porcelain').trim() !== '')
		throw new Error(
			'refusing: the tree has local changes; every staged path must be one this run wrote'
		);
	const keys = stepKeys();
	const first = opts.from ? keys.indexOf(opts.from) : 0;
	const last = opts.to ? keys.indexOf(opts.to) : keys.length - 1;
	if (first < 0 || last < 0)
		throw new Error(`unknown step: ${opts.from || opts.to}; run apply-step.cjs --list`);
	const receipts = [];
	const save = () => {
		if (opts.receipt) fs.writeFileSync(opts.receipt, JSON.stringify(receipts, null, '\t') + '\n');
	};
	for (const key of keys.slice(first, last + 1)) {
		// Each step is recomputed on the tree its predecessors left.
		if (!stepKeys().includes(key)) {
			receipts.push({ key, skipped: 'no moves left' });
			continue;
		}
		console.log(`[phase2] ${key} …`);
		try {
			const receipt = runStep(key, opts);
			receipts.push(receipt);
			console.log(`[phase2] ${key}: ${receipt.commit || 'applied'} — ${receipt.summary}`);
		} catch (error) {
			receipts.push({ key, error: error.message, ...(error.receipt || {}) });
			save();
			console.error(`[phase2] stopped at ${key}:\n${error.message}`);
			process.exit(1);
		}
		save();
	}
	console.log(`[phase2] ${receipts.length} step(s) done.`);
}

if (require.main === module) main();

module.exports = { parseArgs, settleCodegen, runGenerators, failedGenerators };
