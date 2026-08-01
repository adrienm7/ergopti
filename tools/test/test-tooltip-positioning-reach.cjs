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
 *   anchor_cascade                                      NO driver reads it.
 *   Linux reads none of them: its tooltip renderer shares no positioning maths.
 *
 * THE anchor_cascade CASE IS WORTH READING TWICE:
 * It is honestly labelled "(informative — drivers implement this)", so nobody
 * consuming it is not a bug. But it is a four-element array, and the comment
 * three lines above it says "AHK adds a step between 2 and 3: mouse cursor
 * coordinates" — so the data is already wrong for one driver, according to its
 * own documentation, and no code path could ever notice. An informative constant
 * that contradicts the prose beside it is worse than prose alone.
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
const RECORD = {
	caret_offset_x: ['windows', 'macos'],
	caret_offset_y: ['windows', 'macos'],
	max_caret_height: ['windows', 'macos'],
	window_bottom_inset_ahk: ['windows'],
	window_bottom_inset_hs: ['macos'],
	window_offset_y: ['macos'],
	anchor_cascade: []
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

// anchor_cascade: informative, and already contradicted by the prose beside it.
{
	const m = section.match(/anchor_cascade\s*=\s*\[([^\]]*)\]/);
	if (!m) {
		errors.push('anchor_cascade is no longer an array — the record below describes one');
	} else {
		const steps = m[1].split(',').filter((x) => x.trim()).length;
		if (steps !== 4) {
			errors.push(
				`anchor_cascade now lists ${steps} step(s); the record describes 4. Its own comment says ` +
					'"AHK adds a step between 2 and 3", so the array was already wrong for one driver — ' +
					'if that is being fixed, update this gate deliberately.'
			);
		}
		if (!section.includes('informative')) {
			errors.push(
				'anchor_cascade is no longer marked informative. If a driver now reads it, the comment ' +
					'claiming AHK inserts an extra step must be reconciled with the data first.'
			);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] tooltip [positioning] constant reach:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

const shared = keys.filter((k) => RECORD[k] && RECORD[k].length > 1).length;
console.log(
	`\x1b[32m[OK] all ${keys.length} [positioning] constant(s) are read by the drivers recorded ` +
		`(${shared} genuinely shared; window_offset_y macOS-only; anchor_cascade informative).\x1b[0m`
);
