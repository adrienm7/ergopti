// tools/test/test-macos-dev-bootstrap.cjs

/**
 * ==============================================================================
 * MODULE: macOS Development Bootstrap Path Regression
 * DESCRIPTION:
 * Runs the real installer from a minimal source tree, then executes both Lua
 * bootstraps against the actual selected driver path. Quoting is checked at the
 * shell-to-Lua boundary rather than by inspecting an escape spelling. Repeating
 * the install must refresh its own bootstrap without overwriting user backups.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const INSTALLER = path.join(ROOT, 'tools/dev/install-hammerspoon.sh');
const CONTROL_BYTES = String.fromCharCode(
	...Array.from({ length: 31 }, (_, index) => index + 1),
	127
);
const CASES = [
	['spaces and Unicode', 'Érgopti development'],
	['double quotes', 'Ergopti "development"'],
	['backslashes', 'Ergopti\\bootstrap'],
	['newlines', 'Ergopti\nbootstrap'],
	['control bytes followed by digits', `Ergopti${String.fromCharCode(1)}23 development`],
	['control bytes', `Ergopti${CONTROL_BYTES}bootstrap`]
];

/**
 * Executes a real child and reports its failure with its boundary output.
 * @param {string} executable Program to run.
 * @param {string[]} args Literal arguments.
 * @param {object} options Child options.
 * @returns {string} Standard output.
 */
function run(executable, args, options) {
	const result = spawnSync(executable, args, { encoding: 'utf8', timeout: 15000, ...options });
	assert.ifError(result.error);
	assert.equal(result.status, 0, `${executable} failed: ${result.stderr}\n${result.stdout}`);
	return result.stdout;
}

/**
 * Installs and executes both generated configurations inside owned fixtures.
 * @param {string} suffix Literal filesystem path component.
 * @returns {void}
 */
function checkPath(suffix) {
	const temporary = fs.realpathSync(
		fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dev-bootstrap-'))
	);
	try {
		const repository = path.join(temporary, `checkout ${suffix}`);
		const driver = path.join(repository, 'static/ergopti_plus/macos');
		const installer = path.join(repository, 'tools/dev/install-hammerspoon.sh');
		const home = path.join(temporary, `home ${suffix}`);
		const xdg = path.join(temporary, `xdg ${suffix}`);
		const bin = path.join(temporary, 'bin');
		fs.mkdirSync(driver, { recursive: true });
		fs.mkdirSync(path.dirname(installer), { recursive: true });
		fs.mkdirSync(bin);
		fs.copyFileSync(INSTALLER, installer);
		fs.writeFileSync(
			path.join(driver, 'init.lua'),
			'_G.BOOTSTRAP_DRIVER = debug.getinfo(1, "S").source:sub(2)\n'
		);
		// Installer side effects stay inside this fixture, including macOS defaults.
		for (const command of ['defaults', 'hs']) {
			fs.writeFileSync(path.join(bin, command), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
		}
		const env = {
			...process.env,
			HOME: home,
			XDG_CONFIG_HOME: xdg,
			PATH: `${bin}${path.delimiter}${process.env.PATH}`
		};
		const configurations = [
			path.join(home, '.hammerspoon/init.lua'),
			path.join(xdg, 'hammerspoon/init.lua')
		];
		for (const config of configurations) {
			fs.mkdirSync(path.dirname(config), { recursive: true });
			fs.writeFileSync(config, '-- Previous user configuration\n');
		}
		const probe = path.join(temporary, 'probe.lua');
		fs.writeFileSync(
			probe,
			[
				'local bindings = 0',
				'hs = { hotkey = { bind = function(_, key) assert(key == "R"); bindings = bindings + 1 end } }',
				'dofile(arg[1])',
				'assert(bindings == 1, "the generated bootstrap must register reload once")',
				'assert(BOOTSTRAP_DRIVER == arg[2], "the generated bootstrap must execute the exact driver path")',
				'print("BOOTSTRAP_READY")',
				''
			].join('\n')
		);
		let initialBackups;
		for (let attempt = 0; attempt < 2; attempt += 1) {
			run('bash', [installer], { env });
			const backups = [];
			for (const config of configurations) {
				assert.equal(
					run('lua', [probe, config, path.join(driver, 'init.lua')], { env }).trim(),
					'BOOTSTRAP_READY'
				);
				const names = fs
					.readdirSync(path.dirname(config))
					.filter((name) => name.startsWith('init.lua.backup.'));
				assert.equal(names.length, 1, 'only the original user configuration needs a backup');
				const backup = path.join(path.dirname(config), names[0]);
				assert.equal(fs.readFileSync(backup, 'utf8'), '-- Previous user configuration\n');
				backups.push(backup);
			}
			if (attempt === 0) initialBackups = backups;
			else
				assert.deepEqual(
					backups,
					initialBackups,
					'refreshing this bootstrap must preserve the original backup'
				);
		}
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}

const failures = [];
for (const [label, suffix] of CASES) {
	try {
		checkPath(suffix);
		console.log(`PASS macOS dev bootstrap preserves ${label}`);
	} catch (error) {
		failures.push(`${label}: ${error.message}`);
	}
}
assert.deepEqual(
	failures,
	[],
	'the real installer must emit executable Lua for every literal POSIX path'
);
