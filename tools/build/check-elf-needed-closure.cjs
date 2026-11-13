// tools/build/check-elf-needed-closure.cjs

/**
 * ==============================================================================
 * MODULE: ELF Needed-Library Closure Check
 * DESCRIPTION:
 * Refuses a Linux package whose ELF files need a shared library that the image
 * neither carries nor documents as the recipient's own.
 *
 * FEATURES & RATIONALE:
 * 1. check-elf-glibc-ceiling.cjs proves the symbol versions; this proves the
 *    other half of "self-contained": every DT_NEEDED entry of every ELF file in
 *    the tree has a file name or symlink in the tree or is listed in
 *    _shared/updater/data/linux_appimage_recipient_libraries.json,
 *    the documented list of what the recipient supplies (glibc and its loader,
 *    GLib and the C++ runtime, GTK 3). A library a build host linked by accident
 *    fails here, on the runner, instead of at the first launch on a machine
 *    that lacks it.
 * 2. The C library and its loader are not bundled: they must agree with the
 *    recipient's GTK, GL and NSS modules. The image is built on the oldest
 *    supported glibc instead (the ceiling check) and a musl system is refused by
 *    AppRun in words. The baseline is recorded in the data file.
 * 3. A tree with no ELF file fails: an empty extraction must not pass.
 *
 * Usage:
 *   node tools/build/check-elf-needed-closure.cjs <file or directory>...
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { isElf, regularFiles } = require('./check-elf-glibc-ceiling.cjs');

const RECIPIENT_LIBRARIES = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/updater/data/linux_appimage_recipient_libraries.json'
);

/**
 * Parses `readelf --dynamic --wide` output.
 * @param {string} output readelf output, in the C locale.
 * @returns {{needed: string[], soname: string|null}}
 */
function parseDynamic(output) {
	const needed = [];
	let soname = null;
	for (const line of output.split('\n')) {
		const need = line.match(/\(NEEDED\)\s+Shared library: \[(.+)\]\s*$/);
		if (!need && /\(NEEDED\)/.test(line)) throw new Error('unreadable ELF needed library');
		if (need) needed.push(need[1]);
		const own = line.match(/\(SONAME\)\s+Library soname: \[(.+)\]\s*$/);
		if (!own && /\(SONAME\)/.test(line)) throw new Error('unreadable ELF soname');
		if (own) soname = own[1];
	}
	return { needed, soname };
}

/**
 * Validates and indexes the documented recipient libraries.
 * @param {object} data Parsed linux_appimage_recipient_libraries.json.
 * @returns {{has: (name: string) => boolean, groupOf: (name: string) => string|null}}
 */
function recipientLibraries(data) {
	if (!data || data.version !== 1 || !Array.isArray(data.groups) || data.groups.length === 0)
		throw new Error('recipient library list: version 1 and at least one group required');
	const sonames = new Map();
	const prefixes = [];
	for (const group of data.groups) {
		if (
			typeof group.id !== 'string' ||
			typeof group.reason !== 'string' ||
			group.reason.length < 40
		)
			throw new Error(
				`recipient library group ${group.id}: an id and a reason (40+ characters) are required`
			);
		for (const key of ['sonames', 'prefixes']) {
			if (
				group[key] !== undefined &&
				(!Array.isArray(group[key]) ||
					group[key].some((value) => typeof value !== 'string' || value.length === 0))
			)
				throw new Error(
					`recipient library group ${group.id}: ${key} must contain nonempty strings`
				);
		}
		for (const name of group.sonames || []) {
			if (sonames.has(name)) throw new Error(`recipient library ${name} is listed twice`);
			sonames.set(name, group.id);
		}
		for (const prefix of group.prefixes || []) prefixes.push([prefix, group.id]);
	}
	const groupOf = (name) => {
		if (sonames.has(name)) return sonames.get(name);
		for (const [prefix, id] of prefixes) if (name.startsWith(prefix)) return id;
		return null;
	};
	return { has: (name) => groupOf(name) !== null, groupOf };
}

/** ELF shared objects have type ET_DYN; executables cannot satisfy DT_NEEDED. */
function isSharedObject(file) {
	const descriptor = fs.openSync(file, 'r');
	try {
		const header = Buffer.alloc(18);
		if (fs.readSync(descriptor, header, 0, header.length, 0) !== header.length) return false;
		if (header[5] === 1) return header.readUInt16LE(16) === 3;
		if (header[5] === 2) return header.readUInt16BE(16) === 3;
		return false;
	} finally {
		fs.closeSync(descriptor);
	}
}

/**
 * Checks every ELF file under the roots.
 * @param {string[]} roots Files or directories.
 * @param {(file: string) => string} readDynamic Returns readelf --dynamic output for one file.
 * @param {{has: (name: string) => boolean}} recipient Documented recipient libraries.
 * @returns {{checked: string[], violations: {path: string, needed: string}[]}}
 */
function checkClosure(roots, readDynamic, recipient) {
	const files = regularFiles(roots);
	const checked = [];
	const provided = new Set();
	const dynamics = new Map();
	const elfFiles = files.filter(isElf);
	const outputs = new Map(elfFiles.map((file) => [file, readDynamic(file)]));
	// PIE executables also use ET_DYN, but cannot be loaded as libraries.
	const sharedFiles = new Set(
		elfFiles.filter(
			(file) => isSharedObject(file) && !/\(FLAGS_1\)[^\n]*\bPIE\b/.test(outputs.get(file))
		)
	);
	const bundledElfPaths = new Set([...sharedFiles].map((file) => fs.realpathSync(file)));
	for (const root of roots) {
		// Symbolic links count as provided names: libfoo.so.1 is usually a link.
		const pending = [root];
		while (pending.length > 0) {
			const current = pending.pop();
			const stat = fs.lstatSync(current);
			if (stat.isDirectory()) {
				for (const entry of fs.readdirSync(current)) pending.push(path.join(current, entry));
			} else if (stat.isSymbolicLink()) {
				let target;
				try {
					target = fs.realpathSync(current);
				} catch (error) {
					if (error.code === 'ENOENT' || error.code === 'ELOOP') continue;
					throw error;
				}
				if (bundledElfPaths.has(target)) provided.add(path.basename(current));
			}
		}
	}
	for (const file of elfFiles) {
		checked.push(file);
		const dynamic = parseDynamic(outputs.get(file));
		dynamics.set(file, dynamic);
		if (sharedFiles.has(file)) {
			provided.add(path.basename(file));
		}
	}
	const violations = [];
	for (const [file, dynamic] of dynamics)
		for (const needed of dynamic.needed)
			if (!provided.has(needed) && !recipient.has(needed)) violations.push({ path: file, needed });
	return { checked, violations };
}

function readelfDynamic(file) {
	return execFileSync('readelf', ['--dynamic', '--wide', file], {
		encoding: 'utf8',
		env: { ...process.env, LC_ALL: 'C' },
		maxBuffer: 64 * 1024 * 1024
	});
}

function main(roots) {
	if (roots.length === 0) {
		console.error('Usage: node tools/build/check-elf-needed-closure.cjs <file or directory>...');
		return 2;
	}
	const recipient = recipientLibraries(JSON.parse(fs.readFileSync(RECIPIENT_LIBRARIES, 'utf8')));
	const { checked, violations } = checkClosure(roots, readelfDynamic, recipient);
	if (checked.length === 0) {
		console.error(`[ERR] No ELF file under ${roots.join(', ')}: nothing was checked.`);
		return 1;
	}
	for (const violation of violations)
		console.error(
			`[ERR] ${violation.path} needs ${violation.needed}, which the image does not carry and the recipient list does not document.`
		);
	if (violations.length > 0) {
		console.error(
			`[ERR] ${violations.length} unbundled dependenc${violations.length === 1 ? 'y' : 'ies'}: stage the library, or document it in ${path.relative(process.cwd(), RECIPIENT_LIBRARIES)} with a reason.`
		);
		return 1;
	}
	console.log(
		`[OK] ${checked.length} ELF file(s) resolve every needed library inside the image or on the recipient list.`
	);
	return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { parseDynamic, recipientLibraries, checkClosure, RECIPIENT_LIBRARIES };
