// tools/test/fixtures/archive-contract-filesystem.cjs

/**
 * ==============================================================================
 * MODULE: Archive Contract Filesystem Fixture
 * DESCRIPTION:
 * Models the POSIX file metadata used by the real archive producer, inside a
 * closed in-memory namespace. No operation falls back to the host filesystem.
 * Native macOS XCTest and the extra POSIX fixture retain physical verification.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const nativeFs = require('node:fs');
const { Module, createRequire } = require('node:module');

function refusal(code, target) {
	return Object.assign(new Error(code + ': owned archive fixture: ' + target), {
		code,
		path: target
	});
}

/** A file inode is shared by hardlinks; symbolic links own their target text. */
class ArchiveContractFilesystem {
	constructor(namespace) {
		assert(path.isAbsolute(namespace), 'The model namespace must be absolute');
		this.root = path.resolve(namespace);
		this.entries = new Map([[this.root, { kind: 'directory', mode: 0o755 }]]);
		this.sequence = 0;
	}

	key(value) {
		assert.equal(typeof value, 'string', 'Model paths must be explicit strings');
		assert(path.isAbsolute(value), 'Relative model paths are not admitted');
		const key = path.resolve(value);
		if (key !== this.root && !key.startsWith(this.root + path.sep)) throw refusal('EACCES', key);
		return key;
	}

	lookup(value, follow = true, depth = 0) {
		const key = this.key(value);
		if (depth > 40) throw refusal('ELOOP', key);
		if (key === this.root) return { key, node: this.entries.get(key) };
		const parts = path.relative(this.root, key).split(path.sep);
		let current = this.root;
		for (let index = 0; index < parts.length; index++) {
			current = path.join(current, parts[index]);
			const node = this.entries.get(current);
			if (!node) throw refusal('ENOENT', current);
			const final = index === parts.length - 1;
			if (node.kind === 'symlink' && (follow || !final))
				return this.lookup(
					path.resolve(path.dirname(current), node.target, ...parts.slice(index + 1)),
					follow,
					depth + 1
				);
			if (!final && node.kind !== 'directory') throw refusal('ENOTDIR', current);
		}
		return { key: current, node: this.entries.get(current) };
	}

	parent(value) {
		const result = this.lookup(path.dirname(this.key(value)));
		if (result.node.kind !== 'directory') throw refusal('ENOTDIR', result.key);
		return result.key;
	}

	absent(value) {
		const key = this.key(value);
		try {
			this.lookup(key, false);
		} catch (error) {
			if (error.code === 'ENOENT') return key;
			throw error;
		}
		throw refusal('EEXIST', key);
	}

	lstatSync(value) {
		const { node } = this.lookup(value, false);
		return this.statRecord(node);
	}

	statSync(value) {
		return this.statRecord(this.lookup(value).node);
	}

	statRecord(node) {
		return {
			mode:
				node.mode |
				(node.kind === 'directory' ? 0o040000 : node.kind === 'symlink' ? 0o120000 : 0o100000),
			size:
				node.kind === 'file'
					? node.bytes.length
					: node.kind === 'symlink'
						? Buffer.byteLength(node.target)
						: 0,
			isDirectory: () => node.kind === 'directory',
			isFile: () => node.kind === 'file',
			isSymbolicLink: () => node.kind === 'symlink'
		};
	}

	mkdirSync(value, options = {}) {
		const key = this.key(value);
		try {
			const present = this.lookup(key, false);
			if (options.recursive && present.node.kind === 'directory') return;
			throw refusal('EEXIST', key);
		} catch (error) {
			if (error.code !== 'ENOENT') throw error;
		}
		if (options.recursive) this.mkdirSync(path.dirname(key), options);
		const parent = this.parent(key);
		this.entries.set(path.join(parent, path.basename(key)), {
			kind: 'directory',
			mode: options.mode ?? 0o755
		});
	}

	mkdtempSync(prefix) {
		this.parent(prefix);
		for (let attempt = 0; attempt < 1000; attempt++) {
			const target = prefix + (++this.sequence).toString(16).padStart(6, '0');
			if (this.entries.has(this.key(target))) continue;
			this.mkdirSync(target);
			return target;
		}
		throw refusal('EEXIST', prefix);
	}

	writeFileSync(value, bytes, options = {}) {
		let target;
		if (options.flag === 'wx') this.absent(value);
		try {
			target = this.lookup(value);
			if (target.node.kind !== 'file') throw refusal('EISDIR', target.key);
		} catch (error) {
			if (error.code !== 'ENOENT') throw error;
			const key = path.join(this.parent(value), path.basename(this.key(value)));
			target = { key, node: { kind: 'file', mode: 0o644, bytes: Buffer.alloc(0) } };
			this.entries.set(key, target.node);
		}
		target.node.bytes = Buffer.from(bytes);
	}

	readFileSync(value, encoding) {
		const { key, node } = this.lookup(value);
		if (node.kind !== 'file') throw refusal('EISDIR', key);
		return encoding ? node.bytes.toString(encoding) : Buffer.from(node.bytes);
	}

	appendFileSync(value, bytes) {
		this.writeFileSync(value, Buffer.concat([this.readFileSync(value), Buffer.from(bytes)]));
	}

	chmodSync(value, mode) {
		this.lookup(value).node.mode = mode;
	}

	symlinkSync(target, value) {
		assert.equal(typeof target, 'string');
		this.absent(value);
		const key = path.join(this.parent(value), path.basename(this.key(value)));
		this.entries.set(key, { kind: 'symlink', mode: 0o777, target });
	}

	readlinkSync(value) {
		const { key, node } = this.lookup(value, false);
		if (node.kind !== 'symlink') throw refusal('EINVAL', key);
		return node.target;
	}

	realpathSync(value) {
		return this.lookup(value).key;
	}

	readdirSync(value) {
		const { key, node } = this.lookup(value);
		if (node.kind !== 'directory') throw refusal('ENOTDIR', key);
		return [...this.entries.keys()]
			.filter((item) => item !== key && path.dirname(item) === key)
			.map((item) => path.basename(item));
	}

	cpSync(source, destination, options) {
		assert.equal(options.recursive, true);
		assert.equal(options.verbatimSymlinks, true);
		const { node } = this.lookup(source, false);
		if (node.kind === 'directory') {
			this.mkdirSync(destination, { recursive: true });
			this.chmodSync(destination, node.mode);
			for (const name of this.readdirSync(source))
				this.cpSync(path.join(source, name), path.join(destination, name), options);
		} else if (node.kind === 'symlink') {
			this.symlinkSync(node.target, destination);
		} else {
			this.writeFileSync(destination, node.bytes);
			this.chmodSync(destination, node.mode);
		}
	}

	unlinkSync(value) {
		const { key, node } = this.lookup(value, false);
		if (node.kind === 'directory') throw refusal('EISDIR', key);
		this.entries.delete(key);
	}

	linkSync(source, destination) {
		this.absent(destination);
		const { node } = this.lookup(source, false);
		if (node.kind !== 'file') throw refusal('EPERM', source);
		const key = path.join(this.parent(destination), path.basename(this.key(destination)));
		this.entries.set(key, node);
	}

	rmSync(value, options = {}) {
		const key = this.key(value);
		if (key === this.root) throw refusal('EACCES', key);
		let present;
		try {
			present = this.lookup(key, false);
		} catch (error) {
			if (options.force && error.code === 'ENOENT') return;
			throw error;
		}
		const children = [...this.entries.keys()].filter((item) =>
			item.startsWith(present.key + path.sep)
		);
		if (present.node.kind === 'directory' && children.length && !options.recursive)
			throw refusal('ENOTEMPTY', key);
		if (present.node.kind === 'directory') for (const child of children) this.entries.delete(child);
		this.entries.delete(present.key);
	}
}

/** Compile untouched CommonJS owner bytes in the same realm, with closed ports. */
function loadArchiveProducer(
	filename,
	filesystem,
	source = nativeFs.readFileSync(filename, 'utf8')
) {
	assert(source.length > 1000, 'The actual archive owner source is required');
	const local = new Module(filename, module);
	const resolve = createRequire(filename);
	local.require = (name) => {
		if (name === 'node:fs') return filesystem;
		if (name === 'node:child_process')
			return {
				spawnSync() {
					throw new Error('Native tools are forbidden by the archive contract fixture');
				}
			};
		if (['node:path', 'node:crypto', '../lib/paths.cjs'].includes(name)) return resolve(name);
		throw new Error('Unowned archive fixture dependency: ' + name);
	};
	local._compile(source, filename);
	assert.equal(typeof local.exports.createArchives, 'function');
	assert.equal(typeof local.exports.resolveArchives, 'function');
	return local.exports;
}

/** Literal observations keep model errors separate from producer contract checks. */
function verifyArchiveFilesystemModel(namespace) {
	const fs = new ArchiveContractFilesystem(namespace);
	const root = fs.mkdtempSync(path.join(namespace, 'ModelConformance-'));
	const source = path.join(root, 'source');
	fs.mkdirSync(source);
	fs.chmodSync(source, 0o750);
	const file = path.join(source, 'données.txt');
	fs.writeFileSync(file, 'Literal café 😀\n');
	fs.chmodSync(file, 0o751);
	assert.equal(fs.lstatSync(file).mode & 0o7777, 0o751);
	assert.deepEqual(fs.readFileSync(file), Buffer.from('Literal café 😀\n'));
	const link = path.join(source, 'owned-link');
	fs.symlinkSync('données.txt', link);
	assert(fs.lstatSync(link).isSymbolicLink());
	assert(fs.statSync(link).isFile());
	assert.equal(fs.realpathSync(link), file);
	const dangling = path.join(source, 'dangling');
	fs.symlinkSync('foreign-absent', dangling);
	assert(fs.lstatSync(dangling).isSymbolicLink());
	assert.throws(() => fs.statSync(dangling), { code: 'ENOENT' });
	assert.equal(fs.readlinkSync(dangling), 'foreign-absent');
	const restored = path.join(root, 'restored');
	fs.cpSync(source, restored, { recursive: true, verbatimSymlinks: true });
	assert.equal(fs.lstatSync(restored).mode & 0o7777, 0o750);
	assert.deepEqual(
		fs.readFileSync(path.join(restored, 'données.txt')),
		Buffer.from('Literal café 😀\n')
	);
	assert.deepEqual(
		fs.readdirSync(restored).sort(),
		['dangling', 'données.txt', 'owned-link'].sort()
	);
	assert(fs.lstatSync(path.join(restored, 'owned-link')).isSymbolicLink());
	assert.equal(fs.readlinkSync(path.join(restored, 'owned-link')), 'données.txt');
	assert.equal(fs.readlinkSync(path.join(restored, 'dangling')), 'foreign-absent');
	assert.equal(fs.lstatSync(path.join(restored, 'données.txt')).mode & 0o7777, 0o751);
	fs.chmodSync(path.join(restored, 'données.txt'), 0o700);
	assert.equal(fs.lstatSync(path.join(restored, 'données.txt')).mode & 0o7777, 0o700);
	assert.equal(fs.lstatSync(file).mode & 0o7777, 0o751, 'Copy owns a separate inode');
	const published = path.join(root, 'published');
	fs.linkSync(file, published);
	fs.appendFileSync(published, 'shared');
	assert.equal(fs.readFileSync(file, 'utf8'), 'Literal café 😀\nshared');
	for (const target of [published, source, dangling])
		assert.throws(() => fs.linkSync(file, target), { code: 'EEXIST' });
	fs.rmSync(source, { recursive: true });
	assert.equal(
		fs.readFileSync(published, 'utf8'),
		'Literal café 😀\nshared',
		'Publication survives retirement of the temporary link'
	);
	assert.throws(() => fs.readFileSync(path.join(namespace, '..', 'unowned')), { code: 'EACCES' });
	assert.throws(() => fs.rmSync(namespace, { recursive: true }), { code: 'EACCES' });
	assert.notEqual(
		fs.mkdtempSync(path.join(root, 'owned-')),
		fs.mkdtempSync(path.join(root, 'owned-'))
	);
	fs.rmSync(root, { recursive: true });
	assert.deepEqual(fs.readdirSync(namespace), []);
}

module.exports = { ArchiveContractFilesystem, loadArchiveProducer, verifyArchiveFilesystemModel };
