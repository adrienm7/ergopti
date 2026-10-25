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
const { bashExecutable } = require('../lib/git-bash.cjs');

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
			run(bashExecutable(), [installer], { env });
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

/**
 * Preserves every replaced configuration across rapid distinct-clone installs.
 * @returns {void}
 */
function checkBackupCollisions() {
	const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dev-backups-')));
	try {
		const bin = path.join(temporary, 'bin');
		const home = path.join(temporary, 'home');
		const xdg = path.join(temporary, 'xdg');
		fs.mkdirSync(bin);
		for (const command of ['defaults', 'hs']) {
			fs.writeFileSync(path.join(bin, command), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
		}
		// A fixed second reproduces two legitimate rapid installs without a clock race.
		fs.writeFileSync(path.join(bin, 'date'), '#!/bin/sh\nprintf "20000101T000000Z\\n"\n', {
			mode: 0o755
		});
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
		const original = '-- My original Hammerspoon configuration\n';
		for (const config of configurations) {
			fs.mkdirSync(path.dirname(config), { recursive: true });
			fs.writeFileSync(config, original);
		}
		const expected = [original];
		for (const [index, clone] of ['first', 'second', 'second'].entries()) {
			const repository = path.join(temporary, clone);
			const installer = path.join(repository, 'tools/dev/install-hammerspoon.sh');
			const driver = path.join(repository, 'static/ergopti_plus/macos/init.lua');
			fs.mkdirSync(path.dirname(installer), { recursive: true });
			fs.mkdirSync(path.dirname(driver), { recursive: true });
			fs.copyFileSync(INSTALLER, installer);
			fs.writeFileSync(driver, '-- Driver fixture\n');
			if (index === 1) expected.push(fs.readFileSync(configurations[0], 'utf8'));
			run(bashExecutable(), [installer], { env });
			for (const config of configurations) {
				const backups = fs
					.readdirSync(path.dirname(config))
					.filter((name) => name.startsWith('init.lua.backup.'));
				const contents = backups.map((name) =>
					fs.readFileSync(path.join(path.dirname(config), name), 'utf8')
				);
				assert.equal(
					contents.includes(original),
					true,
					'the original user configuration must remain recoverable after another clone installs'
				);
				assert.equal(
					backups.length,
					expected.length,
					'each displaced configuration must keep its own backup within the same second'
				);
				assert.deepEqual(
					contents.sort(),
					[...expected].sort(),
					'neither the original user configuration nor the first bootstrap may be overwritten'
				);
			}
		}
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}

/**
 * Refuses native backup failures before refreshing either configuration.
 * @param {string} operation Native operation whose failure is injected.
 * @returns {void}
 */
function checkBackupFailure(operation) {
	const temporary = fs.realpathSync(
		fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dev-backup-refusal-'))
	);
	try {
		const bin = path.join(temporary, 'bin');
		const home = path.join(temporary, 'home');
		const xdg = path.join(temporary, 'xdg');
		const installer = path.join(temporary, 'tools/dev/install-hammerspoon.sh');
		const driver = path.join(temporary, 'static/ergopti_plus/macos/init.lua');
		const journal = path.join(temporary, 'commands.log');
		fs.mkdirSync(bin);
		fs.mkdirSync(path.dirname(installer), { recursive: true });
		fs.mkdirSync(path.dirname(driver), { recursive: true });
		fs.copyFileSync(INSTALLER, installer);
		fs.writeFileSync(driver, '-- Driver fixture\n');
		for (const command of ['defaults', 'hs', 'mv', ...(operation === 'mktemp' ? ['mktemp'] : [])]) {
			const refusal = command === 'mv' || command === 'mktemp';
			fs.writeFileSync(
				path.join(bin, command),
				[
					'#!/bin/sh',
					`printf '%s\\n' '${command}' >> "$BOOTSTRAP_COMMAND_LOG"`,
					...(refusal ? [`printf '%s\\n' 'fixture-refused-${command}' >&2`] : []),
					`exit ${refusal ? 55 : 0}`,
					''
				].join('\n'),
				{ mode: 0o755 }
			);
		}
		const env = {
			...process.env,
			HOME: home,
			XDG_CONFIG_HOME: xdg,
			PATH: `${bin}${path.delimiter}${process.env.PATH}`,
			BOOTSTRAP_COMMAND_LOG: journal
		};
		const configurations = [
			path.join(home, '.hammerspoon/init.lua'),
			path.join(xdg, 'hammerspoon/init.lua')
		];
		for (const config of configurations) {
			fs.mkdirSync(path.dirname(config), { recursive: true });
			fs.writeFileSync(config, '-- Original configuration\n');
			fs.writeFileSync(`${config}.backup.user-owned`, '-- Earlier user backup\n');
		}
		const result = spawnSync(bashExecutable(), [installer], {
			env,
			encoding: 'utf8',
			timeout: 15000
		});
		assert.ifError(result.error);
		assert.equal(
			result.signal,
			null,
			'the installer must report a native refusal rather than time out'
		);
		assert.notEqual(result.status, 0, 'a refused backup cannot report installation success');
		assert(
			result.stderr.includes(`fixture-refused-${operation}`),
			'the intended native refusal must be reached'
		);
		assert.deepEqual(
			fs.readFileSync(journal, 'utf8').trim().split('\n'),
			[operation],
			'backup refusal must not move after allocation failure or normalize defaults and reload'
		);
		for (const config of configurations) {
			assert.equal(
				fs.readFileSync(config, 'utf8'),
				'-- Original configuration\n',
				'both original initialization files must remain intact before any refresh'
			);
			assert.equal(
				fs.readFileSync(`${config}.backup.user-owned`, 'utf8'),
				'-- Earlier user backup\n'
			);
			assert.deepEqual(
				fs.readdirSync(path.dirname(config)).sort(),
				['init.lua', 'init.lua.backup.user-owned'],
				'only the exact owned placeholder may be cleaned after refusal'
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
try {
	checkBackupCollisions();
	console.log('PASS macOS dev bootstrap preserves distinct backups within one second');
} catch (error) {
	failures.push(`same-second backups: ${error.message}`);
}
for (const operation of ['mktemp', 'mv']) {
	try {
		checkBackupFailure(operation);
		console.log(`PASS macOS dev bootstrap preserves originals after ${operation} refusal`);
	} catch (error) {
		failures.push(`${operation} refusal: ${error.message}`);
	}
}
assert.deepEqual(
	failures,
	[],
	'the real installer must preserve executable bootstraps and displaced user configurations'
);
