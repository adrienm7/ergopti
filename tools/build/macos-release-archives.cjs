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

/** Read one independent signed source requirement through the native owner. */
function signedRequirement(app, run, destination) {
	run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], destination);
	const requirementReceipt = run('/usr/bin/codesign', ['-d', '-r-', app], destination);
	const requirements = (requirementReceipt.stdout + '\n' + requirementReceipt.stderr)
		.split(/\r?\n/)
		.map((line) => (line.startsWith('# designated => ') ? line.slice(2) : line))
		.filter((line) => line.startsWith('designated => '));
	if (requirements.length !== 1 || requirements[0].slice(14).trim() === '')
		throw new Error('The signed source has no unique designated requirement.');
	const requirement = requirements[0].slice(14);
	return requirement;
}

/** Restore through the same native owner before admitting bytes and signature. */
function restoreArchive(
	payload,
	format,
	extracted,
	basename,
	before,
	requirement,
	run,
	destination
) {
	fs.mkdirSync(extracted);
	if (format === 'zip') run('/usr/bin/ditto', ['-x', '-k', payload, extracted], destination);
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
	return restored;
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
	const requirement = signedRequirement(app, run, destination);
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
			restoreArchive(
				payload,
				archive.format,
				extracted,
				basename,
				before,
				requirement,
				run,
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

/** Return canonical CI bindings without introducing another archive policy. */
function ciBindings(options) {
	const defaults =
		options.defaults ??
		JSON.parse(fs.readFileSync(shared('modules/updater/defaults.json'), 'utf8'));
	const archives = resolveArchives(defaults);
	const basename = archives[0].name.slice(0, -FORMATS.get(archives[0].format).length);
	if (
		!basename.endsWith('.app') ||
		archives.some((a) => a.name !== basename + FORMATS.get(a.format))
	)
		throw new Error('CI archives must name one declared application bundle.');
	return { archives, basename, receiptName: basename + '.ci-receipt.json' };
}

/** ENOENT alone permits the next historical format. Other native failures refuse. */
function archiveBytes(filename, allowAbsent = false) {
	let descriptor;
	try {
		descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
	} catch (error) {
		if (allowAbsent && error.code === 'ENOENT') return null;
		throw error;
	}
	try {
		const stat = fs.fstatSync(descriptor);
		if (!stat.isFile() || stat.size === 0)
			throw new Error('A CI archive must be a nonempty physical regular file.');
		return fs.readFileSync(descriptor);
	} finally {
		fs.closeSync(descriptor);
	}
}

function digest(bytes) {
	return crypto.createHash('sha256').update(bytes).digest('hex');
}

/** Record independent signed-source authority without changing ordinary producer output. */
function createCIReceipt(application, input, options = {}) {
	const { archives, basename, receiptName } = ciBindings(options);
	const app = directory(application),
		source = directory(input);
	if (path.basename(app) !== basename) throw new Error('The CI source is not the declared bundle.');
	const before = snapshot(app);
	const requirement = signedRequirement(app, options.execute ?? execute, source);
	const records = [];
	for (const archive of archives) {
		const bytes = archiveBytes(path.join(source, archive.name), true);
		if (bytes !== null) records.push({ ...archive, bytes: bytes.length, sha256: digest(bytes) });
	}
	if (records.length === 0 || snapshot(app) !== before)
		throw new Error('The CI signed source or archive set is unavailable.');
	const receipt = {
		schema_version: 1,
		bundle: basename,
		snapshot: before,
		requirement,
		archives: records
	};
	const target = path.join(source, receiptName);
	fs.writeFileSync(target, JSON.stringify(receipt) + '\n', { flag: 'wx', mode: 0o600 });
	return target;
}

/** Validate the actual producer receipt; callers cannot invent source identity. */
function readCIReceipt(source, bindings) {
	const receipt = JSON.parse(
		archiveBytes(path.join(source, bindings.receiptName)).toString('utf8')
	);
	const keys = ['schema_version', 'bundle', 'snapshot', 'requirement', 'archives'];
	if (
		!receipt ||
		JSON.stringify(Object.keys(receipt).sort()) !== JSON.stringify(keys.sort()) ||
		receipt.schema_version !== 1 ||
		receipt.bundle !== bindings.basename ||
		typeof receipt.snapshot !== 'string' ||
		typeof receipt.requirement !== 'string' ||
		receipt.requirement.trim() === '' ||
		/[\r\n]/.test(receipt.requirement) ||
		!Array.isArray(receipt.archives) ||
		receipt.archives.length === 0
	)
		throw new Error('The CI archive source receipt is invalid.');
	JSON.parse(receipt.snapshot);
	let previous = -1;
	for (const record of receipt.archives) {
		const index = bindings.archives.findIndex(
			(a) => a.name === record?.name && a.format === record?.format
		);
		if (
			index <= previous ||
			!record ||
			JSON.stringify(Object.keys(record).sort()) !==
				JSON.stringify(['name', 'format', 'bytes', 'sha256'].sort()) ||
			!Number.isSafeInteger(record.bytes) ||
			record.bytes <= 0 ||
			typeof record.sha256 !== 'string' ||
			!/^[a-f0-9]{64}$/.test(record.sha256)
		)
			throw new Error('The CI archive integrity binding is invalid.');
		previous = index;
	}
	return receipt;
}

/** Install selected verified bytes, retaining that exact payload for launch evidence. */
function installCIArchive(input, output, options = {}) {
	const bindings = ciBindings(options),
		source = directory(input),
		destination = directory(output);
	const receipt = readCIReceipt(source, bindings);
	const installed = path.join(destination, bindings.basename);
	absent(installed);
	let selected, bytes;
	for (const candidate of bindings.archives) {
		bytes = archiveBytes(path.join(source, candidate.name), true);
		if (bytes !== null) {
			selected = candidate;
			break;
		}
	}
	if (!selected) throw new Error('No declared CI archive is present.');
	const record = receipt.archives.find(
		(a) => a.name === selected.name && a.format === selected.format
	);
	if (!record || record.bytes !== bytes.length || record.sha256 !== digest(bytes))
		throw new Error('The selected CI archive differs from its signed-source receipt.');
	const run = options.execute ?? execute;
	const owned = fs.mkdtempSync(path.join(source, '.ci-install-'));
	let published = false;
	try {
		const payload = path.join(owned, selected.name);
		fs.writeFileSync(payload, bytes, { flag: 'wx' });
		if (options.quarantine !== undefined) {
			if (
				typeof options.quarantine !== 'string' ||
				options.quarantine === '' ||
				/[\r\n]/.test(options.quarantine)
			)
				throw new Error('The CI quarantine stamp is invalid.');
			run('/usr/bin/xattr', ['-w', 'com.apple.quarantine', options.quarantine, payload], source);
		}
		const restored = restoreArchive(
			payload,
			selected.format,
			path.join(owned, 'app'),
			bindings.basename,
			receipt.snapshot,
			receipt.requirement,
			run,
			source
		);
		if (snapshot(restored) !== receipt.snapshot)
			throw new Error('The CI bundle changed during native signature verification.');
		if (digest(archiveBytes(payload)) !== record.sha256)
			throw new Error('The installed CI payload changed during native extraction.');
		absent(installed);
		fs.renameSync(restored, installed);
		published = true;
		return { archive: payload, format: selected.format, sha256: record.sha256 };
	} finally {
		if (!published) fs.rmSync(owned, { recursive: true });
	}
}

if (require.main === module) {
	const args = process.argv.slice(2);
	if (args[0] === '--ci-receipt' && args.length === 3) {
		createCIReceipt(path.resolve(args[1]), path.resolve(args[2]));
	} else if (args[0] === '--ci-install' && (args.length === 3 || args.length === 4)) {
		process.stdout.write(
			JSON.stringify(
				installCIArchive(
					path.resolve(args[1]),
					path.resolve(args[2]),
					args.length === 4 ? { quarantine: args[3] } : {}
				)
			) + '\n'
		);
	} else {
		if (process.argv.length !== 4)
			throw new Error('Expected the signed application and output directory.');
		for (const archive of createArchives(process.argv[2], process.argv[3]))
			process.stdout.write(`Created ${archive.name}\n`);
	}
}

module.exports = { resolveArchives, createArchives, createCIReceipt, installCIArchive };
