// tools/test/lib/portable-c-compiler.cjs

/** Resolves strict portable C builds without changing native production artifacts. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

/** Requires a real successful child; missing tools and signals remain failures. */
function successful(command, args, options, spawn = spawnSync) {
	const result = spawn(command, args, { ...options, timeout: 30000 });
	if (result.error) throw result.error;
	assert.equal(result.signal, null, `${command} terminated by ${result.signal}.`);
	assert.equal(result.status, 0, `${command} exited with ${result.status}.`);
	return result;
}

/** Resolves the installed x64 MSVC environment using the native builder's discovery contract. */
function windowsCompiler(env, spawn, exists) {
	const installer = ['ProgramFiles(x86)', 'ProgramFiles']
		.filter((name) => env[name])
		.map((name) => path.win32.join(env[name], 'Microsoft Visual Studio/Installer/vswhere.exe'))
		.find(exists);
	assert.ok(installer, 'MSVC discovery requires the installed Visual Studio vswhere.exe.');
	const found = successful(
		installer,
		[
			'-latest',
			'-utf8',
			'-products',
			'*',
			'-requires',
			'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
			'-property',
			'installationPath'
		],
		{ encoding: 'utf8', env, windowsHide: true },
		spawn
	)
		.stdout.trim()
		.split(/\r?\n/)
		.filter(Boolean);
	assert.equal(found.length, 1, 'MSVC discovery must return exactly one installation.');
	const setup = path.win32.join(found[0], 'VC/Auxiliary/Build/vcvars64.bat');
	assert.ok(exists(setup), 'The installed MSVC x64 environment script is missing.');
	// Only this discovered system script is shell syntax; explicit CC and sources never are.
	assert.ok(
		path.win32.isAbsolute(setup) && !/["%!\r\n\0]/.test(setup),
		'MSVC environment script path is not a closed shell argument.'
	);
	const command = env.ComSpec;
	assert.ok(
		typeof command === 'string' && path.win32.isAbsolute(command) && exists(command),
		'MSVC environment requires the actual system command interpreter.'
	);
	const output = successful(
		command,
		['/d', '/u', '/s', '/c', `""${setup}" >nul && set"`],
		{ encoding: 'utf16le', env, windowsHide: true, windowsVerbatimArguments: true },
		spawn
	).stdout;
	const prepared = { ...env };
	for (const line of output.split(/\r?\n/)) {
		const match = /^([^=]+)=(.*)$/.exec(line);
		if (match) {
			for (const key of Object.keys(prepared))
				if (key.toLowerCase() === match[1].toLowerCase()) delete prepared[key];
			prepared[match[1]] = match[2];
		}
	}
	assert.ok(
		prepared.INCLUDE && prepared.LIB && prepared.VCToolsInstallDir,
		'MSVC environment did not publish its include, library and compiler roots.'
	);
	const compiler = path.win32.join(prepared.VCToolsInstallDir, 'bin/Hostx64/x64/cl.exe');
	assert.ok(exists(compiler), 'The installed x64 MSVC compiler is missing.');
	return { command: compiler, kind: 'msvc', env: prepared };
}

/** Keeps an explicit compiler executable literal; only an absent Windows CC selects MSVC. */
function resolveCompiler({
	platform = process.platform,
	env = process.env,
	spawn = spawnSync,
	exists = fs.existsSync
} = {}) {
	if (env.CC !== undefined && env.CC !== '') {
		assert.equal(typeof env.CC, 'string', 'CC must be one literal executable path.');
		assert.ok(!/[\r\n\0]/.test(env.CC), 'CC must be one literal executable path.');
		const kind = /^(?:cl|cl\.exe)$/i.test(path.win32.basename(env.CC)) ? 'msvc' : 'gnu';
		if (kind === 'msvc')
			assert.ok(
				env.INCLUDE && env.LIB,
				'An explicit MSVC CC requires its provisioned environment.'
			);
		return { command: env.CC, kind, env };
	}
	if (platform === 'win32') return windowsCompiler(env, spawn, exists);
	return { command: 'cc', kind: 'gnu', env };
}

/** Compiles the unchanged C sources into the caller's owned temporary directory. */
function compilePortable({ sources, binary, sanitize, cwd }, ports = {}) {
	const compiler = resolveCompiler(ports);
	const spawn = ports.spawn || spawnSync;
	if (compiler.kind === 'msvc')
		assert.ok(
			!Object.entries(compiler.env).some(
				([name, value]) =>
					['cl', '_cl_'].includes(name.toLowerCase()) && value !== undefined && value !== ''
			),
			'MSVC implicit flags must not override the strict assertion contract.'
		);
	const flags =
		compiler.kind === 'msvc'
			? [
					'/nologo',
					'/TC',
					'/std:c11',
					'/W4',
					'/WX',
					'/O2',
					'/UNDEBUG',
					`/Fo${path.dirname(binary)}${path.sep}`,
					...sources,
					`/Fe${binary}`
				]
			: [
					'-std=c11',
					'-Wall',
					'-Wextra',
					'-Werror',
					'-pedantic',
					'-UNDEBUG',
					...(sanitize ? ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] : []),
					...sources,
					'-o',
					binary
				];
	if (compiler.kind === 'msvc')
		assert.equal(
			sanitize,
			false,
			'MSVC cannot provide the requested address+undefined sanitizer pair.'
		);
	else
		successful(
			compiler.command,
			['--version'],
			{ cwd, env: compiler.env, stdio: 'inherit', windowsHide: true },
			spawn
		);
	successful(
		compiler.command,
		flags,
		{ cwd: path.dirname(binary), env: compiler.env, stdio: 'inherit', windowsHide: true },
		spawn
	);
}

module.exports = { compilePortable, resolveCompiler };
