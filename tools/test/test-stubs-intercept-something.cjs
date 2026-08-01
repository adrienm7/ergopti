// tools/test/test-stubs-intercept-something.cjs

/**
 * ==============================================================================
 * MODULE: Stub Interception Guard
 * DESCRIPTION:
 * Every `package.loaded["x.y"] = stub` in the Lua suites must name a module that
 * actually exists. A stub keyed to a module nobody can require intercepts
 * nothing — the test runs against the real dependency, or against no dependency
 * at all, and says so nowhere.
 *
 * WHY THIS IS THE GATE THE REORGANISATION NEEDS:
 * Lot 3 renames `lib/` to `infra/` across three drivers. There are 1 144 stub
 * assignments in the two Lua suites, and the rename has to move production code
 * and every one of those keys in the same commit — because a stub still keyed to
 * `infra.foo` after the module became `infra.foo` does not fail. It silently stops
 * intercepting, the module under test quietly loads the real `infra.foo`, and
 * the test keeps passing while testing something else entirely. That is the
 * single most dangerous property of the whole lot, and until now nothing could
 * see it.
 *
 * ROOT CAUSE ENCODED — THREE ALREADY DEAD, BEFORE ANY RENAME:
 *   test_llm_models_presets.lua stubs `modules.llm.models_mgr` and
 *   `ui.menu.menu_llm.models_mgr`. Neither module exists, and the module under
 *   test requires neither — it pulls models_manager_ollama and
 *   models_manager_mlx. Both stubs were inert from the day they were written;
 *   the comment above them hedges, "modules that might be missing".
 *
 *   test_build_inserts_missing_timestamp.lua stubs `infra.json`. sqlite_writer
 *   requires `hs.json`. Nothing in the macOS driver requires `infra.json` at all.
 *
 * None of the three made a test fail, which is the point: an inert stub is
 * indistinguishable from a working one from inside the test.
 *
 * SCOPE: the two Lua drivers. AutoHotkey has no module cache to intercept.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DRIVERS = ['macos', 'linux'];

// Modules the host supplies at runtime, which therefore have no file in the
// repo and cannot be resolved. Stubbing them is the whole reason the harness
// exists — `hs` IS Hammerspoon.
const HOST_PROVIDED = [
	/^hs(\.|$)/, // Hammerspoon and its submodules
	/^lgi(\.|$)/, // GObject introspection, system-installed on Linux
	/^posix(\.|$)/, // luaposix
	/^luv$/,
	/^socket(\.|$)/,
	/^ffi$/,
	/^lfs$/,
	/^cjson(\.|$)/
];

const isHostProvided = (mod) => HOST_PROVIDED.some((re) => re.test(mod));

/** Directories a `require` resolves against, for a given driver. */
const rootsFor = (driver) => [
	path.join(SP, driver),
	path.join(SP, driver, 'tests'),
	path.join(SP, '_shared', 'lua')
];

/** True when `mod` resolves to a real file for this driver. */
function resolves(driver, mod) {
	const rel = mod.split('.').join(path.sep);
	for (const r of rootsFor(driver)) {
		if (fs.existsSync(path.join(r, rel + '.lua'))) return true;
		if (fs.existsSync(path.join(r, rel, 'init.lua'))) return true;
	}
	return false;
}

function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) walk(p, acc);
		else if (e.name.endsWith('.lua')) acc.push(p);
	}
	return acc;
}

const errors = [];
let assignments = 0;
let filesScanned = 0;

for (const driver of DRIVERS) {
	for (const abs of walk(path.join(SP, driver, 'tests'))) {
		filesScanned++;
		const rel = path.relative(SP, abs).split(path.sep).join('/');
		const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
		lines.forEach((line, i) => {
			if (/^\s*--/.test(line)) return;
			// Assignments only. A read (`package.loaded[x]` on the right-hand side)
			// says nothing about interception.
			for (const m of line.matchAll(/package\.loaded\[\s*"([^"]+)"\s*\]\s*=/g)) {
				const mod = m[1];
				assignments++;
				if (isHostProvided(mod)) continue;
				// Assigning nil is a CACHE EVICTION, not a stub: "reload this module
				// fresh". A module that no longer exists cannot be in the cache, so
				// the line is dead weight rather than a broken interception — worth
				// nothing, but not worth failing a build over.
				if (/=\s*nil\b/.test(line)) continue;
				if (resolves(driver, mod)) continue;
				errors.push(
					`${rel}:${i + 1}: stubs "${mod}", which resolves to no module in ${driver}/ or ` +
						'_shared/lua/. The stub intercepts nothing: whatever the test thinks it replaced, ' +
						'the code under test is still using the real one.'
				);
			}
		});
	}
}

if (assignments < 500) {
	errors.push(
		`found only ${assignments} package.loaded assignment(s) across ${filesScanned} test file(s) — ` +
			'the scan is broken, and a guard that inspects nothing passes forever'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] stubs that intercept nothing:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${assignments} stub assignment(s) across ${filesScanned} Lua test file(s) name a ` +
		'module that exists.\x1b[0m'
);
