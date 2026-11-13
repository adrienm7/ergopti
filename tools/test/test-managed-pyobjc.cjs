// tools/test/test-managed-pyobjc.cjs

/**
 * ==============================================================================
 * MODULE: Managed PyObjC Pins And Installer
 * DESCRIPTION:
 * Pins static/ergopti_plus/macos/ai/engine/managed-pyobjc.json, the wheels
 * the App Cloner helpers need in Ergopti's managed Python, and runs
 * ensure-managed-pyobjc.sh against fake bootstrap, download and uv ports: the
 * wheels are fetched with their pinned digest and size, installed offline and
 * without dependencies into the managed interpreter, and the import check
 * decides the result.
 *
 * ROOT CAUSE ENCODED: App Cloner ran on /usr/bin/python3 for PyObjC, so a Mac
 * without the Command Line Tools got an Xcode prompt and cloning failed
 * (owned_runtimes.json). The pinned wheels replace that host dependency; an
 * installer that trusted an unverified wheel, resolved dependencies from an
 * index, or reported success before the imports worked would bring the host
 * dependency back in another form.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const LLM = path.join(ROOT, 'static/ergopti_plus/macos/ai/engine');
const MANIFEST = path.join(LLM, 'managed-pyobjc.json');
const SCRIPT = path.join(LLM, 'bootstrap/ensure-managed-pyobjc.sh');
const LOCATOR = path.join(
	ROOT,
	'static/ergopti_plus/_shared/core/lifecycle/engine/core/managed_python_locator.lua'
);

if (process.platform === 'win32') {
	console.log('[SKIP] The managed PyObjC installer is a macOS shell tool; not run on Windows.');
	process.exit(0);
}

let checks = 0;
/** Runs one named check. */
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-pyobjc-'));
// The fake bootstrap hands out this interpreter, as the real one hands out the managed one.
const INTERPRETER = spawnSync('/bin/sh', ['-c', 'command -v python3'], {
	encoding: 'utf8'
}).stdout.trim();
assert(INTERPRETER.startsWith('/'), 'python3 is required');
const PYTHON_TAG = spawnSync(
	INTERPRETER,
	['-c', 'import sys; print("cp%d%d" % sys.version_info[:2])'],
	{
		encoding: 'utf8'
	}
).stdout.trim();

/** Writes one executable or sourced shell file. */
function write(file, body, mode = 0o644) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, body, { mode });
}

/**
 * Builds a script folder: the real installer beside fake ports and a manifest
 * whose wheels are local fixture files.
 * @param {object} options { modules, tamper, url }.
 * @returns {object} { dir, home, log, wheels }
 */
function fixture({
	modules = ['json'],
	tamper = false,
	url = 'https://files.pythonhosted.org/x/'
} = {}) {
	const dir = fs.mkdtempSync(path.join(scratch, 'run-'));
	const home = path.join(dir, 'home');
	const store = path.join(dir, 'store');
	const log = path.join(dir, 'uv.log');
	fs.mkdirSync(store);
	fs.copyFileSync(SCRIPT, path.join(dir, 'ensure-managed-pyobjc.sh'));
	const wheels = ['alpha', 'beta'].map((stem) => {
		const name = `${stem}-1.0-${PYTHON_TAG}-${PYTHON_TAG}-macosx_10_9_universal2.whl`;
		const bytes = Buffer.from(`wheel ${stem}\n`);
		fs.writeFileSync(path.join(store, name), bytes);
		const digest = crypto.createHash('sha256').update(bytes).digest('hex');
		return {
			name: stem,
			version: '1.0',
			file_name: name,
			url: url + name,
			sha256: tamper && stem === 'beta' ? '0'.repeat(64) : digest,
			size: bytes.length
		};
	});
	write(
		path.join(dir, 'managed-pyobjc.json'),
		JSON.stringify({
			schema_version: 1,
			purpose: 'fixture',
			python_tag: PYTHON_TAG,
			import_check: modules,
			wheels
		})
	);
	// The download port checks size and digest as the real one does.
	write(
		path.join(dir, 'network-retry.sh'),
		[
			'managed_bootstrap_download() {',
			`\tlocal source="${store}/\${1##*/}"`,
			'\t[ "$(wc -c < "$source" | tr -d " ")" = "$4" ] || return 75',
			'\t[ "$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],\'rb\').read()).hexdigest())" "$source")" = "$3" ] || return 76',
			'\tcp "$source" "$2"',
			'}',
			''
		].join('\n')
	);
	// The uv port records its arguments, one per line.
	write(
		path.join(dir, 'fake-uv'),
		`#!/bin/sh\nfor a in "$@"; do printf '%s\\n' "$a"; done > "${log}"\n`,
		0o755
	);
	write(
		path.join(dir, 'native_python_bootstrap.sh'),
		[
			'native_bootstrap_python() {',
			'\tmkdir -p "$1/bin"',
			`\tcp "${path.join(dir, 'fake-uv')}" "$1/bin/uv"`,
			'\tmkdir -p "$1/python/bin"',
			`\tln -sf "${INTERPRETER}" "$1/python/bin/python3"`,
			'\texport ERGOPTI_BOOTSTRAP_PYTHON="$1/python/bin/python3"',
			'}',
			''
		].join('\n')
	);
	return { dir, home, log, wheels };
}

/** Runs the installer of one fixture. */
function run(fix) {
	return spawnSync('/bin/bash', [path.join(fix.dir, 'ensure-managed-pyobjc.sh')], {
		encoding: 'utf8',
		env: { PATH: process.env.PATH, HOME: fix.home, TMPDIR: fix.dir }
	});
}

check('the shipped pins are the closed PyObjC set for the managed Python', () => {
	const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
	const minor = fs.readFileSync(LOCATOR, 'utf8').match(/bin\/python3\.(\d+)"/);
	assert(minor, 'the managed Python locator names its interpreter');
	assert.equal(manifest.python_tag, `cp3${minor[1]}`, 'the wheels match the managed interpreter');
	assert.deepEqual(manifest.import_check, ['objc', 'AppKit', 'Foundation']);
	assert.deepEqual(
		manifest.wheels.map((wheel) => wheel.name),
		['pyobjc-core', 'pyobjc-framework-Cocoa']
	);
	for (const wheel of manifest.wheels) {
		assert.match(wheel.sha256, /^[0-9a-f]{64}$/);
		assert(Number.isInteger(wheel.size) && wheel.size > 0);
		assert(
			wheel.url.startsWith('https://files.pythonhosted.org/') &&
				wheel.url.endsWith('/' + wheel.file_name)
		);
		assert.match(
			wheel.file_name,
			new RegExp(
				`-${wheel.version}-${manifest.python_tag}-${manifest.python_tag}-macosx_10_9_universal2\\.whl$`
			)
		);
	}
});

check('verified wheels are installed offline without dependencies, then imported', () => {
	const fix = fixture();
	const result = run(fix);
	assert.equal(result.status, 0, result.stderr);
	const prefix = path.join(fix.home, 'Library/Application Support/Ergopti/native-bootstrap');
	const managed = path.join(prefix, 'python/bin/python3');
	const link = path.join(prefix, 'app-cloner/python3');
	assert.equal(result.stdout, `PYOBJC_READY\t${link}\n`, 'the stable link is what clones exec');
	assert.equal(fs.readlinkSync(link), managed, 'the link names the managed interpreter');
	const args = fs.readFileSync(fix.log, 'utf8').trim().split('\n');
	assert.deepEqual(args.slice(0, 2), ['pip', 'install']);
	for (const flag of [
		'--break-system-packages',
		'--no-deps',
		'--no-index',
		'--offline',
		'--no-config'
	])
		assert(args.includes(flag), `uv runs with ${flag}`);
	assert.equal(args[args.indexOf('--python') + 1], managed);
	assert.deepEqual(
		args.filter((arg) => arg.endsWith('.whl')).map((arg) => path.basename(arg)),
		fix.wheels.map((wheel) => wheel.file_name)
	);
	assert.deepEqual(
		fs.readdirSync(fix.dir).filter((name) => name.startsWith('ergopti-pyobjc.')),
		[],
		'the download folder is removed'
	);
});

check('a later run points the stable link at the interpreter it installed into', () => {
	const fix = fixture();
	const prefix = path.join(fix.home, 'Library/Application Support/Ergopti/native-bootstrap');
	fs.mkdirSync(path.join(prefix, 'app-cloner'), { recursive: true });
	fs.symlinkSync(
		'/nonexistent/cpython-3.11.15/bin/python3.11',
		path.join(prefix, 'app-cloner/python3')
	);
	const result = run(fix);
	assert.equal(result.status, 0, result.stderr);
	assert.equal(
		fs.readlinkSync(path.join(prefix, 'app-cloner/python3')),
		path.join(prefix, 'python/bin/python3')
	);
	assert.deepEqual(
		fs.readdirSync(path.join(prefix, 'app-cloner')),
		['python3'],
		'no temporary link is left'
	);
});

check('a wheel whose digest differs is never installed', () => {
	const fix = fixture({ tamper: true });
	const result = run(fix);
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /stage download_beta-1\.0-/);
	assert(!fs.existsSync(fix.log), 'uv never ran');
});

check('a failed import check is a failure after the install', () => {
	const fix = fixture({ modules: ['json', 'ergopti_no_such_module'] });
	const result = run(fix);
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /stage import_check ended/);
	assert.doesNotMatch(result.stdout, /PYOBJC_READY/);
});

check('a wheel from another host is refused before any download', () => {
	const fix = fixture({ url: 'http://example.invalid/x/' });
	const result = run(fix);
	assert.equal(result.status, 78, result.stderr);
	assert.match(result.stderr, /stage manifest ended/);
});

fs.rmSync(scratch, { recursive: true, force: true });
console.log(`[OK] managed PyObjC pins and installer (${checks} checks).`);
