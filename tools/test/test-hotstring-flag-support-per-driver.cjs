// tools/test/test-hotstring-flag-support-per-driver.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Entry Flags — Which Drivers Honour Them
 * DESCRIPTION:
 * The shared hotstring corpus declares per-entry flags. Not every driver reads
 * every flag. This gate records which, so a flag that exists in the data but in
 * only one engine is a documented divergence rather than a surprise.
 *
 * WHAT WAS MEASURED:
 * `is_case_sensitive_strict` is declared on **1 302 entries** of the SHARED
 * corpus — 1 300 of them in magickey.toml, plus one each in autocorrection.toml
 * and rolls.toml — and implemented in **Windows only**:
 * three production files parse it and turn it into AutoHotkey's `C` hotstring
 * flag. macOS and Linux read the same files and have **zero** references to it.
 *
 * The consequence is behavioural, not cosmetic. `"OUi" = { output = "Oui", …,
 * is_case_sensitive_strict = true }` exists so that typing `oui` does NOT
 * autocorrect — only the exact miscapitalisation `OUi` should. On Windows that
 * holds. On macOS and Linux the flag is ignored, so the entry matches
 * case-insensitively and the autocorrection fires on input it was explicitly
 * written not to fire on.
 *
 * WHY THIS IS A GATE AND NOT A FIX:
 * Implementing the flag means changing the matching path of both engines, and
 * the shared corpus has no vectors for it — the backlog lists exactly that as
 * the precondition, and its figure of 1 302 is exact. Changing case-matching
 * semantics on faith, in the code with the worst bug history in the repo, is how
 * silent regressions get shipped. Recording the divergence is what makes the fix
 * safe to attempt later.
 *
 * The gate fails in BOTH directions: a flag gaining an implementation is good
 * news that should update this record, and a flag appearing in shared data with
 * no implementation anywhere is a new silent divergence.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS_DIR = path.join(SP, '_shared', 'modules', 'hotstrings');
const DRIVERS = ['windows', 'macos', 'linux'];

const errors = [];

// A hotstring editor lets the user TICK a flag; it does not make the matcher
// honour it. Counting `ui/` and `bridge_handlers/` as support recorded Linux as
// supporting auto_expand and final_result when its engine reads neither — the
// flags reach a settings panel, get written to the user's TOML, and are then
// ignored at match time. Measured: Linux has 0 engine-side references to both
// and 2 UI references to each.
const UI_PATH = /(^|\/)(ui|bridge_handlers)\//;

/** Engine-side sources of a driver (tests, generated code and UI excluded). */
function driverSources(driver) {
	const out = [];
	const root = path.join(SP, driver);
	(function walk(d) {
		if (!fs.existsSync(d)) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests' && e.name !== '_generated') walk(p);
			} else if (/\.(lua|ahk)$/.test(e.name)) {
				const rel = path.relative(root, p).split(path.sep).join('/');
				if (UI_PATH.test(rel)) continue;
				out.push(fs.readFileSync(p, 'utf8'));
			}
		}
	})(path.join(SP, driver));
	return out;
}

const sources = Object.fromEntries(DRIVERS.map((d) => [d, driverSources(d)]));
for (const d of DRIVERS) {
	if (sources[d].length < 20) {
		errors.push(`walked only ${sources[d].length} ${d} source file(s) — the scan is broken`);
	}
}

/** How many shared corpus entries declare a flag. */
function declaredCount(flag) {
	let n = 0;
	if (!fs.existsSync(CORPUS_DIR)) return 0;
	for (const f of fs.readdirSync(CORPUS_DIR)) {
		if (!f.endsWith('.toml')) continue;
		const src = fs.readFileSync(path.join(CORPUS_DIR, f), 'utf8');
		n += (src.match(new RegExp(flag + '\\s*=', 'g')) || []).length;
	}
	return n;
}

const supports = (driver, flag) => sources[driver].some((s) => s.includes(flag));

// The recorded state. `drivers` lists every driver that reads the flag today.
const FLAGS = [
	{ flag: 'is_word', drivers: ['windows', 'macos', 'linux'] },
	{
		flag: 'auto_expand',
		drivers: ['windows', 'macos', 'linux'],
		note:
			'CONVERGED. Windows turns it into AHK\'s "*" flag, macOS reads it in keymap/registry.lua, and ' +
			'the shared engine now honours it for Linux: an entry that does not opt in waits for a ' +
			'terminator via the end-char path. Before that, Linux fired every entry the moment its ' +
			'trigger completed, so typing "yaourt" produced "y’aourt" — the "ya" entry firing mid-word.'
	},
	{ flag: 'is_case_sensitive', drivers: ['windows', 'macos', 'linux'] },
	{
		flag: 'final_result',
		drivers: ['windows', 'macos'],
		note:
			'Suppresses the rescan of an expansion result, so one expansion cannot trigger another. ' +
			'Windows and macOS honour it; the Linux engine has no reference to it outside its editor ' +
			'bridges, so on Linux an expansion is always rescanned and entries marked final can chain.'
	},
	{
		flag: 'is_case_sensitive_strict',
		drivers: ['windows'],
		note:
			'Windows turns it into AHK\'s "C" flag. macOS and Linux ignore it, so entries written to ' +
			'match only in their exact case — "OUi" -> "Oui" — match case-insensitively there and ' +
			'autocorrect input they were written to leave alone.'
	}
];

for (const { flag, drivers: expected, note } of FLAGS) {
	const declared = declaredCount(flag);
	if (declared === 0) {
		errors.push(
			`${flag}: no shared corpus entry declares it any more. If it was removed, remove it from ` +
				'this record too; if the corpus moved, this gate is measuring nothing.'
		);
		continue;
	}
	const actual = DRIVERS.filter((d) => supports(d, flag));
	const missing = expected.filter((d) => !actual.includes(d));
	const extra = actual.filter((d) => !expected.includes(d));

	for (const d of missing) {
		errors.push(
			`${flag}: ${d} is recorded as supporting it but has no production reference. ${declared} ` +
				'shared entr(ies) declare it, so those entries now behave differently there.'
		);
	}
	for (const d of extra) {
		errors.push(
			`${flag}: ${d} now reads it, which the record says it does not. That is good news — the ` +
				`divergence is closing. Update this record.${note ? ' Context: ' + note : ''}`
		);
	}
	if (actual.length === 0) {
		errors.push(
			`${flag}: declared on ${declared} shared entr(ies) and read by NO driver. The data says one ` +
				'thing and every engine does another.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] hotstring flag support changed:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

const strict = declaredCount('is_case_sensitive_strict');
console.log(
	`\x1b[32m[OK] hotstring flag support matches the record — including is_case_sensitive_strict, ` +
		`declared on ${strict} shared entr(ies) and honoured by Windows only.\x1b[0m`
);
