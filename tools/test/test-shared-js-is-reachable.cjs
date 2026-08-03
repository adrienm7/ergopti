// tools/test/test-shared-js-is-reachable.cjs

/**
 * ==============================================================================
 * MODULE: Shared JS Reachability
 * DESCRIPTION:
 * `_shared/modules/**\/*.js` holds logic meant to be ONE implementation across
 * three drivers. A module earns that only two ways:
 *   - **runtime-mirrored** — a driver file names it, so the port it was extracted
 *     from is really reading from it or mirroring it deliberately; or
 *   - **oracle** — it declares test vectors that a corpus consumer replays, so
 *     the drivers' own implementations are checked against it.
 *
 * A module that is neither is a design that was written and never adopted. It
 * still loads, still passes `test-shared-js-is-loadable.cjs`, still looks like
 * shared logic in the tree — and nothing anywhere depends on it being correct.
 * That is the most expensive kind of dead code, because it reads as the answer.
 *
 * Measured 2026-08-03: ONE module is in that state — `draw_calls.js`, 433 lines,
 * a draw-call IR that no driver implements because Windows and macOS both render
 * natively. It is declared below with that reason rather than deleted, because
 * "adopt the IR or drop it" is a design decision, not a cleanup.
 *
 * `lifecycle.js` looked like a second case and is not: windows/ui/tooltip/
 * helpers.ahk names it as the canonical phase list it implements, which is this
 * repo's way of declaring a ported twin. What it lacks is a CORPUS — the mirror
 * is a claim, not a gate — and that is a smaller, separate follow-up.
 *
 * WHAT IS CHECKED:
 * 1. Every shared JS module is runtime-mirrored, or an oracle, or declared here.
 * 2. A declared module that becomes reachable fails, so the note cannot go stale
 *    while the module quietly earns its place.
 * 3. The count of unreachable modules may only fall.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static/ergopti_plus/_shared/modules');
const DRIVERS = ['windows', 'macos', 'linux'];

// Shared JS that is currently neither runtime-mirrored nor an oracle, with why.
// This list may only shrink: adopt the module, give it vectors, or delete it.
const DECLARED_UNREACHABLE = {
	'tooltip/draw_calls.js':
		'defines a draw-call IR that no driver implements — Windows and macOS both render natively. ' +
		'Named only by TooltipRenderer.spec.js prose. Adopting the IR or dropping it is a design decision',
};

const errors = [];

function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) walk(p, acc);
		else acc.push(p);
	}
	return acc;
}

/** Every driver + tools file that could name a shared module. */
function corpusFiles() {
	const out = [];
	for (const d of DRIVERS) out.push(...walk(path.join(ROOT, 'static/ergopti_plus', d)));
	out.push(...walk(path.join(ROOT, 'tools')));
	out.push(...walk(path.join(ROOT, 'static/ergopti_plus/_shared/core')));
	return out.filter((f) => /\.(js|cjs|mjs|lua|ahk)$/.test(f));
}

const modules = walk(SHARED).filter((f) => f.endsWith('.js'));
if (modules.length < 3) {
	errors.push(`found ${modules.length} shared JS module(s) — expected at least 3; the scan is broken`);
}

const files = corpusFiles();
if (files.length < 100) {
	errors.push(`scanned ${files.length} consumer file(s) — expected at least 100; the scan is broken`);
}
const blobs = files.map((f) => {
	try {
		return { rel: path.relative(ROOT, f).replace(/\\/g, '/'), src: fs.readFileSync(f, 'utf8') };
	} catch {
		return { rel: '', src: '' };
	}
});

const unreachable = [];
for (const mod of modules) {
	const rel = path.relative(SHARED, mod).replace(/\\/g, '/');
	const src = fs.readFileSync(mod, 'utf8');
	const base = path.basename(mod, '.js');

	// Oracle: it declares vectors a corpus consumer can replay.
	const isOracle = /TestVectors|testVectors/.test(src);

	// Runtime-mirrored: a DRIVER file names it. tools/ and the port specs do not
	// count — a gate that loads every shared module would otherwise mark them all
	// reachable, which is the exact false green this file exists to prevent.
	const isMirrored = blobs.some(
		(b) =>
			b.rel.startsWith('static/ergopti_plus/') &&
			!b.rel.startsWith('static/ergopti_plus/_shared/') &&
			!/\/tests?\//.test(b.rel) &&
			(b.src.includes(`tooltip/${base}`) || b.src.includes(`modules/${rel}`))
	);

	if (isOracle || isMirrored) {
		if (DECLARED_UNREACHABLE[rel]) {
			errors.push(
				`${rel} is now ${isOracle ? 'an oracle' : 'runtime-mirrored'}, but is still declared ` +
					'unreachable. Remove the entry — a stale reason is worse than none.'
			);
		}
		continue;
	}

	unreachable.push(rel);
	if (!DECLARED_UNREACHABLE[rel]) {
		errors.push(
			`${rel} is neither runtime-mirrored nor an oracle, and nothing records why. Shared logic that ` +
				'no driver reads and no corpus checks still loads, still passes the loadable gate, and still ' +
				'reads as the answer — while nothing depends on it being correct.'
		);
	}
}

for (const rel of Object.keys(DECLARED_UNREACHABLE)) {
	if (!modules.some((m) => path.relative(SHARED, m).replace(/\\/g, '/') === rel)) {
		errors.push(`"${rel}" is declared unreachable but no longer exists — the note is stale`);
	}
}

const BASELINE_UNREACHABLE = 1;
if (unreachable.length > BASELINE_UNREACHABLE) {
	errors.push(
		`unreachable shared JS modules rose to ${unreachable.length} (baseline ${BASELINE_UNREACHABLE}): ` +
			unreachable.join(', ')
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] shared JS reachability:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${modules.length} shared JS module(s): ${modules.length - unreachable.length} runtime-mirrored ` +
		`or oracle, ${unreachable.length} declared unreachable with a reason (baseline ${BASELINE_UNREACHABLE}).\x1b[0m`
);
