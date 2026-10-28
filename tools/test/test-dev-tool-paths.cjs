// tools/test/test-dev-tool-paths.cjs

/**
 * ==============================================================================
 * MODULE: Dev-Tool Path Guard
 * DESCRIPTION:
 * Regression guard for the private-AHK workflow tools under tools/dev/ (the
 * sync/strip/watch scripts plus the pm2 install/uninstall-ahk-watcher.js pair). The
 * static/drivers -> static/ergopti_plus and scripts -> tools/dev reorg left
 * sync-private-ahk.js, watch-ahk.js and the watcher installers pointing at dead pre-reorg paths
 * (static/hotstrings/.local_ahk_path, static/drivers/autohotkey/ErgoptiPlus.ahk,
 * scripts/*.js, the removed update-ahk-date.js, and the removed Python hotstrings
 * generator). The whole private-sync pipeline was therefore broken: every run
 * either no-op'd on a missing override or crashed on a missing script.
 *
 * ROOT CAUSE ENCODED:
 * These dev tools must reference only LIVE post-reorg paths, must agree on a
 * single canonical .local_ahk_path location, and that location must be the one
 * .gitignore actually protects. This guard fails if any dead path signature
 * reappears or the override location drifts between the tools and .gitignore.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DEV = path.join(ROOT, 'tools', 'dev');

const SCRIPTS = [
	'sync-private-ahk.js',
	'remove_ahk_personal_configuration.js',
	'watch-ahk.js',
	'install-ahk-watcher.js',
	'uninstall-ahk-watcher.js'
];

// Canonical post-reorg override location, expressed both as a slash path (for
// .gitignore) and as a path.join segment sequence (for the JS sources).
const OVERRIDE_SLASH = 'static/ergopti_plus/windows/.local_ahk_path';

// Dead path signatures — matched in BOTH `path.join('a', 'b')` segment form and
// 'a/b' slash-literal form so a regression in either style is caught.
const DEAD = [
	{ label: 'static/drivers', re: /['"]static['"]\s*,\s*['"]drivers['"]|static\/drivers/ },
	{ label: 'static/hotstrings', re: /['"]static['"]\s*,\s*['"]hotstrings['"]|static\/hotstrings/ },
	{
		label: 'scripts/ dir for a tool script',
		re: /['"]scripts['"]\s*,\s*['"][\w.-]+\.js['"]|scripts\/[\w.-]+\.js/
	},
	{ label: 'removed 0_generate_hotstrings.py', re: /0_generate_hotstrings/ },
	{ label: 'removed update-ahk-date.js', re: /update-ahk-date/ }
];

// path.join segment form of the canonical override: 'ergopti_plus', 'windows', '.local_ahk_path'.
const OVERRIDE_JOIN_RE =
	/['"]ergopti_plus['"]\s*,\s*['"]windows['"]\s*,\s*['"]\.local_ahk_path['"]/;
const PUBLIC_JOIN_RE = /['"]ergopti_plus['"]\s*,\s*['"]windows['"]\s*,\s*['"]ErgoptiPlus\.ahk['"]/;

const errors = [];

function read(rel) {
	return fs.readFileSync(path.join(DEV, rel), 'utf8');
}

// 1. No dead path signature in any of the three tools.
for (const s of SCRIPTS) {
	const src = read(s);
	for (const d of DEAD) {
		if (d.re.test(src)) {
			errors.push(`${s}: references dead path "${d.label}" — must use the post-reorg location.`);
		}
	}
}

// 2. The tools that read the override must agree on the canonical location.
for (const s of ['sync-private-ahk.js', 'watch-ahk.js', 'install-ahk-watcher.js']) {
	if (!OVERRIDE_JOIN_RE.test(read(s))) {
		errors.push(
			`${s}: must read .local_ahk_path from static/ergopti_plus/windows/.local_ahk_path.`
		);
	}
}

// 3. The sync tool must write the public file to its live location.
if (!PUBLIC_JOIN_RE.test(read('sync-private-ahk.js'))) {
	errors.push(
		'sync-private-ahk.js: public file must be static/ergopti_plus/windows/ErgoptiPlus.ahk.'
	);
}

// 4. .gitignore must actually protect that override location.
const gitignore = fs.readFileSync(path.join(ROOT, '.gitignore'), 'utf8');
if (!gitignore.split(/\r?\n/).some((l) => l.trim() === OVERRIDE_SLASH)) {
	errors.push(
		`.gitignore: must ignore "${OVERRIDE_SLASH}" so the private override pointer is never tracked.`
	);
}

// 5. NO tool anywhere under tools/ may hardcode one machine's checkout.
//
// This check used to be scoped to tools/dev/, and tools/build/ carried two:
// gen-process-prediction-corpus.lua resolved both its module path and its output
// path from "D:/Documents/GitHub/ergopti/…". The generator therefore could not
// run on any other machine or in CI — it would fail to require the shared parser,
// or write its corpus to a directory that does not exist. A path a contributor
// cannot use is a path that quietly makes a tool single-user.
const ABSOLUTE_HOME = [
	{
		label: 'a Windows drive-letter checkout',
		re: /["'][A-Za-z]:[/\\](?:Users|Documents|Dev|Projects|src)[/\\]/i
	},
	{ label: 'a Unix home checkout', re: /["']\/(?:Users|home)\/[A-Za-z][\w.-]*\// }
];

/** Every tracked file under tools/, minus this guard itself. */
function toolFiles(dir, acc = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'node_modules') toolFiles(p, acc);
		} else if (/\.(js|cjs|mjs|lua|py|sh|ps1)$/i.test(e.name)) {
			acc.push(p);
		}
	}
	return acc;
}

const SELF = path.join(ROOT, 'tools', 'test', 'test-dev-tool-paths.cjs');
for (const abs of toolFiles(path.join(ROOT, 'tools'))) {
	if (abs === SELF) continue;
	const text = fs.readFileSync(abs, 'utf8');
	const rel = path.relative(ROOT, abs).replace(/\\/g, '/');
	text.split(/\r?\n/).forEach((line, i) => {
		if (/^\s*(\/\/|#|--|;)/.test(line)) return; // prose may cite a path
		for (const { label, re } of ABSOLUTE_HOME) {
			if (re.test(line)) {
				errors.push(
					`${rel}:${i + 1}: hardcodes ${label} — derive the repo root from the script's own location instead.`
				);
			}
		}
	});
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Dead or inconsistent dev-tool paths:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] Private-AHK dev tools reference only live post-reorg paths.\x1b[0m');

/** Runs the actual sync CLI on owned data files; no AutoHotkey source is executed. */
function testPrivateSyncEncoding() {
	const date = '; Last modified on 2000-01-01 at 00:00 (UTC+0)\n';
	const otherDate = '; Last modified on 2001-01-01 at 00:00 (UTC+0)\n';
	const body =
		'#Requires AutoHotkey v2.0\n; Unicode: café / 漢\nglobal SyncFixture := "owned data"\n';
	const cases = [
		{ name: 'BOM and existing date with LF', input: '\uFEFF' + date + body },
		{ name: 'BOM without a date with LF', input: '\uFEFF' + body },
		{
			name: 'BOM and existing date with CRLF',
			input: ('\uFEFF' + date + body).replaceAll('\n', '\r\n')
		},
		{ name: 'no BOM with CRLF', input: (date + body).replaceAll('\n', '\r\n') },
		{ name: 'BOM without date with CR', input: ('\uFEFF' + body).replaceAll('\n', '\r') },
		{
			name: 'equal body repairs missing public BOM',
			input: '\uFEFF' + otherDate + body,
			existing: date + body,
			expected: '\uFEFF' + date + body
		},
		{
			name: 'equal body repairs public CRLF',
			input: '\uFEFF' + otherDate + body,
			existing: ('\uFEFF' + date + body).replaceAll('\n', '\r\n'),
			expected: '\uFEFF' + date + body
		},
		{
			name: 'equal canonical body preserves its public date',
			input: '\uFEFF' + otherDate + body,
			existing: '\uFEFF' + date + body,
			expected: '\uFEFF' + date + body
		},
		{
			name: 'half-hour east timezone retains minutes',
			input: '\uFEFF' + body,
			timezone: 'Asia/Kolkata',
			offset: '+05:30'
		},
		{
			name: 'quarter-hour east timezone retains minutes',
			input: '\uFEFF' + body,
			timezone: 'Asia/Kathmandu',
			offset: '+05:45'
		},
		{
			name: 'half-hour west timezone retains sign and minutes',
			input: '\uFEFF' + body,
			timezone: 'Pacific/Marquesas',
			offset: '-09:30'
		},
		{
			name: 'UTC timezone retains both zero components',
			input: '\uFEFF' + body,
			timezone: 'Etc/UTC',
			offset: '+00:00'
		}
	];
	const failures = [];
	for (const test of cases) {
		const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-private-sync-'));
		try {
			const directory = path.join(temporary, 'static', 'ergopti_plus', 'windows');
			fs.mkdirSync(directory, { recursive: true });
			const privateFile = path.join(temporary, 'private-input.ahk');
			const publicFile = path.join(directory, 'ErgoptiPlus.ahk');
			fs.writeFileSync(privateFile, test.input);
			fs.writeFileSync(path.join(directory, '.local_ahk_path'), privateFile);
			if (test.existing !== undefined) fs.writeFileSync(publicFile, test.existing);
			const environment = { ...process.env };
			if (test.timezone) environment.TZ = test.timezone;
			const run = () => {
				const result = spawnSync(process.execPath, [path.join(DEV, 'sync-private-ahk.js')], {
					cwd: temporary,
					env: environment,
					encoding: 'utf8',
					timeout: 10000,
					windowsHide: true
				});
				assert.ifError(result.error);
				assert.equal(result.status, 0, result.stdout + result.stderr);
			};
			run();
			const actual = fs.readFileSync(publicFile);
			assert.deepEqual(
				[...actual.subarray(0, 3)],
				[0xef, 0xbb, 0xbf],
				'the public driver must begin with its UTF-8 BOM'
			);
			assert.equal(actual.includes(0x0d), false, 'all public line endings must be LF');
			const text = actual.toString('utf8');
			assert.equal(
				[...text].filter((character) => character === '\uFEFF').length,
				1,
				'the private BOM must never become an embedded source character'
			);
			assert.equal(
				text.slice(text.indexOf('\n') + 1),
				body,
				'the entire Unicode source body must remain byte-for-byte exact'
			);
			if (test.offset !== undefined)
				assert.equal(
					text.slice(0, text.indexOf('\n')).endsWith(`(UTC${test.offset})`),
					true,
					'the generated driver date must retain the exact timezone offset'
				);
			if (test.expected !== undefined)
				assert.equal(
					text,
					test.expected,
					'encoding repair and unchanged sync preserve the existing public date'
				);
			run();
			assert.deepEqual(
				fs.readFileSync(publicFile),
				actual,
				'a second sync must preserve the exact canonical bytes and date'
			);
			assert.equal(
				fs.readFileSync(privateFile, 'utf8'),
				test.input,
				'the private input is never rewritten'
			);
		} catch (failure) {
			failures.push(test.name + ': ' + failure.message);
		} finally {
			fs.rmSync(temporary, { recursive: true, force: true });
		}
	}
	assert.deepEqual(failures, [], 'private AHK sync encoding regressions');
	console.log(
		'[OK] Actual private AHK sync preserves BOM, LF, Unicode and unchanged dates in ' +
			cases.length +
			' data-only cases.'
	);
}

testPrivateSyncEncoding();
