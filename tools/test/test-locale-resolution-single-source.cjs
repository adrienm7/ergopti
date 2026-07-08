/**
 * ==============================================================================
 * ESCROW: Locale resolution single-source gate (P0-G.4)
 * DESCRIPTION:
 * Verifies that macos/lib/locale.lua and linux/lib/locale.lua are thin wrappers
 * around _shared/lua/locale/core.lua — they must NOT contain their own inline
 * locale resolution logic (the old byte-identical copies).
 *
 * ROOT CAUSE ENCODED:
 * The two Lua locale modules were fork quasi-verbatim copies (~160 lines each)
 * differing only in JSON decoder + path resolution. Any behaviour fix or
 * ★-substitution tweak had to be applied twice. This gate ensures the old
 * inline logic is gone and both drivers delegate to the shared module.
 * ==============================================================================
 */

const assert     = require("node:assert").strict;
const { readFileSync } = require("node:fs");
const path       = require("node:path");

const root = path.resolve(__dirname, "../../static/ergopti_plus");

const macosLocalePath  = path.resolve(root, "macos/lib/locale.lua");
const linuxLocalePath  = path.resolve(root, "linux/lib/locale.lua");
const sharedCorePath   = path.resolve(root, "_shared/lua/locale/core.lua");

const macosSrc = readFileSync(macosLocalePath, "utf-8");
const linuxSrc = readFileSync(linuxLocalePath, "utf-8");

// ── Shared module exists and has the core logic ──
const sharedCore = readFileSync(sharedCorePath, "utf-8");
assert.ok(sharedCore.includes("function M.get("),
	"shared/locale/core.lua must define M.get — the single-source getter");
assert.ok(sharedCore.includes("function M.set_locale("),
	"shared/locale/core.lua must define M.set_locale");
assert.ok(sharedCore.includes("★"),
	"shared/locale/core.lua must handle ★ substitution");

// ── macOS wrapper is thin: requires locale.core, no inline logic ──
assert.ok(macosSrc.includes('require("locale.core")'),
	"macos/lib/locale.lua must require locale.core (thin wrapper)");
// The old inline logic patterns — none should exist in the wrapper.
assert.ok(!macosSrc.includes("local _strings     = nil"),
	"macos/lib/locale.lua must NOT declare _strings (moved to shared)");
assert.ok(!macosSrc.includes("local function ensure_loaded()"),
	"macos/lib/locale.lua must NOT define ensure_loaded (moved to shared)");
assert.ok(!macosSrc.includes("local function load_locale"),
	"macos/lib/locale.lua must NOT define load_locale (moved to shared)");
assert.ok(!macosSrc.includes('s:gsub("★"'),
	"macos/lib/locale.lua must NOT contain ★ substitution (moved to shared)");

// ── Linux wrapper is thin: requires locale.core, no inline logic ──
assert.ok(linuxSrc.includes('require("locale.core")'),
	"linux/lib/locale.lua must require locale.core (thin wrapper)");
assert.ok(!linuxSrc.includes("local _strings     = nil"),
	"linux/lib/locale.lua must NOT declare _strings (moved to shared)");
assert.ok(!linuxSrc.includes("local function ensure_loaded()"),
	"linux/lib/locale.lua must NOT define ensure_loaded (moved to shared)");
assert.ok(!linuxSrc.includes("local function load_locale"),
	"linux/lib/locale.lua must NOT define load_locale (moved to shared)");
assert.ok(!linuxSrc.includes('s:gsub("★"'),
	"linux/lib/locale.lua must NOT contain ★ substitution (moved to shared)");
