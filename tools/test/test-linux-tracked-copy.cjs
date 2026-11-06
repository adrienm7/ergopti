// tools/test/test-linux-tracked-copy.cjs

/** Exercises the real bundle copy entry point and its smoke failure propagation. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable, bashPath } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tracked-copy-'));
const subject = fs.readFileSync(path.join(ROOT, 'tools/build/build-linux-driver.sh'), 'utf8');
const start = subject.indexOf('copy_tree() {');
const end = subject.indexOf('\nLINUX_SRC=', start);
assert.ok(start >= 0 && end > start, 'the real copy entry point must exist');

function git(...args) {
	const result = spawnSync('git', ['-C', scratch, ...args], { encoding: 'utf8' });
	assert.equal(result.status, 0, result.stderr);
}

try {
	if (process.platform === 'linux') {
		// Command substitution strips trailing newlines from pwd output. The
		// builder must still recognize and preserve the real checkout path.
		{
			const checkout = path.join(scratch, 'checkout-with-trailing-newline\n');
			const builder = path.join(checkout, 'tools/build/build-linux-driver.sh');
			const sentinel = path.join(checkout, 'keep');
			fs.mkdirSync(path.dirname(builder), { recursive: true });
			fs.writeFileSync(builder, subject);
			fs.writeFileSync(sentinel, 'user data\n');
			const result = spawnSync('/bin/bash', [builder, '--skip-smoke'], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: checkout }
			});
			assert.notEqual(result.status, 0);
			assert.equal(fs.readFileSync(sentinel, 'utf8'), 'user data\n');
			const output = path.join(checkout, 'build/linux');
			const permitted = spawnSync('/bin/bash', [builder, '--skip-smoke'], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: output }
			});
			assert.notEqual(permitted.status, 0, 'the fake checkout has no source copier');
			assert.ok(permitted.stdout.includes(`Source  : ${checkout}/static/ergopti_plus/linux`));
			assert.ok(fs.existsSync(output), 'the ordinary output below build remains allowed');
			for (const filename of [
				'build-linux-deb.sh',
				'build-linux-rpm.sh',
				'build-linux-appimage.sh',
				'build-linux-flatpak.sh',
				'build-linux-bundle-archive.sh',
				'build-linux-native-output.sh',
				'build-proxy-relay.sh',
				'write_build_stamp.sh'
			]) {
				const lines = fs.readFileSync(path.join(ROOT, 'tools/build', filename), 'utf8').split('\n');
				const position = lines.findIndex((line) => line.startsWith('SCRIPT_DIR='));
				assert.ok(position >= 0, `${filename} has a script root`);
				const rootLine = lines[position + 1];
				const variable = rootLine.includes('PROJECT_ROOT') ? 'PROJECT_ROOT' : 'REPO_ROOT';
				assert.ok(rootLine.includes(variable), `${filename} has a checkout root`);
				const probe = path.join(checkout, 'tools/build', `probe-${filename}`);
				fs.writeFileSync(probe, `${lines[position]}\n${rootLine}\nprintf '%s\\0' "$${variable}"\n`);
				const resolved = spawnSync('/bin/bash', [probe], { encoding: 'utf8', timeout: 10000 });
				assert.equal(resolved.status, 0, resolved.stderr);
				assert.equal(resolved.stdout, `${checkout}\0`, `${filename} preserves the root bytes`);
			}
		}
		// An output selector that names the checkout, its ancestor, or its source
		// tree must never authorize deleting that data.
		for (const kind of ['checkout', 'ancestor', 'source', 'alias']) {
			const parent = path.join(scratch, `builder-guard-${kind}`);
			const checkout = path.join(parent, 'checkout');
			const builder = path.join(checkout, 'tools/build/build-linux-driver.sh');
			fs.mkdirSync(path.dirname(builder), { recursive: true });
			fs.writeFileSync(builder, subject);
			const target =
				kind === 'checkout'
					? checkout
					: kind === 'ancestor'
						? parent
						: kind === 'alias'
							? path.join(parent, 'alias')
							: path.join(checkout, 'static');
			if (kind === 'alias') fs.symlinkSync(checkout, target);
			fs.mkdirSync(target, { recursive: true });
			const sentinel = path.join(target, 'preserve-user-file');
			fs.writeFileSync(sentinel, 'keep\n');
			const result = spawnSync('/bin/bash', [builder, '--skip-smoke'], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: target }
			});
			assert.notEqual(result.status, 0, `${kind} must be refused`);
			assert.equal(fs.readFileSync(sentinel, 'utf8'), 'keep\n', `${kind} must remain intact`);
		}
		for (const nested of [false, true]) {
			const parent = path.join(scratch, `sibling-guard-${nested}`);
			const checkout = path.join(parent, 'builder-checkout');
			const sibling = path.join(parent, 'other-checkout');
			const builder = path.join(checkout, 'tools/build/build-linux-driver.sh');
			fs.mkdirSync(path.dirname(builder), { recursive: true });
			fs.writeFileSync(builder, subject);
			fs.mkdirSync(sibling);
			const initialized = spawnSync('git', ['init', '--quiet', sibling], { encoding: 'utf8' });
			assert.equal(initialized.status, 0, initialized.stderr);
			const target = nested ? path.join(sibling, 'source') : sibling;
			fs.mkdirSync(target, { recursive: true });
			const sentinel = path.join(target, 'keep');
			fs.writeFileSync(sentinel, 'other checkout\n');
			const result = spawnSync('/bin/bash', [builder, '--skip-smoke'], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: target }
			});
			assert.notEqual(result.status, 0);
			assert.equal(fs.readFileSync(sentinel, 'utf8'), 'other checkout\n');
		}
		for (const markerKind of ['directory', 'file']) {
			const parent = path.join(scratch, `unavailable-git-${markerKind}`);
			const checkout = path.join(parent, 'builder-checkout');
			const sibling = path.join(parent, 'other-checkout');
			const builder = path.join(checkout, 'tools/build/build-linux-driver.sh');
			const target = path.join(sibling, 'source');
			const bin = path.join(parent, 'bin');
			fs.mkdirSync(path.dirname(builder), { recursive: true });
			fs.writeFileSync(builder, subject);
			fs.mkdirSync(target, { recursive: true });
			if (markerKind === 'directory') fs.mkdirSync(path.join(sibling, '.git'));
			else fs.writeFileSync(path.join(sibling, '.git'), 'gitdir: elsewhere\n');
			fs.mkdirSync(bin);
			fs.writeFileSync(path.join(bin, 'git'), '#!/bin/sh\nexit 128\n', { mode: 0o755 });
			const sentinel = path.join(target, 'keep');
			fs.writeFileSync(sentinel, 'other checkout\n');
			const result = spawnSync('/bin/bash', [builder, '--skip-smoke'], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, PATH: `${bin}:/usr/bin:/bin`, ERGOPTI_LINUX_BUILD_DIR: target }
			});
			assert.notEqual(result.status, 0);
			assert.equal(fs.readFileSync(sentinel, 'utf8'), 'other checkout\n');
		}
		for (const kind of ['own-source', 'shared-build', 'other-checkout', 'other-alias']) {
			const parent = path.join(scratch, `missing-output-${kind}`);
			const checkout = path.join(parent, 'builder-checkout');
			const builder = path.join(checkout, 'tools/build/build-linux-driver.sh');
			fs.mkdirSync(path.dirname(builder), { recursive: true });
			fs.writeFileSync(builder, subject);
			const sibling = path.join(parent, 'other-checkout');
			if (kind === 'other-checkout' || kind === 'other-alias') {
				fs.mkdirSync(sibling);
				const initialized = spawnSync('git', ['init', '--quiet', sibling], { encoding: 'utf8' });
				assert.equal(initialized.status, 0, initialized.stderr);
				if (kind === 'other-alias') fs.symlinkSync(sibling, path.join(parent, 'alias'));
			}
			const target =
				kind === 'own-source'
					? path.join(checkout, 'static/new')
					: kind === 'shared-build'
						? path.join(checkout, 'build') + '/'
						: path.join(kind === 'other-alias' ? path.join(parent, 'alias') : sibling, 'new');
			const result = spawnSync('/bin/bash', [builder, '--skip-smoke'], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: target }
			});
			assert.notEqual(result.status, 0);
			assert.equal(fs.existsSync(target), false, `${kind} must not gain an output directory`);
		}
		// A new child of the checkout's build directory remains an allowed
		// output. This fixture has no sources, so the later copy must still fail.
		{
			const checkout = path.join(scratch, 'allowed-new-output');
			const builder = path.join(checkout, 'tools/build/build-linux-driver.sh');
			const target = path.join(checkout, 'build/linux');
			fs.mkdirSync(path.dirname(builder), { recursive: true });
			fs.writeFileSync(builder, subject);
			const result = spawnSync('/bin/bash', [builder, '--skip-smoke'], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: target }
			});
			assert.notEqual(result.status, 0);
			assert.ok(fs.existsSync(target), 'the guard must admit a new build output');
		}
	}
	git('init', '--quiet');
	const names = ['space name.txt', 'caf\u00e9.txt', '-leading.txt'];
	for (let index = 0; index < 120; index++) names.push(`nested/part-${index}.bin`);
	for (const name of [...names, 'corpus/excluded.txt', 'vendor/excluded.txt']) {
		const filename = path.join(scratch, 'source', name);
		fs.mkdirSync(path.dirname(filename), { recursive: true });
		fs.writeFileSync(filename, Buffer.from(`payload\0${name}\n`, 'utf8'));
	}
	git('add', '--', 'source');
	fs.writeFileSync(path.join(scratch, 'source', 'private-cache.json'), 'private runtime data');
	// Copies must use live tracked bytes, including a not-yet-committed edit.
	fs.writeFileSync(path.join(scratch, 'source', names[0]), 'changed working bytes');
	const stamp = new Date('2024-01-02T03:04:05Z');
	fs.utimesSync(path.join(scratch, 'source', names[0]), stamp, stamp);
	fs.chmodSync(path.join(scratch, 'source', names[1]), 0o755);
	const script =
		'set -euo pipefail\nREPO_ROOT="$1"\nSCRIPT_DIR="$2"\n' +
		subject.slice(start, end) +
		'\ncopy_tree "${REPO_ROOT}/source/" "${REPO_ROOT}/output/" --exclude corpus --exclude vendor\n';
	const began = performance.now();
	const result = spawnSync(
		bashExecutable(),
		['-x', '-s', '--', bashPath(scratch), bashPath(path.join(ROOT, 'tools/build'))],
		{
			input: script,
			encoding: 'utf8',
			timeout: 60000
		}
	);
	const elapsed = performance.now() - began;
	assert.equal(result.status, 0, result.stderr || result.error?.message);
	const actual = fs
		.readdirSync(path.join(scratch, 'output'), { recursive: true })
		.filter((name) => fs.lstatSync(path.join(scratch, 'output', name)).isFile())
		.map((name) => name.replaceAll('\\', '/'))
		.sort();
	assert.deepEqual(actual, [...names].sort(), 'only tracked, non-excluded files may ship');
	for (const name of names) {
		assert.deepEqual(
			fs.readFileSync(path.join(scratch, 'output', name)),
			fs.readFileSync(path.join(scratch, 'source', name)),
			`copy bytes differ: ${name}`
		);
	}
	assert.equal(fs.statSync(path.join(scratch, 'output', names[0])).mtimeMs, stamp.getTime());
	if (process.platform !== 'win32') {
		assert.equal(fs.statSync(path.join(scratch, 'output', names[1])).mode & 0o777, 0o755);
	}
	const perFileProcesses = (result.stderr.match(/^\++ (?:dirname|mkdir|cp) /gm) || []).length;
	console.log(
		`tracked copy: ${names.length} files, ${elapsed.toFixed(1)} ms, ${perFileProcesses} per-file shell processes`
	);
	assert.equal(perFileProcesses, 0, 'tracked-copy-perf: copying must not spawn a process per file');
	const helper = path.join(ROOT, 'tools/build/copy-tracked-tree.cjs');
	const escaped = spawnSync(
		process.execPath,
		[helper, scratch, path.dirname(scratch), path.join(scratch, 'escaped')],
		{ encoding: 'utf8' }
	);
	assert.notEqual(escaped.status, 0, 'an out-of-repository source must fail');
	assert.match(escaped.stderr, /not strictly inside/);
	assert.equal(fs.existsSync(path.join(scratch, 'escaped')), false);
	// A caller that owns its build directory may copy outside the repository, and only there.
	const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-owned-build-'));
	try {
		const refused = spawnSync(
			process.execPath,
			[helper, scratch, path.join(scratch, 'source'), path.join(owned, 'out')],
			{ encoding: 'utf8' }
		);
		assert.notEqual(refused.status, 0, 'a destination outside the repository needs an owner');
		const accepted = spawnSync(
			process.execPath,
			[
				helper,
				scratch,
				path.join(scratch, 'source'),
				path.join(owned, 'out'),
				'--exclude',
				'corpus'
			],
			{ encoding: 'utf8', env: { ...process.env, ERGOPTI_COPY_DESTINATION_ROOT: owned } }
		);
		assert.equal(accepted.status, 0, accepted.stderr);
		const stray = spawnSync(
			process.execPath,
			[helper, scratch, path.join(scratch, 'source'), path.join(scratch, 'stray-output')],
			{ encoding: 'utf8', env: { ...process.env, ERGOPTI_COPY_DESTINATION_ROOT: owned } }
		);
		assert.notEqual(stray.status, 0, 'the owner replaces the repository as the allowed tree');
		assert.equal(fs.existsSync(path.join(scratch, 'stray-output')), false);
	} finally {
		fs.rmSync(owned, { recursive: true, force: true });
	}
	const absent = spawnSync(
		process.execPath,
		[helper, scratch, path.join(scratch, 'empty'), path.join(scratch, 'empty-output')],
		{ encoding: 'utf8' }
	);
	assert.notEqual(absent.status, 0, 'empty inventories must not report a successful copy');
	assert.match(absent.stderr, /No tracked files/);
	if (process.platform === 'linux') {
		const sourceDirectory = path.join(scratch, 'source/private-parent');
		const savedDirectory = path.join(scratch, 'saved-parent');
		const foreignDirectory = path.join(scratch, 'foreign-parent');
		fs.mkdirSync(sourceDirectory);
		fs.mkdirSync(foreignDirectory);
		fs.writeFileSync(path.join(sourceDirectory, 'tracked.txt'), 'tracked source\n');
		fs.writeFileSync(path.join(foreignDirectory, 'tracked.txt'), 'private user data\n');
		git('add', '--', 'source/private-parent/tracked.txt');
		fs.renameSync(sourceDirectory, savedDirectory);
		fs.symlinkSync(foreignDirectory, sourceDirectory);
		try {
			const output = path.join(scratch, 'source-alias-output');
			const copied = spawnSync(
				process.execPath,
				[helper, scratch, path.join(scratch, 'source'), output],
				{ encoding: 'utf8' }
			);
			assert.notEqual(copied.status, 0, 'a source directory replaced by a symlink must be refused');
			assert.equal(fs.existsSync(path.join(output, 'private-parent/tracked.txt')), false);
		} finally {
			fs.unlinkSync(sourceDirectory);
			fs.renameSync(savedDirectory, sourceDirectory);
			git('reset', '--', 'source/private-parent/tracked.txt');
		}
	}
	if (process.platform !== 'win32') {
		fs.symlinkSync(names[0], path.join(scratch, 'source', 'relative-link'));
		git('add', '--', 'source/relative-link');
		const linked = spawnSync(
			process.execPath,
			[
				helper,
				scratch,
				path.join(scratch, 'source'),
				path.join(scratch, 'linked-output'),
				'--exclude',
				'corpus',
				'--exclude',
				'vendor'
			],
			{ encoding: 'utf8' }
		);
		assert.equal(linked.status, 0, linked.stderr);
		assert.equal(fs.readlinkSync(path.join(scratch, 'linked-output', 'relative-link')), names[0]);
	}
	// Execute the complete production smoke block. A failed shared require used
	// to print FAIL, then report a successful assembly and return zero.
	const smokeStart = subject.indexOf('if [ "$SKIP_SMOKE" = true ]; then');
	assert.ok(smokeStart >= 0, 'the production smoke entry point must exist');
	const smokeBin = path.join(scratch, 'smoke-bin');
	fs.mkdirSync(smokeBin);
	const runtime = path.join(smokeBin, 'luajit');
	fs.writeFileSync(path.join(smokeBin, 'uname'), '#!/bin/sh\nprintf "Linux\\n"\n', {
		mode: 0o755
	});
	fs.writeFileSync(
		runtime,
		'#!/bin/sh\nprintf "%s\\n" "$*" >> "$SMOKE_CALLS"\n' +
			'case "$*" in *"\'keycodes.evdev\'"*) [ "$SMOKE_FAILURE" != shared ] ;; *) exit 0 ;; esac\n',
		{ mode: 0o755 }
	);
	fs.mkdirSync(path.join(scratch, 'linux'), { recursive: true });
	const smokeCalls = path.join(scratch, 'smoke-calls');
	function smoke(failure, skip = false) {
		fs.writeFileSync(smokeCalls, '');
		return spawnSync(
			bashExecutable(),
			['-s', '--', String(skip), bashPath(scratch), bashPath(smokeBin)],
			{
				input:
					'set -euo pipefail\nPATH="$3"\nSKIP_SMOKE="$1"\nBUILD_DIR="$2"\n' +
					subject.slice(smokeStart),
				encoding: 'utf8',
				timeout: 15000,
				env: {
					...process.env,
					PATH: bashPath(smokeBin),
					SMOKE_FAILURE: failure,
					SMOKE_CALLS: bashPath(smokeCalls)
				}
			}
		);
	}
	const sharedFailure = smoke('shared');
	assert.equal(
		sharedFailure.status,
		1,
		'package-smoke-shared-failure: shared module refusal must fail assembly'
	);
	assert.match(sharedFailure.stdout, /require\('keycodes\.evdev'\) failed/);
	assert.doesNotMatch(sharedFailure.stdout, /assembled successfully/);
	assert.match(fs.readFileSync(smokeCalls, 'utf8'), /pcall\(require, 'keycodes\.evdev'\)/);
	const successfulSmoke = smoke('none');
	assert.equal(successfulSmoke.status, 0, successfulSmoke.stderr);
	assert.match(successfulSmoke.stdout, /all [1-9][0-9]* shared modules load/);
	assert.match(successfulSmoke.stdout, /assembled successfully/);
	fs.unlinkSync(runtime);
	const unavailable = smoke('none');
	assert.equal(
		unavailable.status,
		1,
		'package-smoke-runtime-absent: missing runtime must fail unless explicitly skipped'
	);
	assert.match(unavailable.stderr, /No Lua runtime found/);
	assert.doesNotMatch(unavailable.stdout, /assembled successfully/);
	const skipped = smoke('none', true);
	assert.equal(skipped.status, 0, skipped.stderr);
	assert.match(skipped.stdout, /Smoke test SKIPPED/);
	assert.equal(fs.readFileSync(smokeCalls, 'utf8'), '', 'an explicit skip runs no runtime');
	// The builder executes native module probes only on Linux. Pass paths with
	// Lua lexical delimiters through its real helper and require a staged file.
	if (process.platform === 'linux') {
		const helperStart = subject.indexOf('\t_lua_with_path() {');
		const helperEnd = subject.indexOf('\n\t# Test 1:', helperStart);
		assert.ok(helperStart >= 0 && helperEnd > helperStart, 'the production Lua probe must exist');
		const realLua = spawnSync(
			bashExecutable(),
			['-c', 'command -v luajit || command -v lua5.4 || command -v lua'],
			{ encoding: 'utf8' }
		);
		assert.equal(realLua.status, 0, 'a Lua smoke runtime is required');
		const helpRoot = path.join(scratch, 'help;source?');
		fs.mkdirSync(helpRoot);
		fs.symlinkSync(path.join(ROOT, 'static/ergopti_plus/linux'), path.join(helpRoot, 'linux'));
		fs.symlinkSync(path.join(ROOT, 'static/ergopti_plus/_shared'), path.join(helpRoot, '_shared'));
		const helpStart = subject.indexOf('\t# Test 1: --help must exit 0');
		const helpEnd = subject.indexOf('\n\t# On real Linux', helpStart);
		assert.ok(helpStart >= 0 && helpEnd > helpStart);
		const help = spawnSync(bashExecutable(), ['-s', '--', helpRoot, realLua.stdout.trim()], {
			input:
				'set -euo pipefail\nLUA_BIN="$2"\nBUILD_DIR="$1"\n' + subject.slice(helpStart, helpEnd),
			encoding: 'utf8',
			timeout: 15000,
			env: { ...process.env, HOME: scratch }
		});
		assert.equal(
			help.status,
			0,
			`help smoke with Lua path delimiters: ${help.stderr || help.stdout}`
		);
		const relativeBin = path.join(scratch, 'relative-bin');
		fs.mkdirSync(relativeBin);
		fs.symlinkSync(realLua.stdout.trim(), path.join(relativeBin, 'lua'));
		const relativeHelp = spawnSync(bashExecutable(), ['-s', '--', helpRoot], {
			input: 'set -euo pipefail\nLUA_BIN=lua\nBUILD_DIR="$1"\n' + subject.slice(helpStart, helpEnd),
			encoding: 'utf8',
			timeout: 15000,
			cwd: scratch,
			env: { ...process.env, HOME: scratch, PATH: 'relative-bin:/usr/bin:/bin' }
		});
		assert.equal(
			relativeHelp.status,
			0,
			`help smoke with relative PATH: ${relativeHelp.stderr || relativeHelp.stdout}`
		);

		for (const name of [
			"bundle's source",
			'bundle\\source',
			'bundle\nsource',
			'bundle;source',
			'bundle?source'
		]) {
			const buildRoot = path.join(scratch, name);
			const moduleFile = path.join(buildRoot, '_shared/lua/packaging_path_probe.lua');
			fs.mkdirSync(path.dirname(moduleFile), { recursive: true });
			fs.writeFileSync(moduleFile, 'return "exact staged bytes"\n');
			const checked = spawnSync(bashExecutable(), ['-s', '--', buildRoot], {
				input:
					'set -euo pipefail\nLUA_BIN=lua\nBUILD_DIR_FWD="$1"\n' +
					subject.slice(helperStart, helperEnd) +
					"\n_lua_with_path \"assert(require('packaging_path_probe') == 'exact staged bytes'); print('staged module loaded')\"\n",
				encoding: 'utf8',
				timeout: 15000,
				cwd: scratch,
				env: { ...process.env, PATH: 'relative-bin:/usr/bin:/bin' }
			});
			assert.equal(
				checked.status,
				0,
				`package-smoke-literal-path ${JSON.stringify(name)}: ${checked.stderr || checked.stdout}`
			);
			assert.equal(checked.stdout.trim(), 'staged module loaded');
		}
	}
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
