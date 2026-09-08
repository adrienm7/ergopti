// tools/test/test-drift-restore-refusal.cjs

/** Exercise the real drift guard with isolated filesystem refusal boundaries. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const registry = require('../build/generators.cjs');
const sourcePath = path.join(__dirname, 'test-features-manifest-no-drift.cjs');
const source = fs.readFileSync(sourcePath, 'utf8');
const root = path.resolve(__dirname, '..', '..');
const outputs = registry.allOutputs();
assert.ok(outputs.length >= 15, 'exercise the actual complete generator registry');

for (const mode of ['healthy', 'drift', 'write', 'unlink', 'read', 'generator-write']) {
	const originals = new Map(
		outputs.map((rel) => [path.join(root, rel), Buffer.from(`original ${rel}`)])
	);
	const first = path.join(root, outputs[0]);
	if (mode === 'unlink') {
		originals.delete(first);
		originals.delete(path.join(root, outputs[1]));
	}
	const files = new Map(originals);
	const diagnostics = [];
	let generated = false;
	let exitCode = 0;
	let escaped;
	const exitSignal = {};
	const io = {
		existsSync: (file) => files.has(file),
		readFileSync(file) {
			if (generated && file === first && mode === 'read') throw new Error('comparison refused');
			assert.ok(files.has(file), `fixture read requires an existing file: ${file}`);
			return Buffer.from(files.get(file));
		},
		writeFileSync(file, bytes) {
			if (file === first && (mode === 'write' || mode === 'generator-write'))
				throw new Error('restoration refused');
			files.set(file, Buffer.from(bytes));
		},
		unlinkSync(file) {
			if (file === first && mode === 'unlink') throw new Error('deletion refused');
			assert.ok(files.delete(file), 'fixture deletion requires an existing file');
		}
	};
	const context = {
		__dirname,
		console: { log: (line) => diagnostics.push(line), error: (line) => diagnostics.push(line) },
		process: {
			exit(code) {
				exitCode = code;
				throw exitSignal;
			}
		},
		require(name) {
			if (name === 'fs') return io;
			if (name === 'path') return path;
			if (name === '../build/generators.cjs') return registry;
			if (name === 'child_process')
				return {
					execFileSync() {
						generated = true;
						if (mode !== 'healthy') {
							for (const rel of outputs) files.set(path.join(root, rel), Buffer.from('generated'));
						}
						if (mode === 'generator-write') throw new Error('original generator failure');
					}
				};
			throw new Error(`Unexpected boundary: ${name}`);
		}
	};
	try {
		vm.runInNewContext(source, context, { filename: sourcePath });
	} catch (error) {
		if (error !== exitSignal) escaped = error;
	}
	assert.ok(generated, `${mode}: the real guard must invoke the generator boundary`);
	for (const [file, bytes] of originals) {
		if (file === first && (mode === 'write' || mode === 'generator-write')) continue;
		assert.deepEqual(
			files.get(file),
			bytes,
			`${mode}: restore every writable original despite a sibling refusal`
		);
	}
	assert.equal(escaped, undefined, `${mode}: report all failures after independent restoration`);
	if (mode === 'unlink')
		assert.equal(
			files.has(path.join(root, outputs[1])),
			false,
			'continue deleting newly generated outputs after a sibling deletion refusal'
		);
	assert.equal(
		exitCode,
		mode === 'healthy' ? 0 : 1,
		`${mode}: native refusal never becomes success`
	);
	if (!['healthy', 'drift'].includes(mode)) {
		assert.ok(
			diagnostics.some((line) => line.includes(outputs[0]) && line.includes('refused')),
			`${mode}: preserve the failed operation and exact target`
		);
	}
	if (mode === 'generator-write') {
		assert.ok(
			diagnostics.some((line) => line.includes('original generator failure')),
			'cleanup must not mask the original generator failure'
		);
	}
	console.log(`[OK] drift restoration: ${mode}`);
}
