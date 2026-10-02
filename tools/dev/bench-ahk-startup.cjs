// tools/dev/bench-ahk-startup.cjs

/**
 * ==============================================================================
 * MODULE: Isolated AutoHotkey Startup Benchmark
 * DESCRIPTION:
 * Runs the real entry under a unique wrapper and copies the chosen configuration
 * into a private temporary fixture for each sample. The live driver is preserved.
 * Prints startup timing lines only, never configuration or general log content.
 *
 * FEATURES & RATIONALE:
 * 1. Comparable workload: each launch uses the same configuration and the same
 *    startup-smoke path, including its intentional 650 ms message-pump fixture.
 * 2. No generated-code cache: the production entry resolves its ordinary shared
 *    caches, so a source edit invalidates them through their real owners.
 * 3. Private copies are deleted; measurements remain in stdout for archiving.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const {
	createStartupCodeFixture,
	prepareStartupPersonalInclude
} = require('../test/lib/ahk-startup-fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const WINDOWS = path.join(ROOT, 'static/ergopti_plus/windows');

async function main() {
	if (process.platform !== 'win32') throw new Error('This benchmark requires Windows.');
	const args = process.argv.slice(2);
	const configArg = args.find((arg) => arg.startsWith('--config-dir='));
	const samplesArg = args.find((arg) => arg.startsWith('--samples='));
	if (args.some((arg) => arg !== configArg && arg !== samplesArg))
		throw new Error('Usage: --config-dir=<existing configuration folder> [--samples=3]');
	if (!configArg) throw new Error('--config-dir is required; the live configuration is read only.');
	const configSource = path.resolve(configArg.slice('--config-dir='.length));
	if (!fs.statSync(configSource).isDirectory())
		throw new Error('The configuration folder is missing.');
	const samples = samplesArg ? Number(samplesArg.slice('--samples='.length)) : 3;
	if (!Number.isInteger(samples) || samples < 1 || samples > 100)
		throw new Error('--samples must be an integer from 1 to 100.');
	const ahk = process.env.ERGOPTI_AHK_EXE || 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
	if (!fs.existsSync(ahk)) throw new Error('AutoHotkey v2 is missing; set ERGOPTI_AHK_EXE.');
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-startup-benchmark-'));
	const code = createStartupCodeFixture(path.join(scratch, 'code'), WINDOWS);
	const wrapper = path.join(code.windows, `.ergopti_startup_benchmark_${process.pid}.ahk`);
	const results = [];
	try {
		fs.writeFileSync(wrapper, '\uFEFF#Requires AutoHotkey v2.0+\n#Include ErgoptiPlus.ahk\n');
		for (let sample = 0; sample < samples; sample++) {
			const fixture = path.join(scratch, String(sample));
			const config = path.join(fixture, 'config');
			fs.cpSync(configSource, config, {
				recursive: true,
				filter: (file) => !/[\\/](metrics|logs|cache)([\\/]|$)/.test(file)
			});
			fs.writeFileSync(
				path.join(fixture, 'paths.toml'),
				`ConfigDirPath = "${config.replace(/\\/g, '/')}"\n`
			);
			prepareStartupPersonalInclude(code.windows, config);
			const started = performance.now();
			const child = spawnSync(ahk, ['/ErrorStdOut', wrapper], {
				cwd: code.windows,
				windowsHide: true,
				encoding: 'utf8',
				timeout: 90000,
				env: { ...process.env, LOCALAPPDATA: fixture, ERGOPTI_STARTUP_SMOKE_DIR: fixture }
			});
			if (child.error || child.status !== 0)
				throw new Error(
					`Sample ${sample} failed (exit=${child.status}): ${child.error?.message || child.stderr || child.stdout}`
				);
			const logDir = path.join(fixture, 'ergopti_plus/logs');
			const lines = fs
				.readdirSync(logDir)
				.filter((name) => /^ErgoptiPlus_\d/.test(name))
				.flatMap((name) => fs.readFileSync(path.join(logDir, name), 'utf8').split(/\r?\n/));
			if (lines.some((line) => /\[(ERROR|FATAL)\]/.test(line)))
				throw new Error(
					`Sample ${sample} logged a startup error; it is not a performance success.`
				);
			const result = {
				sample,
				elapsed_ms: Math.round(performance.now() - started),
				smoke_pump_ms: 650,
				timing: lines.filter((line) => line.includes('[BootProfile]'))
			};
			results.push(result);
			console.log(JSON.stringify(result));
		}
		const times = results.map((result) => result.elapsed_ms).sort((a, b) => a - b);
		console.log(
			JSON.stringify({
				samples,
				median_ms:
					(times[Math.floor((times.length - 1) / 2)] + times[Math.floor(times.length / 2)]) / 2,
				max_ms: times[times.length - 1],
				min_ms: times[0]
			})
		);
	} finally {
		code.close();
		fs.rmSync(wrapper, { force: true });
		// Delete only the exact fresh mkdtemp tree owned by this invocation.
		if (
			path.dirname(path.resolve(scratch)) !== path.resolve(os.tmpdir()) ||
			!path.basename(scratch).startsWith('ergopti-startup-benchmark-')
		)
			throw new Error('Refusing cleanup outside the owned temporary fixture.');
		await new Promise((resolve) => setImmediate(resolve));
		await fs.promises.rm(scratch, {
			recursive: true,
			force: true,
			maxRetries: 12,
			retryDelay: 100
		});
	}
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
