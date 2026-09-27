// tools/test/test-ci-kana-install.cjs

/**
 * ==============================================================================
 * MODULE: CI Kana Installer Safety Gate
 * DESCRIPTION:
 * Runs the actual installer entry point with each runner prerequisite missing.
 * Add-Type is replaced by a throwing boundary, so even a broken guard cannot
 * install a layout on the developer's machine. Separately compiles the native
 * owner without constructing it, catching C# errors before spending a CI run.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const helper = path.resolve(__dirname, 'install-ci-kana-layout.ps1');
const source = fs.readFileSync(helper, 'utf8');
const native = source.match(/Add-Type -TypeDefinition @'\r?\n([\s\S]*?)\r?\n'@/);
assert.ok(native, 'the installer must declare its native job owner');
if (process.platform !== 'win32') {
	console.log('[SKIP] native Kana installer guard execution requires Windows.');
	process.exit(0);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-kana-guard-'));
try {
	const script = path.join(scratch, 'guard.ps1');
	fs.writeFileSync(script, `$ErrorActionPreference = 'Stop'
function Add-Type { throw 'UNSAFE_NATIVE_BOUNDARY' }
try {
	& '${helper.replace(/'/g, "''")}'
	throw 'UNSAFE_RETURN'
} catch {
	if ($_.Exception.Message -cne 'Kana installation is restricted to an ephemeral GitHub Actions runner.') { throw }
}
`);
	for (const missing of ['GITHUB_ACTIONS', 'RUNNER_TEMP', 'GITHUB_ENV', 'wrong-case']) {
		const env = { ...process.env, GITHUB_ACTIONS: 'true', RUNNER_TEMP: scratch, GITHUB_ENV: path.join(scratch, 'env') };
		if (missing === 'wrong-case') env.GITHUB_ACTIONS = 'True';
		else delete env[missing];
		const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script], {
			env, encoding: 'utf8', timeout: 30000,
		});
		assert.equal(result.error, undefined, `${missing}: ${result.error}`);
		assert.equal(result.status, 0, `${missing}: ${result.stdout}\n${result.stderr}`);
	}
	fs.writeFileSync(script, `$ErrorActionPreference = 'Stop'\nAdd-Type -TypeDefinition @'\n${native[1]}\n'@\n`);
	const compiled = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script], {
		encoding: 'utf8', timeout: 30000,
	});
	assert.equal(compiled.error, undefined, String(compiled.error));
	assert.equal(compiled.status, 0, `${compiled.stdout}\n${compiled.stderr}`);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log('[OK] Kana installation refuses every missing CI prerequisite; native ownership code compiles.');
