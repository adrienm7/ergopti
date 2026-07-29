// tools/test/test-metrics-heatmap-translation.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Heatmap Scancode-Translation Guard
 * DESCRIPTION:
 * Executes the real _shared/ui/metrics_typing/heatmap_win.js and asserts that
 * both payload shapes the dashboard feeds it end up keyed by Hammerspoon
 * keycodes — the numbering the heatmap geometry is built on.
 *
 * ROOT CAUSE ENCODED:
 * Two independent defects made the historical keyboard heatmap wrong on Windows
 * and Linux, and neither of them threw.
 *
 * 1. Shape. The live "today" blob is a per-app map, but the historical block
 *    produced by the AHK range reader is a single FLAT aggregate
 *    ({ c, w, kc, sc_kb }). index.html pushes BOTH through translate_win_today,
 *    which walked the flat one as if `c`, `w`, `kc` and `sc_kb` were application
 *    names. Every one of them came back unchanged (a token→item map has no
 *    sc_kb field), so the historical scancode data was never translated — and
 *    since app_state.data declares no sc_kb slot, the merge then silently
 *    skipped a source key that had no destination.
 *
 * 2. Numbering. translate_win_bucket seeded its output from `app_bucket.kc`,
 *    "defensive in case both fields happen to be populated". On Windows that
 *    slot is ALWAYS populated, from ngram_keycodes, whose values are Windows
 *    VIRTUAL KEY codes. VK and Hammerspoon keycodes collide numerically without
 *    overlapping in meaning (VK 65 = 'A' lands on HS keycode 65 = keypad
 *    decimal), so the heatmap coloured unrelated cells for every key typed.
 *
 * The combined symptom is a heatmap that always renders SOMETHING — which is
 * exactly why it read as a cosmetic quirk rather than as data going nowhere.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const REL = 'static/ergopti_plus/_shared/ui/metrics_typing/heatmap_win.js';
const ABS = p.join(ROOT, REL);

const errors = [];

function check(condition, message) {
	if (!condition) errors.push(message);
}

if (!fs.existsSync(ABS)) {
	errors.push(`${REL}: missing — every PC-scancode dashboard loads this script`);
} else {
	const src = fs.readFileSync(ABS, 'utf8');
	const load = new Function(
		'window',
		`${src}\nreturn { SC_TO_KC, translate_win_bucket, translate_win_today };`
	);
	const api = load({});

	// ── 0. Prerequisites, so no assertion below can pass vacuously ──────────
	const KC_A = api.SC_TO_KC[30];
	const KC_LEFT = api.SC_TO_KC[75];
	check(KC_A === 0, `${REL}: scancode 30 ('a') must map to HS keycode 0, got ${KC_A}`);
	check(
		KC_LEFT !== undefined && api.SC_TO_KC[203] === KC_LEFT,
		`${REL}: scancodes 75 and 203 must both map to the left-arrow keycode`
	);

	// ── 1. The FLAT historical aggregate must be translated ─────────────────
	const hist = api.translate_win_today({
		c: { a: { c: 3 } },
		w: {},
		kc: { 65: { c: 99 } },
		sc_kb: { 30: { c: 7 } }
	});
	check(
		hist && hist.kc && hist.kc[String(KC_A)] && hist.kc[String(KC_A)].c === 7,
		`${REL}: the flat historical block must be translated into kc (expected kc[${KC_A}].c === 7, got ${JSON.stringify(hist && hist.kc)})`
	);
	check(
		hist && hist.c && hist.c.a && hist.c.a.c === 3,
		`${REL}: translating the flat historical block must preserve its other n-gram slots`
	);

	// ── 2. A Windows VK code must never survive into the keycode map ────────
	check(
		hist && hist.kc && hist.kc['65'] === undefined,
		`${REL}: a Windows VIRTUAL KEY code must never survive into kc — the renderer's geometry is keyed by Hammerspoon keycodes, where 65 is the keypad decimal point, not 'A'`
	);

	// ── 3. The per-app today shape still works, and drops VK too ────────────
	const today = api.translate_win_today({
		'chrome.exe': { kc: { 65: { c: 99 } }, sc_kb: { 30: { c: 7 } } }
	});
	const bucket = today && today['chrome.exe'];
	check(
		bucket && bucket.kc && bucket.kc[String(KC_A)] && bucket.kc[String(KC_A)].c === 7,
		`${REL}: the per-app today payload must still be translated per app`
	);
	check(
		bucket && bucket.kc && bucket.kc['65'] === undefined,
		`${REL}: the per-app today payload must drop the Windows VK keycode slot as well`
	);

	// ── 4. Several scancodes may share one physical position ────────────────
	const arrows = api.translate_win_bucket({ sc_kb: { 75: { c: 2 }, 203: { c: 5 } } });
	check(
		arrows && arrows.kc && arrows.kc[String(KC_LEFT)] && arrows.kc[String(KC_LEFT)].c === 7,
		`${REL}: the bare and high-byte forms of one arrow key must sum into a single cell`
	);

	// ── 5. macOS payloads must fall through untouched ───────────────────────
	const mac = { 'Safari': { kc: { 0: { c: 4 } } } };
	const macOut = api.translate_win_today(mac);
	check(
		macOut['Safari'].kc['0'].c === 4,
		`${REL}: a payload with no sc_kb (macOS) must pass through unchanged`
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Metrics heatmap scancode translation is broken:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] heatmap_win.js translates both the flat historical block and the per-app today block into HS keycodes, and never leaks Windows VK codes.\x1b[0m'
);
