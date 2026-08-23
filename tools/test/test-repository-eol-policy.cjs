// tools/test/test-repository-eol-policy.cjs

/**
 * Guard the repository-wide LF checkout contract without mass-normalizing an
 * active worktree. Git attributes are the enforcement point; the dedicated AHK
 * encoding gate separately preserves UTF-8 BOM plus LF for driver sources.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const attributes = fs
	.readFileSync(path.join(ROOT, '.gitattributes'), 'utf8')
	.replace(/\r\n?/g, '\n');
const vscode = JSON.parse(fs.readFileSync(path.join(ROOT, '.vscode', 'settings.json'), 'utf8'));
const zed = JSON.parse(fs.readFileSync(path.join(ROOT, '.zed', 'settings.json'), 'utf8'));
const directives = attributes
	.split('\n')
	.map((line) => line.trim())
	.filter((line) => line && !line.startsWith('#'));

assert.equal(
	directives[0],
	'* text=auto eol=lf',
	'the first attribute rule must make LF the repository-wide text default'
);
assert.ok(
	directives.includes('*.ahk text eol=lf'),
	'AHK must retain an explicit LF rule beside its BOM encoding gate'
);
assert.equal(vscode['files.eol'], '\n', 'VS Code must default new and saved text files to LF');
assert.equal(
	zed.line_ending,
	'enforce_lf',
	'Zed must prefer LF for files without an existing line-ending convention'
);

const activePolicyFiles = [
	'AGENTS.md',
	'.husky/pre-commit',
	'.agents/skills/ahk-driver/SKILL.md',
	'docs/memory/windows-ahk.md',
	'docs/ERGOPTI_PLUS.md',
	'static/ergopti_plus/windows/tests/test_framework.ahk'
];
for (const relativePath of activePolicyFiles) {
	const policy = fs.readFileSync(path.join(ROOT, relativePath), 'utf8');
	assert.doesNotMatch(
		policy,
		/BOM\s*\+\s*CRLF|with CRLF line terminators/i,
		`${relativePath} must not describe CRLF as the repository source policy`
	);
}

const samples = [
	'README.md',
	'package.json',
	'tools/test/verify-change.cjs',
	'static/ergopti_plus/windows/ErgoptiPlus.ahk'
];
const result = spawnSync('git', ['check-attr', 'eol', '--', ...samples], {
	cwd: ROOT,
	encoding: 'utf8'
});
assert.equal(result.status, 0, result.stderr);
for (const sample of samples) {
	assert.match(
		result.stdout,
		new RegExp(`^${sample.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}: eol: lf$`, 'm'),
		`${sample} must resolve to eol=lf`
	);
}

console.log('repository EOL policy: LF');
