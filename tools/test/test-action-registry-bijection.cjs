// tools/test/test-action-registry-bijection.cjs

/**
 * ==============================================================================
 * MODULE: Action Registry ↔ Handler Bijection (I4)
 * DESCRIPTION:
 * Every single-gesture action the registry declares for a platform must have its
 * id named in that driver. Every driver is held at zero unresolved actions.
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
 * The Linux backlog was ratcheted from 39 to 28, 17, 11, and finally zero.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const REGISTRY = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const SITE_LOADER = fs.readFileSync(
	path.join(ROOT, 'src', 'routes', 'ergopti-plus', '+page.server.js'),
	'utf8'
);

// Frozen on 2026-08-01. Windows and macOS at zero: a new action declared for
// either without a handler must fail on the first one.
//
// linux 39 → 28 → 17 on 2026-08-06, in two steps worth telling apart.
//
// Ten of the first eleven were not missing CODE: the shared registry described
// the chord for AutoHotkey and Hammerspoon and simply had no `emit_linux`
// column, so the generator emitted no row and the action fell through to
// "Unknown action" at DEBUG. Filling the column in
// _shared/modules/actions/actions.toml wired all ten at once, which is what a
// single source is for — and is why a driver-shaped gap is worth checking in the
// DATA before it is checked in the driver. (The parity test caught the tail of
// it in the same commit: two of those chords named letter keys the combo
// emitter's keysym table did not carry, so they would have parsed and pressed
// nothing.)
//
// The next eleven were real handlers: the driver's own windows and files —
// open_metrics_typing, open_config, open_today_log and their siblings — all
// declared platform = "all" and all reaching the same silent DEBUG branch. The
// picker had been offering them as bindable on Linux the whole time.
//
// 17 → 11: the six screenshot actions. No single binary takes a screenshot on
// every Linux desktop, so each is a cascade — Wayland candidates FIRST, because
// the X11 tools talk to nothing under Wayland and exit zero, which would make a
// cascade ordered the other way "succeed" while capturing nothing.
const BASELINE = { ahk: 0, hs: 0, linux: 0 };

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
const HEADER_FIELD = /^is_header\s*=\s*true\s*$/m;

const errors = [];
const summary = [];

if (!/ACTIONS_ROOT[\s\S]*?modules[/\\]actions/.test(SITE_LOADER)
	|| !/resolve\(ACTIONS_ROOT,\s*'actions\.toml'\)/.test(SITE_LOADER)) {
	errors.push('the Ergopti+ site must read the canonical modules/actions/actions.toml registry');
}
if (/modules[/\\]gestures/.test(SITE_LOADER)) {
	errors.push('the Ergopti+ site still reads the retired shared modules/gestures path');
}

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
	const body = t.body.join('\n');
	if (HEADER_FIELD.test(body)) continue;
	const pm = body.match(PLATFORM_FIELD);
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
				`raise the baseline.\n      unresolved: ${unresolved.map((a) => a.id).join(', ')}`
		);
	}
	// A ratchet that only ever catches a rise lets the gap re-open silently after
	// it has been closed: someone deletes a handler, the count returns to the old
	// baseline, and the gate is green about a regression. Lowering it is the
	// second half of the mechanism, and it has to be enforced or it is a comment.
	if (unresolved.length < BASELINE[drv.key]) {
		errors.push(
			`${drv.key}: only ${unresolved.length} unresolved action(s) remain (baseline ` +
				`${BASELINE[drv.key]}). Lower BASELINE.${drv.key} to ${unresolved.length} in this file — a ` +
				'baseline left above the real count is headroom for the next regression to hide in.'
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
