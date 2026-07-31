// tools/test/test-updater-constants-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Updater Constants Single-Source Gate
 * DESCRIPTION:
 * Drift gate: verifies that the owner/repo/timing literals in
 * windows/lib/updater/core.ahk and macos/lib/updater.lua agree with the
 * canonical values in _shared/modules/updater/defaults.json. A mismatch here
 * means someone edited a per-driver literal without updating the shared JSON
 * (or vice versa).
 *
 * FEATURES & RATIONALE:
 * 1. Parity enforcement: AHK keeps inline literals (AHK parse complexity),
 *    macOS and Linux read from JSON — this gate keeps all three in sync with it.
 * 2. Additive: does not remove any existing checks; purely a new gate.
 *
 * THE THIRD DRIVER, AND THE FALLBACKS NOBODY WAS WATCHING:
 * Linux has a full updater (modules/updater/manager.lua) that this gate did not
 * mention. Both Lua drivers also carry a _DEFAULTS_FALLBACK table — a second,
 * hand-written copy of owner/repo/timing used when the shared JSON is
 * unreachable. Nothing compared those copies to the JSON. A fallback that has
 * drifted is worse than no fallback: on the one path where it is used, the
 * updater silently queries the wrong repository and reports "no update" forever,
 * with no error anywhere. Both fallbacks are now pinned to defaults.json.
 * ==============================================================================
 */

"use strict";

const fs   = require("fs");
const path = require("path");

const ROOT        = path.resolve(__dirname, "..", "..");
const SHARED_ROOT = path.join(ROOT, "static", "ergopti_plus", "_shared");
const DEFAULTS    = path.join(SHARED_ROOT, "modules", "updater", "defaults.json");
const AHK_CORE    = path.join(ROOT, "static", "ergopti_plus", "windows", "lib", "updater", "core.ahk");
const LUA_UPDATER = path.join(ROOT, "static", "ergopti_plus", "macos", "lib", "updater.lua");
const LINUX_UPDATER = path.join(ROOT, "static", "ergopti_plus", "linux", "modules", "updater", "manager.lua");

let exitCode = 0;

function fail(msg) {
	console.error("  FAIL  " + msg);
	exitCode = 1;
}

function pass(msg) {
	console.log("  pass  " + msg);
}

// ─── Load defaults.json ───────────────────────────────────────────────────────

if (!fs.existsSync(DEFAULTS)) {
	fail("_shared/modules/updater/defaults.json not found — file was deleted or moved");
	process.exit(1);
}

let defaults;
try {
	defaults = JSON.parse(fs.readFileSync(DEFAULTS, "utf8"));
} catch (e) {
	fail("_shared/modules/updater/defaults.json is not valid JSON: " + e.message);
	process.exit(1);
}

const owner   = defaults.github && defaults.github.owner;
const repo    = defaults.github && defaults.github.repo;
const interval = defaults.timing && defaults.timing.default_check_interval_sec;
const boot    = defaults.timing && defaults.timing.boot_check_delay_sec;

if (!owner || !repo || !interval || !boot) {
	fail("defaults.json missing required fields: github.owner, github.repo, timing.default_check_interval_sec, timing.boot_check_delay_sec");
	process.exit(1);
}
pass("defaults.json has all required scalar fields");

// ─── Check AHK core.ahk literals match defaults.json ────────────────────────

const ahkSrc = fs.readFileSync(AHK_CORE, "utf8");

const ahkOwnerRe  = /UPDATER_GH_OWNER\s*:=\s*"([^"]+)"/;
const ahkRepoRe   = /UPDATER_GH_REPO\s*:=\s*"([^"]+)"/;
const ahkIntervalRe = /UPDATER_DEFAULT_INTERVAL\s*:=\s*(\d+)/;

const ahkOwnerM   = ahkSrc.match(ahkOwnerRe);
const ahkRepoM    = ahkSrc.match(ahkRepoRe);
const ahkIntervalM = ahkSrc.match(ahkIntervalRe);

if (!ahkOwnerM) {
	fail("core.ahk: could not find UPDATER_GH_OWNER literal");
} else if (ahkOwnerM[1] !== owner) {
	fail(`core.ahk UPDATER_GH_OWNER="${ahkOwnerM[1]}" does not match defaults.json github.owner="${owner}"`);
} else {
	pass(`core.ahk UPDATER_GH_OWNER matches defaults.json ("${owner}")`);
}

if (!ahkRepoM) {
	fail("core.ahk: could not find UPDATER_GH_REPO literal");
} else if (ahkRepoM[1] !== repo) {
	fail(`core.ahk UPDATER_GH_REPO="${ahkRepoM[1]}" does not match defaults.json github.repo="${repo}"`);
} else {
	pass(`core.ahk UPDATER_GH_REPO matches defaults.json ("${repo}")`);
}

if (!ahkIntervalM) {
	fail("core.ahk: could not find UPDATER_DEFAULT_INTERVAL literal");
} else if (Number(ahkIntervalM[1]) !== interval) {
	fail(`core.ahk UPDATER_DEFAULT_INTERVAL=${ahkIntervalM[1]} does not match defaults.json timing.default_check_interval_sec=${interval}`);
} else {
	pass(`core.ahk UPDATER_DEFAULT_INTERVAL matches defaults.json (${interval})`);
}

// ─── Check Lua updater.lua no longer has bare literals ───────────────────────

const luaSrc = fs.readFileSync(LUA_UPDATER, "utf8");

// The Lua file must read from defaults.json — the old bare literals
// ("adrienm7", "ergopti" as standalone local assignments) should be gone.
// We look for the old pattern: `local GH_OWNER   = "adrienm7"` (not inside FALLBACK).
const luaOldOwnerLiteral = /^local\s+GH_OWNER\s*=\s*"adrienm7"/m;
const luaOldRepoLiteral  = /^local\s+GH_REPO\s*=\s*"ergopti"/m;

if (luaOldOwnerLiteral.test(luaSrc)) {
	fail("updater.lua still has bare `local GH_OWNER = \"adrienm7\"` — should now read from defaults.json");
} else {
	pass("updater.lua no longer has bare GH_OWNER literal (reads from defaults.json)");
}

if (luaOldRepoLiteral.test(luaSrc)) {
	fail("updater.lua still has bare `local GH_REPO = \"ergopti\"` — should now read from defaults.json");
} else {
	pass("updater.lua no longer has bare GH_REPO literal (reads from defaults.json)");
}

// ─── Both Lua drivers: the offline fallback must equal defaults.json ─────────

// Each Lua updater keeps a _DEFAULTS_FALLBACK table for the case where the
// shared tree is unreachable. It is a second copy of the canonical values, so it
// is exactly the kind of literal this gate exists to pin — and it was the one
// copy nothing checked.
const LUA_DRIVERS = [
	{ label: "macos/lib/updater.lua", file: LUA_UPDATER },
	{ label: "linux/modules/updater/manager.lua", file: LINUX_UPDATER }
];

for (const drv of LUA_DRIVERS) {
	if (!fs.existsSync(drv.file)) {
		fail(`${drv.label}: not found — the updater moved, or this gate's path is stale`);
		continue;
	}
	const src = fs.readFileSync(drv.file, "utf8");

	const block = src.match(/_DEFAULTS_FALLBACK\s*=\s*\{([\s\S]*?)\n\}/);
	if (!block) {
		fail(`${drv.label}: could not find the _DEFAULTS_FALLBACK table`);
		continue;
	}
	const body = block[1];

	const expectations = [
		{ name: "github.owner", re: /owner\s*=\s*"([^"]+)"/, want: owner },
		{ name: "github.repo", re: /repo\s*=\s*"([^"]+)"/, want: repo },
		{ name: "timing.default_check_interval_sec", re: /default_check_interval_sec\s*=\s*(\d+)/, want: interval },
		{ name: "timing.boot_check_delay_sec", re: /boot_check_delay_sec\s*=\s*(\d+)/, want: boot }
	];

	for (const exp of expectations) {
		const m = body.match(exp.re);
		if (!m) {
			fail(`${drv.label}: _DEFAULTS_FALLBACK has no ${exp.name}`);
			continue;
		}
		const got = /^\d+$/.test(m[1]) ? Number(m[1]) : m[1];
		if (got !== exp.want) {
			fail(
				`${drv.label}: _DEFAULTS_FALLBACK ${exp.name}=${JSON.stringify(got)} does not match ` +
					`defaults.json ${exp.name}=${JSON.stringify(exp.want)} — on the offline path this driver ` +
					"would silently use the wrong value"
			);
		} else {
			pass(`${drv.label}: _DEFAULTS_FALLBACK ${exp.name} matches defaults.json`);
		}
	}

	// The live values must come from the JSON, not from the fallback directly.
	if (!/defaults\.json/.test(src)) {
		fail(`${drv.label}: does not reference _shared/modules/updater/defaults.json — it must read the canonical source`);
	} else {
		pass(`${drv.label}: reads _shared/modules/updater/defaults.json`);
	}
}

// ─── Check the Linux packaging recipes point at the real repository ──────────

// Regression guard: build-linux-deb.sh, build-linux-rpm.sh and PKGBUILD each
// carried "github.com/nizos/ergopti" — a different project. PKGBUILD used it as
// its `source=` clone URL, so `makepkg` would have built the wrong repository,
// and the .deb/.rpm advertised the wrong Homepage. The canonical owner/repo is
// already single-sourced in defaults.json, so these files must agree with it.
// Enumerated as a class rather than pinned per file: any new packaging recipe
// under tools/build/ is covered the moment it is added.
const PACKAGING_DIR = path.join(ROOT, "tools", "build");
const GITHUB_URL_RE = /github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?(?=["'\s)#]|$)/g;

let packagingFilesScanned = 0;
let packagingUrlsChecked  = 0;

for (const entry of fs.readdirSync(PACKAGING_DIR, { withFileTypes: true })) {
	if (!entry.isFile()) continue;
	// Shell packagers plus the extensionless Arch recipe.
	if (!/\.(sh|cjs|js|py)$/.test(entry.name) && entry.name !== "PKGBUILD") continue;

	const full = path.join(PACKAGING_DIR, entry.name);
	const src  = fs.readFileSync(full, "utf8");
	packagingFilesScanned++;

	for (const m of src.matchAll(GITHUB_URL_RE)) {
		packagingUrlsChecked++;
		if (m[1] !== owner || m[2] !== repo) {
			fail(
				`tools/build/${entry.name}: github.com/${m[1]}/${m[2]} does not match ` +
				`defaults.json github.owner/repo (${owner}/${repo})`
			);
		}
	}
}

if (packagingFilesScanned === 0) {
	fail("tools/build/ scan matched no packaging file — the selector is wrong, not the tree");
} else if (packagingUrlsChecked === 0) {
	fail("tools/build/ contains no github.com URL — expected at least the packaging Homepage/source lines");
} else if (exitCode === 0) {
	pass(`every github.com URL in tools/build/ matches defaults.json (${packagingUrlsChecked} URL(s) across ${packagingFilesScanned} file(s))`);
}

// ─── Verify dead constants.toml is gone ──────────────────────────────────────

const deadToml = path.join(SHARED_ROOT, "modules", "updater", "constants.toml");
if (fs.existsSync(deadToml)) {
	fail("_shared/modules/updater/constants.toml still exists — should have been deleted (dead code, §5.6)");
} else {
	pass("dead constants.toml is absent");
}

// ─── Summary ─────────────────────────────────────────────────────────────────

if (exitCode === 0) {
	console.log("\n✅  updater-constants-single-source: all checks passed.");
} else {
	console.error("\n❌  updater-constants-single-source: one or more checks FAILED.");
}

process.exit(exitCode);
