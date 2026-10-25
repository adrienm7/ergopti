// tools/build/publish-linux-rpm.cjs

/**
 * MODULE: RPM Main Package Publication Boundary
 * Keeps the native package set intact while exposing exactly one validated
 * runtime package to release consumers. Debug packages are build outputs, but
 * cannot substitute for the driver merely because filesystem order lists them
 * first. Metadata comes from RPM itself, never from filename guesses.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const DEBUG_PACKAGE_SUFFIXES = ['-debuginfo', '-debugsource'];
const METADATA_QUERY_TIMEOUT_MS = 30000;
const METADATA_QUERY_MAX_BYTES = 65536;

/**
 * Read identity through the native package manager, with bounded output/time.
 * @param {string} filename Package archive path.
 * @returns {{name: string, version: string, arch: string}} Native header identity.
 * @throws {Error} When RPM refuses the archive or returns malformed metadata.
 */
function readRpmIdentity(filename) {
	const query = spawnSync(
		'rpm',
		['-qp', '--queryformat', '%{NAME}\n%{VERSION}\n%{ARCH}\n', filename],
		{
			encoding: 'utf8',
			timeout: METADATA_QUERY_TIMEOUT_MS,
			maxBuffer: METADATA_QUERY_MAX_BYTES
		}
	);
	if (query.error || query.status !== 0)
		throw new Error(
			`native RPM metadata refused ${filename}: ${query.error?.message || query.stderr.trim()}`
		);
	// Successful native queries can still report environment/signature diagnostics.
	if (query.stderr) process.stderr.write(query.stderr);
	const fields = query.stdout.split('\n');
	if (fields.length !== 4 || fields[3] !== '')
		throw new Error(`native RPM metadata has an invalid shape for ${filename}`);
	const identity = { name: fields[0], version: fields[1], arch: fields[2] };
	requireIdentity(identity);
	return identity;
}

function requireIdentity(identity) {
	for (const field of ['name', 'version', 'arch'])
		if (
			typeof identity?.[field] !== 'string' ||
			!identity[field] ||
			/[\r\n\0]/.test(identity[field])
		)
			throw new Error(`RPM identity has an invalid ${field}`);
}
function ordinaryDirectory(directory) {
	const stat = fs.lstatSync(directory);
	if (!stat.isDirectory() || stat.isSymbolicLink())
		throw new Error(`ordinary RPM directory required: ${directory}`);
	return fs.realpathSync(directory);
}
function nested(parent, child) {
	const relative = path.relative(parent, child);
	return (
		!relative ||
		(!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))
	);
}
function nativePackages(directory) {
	const files = [];
	for (const item of fs
		.readdirSync(directory, { withFileTypes: true })
		.sort((left, right) => left.name.localeCompare(right.name))) {
		const filename = path.join(directory, item.name);
		if (item.isDirectory()) files.push(...nativePackages(filename));
		else if (item.isFile() && item.name.endsWith('.rpm')) files.push(filename);
		else throw new Error(`unexpected native RPM output node: ${filename}`);
	}
	return files;
}

function publishRpmPackage({
	nativeRoot,
	publishedRoot,
	expected,
	readIdentity = readRpmIdentity
}) {
	requireIdentity(expected);
	// Architecture becomes one directory component; RPM's native labels have no
	// path separators or shell punctuation.
	if (!/^[A-Za-z0-9_]+$/.test(expected.arch))
		throw new Error('invalid RPM publication architecture');
	const native = ordinaryDirectory(nativeRoot);
	const published = ordinaryDirectory(publishedRoot);
	if (nested(native, published) || nested(published, native))
		throw new Error('RPM output roots must be disjoint');
	if (fs.readdirSync(published).length !== 0)
		throw new Error('RPM publication root contains prior output');
	const files = nativePackages(native);
	const main = [];
	for (const filename of files) {
		const identity = readIdentity(filename);
		requireIdentity(identity);
		if (
			identity.version !== expected.version ||
			identity.arch !== expected.arch ||
			(identity.name !== expected.name &&
				!DEBUG_PACKAGE_SUFFIXES.some((suffix) => identity.name === expected.name + suffix))
		)
			throw new Error(
				`foreign RPM identity: ${identity.name}/${identity.version}/${identity.arch}`
			);
		if (identity.name === expected.name) main.push(filename);
	}
	if (main.length !== 1) throw new Error(`expected exactly one main RPM, found ${main.length}`);

	const staging = fs.mkdtempSync(path.join(path.dirname(published), '.ergopti-rpm-publish-'));
	try {
		const staged = path.join(staging, path.basename(main[0]));
		fs.copyFileSync(main[0], staged, fs.constants.COPYFILE_EXCL);
		const copied = readIdentity(staged);
		requireIdentity(copied);
		if (['name', 'version', 'arch'].some((field) => copied[field] !== expected[field]))
			throw new Error('copied RPM identity does not match the admitted main package');
		const architectureRoot = path.join(published, expected.arch);
		fs.mkdirSync(architectureRoot);
		const artifact = path.join(architectureRoot, path.basename(staged));
		// A no-replace hard link makes the complete admitted file appear at once.
		fs.linkSync(staged, artifact);
		return { artifact, retained: files.length };
	} finally {
		fs.rmSync(staging, { recursive: true, force: true });
	}
}

if (require.main === module) {
	try {
		if (process.argv.length !== 7)
			throw new Error(
				'usage: publish-linux-rpm.cjs <native output> <published output> <name> <version> <arch>'
			);
		const [nativeRoot, publishedRoot, name, version, arch] = process.argv.slice(2);
		const result = publishRpmPackage({
			nativeRoot,
			publishedRoot,
			expected: { name, version, arch }
		});
		console.error(
			`[rpm-publish] Retained ${result.retained} native packages under ${nativeRoot}; published one ${name}/${version}/${arch} main package.`
		);
		process.stdout.write(`${result.artifact}\n`);
	} catch (error) {
		console.error(`[rpm-publish] ERROR: ${error.message}`);
		process.exitCode = 1;
	}
}
module.exports = { publishRpmPackage, readRpmIdentity };
