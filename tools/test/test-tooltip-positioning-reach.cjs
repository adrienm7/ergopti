// tools/test/test-tooltip-positioning-reach.cjs

/**
 * ==============================================================================
 * MODULE: Tooltip [positioning] Constant Reach
 * DESCRIPTION:
 * Records which drivers actually read each `[positioning]` constant in
 * _shared/modules/tooltip/constants.toml, so a value declared shared and read by
 * one driver — or none — is a documented fact rather than an assumption.
 *
 * WHAT WAS MEASURED:
 *   caret_offset_x / caret_offset_y / max_caret_height  windows + macos
 *   window_bottom_inset_ahk                             windows only (by name)
 *   window_bottom_inset_hs                              macos only  (by name)
 *   window_offset_y                                     macos ONLY — Windows
 *       never reads it, though nothing in its comment says so. It is described
 *       as "the vertical gap between the bottom of an input-box or window anchor
 *       and the tooltip top edge", which reads as a shared layout rule.
 *   anchor_cascade                                      DELETED — see below.
 *   Linux reads none of them: its tooltip renderer shares no positioning maths.
 *
 * THE anchor_cascade CASE, KEPT BECAUSE IT IS THE ARGUMENT FOR THIS GATE:
 * It was honestly labelled "(informative — drivers implement this)", so nobody
 * consuming it was not a bug. But it was a four-element array, and the comment
 * three lines above it said "AHK adds a step between 2 and 3: mouse cursor
 * coordinates" — so the data was already wrong for one driver, according to its
 * own documentation, and no code path could ever notice. It is prose now, with
 * the AHK step in it, and the check below asserts it does not come back.
 *
 * WHY A RECORD RATHER THAN A FIX:
 * Making Windows read window_offset_y would change where tooltips appear, and
 * the two drivers have separate bottom-inset constants precisely because their
 * anchors differ. That is a product decision about tooltip placement, not a
 * cleanup. What is safe and useful today is that the asymmetry stops being
 * invisible.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const TOML = path.join(SP, '_shared', 'modules', 'tooltip', 'constants.toml');

const errors = [];
const src = fs.readFileSync(TOML, 'utf8');

// Keys declared under [positioning].
const start = src.indexOf('[positioning]');
if (start === -1) {
	console.error('\x1b[31m[ERROR] constants.toml has no [positioning] section.\x1b[0m');
	process.exit(1);
}
const rest = src.slice(start + '[positioning]'.length);
const end = rest.indexOf('\n[');
const section = end === -1 ? rest : rest.slice(0, end);
const keys = [...section.matchAll(/^([a-z_][a-z0-9_]*)\s*=/gm)].map((m) => m[1]);

/** Production sources of a driver. */
function sources(driver, ext) {
	const out = [];
	(function walk(d) {
		if (!fs.existsSync(d)) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests') walk(p);
			} else if (e.name.endsWith(ext)) {
				out.push(fs.readFileSync(p, 'utf8'));
			}
		}
	})(path.join(SP, driver));
	return out;
}

const drivers = {
	windows: sources('windows', '.ahk'),
	macos: sources('macos', '.lua'),
	linux: sources('linux', '.lua')
};
for (const [d, files] of Object.entries(drivers)) {
	if (files.length < 20) errors.push(`walked only ${files.length} ${d} file(s) — the scan is broken`);
}

const reads = (driver, key) => drivers[driver].some((s) => new RegExp(`\\b${key}\\b`).test(s));

// The recorded state: which drivers read each key today.
// Linux joined every shared positioning value when its tooltip stopped being
// absent. That is the direction this gate exists to reward: three drivers
// reading one number rather than three carrying their own.
const RECORD = {
	caret_offset_x: ['windows', 'macos', 'linux'],
	caret_offset_y: ['windows', 'macos', 'linux'],
	max_caret_height: ['windows', 'macos', 'linux'],
	window_bottom_inset_ahk: ['windows'],
	window_bottom_inset_hs: ['macos'],
	window_bottom_inset_linux: ['linux'],
	window_offset_y: ['macos', 'linux']
};

for (const key of keys) {
	if (!(key in RECORD)) {
		errors.push(
			`${key}: a new [positioning] constant with no recorded reach. Add it here with the ` +
				'drivers that read it — a shared constant read by one driver is the thing this gate exists ' +
				'to keep visible.'
		);
		continue;
	}
	const expected = RECORD[key];
	const actual = ['windows', 'macos', 'linux'].filter((d) => reads(d, key));
	const gained = actual.filter((d) => !expected.includes(d));
	const lost = expected.filter((d) => !actual.includes(d));

	for (const d of gained) {
		errors.push(
			`${key}: ${d} now reads it, which the record says it does not. If a driver adopted a shared ` +
				'positioning value that is good news — update the record.'
		);
	}
	for (const d of lost) {
		errors.push(
			`${key}: ${d} no longer reads it. Either the constant became dead there, or it was renamed ` +
				'and the tooltip now positions itself with a default nobody chose.'
		);
	}
}

for (const key of Object.keys(RECORD)) {
	if (!keys.includes(key)) {
		errors.push(`${key}: recorded here but no longer declared in [positioning] — the record is stale`);
	}
}

// anchor_cascade is GONE, and this asserts it stays gone. It was a four-element
// array labelled "informative — drivers implement this", read by nothing, and the
// paragraph directly above it said "AHK adds a step between 2 and 3" — so the data
// contradicted its own documentation and no code path could ever notice. It is
// prose now. A constant nothing consumes cannot go stale loudly, so it goes stale
// quietly, which is the whole reason this gate measures reach in the first place.
if (/^s*anchor_cascades*=/m.test(section)) {
	errors.push(
		'anchor_cascade is back in [positioning]. It was deleted because nothing read it and ' +
			'it disagreed with the comment beside it. If a driver now genuinely consumes an ' +
			'anchor cascade, the five prose steps — including the AHK-only mouse-cursor step — ' +
			'must be reconciled with the data before it returns.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] tooltip [positioning] constant reach:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

const shared = keys.filter((k) => RECORD[k] && RECORD[k].length > 1).length;
console.log(
	`\x1b[32m[OK] all ${keys.length} [positioning] constant(s) are read by the drivers recorded ` +
		`(${shared} genuinely shared; window_offset_y macOS-only; anchor_cascade deleted).\x1b[0m`
);
