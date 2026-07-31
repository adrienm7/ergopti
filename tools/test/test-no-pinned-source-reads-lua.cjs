// tools/test/test-no-pinned-source-reads-lua.cjs

/**
 * ==============================================================================
 * MODULE: Location-Pinned Source-Read Ratchet (macOS Lua tests)
 * DESCRIPTION:
 * macOS twin of test-no-pinned-source-reads.cjs (the AHK ratchet). Freezes the
 * count of macOS test_*.lua files that read a driver SOURCE file by a hardcoded
 * path — io.open(driver_root() .. "modules/keymap/input_sources.lua") and the
 * like — instead of loading the module and asserting behaviour, or scanning via
 * a move-resilient whole-tree helper. These path-pinned introspection tests are
 * the macOS half of the #1 refactor pain (far more numerous than the 19 on AHK):
 * a `git mv` of the cited file breaks them with a path error, never a behaviour
 * signal, so they discourage the structural splits the project wants.
 *
 * TWO COUNTS, BECAUSE ONE WAS MEASURING THE WRONG THING:
 * The file count says how many test files pin a path; the read count says how
 * many pins exist (31 files, 40 reads). A file already on the list could add
 * pins for free, and the helper exemption is per file. A `git mv` breaks the
 * read, not the file, so the read is the unit that gets ratcheted.
 *
 * ROOT CAUSE ENCODED:
 * A test that concatenates driver_root() with a quoted "(modules|lib|ui)/….lua"
 * path is location-pinned. This ratchet counts them and FAILS if the count rises
 * above the frozen baseline. Lower (never raise) the baseline as tests migrate
 * to behaviour assertions or a move-resilient symbol-keyed scan (the
 * move-resilience checks). It is the test twin of the OS-purity ratchets and of the AHK
 * pinned-read ratchet.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const TESTS_DIR = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'tests');

// Frozen baseline — the current count of path-pinned source-reading macOS test
// files. Drive toward zero by migrating each to a behaviour assertion or a
// move-resilient helper; NEVER raise it to make a new test pass.
// History: 134 → 133 (one test converted to behaviour)
//          133 → 134 (H-1 regression: test_menu_state_keeps_script_control.lua §1 is a
//                     deliberate source invariant; §2 provides the stronger behaviour
//                     guarantee via spy — intentional, not accidental)
//          134 → 136 (user audit 2026-06-30: three new deliberate source invariants —
//                     test_mlx_warmup_timeout_cancel.lua, test_menu_quit_mlx_teardown.lua,
//                     test_menu_state_keeps_script_control.lua §1 — each backed by a
//                     stronger behaviour assertion in a companion section)
//          136 → 140 (four new deliberate source invariants added with bug-fix commits:
//                     test_day_rollover_drain.lua §2 (drain-loop guard),
//                     test_api_token_lazy_decrypt.lua (init.lua + api_remote.lua source scan),
//                     test_ollama_manager_nonblocking.lua §1 (blocking-call source guard))
//          140 → 153 (2026-07-01 audit implementation pass: 13 new deliberate source
//                     invariants, each either audit-prescribed (a source-only check is
//                     the audit's own proposed test for a narrow mechanical fix — e.g.
//                     test_mlx_manager_delete_nonblocking.lua's "no os.execute('rm -rf'
//                     remains, hs.task.new + '-rf' + _active_tasks present" check,
//                     test_api_mlx_discovery_dead_constant_removed.lua's "constant is
//                     gone" check — behaviorally untestable, absence is inherently a
//                     source fact) or backed by a stronger companion behaviour section
//                     in the same file (test_wpm_timer_callbacks_pcall.lua,
//                     test_tooltip_llm_is_visible_after_render_crash.lua,
//                     test_disable_all_releases_clicklock.lua,
//                     test_synthetic_paste_not_logged_as_shortcut.lua,
//                     test_context_tracker_ax_focused_element_pcall.lua,
//                     test_wpm_widget_mouse_callback_stale_geometry.lua,
//                     test_wpm_darken_hex_malformed_input.lua) or a documented
//                     faithful-mirror test pinned against source because the real
//                     function is gated behind private module state unreachable from
//                     the headless stub (test_notify_synthetic_malformed_utf8.lua,
//                     same accepted shape as test_synth_queue_drain.lua's
//                     simulate_drain), plus test_api_mlx_discovery_generation_guard.lua,
//                     test_menu_metrics_master_toggle_pause_gate.lua, and
//                     test_menu_quit_karabiner_ownership.lua)
//          153 → 156 (session 2026-07-10: macOS source-scan tests added —
//                     test_update_preview_early_out.lua (source assertions on
//                     llm_bridge.lua) and test_ignored_window_deferred_buffer_snapshot.lua
//                     (source assertions on init.lua). This ratchet scans macos/tests
//                     ONLY: the .ahk source-scans go to test-no-pinned-source-reads.cjs
//                     and Linux .lua source-scans (e.g. test_injector_commands.lua) are
//                     not counted here at all.)
//          156 → 34 (fix-pinned-source-reads.cjs converted 153 reads once it was
//                     taught the two other handle shapes in the tree —
//                     assert(io.open(…)) and an explicit `if not fh then error(…)
//                     end` — neither of which is any more ambiguous than the bare
//                     io.open it already accepted. The 20 that remain need a human:
//                     their target module has no declaration unique to it, so
//                     read_driver_source would concatenate several files and
//                     silently change what the test asserts.)
const BASELINE = 32;

// Second frozen baseline — the count of individual pinned READS, not of files.
//
// Counting files alone left two holes, and both are the kind a ratchet is
// supposed to make impossible. A file already on the list was free: it could
// grow from one pinned read to ten and the number never moved. And the helper
// exemption below is per FILE, so a test that used read_driver_source() once
// could pin any number of raw paths beside it and disappear from the count
// entirely. The unit a `git mv` breaks is the read, so the read is what gets
// ratcheted. This count deliberately ignores HELPER_RE: raw pins are counted
// even in a file that is otherwise move-resilient.
// History: 40 (first measurement, 2026-07-31 — 32 files, so 8 reads were
//              invisible to the per-file count)
const READ_BASELINE = 40;

// A move-resilient scan helper (symbol-keyed whole-tree read), so converting a
// test to one of these drops it from the FILE count (never from the read count).
const HELPER_RE = /read_driver_source|source_concat|list_lua_files\(/;
// driver_root() concatenated with a quoted relative path into a driver SOURCE
// tree ending in .lua, e.g. driver_root() .. "modules/keymap/input_sources.lua".
const SOURCE_PATH_RE = /driver_root\(\)\s*\.\.\s*["'][^"'\n]*(?:modules|lib|ui)[\\/][^"'\n]*\.lua["']/;
const SOURCE_PATH_RE_G = new RegExp(SOURCE_PATH_RE.source, 'g');

/**
 * Recursively collects every test_*.lua file under a directory.
 * @param {string} dir - Absolute directory to walk.
 * @param {string[]} acc - Accumulator for matched absolute file paths.
 * @returns {string[]} The accumulator, populated with absolute paths.
 */
function collectTests(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			collectTests(full, acc);
		} else if (entry.isFile() && /^test_.*\.lua$/.test(entry.name)) {
			acc.push(full);
		}
	}
	return acc;
}

const pinned = [];
const perFileReads = [];
let reads = 0;
for (const file of collectTests(TESTS_DIR, [])) {
	const src = fs.readFileSync(file, 'utf8');
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');

	// Read count first, and unconditionally: a helper elsewhere in the file does
	// not make a raw pin beside it move-resilient.
	const hits = (src.match(SOURCE_PATH_RE_G) || []).length;
	if (hits > 0) {
		reads += hits;
		perFileReads.push({ rel, hits });
	}

	if (HELPER_RE.test(src)) continue; // already move-resilient
	if (!SOURCE_PATH_RE.test(src)) continue; // reads a fixture, not a source file
	pinned.push(rel);
}

const count = pinned.length;
if (process.argv.includes('--measure')) {
	console.log(`path-pinned macOS source-reading test files: ${count}`);
	for (const f of pinned) console.log('  ' + f);
	console.log(`\npinned macOS source READS: ${reads}`);
	for (const { rel, hits } of perFileReads.sort((a, b) => b.hits - a.hits)) {
		console.log(`  ${String(hits).padStart(3)}  ${rel}`);
	}
	process.exit(0);
}

let failed = false;
if (count > BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Path-pinned source reads in macOS tests rose to ${count} file(s) (baseline ${BASELINE}).\x1b[0m`
	);
	console.error(
		'  A new test reads a driver source file by a hardcoded driver_root() path. Load the\n' +
		'  module and assert behaviour, or use a move-resilient symbol-keyed scan, so a file\n' +
		'  move does not break it. Do NOT raise the baseline.'
	);
}
if (reads > READ_BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Individual pinned macOS source reads rose to ${reads} (baseline ${READ_BASELINE}).\x1b[0m`
	);
	console.error(
		'  A file already on the pinned list gained another hardcoded path — that used to be\n' +
		'  free, because only files were counted. The read is what a `git mv` breaks, so the\n' +
		'  read is what is frozen. Do NOT raise the baseline.'
	);
}
if (failed) {
	console.error('  Run `node tools/test/test-no-pinned-source-reads-lua.cjs --measure` to list them.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No new path-pinned macOS source reads (${count}/${BASELINE} file(s), ${reads}/${READ_BASELINE} read(s)).\x1b[0m`
);
