#!/usr/bin/env node
// tools/test/test-field-report-redact.cjs

/**
 * ==============================================================================
 * MODULE: Field Report Redaction Tests
 * DESCRIPTION:
 * A field report is pushed to a public repository. The macOS reports of
 * 2026-10-30 to 2026-11-09 published the company directory login of the
 * maintainer's Mac in every `ls -la` and `lsof` step output: those outputs were
 * committed raw. tools/dev/field-report-redact.py now rewrites every file of a
 * report folder before the commit and refuses a folder it cannot prove clean;
 * the pre-commit hook refuses any added line naming this machine.
 *
 * The identity is read from the environment the script runs in, so each case
 * runs it with canary values. No value comes from a real machine.
 *
 * Also pins the collectors: all three redact the folder before `git add`, and
 * the pre-commit hook runs the staged gate.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { reportNotExecuted } = require('./lib/host-capabilities.cjs');

const ROOT = path.resolve(__dirname, '../..');
const REDACT = path.join(ROOT, 'tools/dev/field-report-redact.py');
const LOGIN = 'canarylogin';
const DOMAIN = 'corp-canary.example';
const HOST = 'CANARY-HOST-7';
const POSIX_HOME = `/Users/${LOGIN}`;
const WINDOWS_HOME = `C:\\Users\\${LOGIN}`;

/** The first interpreter that really runs: Windows has a python3 Store stub. */
function findPython() {
	for (const name of ['python3', 'python']) {
		const probe = spawnSync(name, ['--version'], { encoding: 'utf8' });
		if (probe.status === 0) return name;
	}
	return null;
}

const python = findPython();
if (!python) {
	reportNotExecuted('field report redaction', 'no Python interpreter runs on this host');
	process.exit(0);
}

/** The canary identity, as the script reads it on every OS. */
function canaryEnv(home) {
	return {
		...process.env,
		HOME: home,
		USERPROFILE: home,
		USER: LOGIN,
		LOGNAME: LOGIN,
		USERNAME: LOGIN,
		USERDOMAIN: DOMAIN,
		COMPUTERNAME: HOST
	};
}

/**
 * Redacts a folder built from files through the real script.
 * @param {Object<string, string|Buffer>} files Relative path to content.
 * @returns {{status: number, stderr: string, files: Object<string, string>}}
 */
function runRedact(files, home = POSIX_HOME) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-redact-'));
	try {
		for (const [name, content] of Object.entries(files)) {
			fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
			fs.writeFileSync(path.join(dir, name), content);
		}
		const run = spawnSync(python, ['-I', REDACT, dir], { encoding: 'utf8', env: canaryEnv(home) });
		const out = {};
		for (const name of Object.keys(files)) {
			const file = path.join(dir, name);
			if (fs.existsSync(file)) out[name] = fs.readFileSync(file, 'utf8');
		}
		return { status: run.status, stderr: run.stderr, files: out };
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

check('the original leak: a directory login with its domain in `ls -la` and `lsof`', () => {
	const run = runRedact({
		'user_layouts.txt': `drwx------+  6 ${LOGIN}@${DOMAIN}  staff   192 28 oct.  18:21 .\n`,
		'listeners.txt': `node  2533 ${LOGIN}@${DOMAIN}  142u  IPv4 0xd5  0t0  TCP 127.0.0.1:7265 (LISTEN)\n`
	});
	assert.equal(run.status, 0, run.stderr);
	for (const text of Object.values(run.files)) {
		assert(!text.includes(LOGIN), text);
		assert(!text.includes(DOMAIN), text);
	}
	assert(run.files['listeners.txt'].includes('TCP 127.0.0.1:7265 (LISTEN)'), 'the fact stays');
});

check('the organisation named by the directory domain leaves on its own too', () => {
	const run = runRedact({
		'f.txt': 'expanded Corp-Canary for the CORP-CANARY team, kept corp-canarying\n'
	});
	assert.equal(run.status, 0, run.stderr);
	assert.equal(
		run.files['f.txt'],
		'expanded <domain> for the <domain> team, kept corp-canarying\n'
	);
});

check('a company login is removed even when the machine does not report it', () => {
	const run = runRedact({ 'a.txt': 'owner other.person@unknown-corp.example\n' });
	assert.equal(run.status, 0, run.stderr);
	assert.equal(run.files['a.txt'], 'owner <email>\n');
});

check('the home folder becomes ~ in every spelling, other homes lose their name', () => {
	const run = runRedact({
		'field_run/11.json': `{"path":"${POSIX_HOME}/Library","escaped":"\\/Users\\/${LOGIN}\\/x"}\n`,
		'b.txt': `${POSIX_HOME}/perso/config\n/Users/someoneelse/x\n/home/someoneelse/y\n/Users/Shared/z\n`
	});
	assert.equal(run.status, 0, run.stderr);
	const json = run.files['field_run/11.json'];
	assert(!json.includes(LOGIN), json);
	assert(json.includes('"~/Library"'), json);
	assert.equal(
		run.files['b.txt'],
		'~/perso/config\n/Users/<user>/x\n/home/<user>/y\n/Users/Shared/z\n'
	);
});

check('a Windows profile folder, the account, the domain and the host leave', () => {
	const run = runRedact(
		{
			'c.txt':
				`${WINDOWS_HOME}\\AppData\\Local\n${DOMAIN}\\${LOGIN} on ${HOST}\n` +
				`C:\\\\Users\\\\someoneelse\\\\x\n`
		},
		WINDOWS_HOME
	);
	assert.equal(run.status, 0, run.stderr);
	const text = run.files['c.txt'];
	for (const value of [LOGIN, DOMAIN, HOST, 'someoneelse']) assert(!text.includes(value), text);
	assert(text.includes('<host>'), text);
});

check('ordinary facts are kept: version pins, code locations, words around the login', () => {
	const kept = 'uv@0.5.1 refused@Owner.swift REPO_ROOT user root canaryloginless\n';
	const run = runRedact({ 'd.txt': kept });
	assert.equal(run.status, 0, run.stderr);
	assert.equal(run.files['d.txt'], kept);
});

check('a binary file that names the user is withheld and said so', () => {
	const run = runRedact({
		'blob.bin': Buffer.concat([Buffer.from([0xff, 0xfe, 0x00]), Buffer.from(POSIX_HOME)]),
		'clean.bin': Buffer.from([0xff, 0xfe, 0x00, 0x01])
	});
	assert.equal(run.status, 0, run.stderr);
	assert(!('blob.bin' in run.files), 'the binary naming the user is deleted');
	assert('clean.bin' in run.files, 'a clean binary stays');
	assert.match(run.stderr, /withheld blob\.bin/);
});

check('a folder it cannot prove clean fails, so the collector commits nothing', () => {
	const run = runRedact({ 'e.txt': 'owner <user>@other-corp.example\n' });
	assert.equal(run.status, 1);
	assert.match(run.stderr, /still holds/);
});

check('the pre-commit gate refuses an added line naming this machine', () => {
	const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-identity-gate-'));
	try {
		const git = (...args) => {
			const run = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
			assert.equal(run.status, 0, run.stderr);
		};
		git('init', '-q');
		const gate = () =>
			spawnSync(python, ['-I', REDACT, '--staged'], {
				cwd: repo,
				encoding: 'utf8',
				env: canaryEnv(POSIX_HOME)
			});
		fs.writeFileSync(path.join(repo, 'clean.txt'), 'nothing personal\n');
		git('add', 'clean.txt');
		assert.equal(gate().status, 0, gate().stderr);
		fs.writeFileSync(path.join(repo, 'leak.txt'), `config at ${POSIX_HOME}/x on ${HOST}\n`);
		git('add', 'leak.txt');
		const refused = gate();
		assert.equal(refused.status, 1);
		assert.match(refused.stderr, /leak\.txt/);
		git('reset', '-q');
		fs.writeFileSync(path.join(repo, 'org.txt'), 'a note about Corp-Canary\n');
		git('add', 'org.txt');
		assert.equal(gate().status, 1, 'the organisation name alone is refused');
	} finally {
		fs.rmSync(repo, { recursive: true, force: true });
	}
});

check('every collector redacts its folder before `git add`, the hook runs the gate', () => {
	const shared = fs.readFileSync(path.join(ROOT, 'tools/dev/field-report-git.sh'), 'utf8');
	const commit = shared.slice(shared.indexOf('field_report_commit() {'));
	assert(commit.indexOf('field-report-redact.py') !== -1, 'the macOS and Linux commit redacts');
	assert(commit.indexOf('field-report-redact.py') < commit.indexOf('git add'), 'before git add');
	for (const collector of ['collect-macos-field-report.sh', 'collect-linux-field-report.sh']) {
		const text = fs.readFileSync(path.join(ROOT, 'tools/dev', collector), 'utf8');
		assert.match(text, /field_report_commit "\$\{subject\}"/, collector);
		assert.doesNotMatch(
			text,
			/^\s*git add -f/m,
			`${collector} commits through field_report_commit only`
		);
	}
	const windows = fs.readFileSync(
		path.join(ROOT, 'tools/dev/collect-windows-field-report.ps1'),
		'utf8'
	);
	const redact = windows.indexOf("'field-report-redact.py'");
	assert(redact !== -1, 'the Windows collector redacts');
	assert(redact < windows.indexOf("Invoke-Git add '-f'"), 'before git add');
	const hook = fs.readFileSync(path.join(ROOT, '.husky/pre-commit'), 'utf8');
	assert.match(hook, /field-report-redact\.py --staged \|\| exit 1/);
});

console.log(`[OK] field report redaction (${checks} checks).`);
