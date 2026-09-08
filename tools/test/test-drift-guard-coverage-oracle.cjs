// tools/test/test-drift-guard-coverage-oracle.cjs

/**
 * Exercise the actual coverage orchestration with hostile guard receipts.
 * Native generator coverage stays in its own CLI test; these fixtures protect
 * its assertions and cleanup, without invoking a generator or touching disk.
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { runCoverage } = require('./test-drift-guard-covers-every-output.cjs');
const root = path.resolve(__dirname, 'virtual-drift-repository');
const relatives = ['macos', 'windows', 'linux'].map(
	(driver) => `static/ergopti_plus/${driver}/_generated/config_template.toml`
);
relatives.push('static/ergopti_plus/linux/_generated/features_manifest.lua');

for (const mode of [
	'healthy',
	'generator-failure',
	'corruption',
	'signal',
	'null',
	'spawn-error',
	'wrong-path',
	'wrong-status',
	'throw',
	'initial-deletion',
	'final-corruption',
	'neighbor-corruption',
	'throw-after-corruption'
]) {
	const originals = new Map(
		relatives.map((rel) => [path.join(root, rel), Buffer.from(`original ${rel}\n`)])
	);
	const files = new Map(originals);
	const seen = new Set();
	let calls = 0;
	const io = {
		existsSync: (file) => files.has(file),
		readFileSync: (file) => Buffer.from(files.get(file)),
		writeFileSync: (file, bytes) => files.set(file, Buffer.from(bytes)),
		unlinkSync: (file) => files.delete(file)
	};
	const forcedError = new Error('guard invocation failed');
	function runGuard() {
		calls++;
		const changed = relatives.filter(
			(rel) => !files.get(path.join(root, rel)).equals(originals.get(path.join(root, rel)))
		);
		if (changed.length === 0) {
			if (mode === 'initial-deletion' && calls === 1) files.delete(path.join(root, relatives[0]));
			if (mode === 'final-corruption' && calls === 6)
				files.set(path.join(root, relatives[0]), Buffer.from('clean control corrupted'));
			return { status: 0, out: 'clean' };
		}
		assert.equal(
			changed.length,
			1,
			'each independent perturbation must be attributed to its own output'
		);
		const rel = changed[0];
		seen.add(rel);
		const abs = path.join(root, rel);
		const marker = rel.endsWith('.toml') ? '#' : '--';
		assert.deepEqual(
			files.get(abs),
			Buffer.concat([originals.get(abs), Buffer.from(`\n${marker} drift-guard coverage probe\n`)]),
			'the perturbation must be a valid comment'
		);
		const reportedPath = mode === 'wrong-path' ? rel + '.unrelated' : rel;
		const result = {
			status: 1,
			out:
				'\x1b[31m[ERROR] generated output has drifted from its source:\x1b[0m\n' +
				`  - ${reportedPath} differs from what \`npm run gen\` produces — refresh it.`
		};
		if (mode === 'generator-failure') result.out = '[ERROR] failed to run a generator:';
		if (mode === 'corruption') files.set(abs, Buffer.from('unrelated corruption\n'));
		if (mode === 'neighbor-corruption' || mode === 'throw-after-corruption') {
			const neighbor = relatives[(relatives.indexOf(rel) + 1) % relatives.length];
			files.set(path.join(root, neighbor), Buffer.from('neighbor corruption\n'));
		}
		if (mode === 'signal') result.signal = 'SIGTERM';
		if (mode === 'null') result.status = null;
		if (mode === 'spawn-error') result.error = forcedError;
		if (mode === 'wrong-status') result.status = 2;
		if (mode === 'throw' || mode === 'throw-after-corruption') throw forcedError;
		return result;
	}
	if (mode === 'throw' || mode === 'throw-after-corruption') {
		assert.throws(
			() => runCoverage({ fs: io, runGuard, root }),
			(error) => error === forcedError
		);
		assert.equal(calls, 2);
		assert.equal(seen.size, 1);
	} else {
		const errors = runCoverage({ fs: io, runGuard, root });
		assert.equal(calls, 6, `${mode}: clean controls must surround four dirty runs`);
		assert.equal(seen.size, 4, `${mode}: every intended output must actually be perturbed`);
		if (mode === 'healthy') assert.deepEqual(errors, []);
		else if (mode === 'initial-deletion' || mode === 'final-corruption') {
			assert.ok(
				errors.some(
					(error) => error.startsWith(`${relatives[0]}:`) && error.includes('exact edited bytes')
				)
			);
		} else {
			const reason =
				mode === 'corruption' || mode === 'neighbor-corruption'
					? 'exact edited bytes'
					: 'path-specific drift receipt';
			for (const rel of relatives) {
				assert.ok(
					errors.some((error) => error.startsWith(`${rel}:`) && error.includes(reason)),
					`${mode}: reject the actual faulty receipt for ${rel}`
				);
			}
		}
	}
	for (const [file, original] of originals) {
		assert.deepEqual(
			files.get(file),
			original,
			`${mode}: restore the original bytes even after guard failure`
		);
	}
	console.log(`[OK] coverage oracle: ${mode}`);
}
