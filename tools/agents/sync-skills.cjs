// tools/agents/sync-skills.cjs

/**
 * Keep the cross-agent skill catalogue byte-identical without making a second
 * directory authoritative. `.agents/skills` is canonical; `.claude/skills` is
 * a generated compatibility mirror for clients that do not discover the
 * Agent Skills directory yet.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_ROOT = path.resolve(__dirname, '..', '..');

function fail(message) {
	throw new Error(message);
}

function parseArgs(argv) {
	const command = argv[0];
	if (!['check', 'write', 'bootstrap-from-claude'].includes(command)) {
		fail('usage: node tools/agents/sync-skills.cjs <check|write|bootstrap-from-claude> [--root <repo>]');
	}
	let root = DEFAULT_ROOT;
	for (let index = 1; index < argv.length; index += 1) {
		if (argv[index] !== '--root' || !argv[index + 1]) fail(`unknown or incomplete argument: ${argv[index]}`);
		root = path.resolve(argv[index + 1]);
		index += 1;
	}
	return { command, root };
}

function assertSafeDirectory(root, candidate, label) {
	const relative = path.relative(root, candidate);
	if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
		fail(`${label} must be a child of the repository root`);
	}
}

function listFiles(directory) {
	if (!fs.existsSync(directory)) return [];
	const files = [];
	const visit = (current) => {
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const absolute = path.join(current, entry.name);
			const stat = fs.lstatSync(absolute);
			if (stat.isSymbolicLink()) fail(`skill trees may not contain symlinks: ${absolute}`);
			if (entry.isDirectory()) visit(absolute);
			else if (entry.isFile()) files.push(path.relative(directory, absolute));
			else fail(`unsupported skill-tree entry: ${absolute}`);
		}
	};
	visit(directory);
	return files.sort();
}

function compareTrees(source, target) {
	const sourceFiles = listFiles(source);
	const targetFiles = listFiles(target);
	const sourceSet = new Set(sourceFiles);
	const targetSet = new Set(targetFiles);
	const missing = sourceFiles.filter((file) => !targetSet.has(file));
	const stale = targetFiles.filter((file) => !sourceSet.has(file));
	const changed = sourceFiles.filter((file) =>
		targetSet.has(file) && !fs.readFileSync(path.join(source, file)).equals(fs.readFileSync(path.join(target, file))),
	);
	return { sourceFiles, missing, stale, changed };
}

function removeEmptyDirectories(directory, keepRoot = true) {
	if (!fs.existsSync(directory)) return;
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		if (entry.isDirectory()) removeEmptyDirectories(path.join(directory, entry.name), false);
	}
	if (!keepRoot && fs.readdirSync(directory).length === 0) fs.rmdirSync(directory);
}

function syncTrees(source, target) {
	const sourceFiles = listFiles(source);
	if (sourceFiles.length === 0) fail(`source skill tree is empty: ${source}`);
	fs.mkdirSync(target, { recursive: true });
	const sourceSet = new Set(sourceFiles);
	for (const relative of listFiles(target)) {
		if (!sourceSet.has(relative)) fs.unlinkSync(path.join(target, relative));
	}
	removeEmptyDirectories(target);
	for (const relative of sourceFiles) {
		const destination = path.join(target, relative);
		fs.mkdirSync(path.dirname(destination), { recursive: true });
		fs.copyFileSync(path.join(source, relative), destination);
	}
	return sourceFiles.length;
}

function run(argv) {
	const { command, root } = parseArgs(argv);
	const canonical = path.resolve(root, '.agents', 'skills');
	const mirror = path.resolve(root, '.claude', 'skills');
	assertSafeDirectory(root, canonical, 'canonical skill directory');
	assertSafeDirectory(root, mirror, 'Claude mirror directory');

	if (command === 'bootstrap-from-claude') {
		if (listFiles(canonical).length > 0) fail('bootstrap refused: .agents/skills is already non-empty');
		const copied = syncTrees(mirror, canonical);
		return { command, canonical, mirror, copied };
	}
	if (command === 'write') {
		const copied = syncTrees(canonical, mirror);
		return { command, canonical, mirror, copied };
	}

	const comparison = compareTrees(canonical, mirror);
	if (comparison.sourceFiles.length === 0) fail('canonical skill tree is empty');
	if (comparison.missing.length || comparison.stale.length || comparison.changed.length) {
		fail(`skill mirror drift: ${comparison.missing.length} missing, ${comparison.stale.length} stale, ${comparison.changed.length} changed`);
	}
	return { command, canonical, mirror, files: comparison.sourceFiles.length };
}

if (require.main === module) {
	try {
		console.log(JSON.stringify(run(process.argv.slice(2))));
	} catch (error) {
		console.error(`sync-skills: ${error.message}`);
		process.exit(1);
	}
}

module.exports = { compareTrees, listFiles, parseArgs, run, syncTrees };
