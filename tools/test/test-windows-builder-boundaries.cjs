// tools/test/test-windows-builder-boundaries.cjs
/**
 * Native Windows builders treat their paths and manifests literally
 * (2026-10-28 audit, remaining finding 5).
 *
 * Push-Location without -LiteralPath reads [ ] in a checkout path as a wildcard
 * and fails, or enters another directory. `-ne` coerces, so a manifest whose
 * schema_version is the string "1" passed for the integer 1. Both behaviours
 * are measured on the real PowerShell where the host has one.
 */

'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const BUILD_DIR = path.join(REPO_ROOT, 'tools', 'build');

const builders = fs.readdirSync(BUILD_DIR).filter((name) => name.endsWith('.ps1'));
assert.ok(builders.length >= 3, 'the builder census must find the native builders');

let pushes = 0;
for (const name of builders) {
	const source = fs.readFileSync(path.join(BUILD_DIR, name), 'utf8');
	for (const line of source.split('\n')) {
		if (!/^\s*(Push-Location|Set-Location)\b/.test(line)) continue;
		pushes += 1;
		assert.match(line, /-LiteralPath\b/, `${name}: a builder path is literal: ${line.trim()}`);
	}
}
assert.ok(pushes >= 3, 'the census must see the builders changing directory');

const navOwner = fs.readFileSync(path.join(BUILD_DIR, 'build_windows_nav_owner.ps1'), 'utf8');
const schemaGuard = navOwner.match(/^\s*if \((.*schema_version.*)\) \{$/m);
assert.ok(schemaGuard, 'the provenance schema guard must exist');

if (process.platform === 'win32') {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-builder-boundary-'));
	try {
		const bracketed = path.join(scratch, 'check[1]out');
		fs.mkdirSync(bracketed);
		const script = path.join(scratch, 'probe.ps1');
		const quoted = bracketed.replace(/'/g, "''");
		fs.writeFileSync(
			script,
			`$ErrorActionPreference = 'Stop'
$buildDir = '${quoted}'
Push-Location -LiteralPath $buildDir
try { if ((Get-Location).ProviderPath -cne $buildDir) { throw 'Wrong directory' } } finally { Pop-Location }
$SchemaVersion = 1
foreach ($case in @(@{ Json = '{"schema_version":1}'; Refused = $false }, @{ Json = '{"schema_version":"1"}'; Refused = $true })) {
 $manifest = $case.Json | ConvertFrom-Json
 $refused = [bool](${schemaGuard[1]})
 if ($refused -ne $case.Refused) { throw "Schema guard disagrees on $($case.Json)" }
}
Write-Output '[OK] literal builder paths and strict schema kind'
`
		);
		const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script], {
			encoding: 'utf8',
			timeout: 30000,
			windowsHide: true
		});
		assert.equal(result.status, 0, result.stderr || result.error?.message || result.stdout);
		assert.match(result.stdout, /\[OK\]/);
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

console.log('[OK] native builders treat paths and manifests literally.');
