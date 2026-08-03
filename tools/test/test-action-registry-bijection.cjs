// tools/test/test-action-registry-bijection.cjs

/**
 * ==============================================================================
 * MODULE: Action Registry ↔ Handler Bijection (I4)
 * DESCRIPTION:
 * Every single-gesture action the registry declares for a platform must have its
 * id named in that driver. Windows and macOS are held at **zero** unresolved;
 * Linux is frozen at the 39 it is missing.
 *
 * WHAT AN UNRESOLVED ACTION DOES:
 * The action picker builds its list from `actions.toml`, so a declared action is
 * offered to the user as something they can bind to a gesture. If the driver has
 * no handler for that id, the binding is accepted, stored, and does nothing when
 * the gesture fires. There is no error at bind time and none at fire time — the
 * gesture simply has no effect, which reads as a gesture-recognition problem
 * rather than a missing handler, and that is where the debugging goes.
 *
 * WHY `ax_actions` ARE EXCLUDED:
 * The axis actions are dispatched by composing the key at runtime —
 * `_SecKey := "ax_actions." . _Item` in windows/modules/gestures/actions.ahk —
 * so their ids never appear as literals anywhere. Counting them made Windows
 * look 13 short when it is not missing one. That is the same composed-name trap
 * that made the menu guard misjudge two manifest sections, and it is why the
 * exclusion is stated here rather than being a silent filter.
 *
 * THE REAL NUMBERS (2026-08-01):
 * Windows 134 declared / 0 unresolved. macOS 103 / 0. Linux 94 / 39 — the
 * driver implements the gesture layer but not most of the single-gesture text
 * and window actions. Lower the Linux baseline as handlers land. Never raise it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const REGISTRY = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');

// Frozen on 2026-08-01. Windows and macOS at zero: a new action declared for
// either without a handler must fail on the first one.
const BASELINE = { ahk: 0, hs: 0, linux: 39 };

// Floors on the declared count per driver — a manifest walk that collapses
// would report nothing unresolved and pass having compared nothing.
const MIN_DECLARED = { ahk: 100, hs: 80, linux: 70 };

const DRIVERS = [
	{ key: 'ahk', dir: 'windows', ext: '.ahk' },
	{ key: 'hs', dir: 'macos', ext: '.lua' },
	{ key: 'linux', dir: 'linux', ext: '.lua' }
];

// Only the single-gesture family is checked by id; see the docstring.
const CHECKED_FAMILY = 'sg_actions';

const TABLE_HEADER = /^(\[+)([A-Za-z0-9_.]+)(\]+)\s*$/;
const PLATFORM_FIELD = /^platform\s*=\s*"([^"]+)"/m;

const errors = [];
const summary = [];

/**
 * True when a `platform` field claims a driver.
 *
 * The field is "all", one driver key, or a comma-separated list of them. The
 * list form exists because the field could not previously say "two drivers out
 * of three": the two window cyclers ship on macOS and Windows and not on Linux,
 * and both single-value answers were false — "all" declared two rows Linux
 * cannot perform, "hs" or "ahk" hid half the feature.
 * @param {string} platform The declared field.
 * @param {string} driver The driver key to test.
 * @returns {boolean}
 */
function claims(platform, driver) {
	if (platform === 'all') return true;
	return String(platform).split(',').map((s) => s.trim()).includes(driver);
}

if (!fs.existsSync(REGISTRY)) {
	console.error('\x1b[31m[ERROR] actions.toml is missing.\x1b[0m');
	process.exit(1);
}

// Accumulate each table body under its header.
const tables = [];
let current = null;
for (const line of fs.readFileSync(REGISTRY, 'utf8').split(/\r?\n/)) {
	const m = line.match(TABLE_HEADER);
	if (m) {
		if (current) tables.push(current);
		current = { name: m[2], body: [] };
		continue;
	}
	if (current) current.body.push(line);
}
if (current) tables.push(current);

const actions = [];
for (const t of tables) {
	const dot = t.name.indexOf('.');
	if (dot < 0) continue;
	if (t.name.slice(0, dot) !== CHECKED_FAMILY) continue;
	const pm = t.body.join('\n').match(PLATFORM_FIELD);
	actions.push({ id: t.name.slice(dot + 1), platform: pm ? pm[1] : 'all' });
}

if (actions.length < 80) {
	errors.push(
		`parsed only ${actions.length} ${CHECKED_FAMILY} row(s) — the registry walk is broken, and every ` +
			'driver would then look fully wired'
	);
}

for (const drv of DRIVERS) {
	const base = path.join(SP, drv.dir);
	if (!fs.existsSync(base)) {
		errors.push(`${drv.dir}: driver directory is missing`);
		continue;
	}

	const chunks = [];
	(function walk(dir) {
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests' && e.name !== 'vendor' && e.name !== 'node_modules') walk(p);
			} else if (path.extname(e.name) === drv.ext) {
				chunks.push(fs.readFileSync(p, 'utf8'));
			}
		}
	})(base);
	const corpus = chunks.join('\n');

	// "all" means every platform; otherwise the row names the drivers it ships
	// on, as one key or a comma-separated list of them.
	const declared = actions.filter((a) => claims(a.platform, drv.key));

	if (declared.length < MIN_DECLARED[drv.key]) {
		errors.push(
			`${drv.key}: only ${declared.length} action(s) declared (floor ${MIN_DECLARED[drv.key]}) — the ` +
				'platform filter is broken and this comparison means nothing'
		);
		continue;
	}

	const unresolved = declared.filter(
		(a) => !corpus.includes(`"${a.id}"`) && !corpus.includes(`'${a.id}'`)
	);
	summary.push(`${drv.key} ${unresolved.length}/${BASELINE[drv.key]}`);

	if (unresolved.length > BASELINE[drv.key]) {
		errors.push(
			`${drv.key}: ${unresolved.length} declared action(s) have no handler in ${drv.dir}/ (baseline ` +
				`${BASELINE[drv.key]}). The picker offers every declared action as bindable, so the user ` +
				'binds it, the binding is stored, and the gesture then does nothing when it fires — no ' +
				'error at bind time and none at fire time. Wire it up, or restrict its platform. Do NOT ' +
				`raise the baseline.\n      unresolved: ${unresolved.slice(0, 8).map((a) => a.id).join(', ')}` +
				`${unresolved.length > 8 ? `, +${unresolved.length - 8} more` : ''}`
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action registry bijection:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] declared actions with no handler: ${summary.join(', ')} ` +
		`(${actions.length} ${CHECKED_FAMILY} rows).\x1b[0m`
);
