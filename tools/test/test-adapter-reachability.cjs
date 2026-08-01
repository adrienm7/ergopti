// tools/test/test-adapter-reachability.cjs

/**
 * ==============================================================================
 * MODULE: Adapter Reachability
 * DESCRIPTION:
 * An adapter with no production caller is not an implementation, it is a claim.
 * This gate counts, per driver, how many adapters nothing requires, and ratchets
 * that count downward.
 *
 * WHAT IT MEASURED ON ARRIVAL, and why the backlog figure was wrong:
 * the recorded estimate was "3 101 lines of dead adapter code — 12 of 21 Windows
 * adapters and 11 of 21 Linux ones have no production caller". Re-measured:
 *
 *   macOS   24 adapters,  0 unreferenced
 *   Windows 21 adapters,  0 unreferenced   (recorded: 12)
 *   Linux   23 adapters,  9 unreferenced, 1 540 lines   (recorded: 11)
 *
 * Windows is clean, and the real total is half the recorded one and confined to
 * one driver. The earlier count almost certainly matched on the adapter's NAME
 * rather than on its module path: "clipboard" appears in three Linux production
 * files, every one of them prose — a comment about the clipboard injection mode
 * — while nothing requires `adapters.clipboard`. Searching for a word finds
 * discussion; searching for the require finds wiring.
 *
 * WHY IT DOES NOT DELETE THEM:
 * two of the nine (notifier, tooltip_renderer) are named by
 * linux/tests/unit/meta/test_port_adapter_presence.lua, which asserts that each
 * declared port HAS an adapter file. So the nine are not accidents: they exist
 * because the architecture declares the port. Removing them means shrinking
 * `contracts.json` to the ports with real traffic and superseding ADR-001 with
 * the measured reality — a decision about the hexagonal boundary, not a cleanup.
 * The count is frozen here so it cannot grow while that decision is pending.
 *
 * WHY A MODULE-PATH SCAN AND NOT A NAME SCAN:
 * see above. This looks for `adapters.<stem>` / `adapters/<stem>` /
 * `adapters\<stem>`, which is how a Lua require and an AutoHotkey include both
 * spell it, and never for the bare stem.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DRIVERS = ['macos', 'windows', 'linux'];

// Never production: tests, third-party code, generated output, build residue.
const SKIP_DIRS = new Set(['tests', 'vendor', '_generated', 'build', '.venv', 'node_modules']);

/** Every production source file of a driver. */
function productionFiles(driver) {
	const out = [];
	(function walk(d) {
		if (!fs.existsSync(d)) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			if (e.isDirectory()) {
				if (!SKIP_DIRS.has(e.name)) walk(path.join(d, e.name));
			} else if (/\.(lua|ahk)$/.test(e.name)) {
				out.push(path.join(d, e.name));
			}
		}
	})(path.join(SP, driver));
	return out;
}

// Recorded state. Lower these as adapters gain callers or are removed; never
// raise one to make a change pass — a new unreferenced adapter is a port claimed
// and not wired, which is the thing this gate exists to stop.
const BASELINE_UNREFERENCED = {
	macos: 0,
	windows: 0,
	linux: 9
};

const errors = [];
const report = [];

for (const driver of DRIVERS) {
	const adapterDir = path.join(SP, driver, 'adapters');
	if (!fs.existsSync(adapterDir)) {
		errors.push(`${driver}/adapters/ does not exist — this gate is measuring nothing for it`);
		continue;
	}
	const adapters = fs
		.readdirSync(adapterDir)
		.filter((f) => /\.(lua|ahk)$/.test(f))
		.sort();
	const sources = productionFiles(driver).map((p) => ({
		p,
		src: fs.readFileSync(p, 'utf8')
	}));

	if (adapters.length === 0 || sources.length < 20) {
		errors.push(
			`${driver}: walked ${adapters.length} adapter(s) and ${sources.length} source file(s) — ` +
				'the scan is broken, and a ratchet over nothing passes forever'
		);
		continue;
	}

	const unreferenced = [];
	for (const a of adapters) {
		const stem = a.replace(/\.(lua|ahk)$/, '');
		const self = path.join(adapterDir, a);
		const needles = [`adapters.${stem}`, `adapters/${stem}`, `adapters\\${stem}`];
		const hasCaller = sources.some(
			({ p, src }) => p !== self && needles.some((n) => src.includes(n))
		);
		if (!hasCaller) {
			const lines = fs.readFileSync(self, 'utf8').split('\n').length;
			unreferenced.push({ file: a, lines });
		}
	}

	const baseline = BASELINE_UNREFERENCED[driver];
	const deadLines = unreferenced.reduce((n, u) => n + u.lines, 0);
	report.push(
		`${driver}: ${adapters.length} adapter(s), ${unreferenced.length} unreferenced` +
			(deadLines ? ` (${deadLines} lines)` : '')
	);

	if (unreferenced.length > baseline) {
		errors.push(
			`${driver}: ${unreferenced.length} adapter(s) have no production caller, above the ` +
				`recorded ${baseline} — ${unreferenced.map((u) => u.file).join(', ')}. An adapter ` +
				'nothing requires is a port declared and not wired: the presence gates still pass, ' +
				'the compliance gates still pass, and no code path reaches it.'
		);
	}
	if (unreferenced.length < baseline) {
		errors.push(
			`${driver}: down to ${unreferenced.length} unreferenced adapter(s) from ${baseline} — ` +
				'good news. Lower the baseline in this file to lock the gain in.'
		);
	}
}

if (process.argv.includes('--measure')) {
	for (const line of report) console.log(line);
	for (const driver of DRIVERS) {
		const adapterDir = path.join(SP, driver, 'adapters');
		if (!fs.existsSync(adapterDir)) continue;
		const sources = productionFiles(driver).map((p) => ({ p, src: fs.readFileSync(p, 'utf8') }));
		const dead = fs
			.readdirSync(adapterDir)
			.filter((f) => /\.(lua|ahk)$/.test(f))
			.filter((a) => {
				const stem = a.replace(/\.(lua|ahk)$/, '');
				const self = path.join(adapterDir, a);
				const needles = [`adapters.${stem}`, `adapters/${stem}`, `adapters\\${stem}`];
				return !sources.some(({ p, src }) => p !== self && needles.some((n) => src.includes(n)));
			});
		if (dead.length) console.log(`\n${driver} unreferenced:\n  ` + dead.join('\n  '));
	}
	process.exit(0);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] adapter reachability:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	console.error('    Run with --measure for the full list.');
	process.exit(1);
}

console.log(`\x1b[32m[OK] adapter reachability — ${report.join('; ')}.\x1b[0m`);
