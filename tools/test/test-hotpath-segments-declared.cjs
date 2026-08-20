// tools/test/test-hotpath-segments-declared.cjs

/**
 * ==============================================================================
 * MODULE: HotPath Segment Inventory
 * DESCRIPTION:
 * Instrumentation is the one kind of code whose absence is invisible. A missing
 * assertion fails a test; a missing segment produces a profile that looks clean
 * because nothing measured the slow part. The performance backlog was written
 * around exactly that: "what is left is mostly unmeasured, and silence reads as
 * optimal".
 *
 * So the segments are inventoried here rather than trusted. Each entry names the
 * hot path it covers and why it exists — a segment deleted during a refactor
 * fails with the reason it was added, not with a diff.
 *
 * WHAT IS CHECKED:
 * 1. Every segment in the inventory is still emitted by the driver.
 * 2. Every segment the driver emits is in the inventory. A new one is cheap to
 *    add and the point is that the list stays the answer to "what is measured" —
 *    a segment nobody wrote down is one nobody looks for in the log.
 * 3. The parse is floored: a regex that stopped matching would report zero
 *    segments and pass over nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'static/ergopti_plus/windows');

// Segment → why it exists. Order is the keystroke path first, then render, then
// idle, because that is the order a latency investigation walks them in.
const INVENTORY = {
	'Hook.KeyDown': 'the first stage of every keystroke: two tap-hold trackers plus the whole EVT_KB_DOWN fan-out, inside the hook callback',
	'Hook.KeyUp': 'the release half of the same path — a slow release is a stuck-feeling key',
	RemapEmit: 'the layout remap that turns a physical key into the emitted one',
	OnChar: 'the character event both the hotstring engine and the LLM bridge consume',
	'HSE.FeedChar': 'the hotstring engine consuming one character',
	'HSE.Dispatch': 'the hotstring engine deciding and firing an expansion',
	'LLM.OnChar': 'the other consumer of every character — the profiler showed slow OnChar events with no matching slow HSE.FeedChar, and this was the only unattributed candidate',
	'KL.Ingest': 'the keylogger ingest, which closes the per-keystroke budget with the hook fan-out',
	'KL.RoiPrune': 'the bounded trigger-ROI survivor selection, measured separately so pruning cost stays distinguishable from per-keystroke ingest',
	'KLR.CandidateClone': 'the O(database-size) SQLite backup paid before an incremental metrics projection can publish atomically',
	'Tooltip.Build': 'building the tooltip GUI rows',
	'Tooltip.ResolvePos': 'resolving where the tooltip goes, including the UIA path',
	'Tooltip.Present': 'the composite present: clamp, prepare, corners, border, reveal (sub-attributed by HotPath_BreakdownMark)',
	'Tooltip.DequeuePresent': 'the same present from the destack rebuild, so a slow row expiry is not mistaken for a slow render',
	'Tooltip.LlmPresent': 'presenting an LLM prediction preview',
	'Tooltip.BorderPixelLoop': 'the per-pixel border draw, the one step that scales with tooltip size',
	'Gesture.Invoke': 'the single choke point all three dispatchers share (gesture, shortcut slot, tap-hold), so one segment covers every user-triggered action',
	'Config.TomlWrite': 'a config save: full read-modify-write plus canonicalisation, run from menu callbacks, so a slow one blocks the tray menu while the user watches',
	'Config.TomlBuild': 'the detached TOML candidate build before a transactional config publication, including exact-subtree reconstruction and stage verification',
	'Updater.Poll': 'the async update check, which calls WaitForResponse(0) on a COM object every tick — a COM call that blocks stalls the whole message pump',
	'Webview.Eval': 'the host-to-page half of the webview bridge — ExecuteScriptAsync is named async but the COM marshalling is not free, and this is what pushes the init payload',
	'UIA.SelectionPoll': 'the idle UI-Automation selection poll',
	'Metrics.FocusRefresh': 'the canonical 20 Hz focus snapshot — WM_GETTEXT has a 5 ms SendMessageTimeoutW deadline and every partial identity fails privacy closed'
};

const errors = [];

function walk(dir, acc = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (['tests', 'vendor', '_generated'].includes(e.name)) continue;
			walk(p, acc);
		} else if (e.name.endsWith('.ahk')) acc.push(p);
	}
	return acc;
}

const declared = new Map();
for (const f of walk(WIN)) {
	const rel = path.relative(ROOT, f).replace(/\\/g, '/');
	const src = fs.readFileSync(f, 'utf8');
	for (const m of src.matchAll(/HotPath_LogIfSlow\(\s*"([^"]+)"/g)) {
		if (!declared.has(m[1])) declared.set(m[1], rel);
	}
}

if (declared.size < 10) {
	errors.push(
		`parsed ${declared.size} HotPath segment(s) from the driver — expected at least 10. The parser ` +
			'drifted, and an inventory over nothing passes forever.'
	);
}

for (const [name, why] of Object.entries(INVENTORY)) {
	if (!declared.has(name)) {
		errors.push(
			`the "${name}" segment is gone. It measured: ${why}. Instrumentation is the one kind of code ` +
				'whose absence is invisible — the profile just looks clean.'
		);
	}
}

for (const [name, where] of declared) {
	if (!INVENTORY[name]) {
		errors.push(
			`"${name}" (${where}) is emitted but not in the inventory. Add it with a line saying what hot ` +
				'path it covers — a segment nobody wrote down is one nobody looks for in the log.'
		);
	}
}





// ==================================================
// ==================================================
// ======= 2/ Pre-Logger Boot Stamps ================
// ==================================================
// ==================================================

// The five stamps taken BEFORE BootProfile_Begin, when the logger does not exist
// yet: they record a tick only, and are replayed as log lines once it does.
// Without them the whole span from process creation to BootProfile_Begin is one
// opaque "script parse + load: ~N ms" with no attribution inside it.
const BOOT_STAMPS = [
	'Bundle extracted',
	'Module includes initialised',
	'Tray reset + onboarding',
	'Config parsed (TOML + i18n)',
	'Hotstring engine initialised'
];

const entry = fs.readFileSync(path.join(WIN, 'ErgoptiPlus.ahk'), 'utf8');
const stamped = [...entry.matchAll(/BootProfile_Stamp\(\s*"([^"]+)"/g)].map((m) => m[1]);

if (stamped.length === 0) {
	errors.push(
		'parsed 0 BootProfile_Stamp call(s) from ErgoptiPlus.ahk — the parser drifted, and the boot ' +
			'stamp check below would pass over nothing'
	);
}
for (const name of BOOT_STAMPS) {
	if (!stamped.includes(name)) {
		errors.push(
			`the pre-logger boot stamp "${name}" is gone. Without it the span from process creation to ` +
				'BootProfile_Begin collapses back into one opaque number with no attribution inside it.'
		);
	}
}
for (const name of stamped) {
	if (!BOOT_STAMPS.includes(name)) {
		errors.push(`ErgoptiPlus.ahk takes a boot stamp "${name}" that is not in the inventory — add it`);
	}
}




// ==================================================
// ==================================================
// ======= 3/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the instrumentation inventory and the driver disagree:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${declared.size} HotPath segment(s) and ${stamped.length} pre-logger boot stamp(s), ` +
		'all declared, all emitted.\x1b[0m'
);
