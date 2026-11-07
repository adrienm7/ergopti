// tools/test/test-owned-runtimes-inventory.cjs

/**
 * ==============================================================================
 * MODULE: Owned Runtimes Inventory Tests
 * DESCRIPTION:
 * Keeps the owned runtimes registry (_shared/data/owned_runtimes.json, which
 * docs/design/owned-runtimes.md renders) complete for the three drivers: every
 * external program the driver code starts, as derived from the code by
 * tools/test/lib/spawned-tools.cjs, is in the `programs` of one of that
 * driver's rows, each of which carries a decision, so a new spawn cannot join
 * the product without one.
 *
 * FEATURES & RATIONALE:
 * 1. The extractor itself is pinned on small sources: it must find a program
 *    in each spawn shape the drivers use and nothing in a log line, an SQL
 *    statement, a phase name or a shell function.
 * 2. The registry's rows name every program derived for their driver in their
 *    `programs` list. Rows are read from the JSON, not parsed from Markdown.
 *    A Windows name compares without its `.exe` and without case.
 * 3. The registry load rejects a row whose decision is outside its closed
 *    vocabulary (tools/lib/owned-runtimes.cjs).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const Spawned = require('./lib/spawned-tools.cjs');
const Registry = require('../lib/owned-runtimes.cjs');

const ROOT = path.resolve(__dirname, '../..');
const DATA = path.relative(ROOT, Registry.DATA_PATH);
// The Windows driver starts few programs: most of its work is in-process. A
// floor catches an extractor that stopped reading its sources.
const MINIMUM_PROGRAMS = Object.freeze({ macos: 21, linux: 21, windows: 10 });
const DRIVERS = Object.freeze(Object.keys(MINIMUM_PROGRAMS));
// The words a row's `today` ends with when only a source checkout uses the host.
const DEV_ONLY_MARKER = 'dev-only: source checkout uses host packages';

let failures = 0;
let checks = 0;

/**
 * Runs one named check and records its outcome.
 * @param {string} name
 * @param {Function} body
 */
function check(name, body) {
	checks += 1;
	try {
		body();
		console.log(`PASS ${name}`);
	} catch (error) {
		failures += 1;
		console.error(`FAIL ${name}\n${error.stack || error}`);
	}
}

/**
 * Names the programs a Lua source starts, through the extractor.
 * @param {string} source
 * @returns {string[]}
 */
function programsIn(source) {
	const functions = new Set();
	const literals = Spawned.luaLiterals(source);
	for (const { value } of literals) {
		for (const match of value.matchAll(/(?:^|[\s;{])([a-z_][a-z0-9_]*)\s*\(\)/g))
			functions.add(match[1]);
	}
	return [
		...new Set(literals.flatMap((literal) => Spawned.literalPrograms(literal, functions)))
	].sort();
}

/**
 * Names every program a driver's registry rows cover.
 * @param {object} registry Loaded registry.
 * @param {string} driver One of DRIVERS.
 * @returns {Set<string>}
 */
function programsOf(registry, driver) {
	const rows = registry.rows.filter((row) => row.os === driver);
	assert(rows.length > 0, `${DATA} has no ${driver} row`);
	const names = rows.flatMap((row) => row.programs);
	return new Set(
		driver === 'windows' ? names.map((name) => name.replace(/\.exe$/i, '').toLowerCase()) : names
	);
}

check('the extractor finds each spawn shape the drivers use', () => {
	const source = [
		'local AWK = "/usr/bin/awk"',
		'local path = root .. "/bin/ollama"',
		'if Shell.has_command("zenity") then end',
		'local PYTHON = "python3"',
		'pcall(luv.spawn, "sha256sum", { args = {} })',
		'start("xdotool", { "mousedown", "1" })',
		'Shell.run("wmctrl -s " .. id)',
		'io.popen("xclip -o -selection primary 2>/dev/null", "r")',
		'local actions = { mute = { tool = "pactl set-sink-mute @DEFAULT_SINK@ toggle" } }',
		'local shot = "grim - | wl-copy || maim | xclip -selection clipboard"',
		'local probe = "command -v kdialog >/dev/null"',
		'Shell.run("LC_ALL=C exec nohup setsid x")',
		'Shell.run(prefix .. " --quiet 2>/dev/null || fallback-tool --version")'
	].join('\n');
	assert.deepEqual(programsIn(source), [
		'awk',
		'fallback-tool',
		'grim',
		'kdialog',
		'maim',
		'ollama',
		'pactl',
		'python3',
		'setsid',
		'sha256sum',
		'wl-copy',
		'wmctrl',
		'xclip',
		'xdotool',
		'zenity'
	]);
});

check('the extractor ignores logs, SQL, phases, comments and shell functions', () => {
	const source = [
		'-- io.popen("commented-out-tool --flag")',
		'Logger.start(LOG, "LLM request | model: %s | max tokens: %d.")',
		'_exec("BEGIN;\\nALTER TABLE devices RENAME TO old;")',
		'run_start_step("keymap registry transaction")',
		'M.SLOW_AWK = [[ if (a && b) { print $1 } ]]',
		'Shell.run("has() { command -v \\"$1\\"; }; has slurp && echo ok 2>/dev/null")',
		'local x = "[ -z \\"$P\\" ] && echo \'none\' && exit 0"',
		'local probe = \'kill -0 "$pid" 2>/dev/null || failure="it quit during the probation"\'',
		'return "ready", { chunk = data }'
	].join('\n');
	assert.deepEqual(programsIn(source), []);
});

check('the Windows extractor finds what starts and ignores names that only compare', () => {
	const source = [
		'; Run("commented-out.exe")',
		"Run('notepad.exe \"' . Path . '\"')",
		'Exe := A_WinDir . "\\System32\\curl.exe"',
		'Run("explorer " . Folder)',
		"RunWait('reg query HKCU')",
		'"slack.exe",   "communication",',
		'"zoom.exe", "teams.exe",',
		'"KeePass.exe", true,',
		'if WinActive("ahk_exe EXCEL.EXE") {',
		'if (ProcName == "Code.exe") {',
		"$Start = Join-Path $Root 'ollama.exe'",
		'"i)\\.recovery\\.exe$", ".republish.exe")'
	].join('\n');
	assert.deepEqual([...Spawned.windowsPrograms(source)].sort(), [
		'curl',
		'explorer',
		'notepad',
		'ollama',
		'reg'
	]);
});

check('a long name-table row is read in linear time', () => {
	// One pattern for the whole row backtracked exponentially on this input.
	const line = `"alpha"${'\t""'.repeat(24)} Run("calc.exe")`;
	const started = Date.now();
	assert.deepEqual([...Spawned.windowsPrograms(line)], ['calc']);
	assert(Date.now() - started < 2000, 'the name-table reader must stay linear');
});

// A malformed registry or an undecided row fails here, before any check.
const registry = Registry.load();

for (const driver of DRIVERS) {
	check(`the ${driver} rows list every program the ${driver} driver starts`, () => {
		const derived = Spawned.spawnedTools(driver);
		assert(
			derived.size >= MINIMUM_PROGRAMS[driver],
			`the extractor found only ${derived.size} ${driver} programs`
		);
		const names = programsOf(registry, driver);
		const missing = [...derived.keys()]
			.filter((name) => !names.has(name))
			.sort()
			.map((name) => `${name} (${derived.get(name).join(', ')})`);
		assert.deepEqual(
			missing,
			[],
			`add each program to the "programs" of a ${driver} row of ${DATA}, with its decision, ` +
				'then run node tools/codegen/codegen-owned-runtimes.cjs:\n' +
				missing.join('\n')
		);
	});
}

check('the registry load refuses a row without a decided class', () => {
	const undecided = structuredClone(registry);
	undecided.rows[0].decision = 'PROPOSAL';
	assert.throws(() => Registry.validate(undecided), /unknown decision/);
});

// Ruling of 1 November: an install from a source checkout is a developer path,
// so a Linux row whose only host use is that install is done, says so with the
// dev-only marker, and is pinned; it does not stay open for it.
check('a Linux row is not left open for a source-checkout install alone', () => {
	const linux = registry.rows.filter((row) => row.os === 'linux');
	const devOnly = linux.filter((row) => row.today.includes(DEV_ONLY_MARKER));
	assert(devOnly.length >= 7, `expected the private-runtime rows to carry "${DEV_ONLY_MARKER}"`);
	for (const row of devOnly) {
		assert.equal(row.status, 'done', `${row.tool} is dev-only on the host and must be done`);
		assert.equal(row.current_class, 'PIN', `${row.tool} ships pinned and must be classed PIN`);
	}
	for (const row of linux.filter((entry) => entry.status !== 'done'))
		assert.doesNotMatch(
			row.today,
			/source checkout/,
			`${row.tool} stays open only for a source-checkout install`
		);
});

if (failures > 0) {
	console.error(`[FAIL] owned runtimes inventory: ${failures} of ${checks} checks failed.`);
	process.exit(1);
}
console.log(`[OK] owned runtimes inventory (${checks} checks).`);
