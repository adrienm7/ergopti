// tools/dev/regen-staged.cjs

/**
 * ==============================================================================
 * MODULE: Pre-commit Regeneration
 * DESCRIPTION:
 * Regenerates the committed generated files when a commit stages one of their
 * sources, and stages what changed, so a commit never ships a stale projection.
 * On 2026-11-23 a manifest change reached dev without its parity table and
 * turned the Linux parity check red: only CI saw it.
 *
 * FEATURES & RATIONALE:
 * 1. One list: the generators and their outputs are tools/build/generators.cjs.
 * 2. Only when it matters: nothing runs unless a staged path that is not itself
 *    a generated output lies under a source root (SOURCE_ROOTS).
 * 3. Bounded cost: a generator may name its own `precommitInputs` (the layout
 *    analysis, 13 s, runs only for its sources) or a `precommitSkip` reason
 *    (a host tool a development machine may lack); CI still runs them all.
 * 4. No unrelated edit is committed: an output with unstaged changes is refused
 *    before anything runs, as format.cjs --staged refuses a partly staged file.
 * 5. Fail fast: a failing generator stops the commit with its own output.
 *
 * USAGE:  node tools/dev/regen-staged.cjs
 * ==============================================================================
 */

'use strict';

const path = require('path');
const { execFileSync } = require('child_process');
const { GENERATORS, allOutputs } = require('../build/generators.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

/** Paths whose change can alter a generated file. */
const SOURCE_ROOTS = [
	'static/ergopti_plus/_shared/',
	'static/corpus/',
	'static/img/logo/',
	'tools/codegen/',
	'tools/build/',
	'tools/lib/'
];

/**
 * Runs git and returns its NUL-separated path list.
 * @param {string[]} args Git arguments (with -z).
 * @returns {string[]} Paths.
 */
function gitPaths(args) {
	return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8' }).split('\0').filter(Boolean);
}

function main() {
	const outputs = new Set(allOutputs());
	const sources = gitPaths(['diff', '--cached', '--name-only', '-z', '--diff-filter=ACMRD']).filter(
		(p) => !outputs.has(p) && SOURCE_ROOTS.some((root) => p.startsWith(root))
	);
	if (sources.length === 0) return;

	const unstaged = gitPaths(['diff', '--name-only', '-z']).filter((p) => outputs.has(p));
	if (unstaged.length > 0) {
		console.error(
			'[regen-staged] these generated files have unstaged changes; stage or discard them first:'
		);
		for (const p of unstaged) console.error('  ' + p);
		process.exit(1);
	}

	for (const g of GENERATORS) {
		if (g.precommitSkip) continue;
		if (g.precommitInputs && !sources.some((p) => g.precommitInputs.some((i) => p.startsWith(i))))
			continue;
		try {
			execFileSync('node', [path.join(ROOT, 'tools', g.script)], { cwd: ROOT, stdio: 'pipe' });
		} catch (err) {
			console.error(`[regen-staged] ${g.script} failed:`);
			console.error(String(err.stdout || '') + String(err.stderr || ''));
			process.exit(1);
		}
	}

	const changed = gitPaths(['diff', '--name-only', '-z']).filter((p) => outputs.has(p));
	if (changed.length === 0) return;
	execFileSync('git', ['add', '--', ...changed], { cwd: ROOT });
	console.log('[regen-staged] regenerated and staged:');
	for (const p of changed) console.log('  ' + p);
}

main();
