// tools/deploy/fix-ahk-encoding.cjs

/**
 * Add the UTF-8 BOM and normalize line endings to LF for explicitly selected
 * AHK files. The pre-commit hook uses --staged so unrelated working-tree files
 * are never scanned or rewritten.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const BOM = Buffer.from([0xef, 0xbb, 0xbf]);
const DEFAULT_ROOT = path.resolve(__dirname, '..', '..');

function fail(message) {
	throw new Error(message);
}

function git(root, args) {
	const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
	if (result.error || result.status !== 0) {
		const diagnostic = result.stderr || result.stdout || result.error?.message || 'unknown error';
		fail(`git ${args.join(' ')} failed: ${diagnostic.trim()}`);
	}
	return result.stdout;
}

function samePath(left, right) {
	const normalize = (value) => {
		const resolved = path.resolve(value);
		return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
	};
	return normalize(left) === normalize(right);
}

function repositoryRoot(candidate) {
	const root = git(candidate, ['rev-parse', '--show-toplevel']).trim();
	if (!samePath(root, candidate)) fail(`--root must name a repository root: ${root}`);
	return path.resolve(root);
}

function parseArgs(argv) {
	const options = { root: DEFAULT_ROOT, staged: false, files: [] };
	for (let index = 0; index < argv.length; index += 1) {
		const argument = argv[index];
		if (argument === '--root') {
			if (!argv[index + 1]) fail('--root requires a path');
			options.root = path.resolve(argv[index + 1]);
			index += 1;
		} else if (argument === '--staged') {
			options.staged = true;
		} else if (argument === '--') {
			options.files.push(...argv.slice(index + 1));
			break;
		} else if (argument.startsWith('--')) {
			fail(`unknown option: ${argument}`);
		} else {
			options.files.push(argument);
		}
	}
	if (options.staged && options.files.length > 0) {
		fail('--staged cannot be combined with explicit files');
	}
	if (!options.staged && options.files.length === 0) {
		fail('usage: fix-ahk-encoding.cjs --staged [--root <repo>] | -- <file.ahk> [...]');
	}
	return options;
}

function stagedAhkPaths(root) {
	const output = git(root, ['diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR', '--']);
	return output.split('\0').filter((file) => file && file.toLowerCase().endsWith('.ahk'));
}

function resolveSafeAhkFile(root, candidate) {
	const absolute = path.resolve(root, candidate);
	const relative = path.relative(root, absolute);
	if (
		!relative ||
		relative === '..' ||
		relative.startsWith(`..${path.sep}`) ||
		path.isAbsolute(relative)
	) {
		fail(`AHK path must stay inside the repository: ${candidate}`);
	}
	if (path.extname(relative).toLowerCase() !== '.ahk') fail(`not an AHK file: ${candidate}`);
	let stat;
	try {
		stat = fs.lstatSync(absolute);
	} catch (error) {
		fail(`cannot inspect ${candidate}: ${error.message}`);
	}
	if (stat.isSymbolicLink() || !stat.isFile())
		fail(`AHK path must be a regular file: ${candidate}`);
	return { absolute, relative: relative.replace(/\\/g, '/') };
}

function assertNoUnstagedChanges(root, files) {
	const partiallyStaged = files.filter((file) => {
		const result = spawnSync('git', ['diff', '--quiet', '--', file.relative], {
			cwd: root,
			encoding: 'utf8'
		});
		if (result.error || (result.status !== 0 && result.status !== 1)) {
			const diagnostic = result.stderr || result.stdout || result.error?.message || 'unknown error';
			fail(`cannot inspect unstaged changes for ${file.relative}: ${diagnostic.trim()}`);
		}
		return result.status === 1;
	});
	if (partiallyStaged.length > 0) {
		fail(
			'refusing to rewrite partially staged AHK file(s); stage the remaining changes or ' +
				`unstage the file before retrying: ${partiallyStaged.map((file) => file.relative).join(', ')}`
		);
	}
}

function fixFile(file) {
	const original = fs.readFileSync(file.absolute);
	const hasBom =
		original.length >= BOM.length &&
		original[0] === BOM[0] &&
		original[1] === BOM[1] &&
		original[2] === BOM[2];
	const content = (hasBom ? original.subarray(BOM.length) : original).toString('binary');
	const normalized = content.replace(/\r\n?/g, '\n');
	const fixedBom = !hasBom;
	const fixedLf = normalized !== content;
	if (fixedBom || fixedLf) {
		fs.writeFileSync(file.absolute, Buffer.concat([BOM, Buffer.from(normalized, 'binary')]));
	}
	return { ...file, fixedBom, fixedLf, changed: fixedBom || fixedLf };
}

function stageFiles(root, files) {
	for (let index = 0; index < files.length; index += 100) {
		git(root, ['add', '--', ...files.slice(index, index + 100).map((file) => file.relative)]);
	}
}

function run(argv) {
	const options = parseArgs(argv);
	const root = repositoryRoot(options.root);
	const candidates = options.staged ? stagedAhkPaths(root) : options.files;
	const unique = [...new Set(candidates)];
	const files = unique.map((candidate) => resolveSafeAhkFile(root, candidate));
	if (options.staged) assertNoUnstagedChanges(root, files);
	const results = files.map(fixFile);

	if (options.staged && files.length > 0) stageFiles(root, files);
	for (const result of results.filter((item) => item.changed)) {
		const tags = [];
		if (result.fixedBom) tags.push('BOM added');
		if (result.fixedLf) tags.push('LF normalized');
		console.log(`  FIXED [${tags.join(', ')}]: ${result.relative}`);
	}
	if (files.length > 0) {
		const fixedBom = results.filter((item) => item.fixedBom).length;
		const fixedLf = results.filter((item) => item.fixedLf).length;
		const alreadyOk = results.filter((item) => !item.changed).length;
		console.log(
			`Done. ${fixedBom} file(s) got BOM, ${fixedLf} file(s) got LF normalization, ${alreadyOk} already OK.`
		);
	}
	return { selected: files.length, results };
}

if (require.main === module) {
	try {
		run(process.argv.slice(2));
	} catch (error) {
		console.error(`fix-ahk-encoding: ${error.message}`);
		process.exit(1);
	}
}

module.exports = {
	assertNoUnstagedChanges,
	fixFile,
	parseArgs,
	resolveSafeAhkFile,
	run,
	stagedAhkPaths
};
