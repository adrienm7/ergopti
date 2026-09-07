// tools/build/copy-tracked-tree.cjs

/** Copies current tracked bytes without launching a process for each file. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const [rootArgument, sourceArgument, destinationArgument, ...options] = process.argv.slice(2);
if (!rootArgument || !sourceArgument || !destinationArgument) {
	throw new Error('Expected repository root, source directory, and destination directory');
}
const root = fs.realpathSync(rootArgument);
const source = path.resolve(sourceArgument);
const destination = path.resolve(destinationArgument);

function relativeWithin(parent, child) {
	const relative = path.relative(parent, child);
	if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
		throw new Error(`Copy path is not strictly inside its owner: ${child}`);
	}
	return relative;
}

const relativeSource = relativeWithin(root, source).split(path.sep).join('/');
relativeWithin(root, destination);
if (destination === source || destination.startsWith(source + path.sep)
	|| source.startsWith(destination + path.sep)) {
	throw new Error('Source and destination trees must not overlap');
}
const exclusions = [];
for (let index = 0; index < options.length; index += 2) {
	if (options[index] !== '--exclude' || !options[index + 1]) throw new Error('Invalid exclusion arguments');
	exclusions.push(options[index + 1]);
}
const inventory = execFileSync('git', ['-C', root, 'ls-files', '-z', '--', relativeSource], {
	encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
}).split('\0').filter(Boolean);
const directories = new Set();

function ensureDirectory(directory) {
	if (directories.has(directory)) return;
	if (directory !== root) ensureDirectory(path.dirname(directory));
	if (!fs.existsSync(directory)) fs.mkdirSync(directory);
	const stat = fs.lstatSync(directory);
	if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`Unsafe copy directory: ${directory}`);
	directories.add(directory);
}

let copied = 0;
for (const tracked of inventory) {
	if (!tracked.startsWith(relativeSource + '/')) throw new Error(`Unexpected tracked path: ${tracked}`);
	const relative = tracked.slice(relativeSource.length + 1);
	if (exclusions.some((excluded) => relative === excluded || relative.startsWith(excluded + '/'))) continue;
	const from = path.resolve(root, tracked);
	const to = path.resolve(destination, relative);
	relativeWithin(source, from);
	relativeWithin(destination, to);
	ensureDirectory(path.dirname(to));
	const stat = fs.lstatSync(from);
	if (fs.existsSync(to) || fs.lstatSync(to, { throwIfNoEntry: false })) {
		throw new Error(`Copy destination already exists: ${to}`);
	}
	if (stat.isSymbolicLink()) {
		fs.symlinkSync(fs.readlinkSync(from), to);
		fs.lutimesSync(to, stat.atime, stat.mtime);
	} else if (stat.isFile()) {
		fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL);
		fs.chmodSync(to, stat.mode);
		fs.utimesSync(to, stat.atime, stat.mtime);
	} else {
		throw new Error(`Tracked copy source is not a file or link: ${from}`);
	}
	copied += 1;
}
if (copied === 0) throw new Error(`No tracked files found below ${relativeSource}`);
