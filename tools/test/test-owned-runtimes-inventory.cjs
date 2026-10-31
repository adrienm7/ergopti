// tools/test/test-owned-runtimes-inventory.cjs

/**
 * ==============================================================================
 * MODULE: Owned Runtimes Inventory Tests
 * DESCRIPTION:
 * Keeps docs/design/owned-runtimes.md complete for the macOS and Linux drivers:
 * every external program the driver code starts, as derived from the code by
 * tools/test/lib/spawned-tools.cjs, has a row in that driver's table with a
 * proposal, so a new spawn cannot join the product without a decision.
 *
 * FEATURES & RATIONALE:
 * 1. The extractor itself is pinned on small sources: it must find a program
 *    in each spawn shape the drivers use and nothing in a log line, an SQL
 *    statement, a phase name or a shell function.
 * 2. The macOS table (section 3) and the Linux table (section 4) name every
 *    derived program in their Tool column, in backticks or as the row's name.
 * 3. Every row ends with a proposal of the document's vocabulary.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Spawned = require('./lib/spawned-tools.cjs');

const ROOT = path.resolve(__dirname, '../..');
const DOC = 'docs/design/owned-runtimes.md';
const SECTIONS = Object.freeze({ macos: '3. macOS', linux: '4. Linux' });
// The proposal cell of a row starts with one of these.
const PROPOSALS = /^(?:PIN|SYS|OPT|Delete|Remove|Not applicable)/;
// A row for something the driver does not use carries no proposal.
const NOT_USED = /^Not used/;

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
 * Reads the rows of a driver's table.
 * @param {string} driver Key of SECTIONS.
 * @returns {{ names: Set<string>, rows: string[][] }}
 */
function tableOf(driver) {
	const text = fs.readFileSync(path.join(ROOT, DOC), 'utf8');
	const section = text.split(/\n## /).find((part) => part.startsWith(SECTIONS[driver]));
	assert(section, `${DOC} has no section "${SECTIONS[driver]}"`);
	const rows = section
		.split('\n')
		.filter(
			(line) => line.startsWith('| ') && !/^\|\s*-/.test(line) && !/^\|\s*Tool\s*\|/.test(line)
		)
		.map((line) =>
			line
				.split('|')
				.slice(1, -1)
				.map((cell) => cell.trim())
		);
	assert(rows.length > 0, `the ${driver} table has no row`);
	const names = new Set();
	for (const [tool] of rows) {
		// A row named in words ("curl", "openssl CLI") names its program too.
		for (const word of tool.replace(/`[^`]*`/g, ' ').split(/[\s,()]+/))
			if (word) names.add(word.toLowerCase());
		for (const match of tool.matchAll(/`([^`]+)`/g)) {
			for (const word of match[1].split(/[\s,]+/)) names.add(word.replace(/.*\//, ''));
		}
	}
	return { names, rows };
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
		'return "ready", { chunk = data }'
	].join('\n');
	assert.deepEqual(programsIn(source), []);
});

for (const driver of Object.keys(SECTIONS)) {
	check(`the ${driver} table lists every program the ${driver} driver starts`, () => {
		const derived = Spawned.spawnedTools(driver);
		assert(derived.size > 20, `the extractor found only ${derived.size} ${driver} programs`);
		const { names } = tableOf(driver);
		const missing = [...derived.keys()]
			.filter((name) => !names.has(name))
			.sort()
			.map((name) => `${name} (${derived.get(name).join(', ')})`);
		assert.deepEqual(
			missing,
			[],
			`add a row with a proposal to ${DOC} section ${SECTIONS[driver]} for:\n` + missing.join('\n')
		);
	});

	check(`every ${driver} row ends with a proposal`, () => {
		for (const row of tableOf(driver).rows) {
			const proposal = row[row.length - 1];
			assert(
				PROPOSALS.test(proposal) || NOT_USED.test(row[1]),
				`row "${row[0]}" has no proposal: ${proposal}`
			);
		}
	});
}

if (failures > 0) {
	console.error(`[FAIL] owned runtimes inventory: ${failures} of ${checks} checks failed.`);
	process.exit(1);
}
console.log(`[OK] owned runtimes inventory (${checks} checks).`);
