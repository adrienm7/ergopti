// tools/build/macos-release-archives.cjs

/**
 * ==============================================================================
 * MODULE: Native macOS Release Archives
 * DESCRIPTION:
 * Builds every archive declared by the shared manual-install policy from the
 * already signed application. Native extraction verifies the signature and
 * exact file bytes, modes and symlink targets before either file is published.
 * Publishing uses exclusive links: existing output files are never replaced.
 * The source bundle, historical feed and native-helper ZIP stay independent.
 *
 * USAGE: node tools/build/macos-release-archives.cjs <signed.app> <output-dir>
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { shared } = require('../lib/paths.cjs');

const FORMATS = new Map([
	['zip', '.zip'],
	['tar.xz', '.tar.xz']
]);

/** Resolve native format/name bindings from actual canonical updater data. */
function resolveArchives(defaults) {
	const bindings = defaults?.release_install?.macos_archives;
	if (
		!Array.isArray(bindings) ||
		bindings.length === 0 ||
		Object.keys(bindings).length !== bindings.length ||
		Object.keys(bindings).some((key, index) => key !== String(index))
	)
		throw new Error('The macOS producer requires a nonempty declared archive array.');
	const formats = new Set();
	const names = new Set();
	return bindings.map((binding) => {
		const format = binding?.format;
		const name = defaults?.release_assets?.[binding?.asset_key];
		if (
			!FORMATS.has(format) ||
			formats.has(format) ||
			typeof name !== 'string' ||
			!/^[A-Za-z0-9._-]+$/.test(name) ||
			!name.endsWith(FORMATS.get(format)) ||
			names.has(name)
		)
			throw new Error('The declared macOS archive binding is invalid.');
		formats.add(format);
		names.add(name);
		return { name, format };
	});
}

/** Native tool failure stops the producer; no output is advertised as valid. */
function execute(executable, args, cwd) {
	const result = spawnSync(executable, args, { cwd, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
	if (result.error) throw result.error;
	if (result.status !== 0)
		throw new Error(
			`${path.basename(executable)} failed: ${result.status}\n${result.stdout}${result.stderr}`
		);
	return { stdout: result.stdout, stderr: result.stderr };
}

/** Keep all regular-file bytes/modes and symbolic-link targets independent. */
function snapshot(directory) {
	const records = [];
	function visit(relative) {
		const target = path.join(directory, relative);
		const stat = fs.lstatSync(target);
		if (stat.isSymbolicLink()) {
			records.push([relative, 'symlink', fs.readlinkSync(target)]);
		} else if (stat.isDirectory()) {
			records.push([relative, 'directory', stat.mode & 0o7777]);
			for (const name of fs.readdirSync(target).sort()) visit(path.join(relative, name));
		} else if (stat.isFile()) {
			records.push([
				relative,
				'file',
				stat.mode & 0o7777,
				crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex')
			]);
		} else throw new Error('A release bundle contains an unsupported native file type.');
	}
	visit('');
	return JSON.stringify(records);
}

/** Admit existing physical directories; do not follow a substituted root. */
function directory(value) {
	if (typeof value !== 'string' || !path.isAbsolute(value))
		throw new Error('An absolute directory is required.');
	const stat = fs.lstatSync(value);
	if (!stat.isDirectory() || stat.isSymbolicLink())
		throw new Error('A physical directory is required.');
	return fs.realpathSync(value);
}

/** Refuse a pre-existing regular file, directory or dangling symbolic link. */
function absent(target) {
	try {
		fs.lstatSync(target);
	} catch (error) {
		if (error.code === 'ENOENT') return;
		throw error;
	}
	throw new Error('A release archive output already exists.');
}

/**
 * Build and verify both archives using the actual native command owner.
 * Tests may supply a recording native executor; CLI always uses real tools.
 */
function createArchives(application, output, options = {}) {
	const defaults =
		options.defaults ??
		JSON.parse(fs.readFileSync(shared('modules/updater/defaults.json'), 'utf8'));
	const archives = resolveArchives(defaults);
	const app = directory(application);
	const destination = directory(output);
	const basename = path.basename(app);
	if (!basename.endsWith('.app'))
		throw new Error('The archive source must be an application bundle.');
	for (const archive of archives) absent(path.join(destination, archive.name));
	const run = options.execute ?? execute;
	const before = snapshot(app);
	run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], destination);
	const requirementReceipt = run('/usr/bin/codesign', ['-d', '-r-', app], destination);
	const requirements = (requirementReceipt.stdout + '\n' + requirementReceipt.stderr)
		.split(/\r?\n/)
		.map((line) => (line.startsWith('# designated => ') ? line.slice(2) : line))
		.filter((line) => line.startsWith('designated => '));
	if (requirements.length !== 1 || requirements[0].slice(14).trim() === '')
		throw new Error('The signed source has no unique designated requirement.');
	const requirement = requirements[0].slice(14);
	const owned = fs.mkdtempSync(path.join(destination, '.release-archives-'));
	try {
		for (const archive of archives) {
			const payload = path.join(owned, archive.name);
			if (archive.format === 'zip') {
				// Keep plain maximum-deflate ZIP while preserving Mac metadata.
				run(
					'/usr/bin/ditto',
					[
						'-c',
						'-k',
						'--sequesterRsrc',
						'--keepParent',
						'--zlibCompressionLevel',
						'9',
						app,
						payload
					],
					destination
				);
			} else {
				// The .app itself is the root entry, with no enclosing directory.
				run(
					'/usr/bin/tar',
					[
						'-cJf',
						payload,
						'--options',
						'xz:compression-level=9',
						'-C',
						path.dirname(app),
						'--',
						basename
					],
					destination
				);
			}
			if (
				!fs.lstatSync(payload).isFile() ||
				fs.lstatSync(payload).isSymbolicLink() ||
				fs.statSync(payload).size === 0
			)
				throw new Error('The native archive output is not a nonempty regular file.');
			const extracted = path.join(owned, 'verify-' + archive.format);
			fs.mkdirSync(extracted);
			if (archive.format === 'zip')
				run('/usr/bin/ditto', ['-x', '-k', payload, extracted], destination);
			else run('/usr/bin/tar', ['-xJpf', payload, '-C', extracted], destination);
			if (JSON.stringify(fs.readdirSync(extracted).sort()) !== JSON.stringify([basename]))
				throw new Error('A release archive has an unexpected top-level entry.');
			const restored = path.join(extracted, basename);
			if (snapshot(restored) !== before)
				throw new Error('A release archive changed bundle bytes, modes or symlinks.');
			run(
				'/usr/bin/codesign',
				['--verify', '--deep', '--strict', '-R', '=' + requirement, restored],
				destination
			);
		}
		if (snapshot(app) !== before)
			throw new Error('The signed source changed during native archiving.');
		// Link only after every archive passes. EEXIST refuses concurrent output
		// replacement; the temporary directory belongs to this invocation alone.
		for (const archive of archives)
			fs.linkSync(path.join(owned, archive.name), path.join(destination, archive.name));
		return archives.map((archive) => ({ ...archive, path: path.join(destination, archive.name) }));
	} finally {
		fs.rmSync(owned, { recursive: true });
	}
}

if (require.main === module) {
	if (process.argv.length !== 4)
		throw new Error('Expected the signed application and output directory.');
	for (const archive of createArchives(process.argv[2], process.argv[3]))
		process.stdout.write(`Created ${archive.name}\n`);
}

module.exports = { resolveArchives, createArchives };
