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

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

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
	const result = spawnSync('git', args, {
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	});
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

// Prettier formats one file at a time. The whole-tree check took most of the
// CI formatting job, which every lane waits for, so the tree is split into
// disjoint path groups that separate processes check at once.
const MAX_PRETTIER_WORKERS = 4;
// Directories Prettier never expands into from '.'; skipping them keeps the
// groups equal to what '.' would cover.
const PRETTIER_SKIPPED_DIRECTORIES = new Set(['.git', '.sl', '.svn', '.hg', '.jj', 'node_modules']);
// Relative Prettier time per byte, measured on this tree, for balancing only.
const PRETTIER_BYTE_COST = {
	'.json': 1,
	'.jsonc': 1,
	'.yml': 2,
	'.yaml': 2,
	'.js': 3,
	'.cjs': 3,
	'.mjs': 3,
	'.ts': 3,
	'.md': 5,
	'.css': 8,
	'.html': 8,
	'.svelte': 9
};

/** Sorts names by UTF-16 code units, independent of the locale. */
const byName = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/** Lists one directory's entries Prettier's expansion of '.' would enter. */
function prettierEntries(relative) {
	return fs
		.readdirSync(path.join(ROOT, relative), { withFileTypes: true })
		.filter(
			(entry) =>
				(entry.isFile() || entry.isDirectory()) &&
				!entry.isSymbolicLink() &&
				!PRETTIER_SKIPPED_DIRECTORIES.has(entry.name)
		)
		.map((entry) => ({
			path: relative === '.' ? entry.name : `${relative}/${entry.name}`,
			directory: entry.isDirectory()
		}))
		.sort((a, b) => byName(a.path, b.path));
}

/**
 * Splits the tree into at most `count` groups of paths whose expansions
 * together equal Prettier's expansion of '.'. A directory heavier than a
 * fraction of the work is replaced by its entries, so no single directory
 * becomes one worker's whole load. The work is the cost-weighted size of
 * the tracked files Prettier owns; it only balances groups, never selects files.
 */
function prettierGroups(count) {
	const work = new Map();
	for (const file of git(['ls-files', '-z']).split('\0')) {
		if (!file || !PRETTIER_EXTENSIONS.has(path.extname(file))) continue;
		// A tracked file deleted in the working tree is no work for Prettier.
		const size =
			(fs.statSync(path.join(ROOT, file), { throwIfNoEntry: false })?.size ?? 0) *
			PRETTIER_BYTE_COST[path.extname(file)];
		const parts = file.split('/');
		for (let depth = 1; depth <= parts.length; depth++) {
			const prefix = parts.slice(0, depth).join('/');
			work.set(prefix, (work.get(prefix) ?? 0) + size);
		}
	}
	const total = [...work.keys()]
		.filter((key) => !key.includes('/'))
		.reduce((sum, key) => sum + work.get(key), 0);
	const limit = total / (count * 8);
	const units = [];
	const pending = prettierEntries('.');
	while (pending.length > 0) {
		const entry = pending.shift();
		if (entry.directory && (work.get(entry.path) ?? 0) > limit)
			pending.push(...prettierEntries(entry.path));
		else units.push(entry.path);
	}
	const groups = Array.from({ length: Math.min(count, units.length) }, () => ({
		load: 0,
		units: []
	}));
	const weight = (unit) => work.get(unit) ?? 0;
	const ordered = [...units].sort((a, b) => weight(b) - weight(a) || byName(a, b));
	for (const unit of ordered) {
		const lightest = groups.reduce((best, group) => (group.load < best.load ? group : best));
		lightest.load += weight(unit);
		lightest.units.push(unit);
	}
	return groups.map((group) => group.units.sort(byName));
}

/**
 * Runs Prettier over the whole tree in parallel groups. Output is buffered and
 * printed group by group in a fixed order, so a failure reads the same on
 * every run; the status is non-zero when any group reports a difference.
 */
async function prettierTree(mode) {
	const workers = Math.max(1, Math.min(MAX_PRETTIER_WORKERS, os.availableParallelism()));
	const groups = prettierGroups(workers);
	if (groups.length === 0) throw new Error('found no path for Prettier to check');
	const results = await Promise.all(
		groups.map(
			(units) =>
				new Promise((resolve, reject) => {
					const child = spawn(
						process.execPath,
						[
							PRETTIER_BIN,
							mode,
							'--log-level',
							'warn',
							// Explicit top-level files of other types are skipped, as '.'
							// skips them, and a group whose paths are all ignored is empty.
							'--ignore-unknown',
							'--no-error-on-unmatched-pattern',
							'--',
							...units
						],
						{ cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] }
					);
					const output = [];
					child.stdout.on('data', (chunk) => output.push(['stdout', chunk]));
					child.stderr.on('data', (chunk) => output.push(['stderr', chunk]));
					child.on('error', (error) =>
						reject(new Error(`prettier could not run: ${error.message}`))
					);
					child.on('close', (status, signal) => resolve({ status, signal, output }));
				})
		)
	);
	let failed = false;
	for (const { status, signal, output } of results) {
		for (const [stream, chunk] of output) process[stream].write(chunk);
		if (status !== 0) failed = true;
		if (signal) console.error(`[format] prettier stopped by ${signal}`);
	}
	return failed ? 1 : 0;
}

function ruff(args) {
	requireRuff();
	return run('ruff', args);
}

/** Formats the whole tree, or only checks it. */
async function all(check) {
	const prettierStatus = await prettierTree(check ? '--check' : '--write');
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
	Promise.resolve()
		.then(() => main(process.argv.slice(2)))
		.then(
			(status) => {
				process.exitCode = status;
			},
			(err) => {
				console.error(`[format] ${err.message}`);
				process.exitCode = 1;
			}
		);
}

module.exports = { RUFF_VERSION, PRETTIER_EXTENSIONS, prettierGroups, prettierTree };
