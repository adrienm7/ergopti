// tools/test/fixtures/tis_fixture_metadata_port.cjs
// Closed Windows fixture metadata; native POSIX admission remains independent.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const Module = require('node:module');

/** Bind physical bytes and descriptor identity without claiming POSIX metadata. */
function createPort(root) {
	if (process.platform !== 'win32')
		throw new Error('The TIS metadata port is Windows-fixture-only.');
	const owned = path.resolve(root);
	const same = (a, b) => path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase();
	if (
		!path.isAbsolute(root) ||
		!same(fs.realpathSync(root), owned) ||
		!fs.lstatSync(root).isDirectory()
	)
		throw new Error('The TIS metadata owner must be a real private directory.');
	const descriptors = new Map();
	function requireOwned(filename) {
		if (typeof filename !== 'string')
			throw new Error('The TIS metadata port refuses non-path input.');
		const candidate = path.resolve(filename);
		if (
			!same(candidate, owned) &&
			!candidate.toLowerCase().startsWith(owned.toLowerCase() + path.sep)
		)
			throw new Error('The TIS metadata port refuses a foreign path.');
		return candidate;
	}
	function nativeTuple(filename, descriptor) {
		const literal = requireOwned(filename);
		const source = fs.lstatSync(literal, { bigint: true });
		const retained = fs.fstatSync(descriptor, { bigint: true });
		if (
			!same(fs.realpathSync(literal), literal) ||
			!source.isFile() ||
			source.isSymbolicLink() ||
			source.ino !== retained.ino ||
			source.size !== retained.size ||
			source.nlink !== retained.nlink ||
			!retained.isFile() ||
			(source.dev !== 0n && source.dev !== retained.dev)
		)
			throw new Error('The TIS metadata port refuses a native identity mismatch.');
		return retained;
	}
	function expose(numeric, native) {
		const result = Object.assign(Object.create(Object.getPrototypeOf(numeric)), numeric);
		// Preserve actual retained volume identity and the entire native inode.
		result.dev = native.dev.toString();
		result.ino = native.ino.toString();
		return result;
	}
	const port = {
		constants: Object.freeze({
			O_RDONLY: fs.constants.O_RDONLY,
			O_NOFOLLOW: fs.constants.O_NOFOLLOW
		})
	};
	port.readdirSync = function (filename) {
		const literal = requireOwned(filename);
		if (
			!same(literal, owned) ||
			!same(fs.realpathSync(literal), literal) ||
			!fs.lstatSync(literal).isDirectory() ||
			fs.lstatSync(literal).isSymbolicLink()
		)
			throw new Error('The TIS metadata port refuses an unowned directory census.');
		return fs.readdirSync(literal);
	};
	port.lstatSync = function (filename) {
		const literal = requireOwned(filename);
		const status = fs.lstatSync(literal);
		// The original validator still rejects directories/symbolic/nonregular rows.
		if (!status.isFile() || status.isSymbolicLink()) return status;
		const descriptor = fs.openSync(literal, fs.constants.O_RDONLY);
		try {
			return expose(status, nativeTuple(literal, descriptor));
		} finally {
			fs.closeSync(descriptor);
		}
	};
	port.openSync = function (filename, flags) {
		const literal = requireOwned(filename);
		if (flags !== (fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0)))
			throw new Error('The TIS metadata port refuses non-read admission.');
		const descriptor = fs.openSync(literal, flags);
		try {
			const identity = nativeTuple(literal, descriptor);
			descriptors.set(descriptor, { dev: identity.dev, ino: identity.ino });
			return descriptor;
		} catch (error) {
			fs.closeSync(descriptor);
			throw error;
		}
	};
	function retained(descriptor) {
		const owner = descriptors.get(descriptor);
		if (!owner) throw new Error('The TIS metadata port refuses an unknown descriptor.');
		const status = fs.fstatSync(descriptor, { bigint: true });
		if (status.dev !== owner.dev || status.ino !== owner.ino)
			throw new Error('The TIS metadata port refuses descriptor substitution.');
		return status;
	}
	port.fstatSync = function (descriptor) {
		const native = retained(descriptor);
		return expose(fs.fstatSync(descriptor), native);
	};
	port.readFileSync = function (descriptor) {
		retained(descriptor);
		return fs.readFileSync(descriptor);
	};
	port.closeSync = function (descriptor) {
		retained(descriptor);
		fs.closeSync(descriptor);
		descriptors.delete(descriptor);
	};
	return { port, outstanding: () => descriptors.size };
}

/** Compile byte-exact validator source; its own require.main branch owns the CLI. */
function loadValidator(root, cli = false) {
	const filename = path.resolve(__dirname, '../../diagnostics/tis_evidence_transport.cjs');
	const { port, outstanding } = createPort(root);
	const source = fs.readFileSync(filename, 'utf8');
	const local = { exports: {}, filename };
	const nativeRequire = Module.createRequire(filename);
	function ownedRequire(id) {
		if (id === 'node:fs') return port;
		if (id === 'node:path' || id === 'node:crypto') return nativeRequire(id);
		throw new Error('The closed TIS validator has an unexpected dependency: ' + id);
	}
	ownedRequire.main = cli ? local : module;
	const body = vm.runInThisContext(Module.wrap(source), { filename });
	body(local.exports, ownedRequire, local, filename, path.dirname(filename));
	assert.equal(outstanding(), 0, 'the actual TIS validator retires every acquired descriptor');
	assert.equal(typeof local.exports.validate, 'function');
	return local.exports;
}

/** Independently witness real native identity and closed descriptor admission. */
function verifyPort(root) {
	const directory = fs.mkdtempSync(path.join(root, 'tis-port-control-'));
	const source = path.join(directory, 'independent.txt');
	const foreign = path.join(root, 'foreign-control.txt');
	fs.writeFileSync(source, 'Independent native bytes\n');
	fs.writeFileSync(foreign, 'Foreign fixture bytes\n');
	try {
		const { port, outstanding } = createPort(directory);
		const nativeDescriptor = fs.openSync(source, fs.constants.O_RDONLY);
		try {
			const native = fs.fstatSync(nativeDescriptor, { bigint: true });
			const literal = fs.lstatSync(source, { bigint: true });
			assert.equal(literal.ino, native.ino);
			assert.equal(literal.size, native.size);
			assert.ok(literal.dev === 0n || literal.dev === native.dev);
			const status = port.lstatSync(source);
			assert.equal(status.ino, literal.ino.toString());
			assert.equal(status.dev, native.dev.toString());
			const descriptor = port.openSync(source, fs.constants.O_RDONLY);
			try {
				assert.equal(port.fstatSync(descriptor).ino, native.ino.toString());
				assert.equal(port.fstatSync(descriptor).dev, native.dev.toString());
				assert.equal(port.readFileSync(descriptor).toString('utf8'), 'Independent native bytes\n');
			} finally {
				port.closeSync(descriptor);
			}
		} finally {
			fs.closeSync(nativeDescriptor);
		}
		assert.deepEqual(port.readdirSync(directory), ['independent.txt']);
		assert.throws(() => port.readdirSync(root), /foreign path/);
		assert.equal(port.writeFileSync, undefined);
		assert.equal(port.unlinkSync, undefined);
		assert.equal(port.renameSync, undefined);
		assert.equal(port.rmSync, undefined);
		assert.ok(Object.isFrozen(port.constants));
		assert.throws(() => port.openSync(foreign, fs.constants.O_RDONLY), /foreign path/);
		assert.throws(() => port.openSync(source, fs.constants.O_WRONLY), /non-read admission/);
		assert.throws(() => port.fstatSync(-1), /unknown descriptor/);
		assert.throws(() => port.readFileSync(-1), /unknown descriptor/);
		assert.throws(() => port.closeSync(-1), /unknown descriptor/);
		assert.equal(outstanding(), 0);
		assert.equal(fs.readFileSync(foreign, 'utf8'), 'Foreign fixture bytes\n');
	} finally {
		try {
			fs.rmSync(directory, { recursive: true });
		} finally {
			fs.unlinkSync(foreign);
		}
	}
}
module.exports = { loadValidator, verifyPort };
if (require.main === module) {
	if (
		process.argv.length !== 4 ||
		process.argv[2] !== process.env.ERGOPTI_TIS_EVIDENCE_DIR ||
		process.argv[3] !== process.env.ERGOPTI_TIS_EVIDENCE_SESSION
	)
		throw new Error('The TIS fixture CLI requires the actual private session owner.');
	loadValidator(process.argv[2], true);
}
