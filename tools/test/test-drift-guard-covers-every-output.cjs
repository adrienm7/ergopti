// tools/test/test-drift-guard-covers-every-output.cjs

/**
 * ==============================================================================
 * MODULE: Drift-Guard Coverage Meta Test
 * DESCRIPTION:
 * test-features-manifest-no-drift.cjs must guard EVERY file the manifest
 * generator writes, and must never eat an uncommitted change.
 *
 * ROOT CAUSE ENCODED:
 * build-features-manifest.js writes six files — a features manifest and a
 * config_template.toml for each of the three drivers. The drift guard listed
 * two. It snapshotted those two, ran the generator in place, and restored those
 * two, leaving the other four exactly as the generator had just rewritten them.
 *
 * So the guard did two wrong things at once, and the second is the dangerous
 * one. It never checked four of its six outputs for drift — the thing it exists
 * to do. And it silently reverted any uncommitted edit to those four: appending
 * a line to linux/_generated/config_template.toml and running the guard printed
 * "[OK] … no drift" and left `git status` clean. The edit was simply gone.
 *
 * A hand-maintained list of generator outputs falls behind the generator; this
 * one had fallen four behind, and nothing could tell you. The fix snapshots the
 * whole of each `_generated/` tree instead of naming files.
 *
 * WHY THIS TEST PERTURBS AN ISOLATED COPY:
 * The failure is only observable through a real edit surviving a real run. A
 * static check ("does the guard mention config_template?") would pass on a
 * guard that mentions it and still restores nothing. Every perturbation below
 * is restored from an in-memory snapshot in a finally block. Run those probes
 * against current source bytes in a private tree: native readers of a running
 * driver must never contend with a test overwriting their configuration.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync, execFileSync } = require('child_process');
const ROOT = path.resolve(__dirname, '..', '..');
const PREVIOUSLY_UNGUARDED = [
	'static/ergopti_plus/macos/_generated/config_template.toml',
	'static/ergopti_plus/windows/_generated/config_template.toml',
	'static/ergopti_plus/linux/_generated/config_template.toml',
	'static/ergopti_plus/linux/_generated/features_manifest.lua'
];

/** Runs the real guard without dropping launch failure or signal receipts. */
function runGuardNative(root) {
	const result = spawnSync(
		process.execPath,
		[path.join(root, 'tools/test/test-features-manifest-no-drift.cjs')],
		{
			cwd: root,
			encoding: 'utf8'
		}
	);
	return { ...result, out: (result.stdout || '') + (result.stderr || '') };
}

/** Exercises detection and byte preservation through the actual coverage path. */
function runCoverage({ fs: io = fs, runGuard = runGuardNative, root = ROOT } = {}) {
	const errors = [];
	const cleanExit = (result, expected) =>
		!result.error && !result.signal && result.status === expected;
	function callGuard() {
		const before = new Map(
			PREVIOUSLY_UNGUARDED.map((rel) => {
				const abs = path.join(root, rel);
				return [rel, io.existsSync(abs) ? io.readFileSync(abs) : undefined];
			})
		);
		let primaryFailure;
		try {
			return runGuard(root);
		} catch (error) {
			primaryFailure = error;
			throw error;
		} finally {
			// A faulty guard may damage a neighbor or a clean control. Snapshot
			// every covered target, not only the intentionally perturbed output.
			const recoveryFailures = [];
			for (const [rel, bytes] of before) {
				const abs = path.join(root, rel);
				let changed = true;
				try {
					const exists = io.existsSync(abs);
					changed = bytes === undefined ? exists : !exists || !io.readFileSync(abs).equals(bytes);
				} catch (error) {
					recoveryFailures.push(
						new Error(`${rel}: comparison failed: ${error.message}`, { cause: error })
					);
				}
				if (!changed) continue;
				errors.push(`${rel}: the guard did not preserve the exact edited bytes`);
				try {
					if (bytes === undefined) {
						if (io.existsSync(abs)) io.unlinkSync(abs);
					} else io.writeFileSync(abs, bytes);
				} catch (error) {
					recoveryFailures.push(
						new Error(`${rel}: restoration failed: ${error.message}`, { cause: error })
					);
				}
			}
			if (recoveryFailures.length > 0) {
				if (primaryFailure !== undefined) recoveryFailures.unshift(primaryFailure);
				throw new AggregateError(recoveryFailures, 'Drift coverage recovery failed');
			}
		}
	}
	const base = callGuard();
	if (!cleanExit(base, 0)) {
		return [...errors, 'The drift guard already fails before perturbation.', base.out || ''];
	}
	for (const rel of PREVIOUSLY_UNGUARDED) {
		const abs = path.join(root, rel);
		if (!io.existsSync(abs)) {
			errors.push(`${rel}: expected generated output is missing`);
			continue;
		}
		const original = io.readFileSync(abs);
		const marker = rel.endsWith('.toml') ? '#' : '--';
		const perturbed = Buffer.concat([
			original,
			Buffer.from(`\n${marker} drift-guard coverage probe\n`)
		]);
		let perturbationFailure;
		try {
			io.writeFileSync(abs, perturbed);
			const result = callGuard();
			const output = (result.out || '').replace(/\x1b\[[0-9;]*m/g, '');
			const reportsDrift =
				output.includes('[ERROR] generated output has drifted from its source:') &&
				output
					.split(/\r?\n/)
					.some((line) => line.startsWith(`  - ${rel} differs from what \`npm run gen\` produces`));
			if (!cleanExit(result, 1) || !reportsDrift) {
				errors.push(`${rel}: no valid, path-specific drift receipt\n${output}`);
			}
		} catch (error) {
			perturbationFailure = error;
			throw error;
		} finally {
			try {
				io.writeFileSync(abs, original);
			} catch (error) {
				const failures = [
					new Error(`${rel}: original restoration failed: ${error.message}`, { cause: error })
				];
				if (perturbationFailure !== undefined) failures.unshift(perturbationFailure);
				throw new AggregateError(failures, 'Drift perturbation recovery failed');
			}
		}
	}
	const final = callGuard();
	if (!cleanExit(final, 0)) errors.push('The drift guard did not return to green.');
	return errors;
}

/** Copies current source bytes and confines every perturbation to that copy. */
function runIsolatedCoverage({ files, probe = runCoverage } = {}) {
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-drift-coverage-'));
	let failure;
	try {
		const selected =
			files ||
			execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--'], {
				cwd: ROOT,
				encoding: 'utf8'
			})
				.split('\0')
				.filter(Boolean);
		for (const relative of new Set(selected)) {
			const source = path.resolve(ROOT, relative);
			const destination = path.resolve(temporary, relative);
			if (!source.startsWith(ROOT + path.sep) || !destination.startsWith(temporary + path.sep))
				throw new Error('Drift fixture path escapes its source or private tree');
			if (!fs.existsSync(source)) continue;
			fs.mkdirSync(path.dirname(destination), { recursive: true });
			fs.copyFileSync(source, destination);
		}
		fs.symlinkSync(
			path.join(ROOT, 'node_modules'),
			path.join(temporary, 'node_modules'),
			process.platform === 'win32' ? 'junction' : 'dir'
		);
		return probe({ root: temporary });
	} catch (error) {
		failure = error;
		throw error;
	} finally {
		try {
			fs.rmSync(temporary, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
		} catch (error) {
			if (failure) throw new AggregateError([failure, error], 'Drift fixture and cleanup failed');
			throw error;
		}
	}
}

module.exports = { runCoverage, runIsolatedCoverage };

if (require.main === module) {
	const errors = runIsolatedCoverage();
	if (errors.length > 0) {
		console.error('[ERROR] drift-guard coverage:');
		for (const error of errors) console.error('    - ' + error);
		process.exitCode = 1;
	} else {
		console.log(
			`[OK] The drift guard detects changes to all ${PREVIOUSLY_UNGUARDED.length} previously ` +
				'unguarded outputs and preserves their exact edited bytes.'
		);
	}
}
