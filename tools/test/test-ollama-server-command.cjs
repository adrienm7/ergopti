// tools/test/test-ollama-server-command.cjs

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const SHARED_LUA_ROOT = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'lua');
const PORT = 45678;

function findBash() {
	const candidates = [];
	if (process.platform === 'win32') {
		const git = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
		if (git.status === 0 && git.stdout.trim()) {
			candidates.push(path.resolve(git.stdout.trim(), '..', '..', '..', 'bin', 'bash.exe'));
		}
		candidates.push('C:\\Program Files\\Git\\bin\\bash.exe');
	} else {
		candidates.push('/bin/bash', 'bash');
	}
	for (const candidate of candidates) {
		if (candidate === 'bash' || fs.existsSync(candidate)) return candidate;
	}
	throw new Error('bash is required for the Ollama daemon command regression');
}

function toBashPath(filePath) {
	if (process.platform !== 'win32') return filePath;
	const match = path.resolve(filePath).match(/^([A-Za-z]):[\\/](.*)$/);
	if (!match) throw new Error(`cannot convert path for Git Bash: ${filePath}`);
	return `/${match[1].toLowerCase()}/${match[2].replace(/\\/g, '/')}`;
}

function shellQuote(value) {
	return `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

function buildCommand(fakeBinary, logFile) {
	const moduleRoot = MACOS_ROOT.replace(/\\/g, '/');
	const sharedRoot = SHARED_LUA_ROOT.replace(/\\/g, '/');
	const source = [
		`package.path = ${JSON.stringify(`${moduleRoot}/?.lua;${moduleRoot}/?/init.lua;${sharedRoot}/?.lua;${sharedRoot}/?/init.lua;`)} .. package.path`,
		'local Builder = require("modules.llm.ollama_server_command")',
		`local command, detail = Builder.build(${JSON.stringify(fakeBinary)}, ${JSON.stringify(logFile)}, ${PORT})`,
		'if not command then io.stderr:write(tostring(detail)); os.exit(2) end',
		'io.write(command)',
	].join('; ');
	const result = spawnSync('lua', ['-e', source], {
		cwd: MACOS_ROOT,
		encoding: 'utf8',
	});
	assert.equal(result.status, 0, result.stderr || result.stdout);
	return result.stdout;
}

function readOnlyLog(logDir) {
	const names = fs.readdirSync(logDir).filter((name) => /^ErgoptiPlus_.*\.log$/.test(name));
	assert.equal(names.length, 1, `expected one dated log in ${logDir}`);
	return fs.readFileSync(path.join(logDir, names[0]), 'utf8');
}

const bash = findBash();
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ollama-command-'));

try {
	const fakeBinaryPath = path.join(temporaryRoot, 'fake ollama');
	fs.writeFileSync(fakeBinaryPath, [
		'#!/usr/bin/env bash',
		'if [[ "$1" != "serve" ]]; then exit 64; fi',
		'printf "first line\\nhost=%s" "$OLLAMA_HOST"',
		'',
	].join('\n'));
	const fakeBinary = toBashPath(fakeBinaryPath);
	const chmod = spawnSync(bash, ['-c', `chmod +x ${shellQuote(fakeBinary)}`], { encoding: 'utf8' });
	assert.equal(chmod.status, 0, chmod.stderr || chmod.stdout);

	const mutantDir = path.join(temporaryRoot, 'mutant');
	fs.mkdirSync(mutantDir);
	const mutantCommand = buildCommand(fakeBinary,
		`${toBashPath(mutantDir)}/ErgoptiPlus_launch.log`).replace(
		'while IFS= read -r LINE || [ -n "$LINE" ]; do',
		'while IFS= read -r LINE; do');
	const mutantRun = spawnSync(bash, ['-c', mutantCommand], { encoding: 'utf8' });
	assert.equal(mutantRun.status, 0, mutantRun.stderr || mutantRun.stdout);
	const mutantLog = readOnlyLog(mutantDir);
	assert.match(mutantLog, /first line/);
	assert.doesNotMatch(mutantLog, /host=/,
		'the behavioral harness must detect the original unterminated-tail loss');

	const fixedDir = path.join(temporaryRoot, 'fixed');
	fs.mkdirSync(fixedDir);
	const command = buildCommand(fakeBinary,
		`${toBashPath(fixedDir)}/ErgoptiPlus_launch.log`);
	assert.match(command, new RegExp(`OLLAMA_HOST=.*127\\.0\\.0\\.1:${PORT}`));
	const run = spawnSync(bash, ['-c', command], { encoding: 'utf8' });
	assert.equal(run.status, 0, run.stderr || run.stdout);
	const fixedLog = readOnlyLog(fixedDir);
	assert.match(fixedLog, /first line/);
	assert.match(fixedLog, new RegExp(`host=127\\.0\\.0\\.1:${PORT}`),
		'the final non-newline record and configured bind port must reach the dated log');

	console.log('ollama server command: ok');
} finally {
	fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
