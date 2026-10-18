// tools/build/check-elf-glibc-ceiling.cjs

/**
 * ==============================================================================
 * MODULE: ELF glibc Ceiling Check
 * DESCRIPTION:
 * Refuses a Linux package whose bundled ELF files need a GLIBC_ symbol version
 * newer than the oldest supported Ubuntu LTS provides.
 *
 * FEATURES & RATIONALE:
 * 1. The AppImage carries LuaJIT, curl, luv and their libraries but uses the
 *    recipient's glibc. Built on ubuntu-latest, its luajit needed GLIBC_2.38
 *    and the AppImage catalogue test, run on Ubuntu 22.04, died before any tray
 *    icon appeared. The version-needs section of every ELF file names exactly
 *    what the loader will demand, so reading it proves the ceiling without a
 *    machine of that vintage.
 * 2. GLIBC_PRIVATE ties a file to one glibc build and is refused as well.
 * 3. A tree with no ELF file at all fails: an empty extraction must not pass.
 *
 * Usage:
 *   node tools/build/check-elf-glibc-ceiling.cjs <file or directory>...
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

/** glibc of the oldest Ubuntu LTS in standard support (22.04), as the catalogue tests it. */
const GLIBC_CEILING = '2.35';
/** The container image of that release: tools/build/appimage-oldest-lts.sh builds and launches the AppImage in it. */
const OLDEST_LTS_IMAGE = 'ubuntu:22.04';

const ELF_MAGIC = Buffer.from([0x7f, 0x45, 0x4c, 0x46]);

/**
 * Parses `readelf --version-info --wide` output into the versions each needed
 * library file must provide.
 * @param {string} output readelf output, in the C locale.
 * @returns {{file: string, name: string}[]} One entry per needed version.
 */
function parseVersionNeeds(output) {
	const needs = [];
	let inNeeds = false;
	let file = null;
	for (const line of output.split('\n')) {
		if (/^Version needs section/.test(line)) {
			inNeeds = true;
			file = null;
			continue;
		}
		if (/^Version (symbols|definition) section/.test(line)) {
			inNeeds = false;
			continue;
		}
		if (!inNeeds) continue;
		const fileMatch = line.match(/File: (\S+)\s+Cnt: \d+/);
		if (fileMatch) {
			file = fileMatch[1];
			continue;
		}
		const nameMatch = line.match(/Name: (\S+)\s+Flags:/);
		if (nameMatch) {
			if (file === null) throw new Error(`Version need without a file: ${line.trim()}`);
			needs.push({ file, name: nameMatch[1] });
		}
	}
	return needs;
}

/**
 * Whether a needed version is beyond the ceiling.
 * @param {string} name A version name such as GLIBC_2.38.
 * @param {string} ceiling Highest admitted glibc version, such as 2.35.
 * @returns {boolean} True for a newer GLIBC_ version or GLIBC_PRIVATE.
 */
function exceedsCeiling(name, ceiling = GLIBC_CEILING) {
	if (name === 'GLIBC_PRIVATE') return true;
	const match = name.match(/^GLIBC_(\d+)\.(\d+)(?:\.(\d+))?$/);
	if (!match) return false;
	const limit = ceiling.split('.').map(Number);
	const version = [Number(match[1]), Number(match[2]), Number(match[3] || 0)];
	for (let index = 0; index < 3; index++) {
		const bound = limit[index] || 0;
		if (version[index] !== bound) return version[index] > bound;
	}
	return false;
}

function isElf(file) {
	const descriptor = fs.openSync(file, 'r');
	try {
		const head = Buffer.alloc(4);
		return fs.readSync(descriptor, head, 0, 4, 0) === 4 && head.equals(ELF_MAGIC);
	} finally {
		fs.closeSync(descriptor);
	}
}

/** Lists regular files under each root without following symbolic links. */
function regularFiles(roots) {
	const files = [];
	const pending = [...roots];
	while (pending.length > 0) {
		const current = pending.pop();
		const stat = fs.lstatSync(current);
		if (stat.isDirectory()) {
			for (const entry of fs.readdirSync(current)) pending.push(path.join(current, entry));
		} else if (stat.isFile()) {
			files.push(current);
		}
	}
	return files.sort();
}

/**
 * Checks every ELF file under the roots.
 * @param {string[]} roots Files or directories.
 * @param {(file: string) => string} readVersions Returns readelf output for one file.
 * @returns {{checked: string[], violations: {path: string, file: string, name: string}[]}}
 */
function checkTree(roots, readVersions) {
	const checked = [];
	const violations = [];
	for (const file of regularFiles(roots)) {
		if (!isElf(file)) continue;
		checked.push(file);
		for (const need of parseVersionNeeds(readVersions(file))) {
			if (exceedsCeiling(need.name)) violations.push({ path: file, ...need });
		}
	}
	return { checked, violations };
}

function readelf(file) {
	return execFileSync('readelf', ['--version-info', '--wide', file], {
		encoding: 'utf8',
		env: { ...process.env, LC_ALL: 'C' },
		maxBuffer: 64 * 1024 * 1024
	});
}

function main(roots) {
	if (roots.length === 0) {
		console.error('Usage: node tools/build/check-elf-glibc-ceiling.cjs <file or directory>...');
		return 2;
	}
	const { checked, violations } = checkTree(roots, readelf);
	if (checked.length === 0) {
		console.error(`[ERR] No ELF file under ${roots.join(', ')}: nothing was checked.`);
		return 1;
	}
	for (const violation of violations) {
		console.error(
			`[ERR] ${violation.path} needs ${violation.name} from ${violation.file} (ceiling GLIBC_${GLIBC_CEILING}, ${OLDEST_LTS_IMAGE}).`
		);
	}
	if (violations.length > 0) {
		console.error(`[ERR] ${violations.length} glibc requirement(s) above ${GLIBC_CEILING}.`);
		return 1;
	}
	console.log(
		`[OK] ${checked.length} ELF file(s) need at most GLIBC_${GLIBC_CEILING} (${OLDEST_LTS_IMAGE}).`
	);
	return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = {
	GLIBC_CEILING,
	OLDEST_LTS_IMAGE,
	parseVersionNeeds,
	exceedsCeiling,
	checkTree
};
