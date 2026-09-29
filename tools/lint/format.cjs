// tools/lint/format.cjs

/**
 * ==============================================================================
 * MODULE: Repository Formatter
 * DESCRIPTION:
 * The one entry point that formats, or checks the format of, every file a
 * canonical formatter owns: Prettier for JavaScript, Svelte, CSS, HTML, JSON,
 * Markdown and YAML (.prettierrc, .prettierignore), Ruff for Python
 * (pyproject.toml [tool.ruff]). CI runs --check, the pre-commit hook --staged.
 *
 * FEATURES & RATIONALE:
 * 1. One Ruff version: formatting output changes between Ruff releases, so the
 *    pin lives here (--ruff-version prints it for CI) and a different Ruff on
 *    PATH is refused instead of producing a diff CI would reject.
 * 2. Staged files only in the hook: the commit carries the formatted bytes and
 *    no unrelated working-tree file is rewritten. A file with unstaged changes
 *    is refused, since re-staging it would commit those changes too.
 * 3. Ignore files are honoured for explicit paths too (Prettier reads
 *    .prettierignore; Ruff gets --force-exclude), so generated and vendored
 *    files are never formatted.
 *
 * USAGE:  node tools/lint/format.cjs --check | --write | --staged | --ruff-version
 * ==============================================================================
 */

'use strict';

const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');

// Ruff release whose output the repository is formatted with
const RUFF_VERSION = '0.15.8';

// Extensions Prettier formats in this repository
const PRETTIER_EXTENSIONS = new Set([
	'.js',
	'.cjs',
	'.mjs',
	'.ts',
	'.svelte',
	'.css',
	'.html',
	'.json',
	'.jsonc',
	'.md',
	'.yml',
	'.yaml'
]);

const PRETTIER_BIN = path.join(ROOT, 'node_modules', 'prettier', 'bin', 'prettier.cjs');

function run(command, args, options = {}) {
	const result = spawnSync(command, args, { cwd: ROOT, stdio: 'inherit', ...options });
	if (result.error) throw new Error(`${command} could not run: ${result.error.message}`);
	return result.status;
}

function git(args) {
	const result = spawnSync('git', args, { cwd: ROOT, encoding: 'utf8' });
	if (result.error || result.status !== 0) {
		throw new Error(`git ${args.join(' ')} failed: ${(result.stderr || '').trim()}`);
	}
	return result.stdout;
}

/** Fails unless the Ruff on PATH is the pinned release. */
function requireRuff() {
	const probe = spawnSync('ruff', ['--version'], { encoding: 'utf8' });
	if (probe.error) {
		throw new Error(
			`Ruff is not installed. Install the pinned release: pip install ruff==${RUFF_VERSION} (or uv tool install ruff@${RUFF_VERSION}).`
		);
	}
	const found = probe.stdout.trim().split(/\s+/)[1];
	if (found !== RUFF_VERSION) {
		throw new Error(
			`Ruff ${found} is installed, the repository is formatted with Ruff ${RUFF_VERSION}: pip install ruff==${RUFF_VERSION}.`
		);
	}
}

function prettier(args) {
	return run(process.execPath, [PRETTIER_BIN, ...args]);
}

function ruff(args) {
	requireRuff();
	return run('ruff', args);
}

/** Formats the whole tree, or only checks it. */
function all(check) {
	const prettierStatus = prettier([check ? '--check' : '--write', '--log-level', 'warn', '.']);
	const ruffStatus = ruff(check ? ['format', '--check', '.'] : ['format', '.']);
	if (prettierStatus !== 0 || ruffStatus !== 0) {
		console.error(
			check ? 'Formatting differs: run npm run format.' : 'Formatting failed (see above).'
		);
		return 1;
	}
	return 0;
}

/** Formats the staged files the formatters own and stages the result. */
function staged() {
	const listed = git(['diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR', '--'])
		.split('\0')
		.filter(Boolean);
	const pretty = listed.filter((file) => PRETTIER_EXTENSIONS.has(path.extname(file)));
	const python = listed.filter((file) => path.extname(file) === '.py');
	const owned = [...pretty, ...python];
	if (owned.length === 0) return 0;

	const unstaged = new Set(
		git(['diff', '--name-only', '-z', '--', ...owned])
			.split('\0')
			.filter(Boolean)
	);
	const partial = owned.filter((file) => unstaged.has(file));
	if (partial.length > 0) {
		console.error(
			'[format] These staged files also have unstaged changes; formatting them would stage those too:'
		);
		for (const file of partial) console.error(`  ${file}`);
		console.error('[format] Stage or discard the rest of each file, then commit again.');
		return 1;
	}

	if (
		pretty.length > 0 &&
		prettier(['--write', '--log-level', 'warn', '--ignore-unknown', '--', ...pretty]) !== 0
	) {
		return 1;
	}
	if (python.length > 0 && ruff(['format', '--force-exclude', '--quiet', '--', ...python]) !== 0) {
		return 1;
	}
	git(['add', '--', ...owned]);
	return 0;
}

function main(args) {
	switch (args.join(' ')) {
		case '--check':
			return all(true);
		case '--write':
			return all(false);
		case '--staged':
			return staged();
		case '--ruff-version':
			process.stdout.write(`${RUFF_VERSION}\n`);
			return 0;
		default:
			console.error(
				'usage: node tools/lint/format.cjs --check | --write | --staged | --ruff-version'
			);
			return 1;
	}
}

if (require.main === module) {
	try {
		process.exitCode = main(process.argv.slice(2));
	} catch (err) {
		console.error(`[format] ${err.message}`);
		process.exitCode = 1;
	}
}

module.exports = { RUFF_VERSION, PRETTIER_EXTENSIONS };
