// tools/test/test-driver-tree-parity.cjs

/**
 * ==============================================================================
 * MODULE: Driver Tree Parity (I1)
 * DESCRIPTION:
 * Measures how much of the three drivers' directory structure is shared, and
 * ratchets it upward. This is invariant I1 of the simplification programme: the
 * same feature should live at the same path in every driver.
 *
 * WHY A RATCHET AND NOT AN EQUALITY CHECK:
 * The trees are 19% identical today. Asserting equality would fail on arrival
 * and stay failing for the length of a multi-lot refactor, which means it would
 * be disabled within a week and guard nothing. A ratchet is useful from the
 * first commit: it records where the reorganisation has got to, and refuses to
 * let it slide back while the lots land one at a time.
 *
 * WHAT COUNTS:
 * Depth-≤2 subdirectories of each driver, excluding tests/ (its layout mirrors
 * the code it covers rather than being structure of its own) and excluding
 * build/tooling residue that is not part of the driver's architecture —
 * .venv, __pycache__, .pytest_cache, node_modules and the macOS .app bundles,
 * none of which any other driver could meaningfully mirror. The tests/ trees
 * are ratcheted on their own measurement below, so a suite that moves away from
 * its counterparts fails without moving the architecture's number.
 *
 * The metric is the share of DISTINCT directory paths that exist in all three
 * drivers. A path present in one driver only counts against it, which is the
 * point: `windows/modules/updater/` and `macos/platform/remap/` are both real
 * work that has no counterpart, and the number should say so.
 *
 * WHY IT IS NOT A LINE COUNT:
 * Sharing structure is what makes a change reviewable across drivers — knowing
 * that the gestures code is at modules/gestures/ everywhere is worth more than
 * any individual file being identical. Directory identity is the cheap proxy
 * for that, and unlike a line count it cannot be gamed by moving code around
 * inside a file.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DRIVERS = ['macos', 'windows', 'linux'];

const TRACKED_PREFIX = 'static/ergopti_plus/';

// The architecture is the commit candidate, not every local directory under
// the checkout. `--cached` includes newly staged files while excluding runtime
// and personal artifacts that Git will never ship.
const trackedFiles = execFileSync(
	'git',
	['ls-files', '--cached', '-z', '--', 'static/ergopti_plus'],
	{ cwd: ROOT, encoding: 'utf8' }
)
	.split('\0')
	.filter(Boolean)
	.map((rel) => rel.split(path.sep).join('/'));

// Not architecture: virtualenvs, caches, build output, packaging helpers and macOS app bundles.
// Counting them would move the ratio for reasons that have nothing to do with
// how the drivers are organised.
const IGNORED = [
	/^\./, // .venv, .pytest_cache, …
	/^__pycache__$/,
	/^node_modules$/,
	/^tests$/,
	/^build$/,
	/^bin$/,
	/^install$/,
	/\.app$/
];

const isIgnored = (segment) => IGNORED.some((re) => re.test(segment));

/** Depth-≤2 directory paths of a driver, POSIX-style, architecture only. */
function treeOf(driver) {
	const out = new Set();
	const prefix = `${TRACKED_PREFIX}${driver}/`;
	for (const file of trackedFiles) {
		if (!file.startsWith(prefix)) continue;
		const parts = file.slice(prefix.length).split('/');
		const top = parts[0];
		if (parts.length < 2 || isIgnored(top)) continue;
		out.add(top);
		const sub = parts[1];
		if (parts.length < 3 || isIgnored(sub)) continue;
		out.add(`${top}/${sub}`);
	}
	return out;
}

const trees = new Map(DRIVERS.map((d) => [d, treeOf(d)]));

const errors = [];
for (const [d, t] of trees) {
	if (t.size === 0) {
		errors.push(
			`${d}/ produced no directories — the walk is broken, and a ratchet over nothing passes forever`
		);
	}
}

const union = new Set();
for (const t of trees.values()) for (const p of t) union.add(p);

const shared = [...union].filter((p) => DRIVERS.every((d) => trees.get(d).has(p))).sort();
const ratio = union.size === 0 ? 0 : (shared.length / union.size) * 100;

// ── History of the shared count ─────────────────────────────────────────────
//
// Until 2026-11-24 this gate compared five literal counts (shared 66, union 87,
// tests 18/75, canonical 9). A count let a regression and an unrelated fix of
// the same size cancel out unseen, and its failure named a total, not the path.
// The ledger (driver-tree-parity-baseline.json) now names every path with the
// drivers that hold it. The counts' history stays below for the reasons it
// gives for each per-driver path.
//
//   11/51 (21.6 %) — first measurement.
//   12/51 (23.5 %) — crash_reporter promoted out of lib/ into modules/diagnostics
//                    on macOS and Windows, where Linux already had it. The union
//                    did not grow: the path already existed, on one driver.
//   13/50 (26.0 %) — updater promoted the same way. Here the union SHRANK too,
//                    because Windows had a whole lib/updater/ directory that
//                    moved rather than a single file: one unshared path removed
//                    and one shared path gained, from the same move.
//   14/50 (28.0 %) — dynamic_hotstrings. macOS and Linux both had
//                    modules/dynamic_hotstrings/; on Windows the same behaviour
//                    was section 5 of hotstrings/engine/catalogue/text_expansion.ahk.
//                    Found only after this file's OWN report was fixed: it used
//                    to print a two-driver path once under each driver's
//                    "unique to it" list, so the strongest promotion candidate
//                    in the tree read as two unrelated private folders.
////   23/49 (46.9 %) — the Linux UI, reorganised by FEATURE to match the other
//                    two. It was the only driver with two `ui` namespaces:
//                    modules/ui/ held one webview manager plus a flat folder of
//                    per-page bridge handlers, and modules/menu/ held the menu.
//                    Nine paths became shared at once and the union SHRANK, so
//                    the twelve "missing ui/*" were never twelve gaps — they
//                    were one structural choice. Page names come from
//                    _shared/ui/, the canonical set, rather than from what this
//                    driver happened to call them.
//
//   25/47 (53.2 %) — measured 2026-08-04, and the ratchet had been carrying two
//                    paths of slack since 2026-08-01. Slack in a ratchet is not
//                    harmless: it is exactly enough room for a regression to
//                    land and pass, and the gate would report OK while the
//                    programme went backwards. Tightened to the measurement.
//                    The union shrank 49 → 47 over the same period, which is the
//                    healthy direction: fewer unshared directories, not more
//                    shared ones bolted onto a growing tree.
//   26/48 (54.2 %) — platform/tray. Linux gained a real one (an SNI object it
//                    has to HOST for the life of the process, bound through
//                    libayatana-appindicator); macOS and Windows ship the
//                    Convention S README saying what they use instead, because
//                    hs.menubar and A_TrayMenu are one call each and a seam
//                    around one call is a folder, not an abstraction. The union
//                    grew with the shared count, which is the only shape of
//                    growth this ratchet permits.
//   29/52 (55.8 %) — ui/error_dialog, the host of the shared error window
//                    (_shared/ui/error_dialog/), born on all three drivers at
//                    once: the union grew with the shared count again. Measured,
//                    and tightened to the measurement (the ratchet carried two
//                    paths of slack).
//   32/54 (59.3 %) — layer_editor and layout_manager join error_dialog on all
//                    drivers; measured from the combined staged tree.
//   33/55 (60.0 %) — ui/config_cleanup hosts the common cleanup WebView on all
//                    three drivers; the shared ratio rises from 59.3 %.
//   34/56 (60.7 %) — ui/update_check hosts the shared update-check window on
//                    all three drivers (the union took the path with macOS).
//   35/58 (60.3 %) — platform/network records native proxy/runtime ownership on
//                    all three drivers. Linux binds GIO in an owned child; macOS
//                    and Windows document their existing native adapter owners.
//   35/58 (60.3 %) — ui/physical_shortcuts adds one symmetric feature path.
//                    macOS and Linux host the shared editor; Windows records
//                    its unavailable native host in a Convention S README.
//                    That marker declares absence, not runtime support; the
//                    canonical source predicate below remains unchanged.
//   36/59 (61.0 %) — merge the two symmetric additions above. Their
//                    independent branch measurements share the same base; both
//                    paths remain in the combined tracked driver tree.
//   39/62 (62.9 %) — 2026-10-24: ui/field_check, the host of the one-click
//                    Debug checks, landed on macOS and Windows; the three Linux
//                    check modules moved from flat ui/ files into
//                    ui/field_check/, so the path is shared on all three. The
//                    measurement had also carried two paths of slack (38 against
//                    36); tightened to the measurement.
//   61 (2026-11-15) — ui/layer_editor is retired, not moved: the navigation
//                    layer is edited in Ergopti Studio (ui/layout_manager), so
//                    the path leaves the shared set with no counterpart. The one
//                    lowering this ratchet allows is a feature removed from every
//                    driver (decided by the agent, to review by the maintainer).

// ── History of the union count ──────────────────────────────────────────────
//
// The union was ratcheted too, downward: a driver that grows a new unshared
// directory dilutes the ratio even when nothing was removed. The ledger keeps
// that rule: a path on fewer than three drivers is new debt until recorded.
//
//   48 → 49 on 2026-08-06 — ui/numeric_prompt, Linux only, and this is the
//   exemption the message above names rather than a concession. macOS asks for
//   a number with hs.dialog and Windows with InputBox: one call each, built
//   into the toolkit. Linux has neither, so the only way for its tray to accept
//   a typed value at all is a webview — the same shape of argument as
//   platform/tray above, where Linux has to HOST an object the other two get
//   from one call. A counterpart directory on macOS and Windows would be a
//   folder wrapping a function they already have, which is the thing this
//   ratchet exists to discourage in the other direction.
//
//   The alternative was to leave the gap: presets on Linux, free entry on
//   macOS, for a setting the manifest declares once. That is convergence
//   downwards wearing a clean ratchet.
//
//   49 → 51 on 2026-08-23 — windows/native plus native/nav_event_owner. AHK's
//   split HotIf/callback model cannot atomically own a physical event, so the
//   Windows driver needs a packaged WH_KEYBOARD_LL component with its own C ABI,
//   hook-free tests and hardened-build gate. Empty Lua counterparts would add
//   structure without a corresponding macOS/Linux runtime responsibility.
//
//   51 → 52 on 2026-09-24 — ui/error_dialog, shared by all three drivers (see
//   the shared count above): no driver grew an unshared directory.
//   52 → 54 — ui/layer_editor and ui/layout_manager add two shared paths after
//   ui/error_dialog; no new asymmetric directory is introduced.
//   54 → 55 — ui/config_cleanup adds one path on all three drivers. This is
//   symmetric growth, paired with the shared-count increase above.
//   55 → 56 — ui/update_check, the host of the shared update-check window,
//   landed on macOS first; the Linux and Windows hosts made it a shared path
//   (the shared count 34).
//   56 → 57 on 2026-09-29 — ui/permission_dialog, macOS only. It walks the
//   user through a macOS privacy grant (System Settings > Privacy & Security,
//   the TCC entry of the embedded runtime), which neither Windows nor Linux
//   has: a counterpart folder there would host nothing. The geometry gate
//   records the same exemption for Windows.
//   57 → 58 on 2026-10-05 — platform/network is added on all three drivers,
//   paired with the shared count 35. Native GIO runtime/child probes need an
//   explicit seam; the sibling README files identify their existing native
//   HTTP/proxy owners without pretending to load GIO or adding wrapper code.
//   57 → 58 on 2026-10-06 — ui/physical_shortcuts, one path on all three
//   drivers. Windows carries the explicit Convention S unavailable marker;
//   the shared-count floor rises to 35 at the same time. No asymmetric path
//   allowance is added and no native implementation is inferred from a README.
//   58 → 59 on 2026-10-06 — preserve both platform/network and
//   ui/physical_shortcuts at integration. Each adds exactly one symmetric path;
//   the combined shared floor is 36 and the canonical source floor stays 17.
//   59 -> 60 on 2026-10-06 - Linux native/archive_output contains the real
//   retained-directory/O_TMPFILE/linkat implementation in archive_publication.c
//   and its C ABI header. This is an explicit Linux-only native allowance:
//   Windows and macOS use their own native file APIs and gain no wrapper folders.
//   Shared-count36 and canonical-source17 remain unchanged. No generated bin,
//   private fixture directory or implementation-independent feature is counted.
//   60 -> 62 on 2026-10-24 - ui/field_check is one path on all three drivers,
//   paired with the shared count 39 (symmetric growth). vendor/remap-runtime is
//   macOS only: it pins the owned Karabiner remap runtime and its VirtualHID
//   driver package (ADR 011), which neither Windows nor Linux ships; a
//   counterpart folder there would hold nothing.
//   62 -> 63 on 2026-10-27 - linux/_generated/shell_messages, Linux only: the
//   catalogues the Linux shell scripts (install.sh, uninstall.sh, the
//   launcher and install/ helpers) print from, generated from the shared
//   locales because those scripts run before LuaJIT can be assumed. The macOS
//   and Windows installers are not shell scripts printing to a terminal, so a
//   counterpart folder there would hold nothing.
//   63 -> 65 on 2026-11-07, confirmed by the maintainer on 2026-11-08 -
//   windows/native/keyboard_layout holds the C, header,
//   resource and module-definition sources generated from the .keylayout that
//   the Windows keyboard DLL compiles from, and windows/vendor/keyboard_layout
//   the elevated installer of that DLL. macOS and Linux install the .keylayout
//   and XKB files themselves and build no keyboard DLL, so counterpart
//   folders there would hold nothing.
//   65 -> 68 on 2026-11-11 (coordinator, overnight; to review by the maintainer) -
//   linux/platform/desktop_focus with its gnome and kwin children: the GNOME Shell
//   extension and the KWin script the installer places so the daemon can read
//   the focused window under Wayland, where no client may ask the compositor.
//   Windows and macOS read focus through their own native APIs and install no
//   desktop-shell code, so counterpart folders there would hold nothing.

// ── The test trees, measured apart from the architecture ────────────────────
//
// The tests/ trees were excluded from the numbers above, so nothing noticed them
// drifting (audit 2026-10-18, item 4 of its tidy-tree plan). They get their own
// ledger section rather than joining the architecture's ratio: a directory of
// fixtures is not structure a driver owes its siblings.
/** Depth-≤2 directory paths of a driver's tests/ tree, POSIX-style. */
function testsTreeOf(driver) {
	const out = new Set();
	const prefix = `${TRACKED_PREFIX}${driver}/tests/`;
	for (const file of trackedFiles) {
		if (!file.startsWith(prefix)) continue;
		const parts = file.slice(prefix.length).split('/');
		const top = parts[0];
		if (parts.length < 2 || isIgnored(top)) continue;
		out.add(top);
		const sub = parts[1];
		if (parts.length < 3 || isIgnored(sub)) continue;
		out.add(`${top}/${sub}`);
	}
	return out;
}

const testsTrees = new Map(DRIVERS.map((d) => [d, testsTreeOf(d)]));
const testsUnion = new Set();
for (const t of testsTrees.values()) for (const p of t) testsUnion.add(p);
const testsShared = [...testsUnion]
	.filter((p) => DRIVERS.every((d) => testsTrees.get(d).has(p)))
	.sort();

// ── The canonical features, the third measurement this gate never had ───────
//
// Comparing the drivers to EACH OTHER says nothing about a feature none of them
// has, and cannot tell a deliberate absence from an oversight. _shared/core/
// features.json is the machine-readable canonical list — it existed only as
// prose in TODO.md until 2026-08-03, which is why Convention S ("every canonical
// folder exists on every driver, with a reason where it is unimplemented") had
// no gate at all: nothing could enumerate the folders it was talking about.
//
// Each feature declares the TREE it belongs to, and that field is the finding
// rather than a formality: the prose said every named feature is
// `modules/<name>/`, and ten of the 25 are windows that live in `ui/`. A feature
// the user OPERATES is a module; one the user LOOKS AT is a window.
const CANONICAL = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'core', 'features.json'), 'utf8')
).features;

/** True when `dir` contains at least one driver source file, at any depth. */
function containsSource(relDir) {
	const prefix = `${relDir}/`;
	return trackedFiles.some((file) => file.startsWith(prefix) && /\.(lua|ahk)$/.test(file));
}

/**
 * True when a driver ships a canonical feature at its declared path.
 *
 * "Ships" means there is CODE there, not merely a path. This used to be a bare
 * fs.existsSync, and the ratchet below is the number this function feeds — so
 * three folders holding nothing but a README raised it, and nothing in the gate
 * could tell that from the extraction it is supposed to reward. Convention S
 * prescribes exactly such a README for an unimplemented folder, which makes the
 * hole reachable by following the convention rather than by cheating.
 *
 * It stops at "a .lua or .ahk file exists" on purpose. Requiring the code to be
 * REACHED by something would be the stronger test and would contradict
 * Convention S directly: a stub declaring STATUS: not implemented has no callers
 * by design. So the residual hole is a stub folder with one empty .lua in it,
 * and that is a deliberate floor rather than an oversight.
 */
function hasFeature(driver, feature) {
	const base = `${TRACKED_PREFIX}${driver}/${feature.tree}/${feature.name}`;
	if (containsSource(base)) return true;
	return ['.lua', '.ahk'].some((ext) => trackedFiles.includes(base + ext));
}

const canonicalOnAll = CANONICAL.filter((f) => DRIVERS.every((d) => hasFeature(d, f)));
const canonicalPartial = CANONICAL.filter(
	(f) => !DRIVERS.every((d) => hasFeature(d, f)) && DRIVERS.some((d) => hasFeature(d, f))
);
const canonicalNowhere = CANONICAL.filter((f) => !DRIVERS.some((d) => hasFeature(d, f)));

// History of the count of canonical features on all three drivers, frozen
// 2026-08-03 at the first measurement (the ledger now names each feature):
//   14/25 on all three, 5 partial, 6 nowhere.
// The six that are nowhere — apps, download, hotstrings_config, layout,
// metrics, personal_info — are the ones Convention S cannot stub, because there is
// nothing to stub around: the capability exists, spread through another module,
// so the work is extraction rather than a README.
// 2026-08-04: 14 → 16. Not new implementations — two canonical entries were
// simply named more shortly than the folder every driver actually ships
// (`personal_info` against `ui/personal_info_editor`, `hotstrings_config`
// against `ui/hotstrings_config_window`). The three drivers already agreed;
// only the list disagreed with them. Renaming the entries moved the count
// without touching a line of driver code, which is the same correction the
// `tree` field was written to make for ten other features.
// 2026-08-04, second pass: 16 → 17. Same correction a third time. Of the four
// entries the list still called absent from every driver, only two really are.
// `metrics` is modules/keystats, shared by all three; `download` is
// ui/download_window, which two drivers ship — it was filed under modules/ in
// contradiction of this file's own tree rule, so a window was being counted as
// a missing module. Raised the same day it was measured: leaving it at 16 would
// hand the ratchet exactly one feature of slack, which is the failure the note
// above condemns and would silently undo the tightening it describes.

// ── The ledger ──────────────────────────────────────────────────────────────
//
// One entry per measured path or canonical feature, naming the drivers that
// hold it: `tree:<path>` for the architecture, `tests:<path>` for the tests/
// trees and `canonical:<tree>/<name>` for _shared/core/features.json (`none`
// when no driver ships it). The measurement must equal the ledger, so a
// regression and an unrelated fix can no longer cancel out, and a failure
// names the path. The two directions of a difference differ in who records it:
//   - convergence (a path gains a driver, a path not on all three disappears,
//     a canonical feature reaches another driver, a new path on all three):
//     any change records it with --record-convergence;
//   - divergence (a path loses a driver, a new path not on all three, a path
//     every driver held disappears): the structure phase 2 runner records it
//     with --update-baseline --allow-rise, one `[RISE]` line each for the
//     step's commit. Any other change edits the ledger by hand and says why
//     the structure is genuinely per-driver in its commit.
const LEDGER_PATH = path.join(__dirname, 'driver-tree-parity-baseline.json');
const LEDGER_ABOUT =
	'Ledger of tools/test/test-driver-tree-parity.cjs (invariant I1): every depth-2 directory of ' +
	'the three drivers (tree:), of their tests/ trees (tests:) and every canonical feature ' +
	'(canonical:), with the drivers that hold it. Record convergence with --record-convergence; ' +
	'divergence is recorded by the structure phase 2 runner or by hand with its reason in the commit.';
const ALL_THREE = DRIVERS.slice().sort().join('+');

const holdersOf = (has) => DRIVERS.filter(has).sort().join('+') || 'none';
const measured = {};
for (const p of union) measured[`tree:${p}`] = holdersOf((d) => trees.get(d).has(p));
for (const p of testsUnion) measured[`tests:${p}`] = holdersOf((d) => testsTrees.get(d).has(p));
for (const f of CANONICAL)
	measured[`canonical:${f.tree}/${f.name}`] = holdersOf((d) => hasFeature(d, f));

/**
 * Whether a recorded entry may move to a measured one without divergence.
 * @param {string} key - The ledger key.
 * @param {string|undefined} recorded - The holders the ledger names.
 * @param {string|undefined} found - The holders measured now.
 * @returns {boolean} True when the change only brings the drivers together.
 */
function converges(key, recorded, found) {
	const canonical = key.startsWith('canonical:');
	if (recorded === undefined) return canonical || found === ALL_THREE;
	if (found === undefined) return recorded !== ALL_THREE;
	const before = recorded === 'none' ? [] : recorded.split('+');
	const after = new Set(found === 'none' ? [] : found.split('+'));
	return before.every((d) => after.has(d));
}

let ledger;
try {
	ledger = JSON.parse(fs.readFileSync(LEDGER_PATH, 'utf8'));
} catch (error) {
	console.error(`[ERROR] ${path.relative(ROOT, LEDGER_PATH)} is unreadable: ${error.message}`);
	process.exit(1);
}
const recordedEntries = Object.fromEntries(
	Object.entries(ledger).filter(([key]) => !key.startsWith('_'))
);
const differences = [...new Set([...Object.keys(recordedEntries), ...Object.keys(measured)])]
	.sort()
	.filter((key) => recordedEntries[key] !== measured[key])
	.map((key) => ({
		key,
		recorded: recordedEntries[key],
		found: measured[key],
		converges: converges(key, recordedEntries[key], measured[key])
	}));
const describe = ({ key, recorded, found }) =>
	`${key}: recorded ${recorded ?? 'absent'}, measured ${found ?? 'absent'}`;

const recordConvergence = process.argv.includes('--record-convergence');
const updateBaseline = process.argv.includes('--update-baseline');
if (recordConvergence || updateBaseline) {
	if (updateBaseline) {
		if (!process.argv.includes('--allow-rise') || process.env.ERGOPTI_STRUCTURE_PHASE !== '2') {
			console.error(
				'[ERROR] --update-baseline --allow-rise is for the structure phase 2 runner only.'
			);
			process.exit(1);
		}
	} else {
		const diverging = differences.filter((d) => !d.converges);
		if (diverging.length > 0) {
			console.error('[ERROR] --record-convergence refuses a divergence:');
			for (const d of diverging) console.error(`    - ${describe(d)}`);
			process.exit(1);
		}
	}
	for (const d of differences)
		console.log(`${d.converges ? '[RECORD]' : '[RISE]'} I1 ${describe(d)}`);
	const written = { _about: LEDGER_ABOUT };
	for (const key of Object.keys(measured).sort()) written[key] = measured[key];
	fs.writeFileSync(LEDGER_PATH, JSON.stringify(written, null, '\t') + '\n');
	process.exit(0);
}

for (const d of differences) {
	errors.push(
		d.converges
			? `${describe(d)}: the drivers converged; record it with --record-convergence.`
			: `${describe(d)}: a driver diverged. Add its counterparts, or record it in the ledger ` +
					'with a commit that says why the structure is genuinely per-driver.'
	);
}

if (process.argv.includes('--measure')) {
	console.log(
		`canonical features (_shared/core/features.json): ${canonicalOnAll.length} on all three, ` +
			`${canonicalPartial.length} partial, ${canonicalNowhere.length} nowhere`
	);
	for (const f of canonicalPartial) {
		const has = DRIVERS.filter((d) => hasFeature(d, f));
		console.log(`  partial: ${f.tree}/${f.name} — on ${has.join(' + ')}`);
	}
	for (const f of canonicalNowhere) console.log(`  nowhere: ${f.tree}/${f.name} — ${f.role}`);
	console.log('');
	console.log(`union: ${union.size} distinct path(s) across ${DRIVERS.length} driver(s)`);
	console.log(`shared by all three: ${shared.length} (${ratio.toFixed(1)} %)`);
	console.log(`tests/ trees: ${testsShared.length} of ${testsUnion.size} shared by all three\n`);
	console.log('shared:');
	for (const p of shared) console.log('  ' + p);
	// Two classes, not one. The report used to print every non-shared path under
	// "per driver, unique to it", which listed a path held by TWO drivers once
	// under each of them — so modules/dynamic_hotstrings appeared as if macOS and
	// Linux each had a private directory of that name. That is backwards for the
	// one question this report exists to answer: the repo's objective promotion
	// test is "where does the same code live in the other drivers?", and a path
	// two drivers already agree on is the strongest evidence there is. Printing it
	// as two separate one-driver paths hid the shortest route to raising I1.
	const holders = (p) => DRIVERS.filter((d) => trees.get(d).has(p));

	const onTwo = [...union].filter((p) => holders(p).length === 2).sort();
	console.log(`\ntwo drivers agree, one is missing — ${onTwo.length} promotion candidate(s):`);
	for (const p of onTwo) {
		const has = holders(p);
		const missing = DRIVERS.filter((d) => !has.includes(d));
		console.log(`  ${p}  (on ${has.join(' + ')}, absent on ${missing.join(', ')})`);
	}

	console.log('\ngenuinely single-driver:');
	for (const d of DRIVERS) {
		const only = [...trees.get(d)].filter((p) => holders(p).length === 1).sort();
		console.log(`  ${d} (${only.length}): ${only.join(', ')}`);
	}
	process.exit(0);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] driver tree parity (I1):\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	console.error('    Run with --measure to see the full breakdown.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] driver tree parity (I1): ${shared.length}/${union.size} director(ies) shared by all ` +
		`three drivers — ${ratio.toFixed(1)} %; ${canonicalOnAll.length}/${CANONICAL.length} canonical ` +
		`features on all three; tests/ trees ${testsShared.length}/${testsUnion.size}.\x1b[0m`
);
