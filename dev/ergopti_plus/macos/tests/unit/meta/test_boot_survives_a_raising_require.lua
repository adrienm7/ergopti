--- tests/unit/meta/test_boot_survives_a_raising_require.lua

--- ==============================================================================
--- MODULE: Regression — a module that raises at require time must not cost the
---         user their keyboard
--- DESCRIPTION:
--- `platform/remap/defaults.lua` calls `error()` at REQUIRE time — its top-level
--- body runs load_sections() and require_section(), and both raise — and the chain
--- up to root `init.lua` was un-pcall'd: defaults.lua ← config.lua ←
--- karabiner/init.lua ← `karabiner = require("platform.remap")`. A raise there
--- aborts the top-level chunk, so every line below it never runs.
---
--- 689d807c9 fixed WHERE the teardown is armed: the shutdown callback is now
--- installed above the risky requires. Necessary, and not sufficient. The
--- callback's exact-lease shutdown branch is gated on the `karabiner` local,
--- which is still nil when the require raised, so the branch no-ops. The managed
--- generation remains active after Hammerspoon exits, and both things that could
--- recover it (the menubar and the panic-button eventtap) are below the raise and
--- were never created. No stock Karabiner process is owned by Ergopti.
---
--- ROOT CAUSE ENCODED:
--- A teardown whose ability to run depends on the very require that failed.
---
--- PROVENANCE: these are assertions about the SHAPE of the boot file. init.lua
--- cannot be loaded in a unit test — it needs a live Hammerspoon — which is
--- precisely why this class of bug reaches production here, and why the driver
--- already carries several static guards over this one file.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by a symbol rather than a path, so the guard survives a file move and
-- satisfies the pinned-read ratchet.
local ANCHOR = "HS_BOOT_READY_SETTING_KEY"

-- The declaration contains the fallback body; the assignment is the line that
-- actually arms it. Everything after the assignment is inside the window where
-- a raise costs the user their keyboard rather than merely a feature.
local SHUTDOWN_DECLARATION = "local function shutdown_all_resources()"
local ARMING = "hs.shutdownCallback = shutdown_all_resources"

-- The module whose require chain is proven to reach an error() at load time.
-- Matched on the NAME rather than on a call spelling, so the guarded form
-- `pcall(require, "platform.remap")` is what this test looks at instead of
-- being invisible to it.
local RISKY_MODULE = '"platform.remap"'




-- ==================================================================
-- ==================================================================
-- ======= 1/ The require proven to raise is guarded ================
-- ==================================================================
-- ==================================================================

--- Returns root init.lua with its comments stripped.
--- @return string
local function boot_code()
	local src = helpers.read_driver_source(ANCHOR)
	helpers.assert_true(src ~= nil and src ~= "",
		"root init.lua must be locatable by '" .. ANCHOR .. "'")
	return (src:gsub("%-%-[^\n]*", ""))
end


--- Returns the single source line containing position `at`.
--- @param code string
--- @param at number
--- @return string
local function line_at(code, at)
	local start = 1
	local nl = code:sub(1, at):match(".*()\n")
	if nl then start = nl + 1 end
	local stop = code:find("\n", at) or (#code + 1)
	return code:sub(start, stop - 1)
end


helpers.describe("boot: one raising module must not abort the rest of init", function()

	helpers.it("the require chain that reaches an error() at load time is guarded", function()
		local code = boot_code()
		local arm_at = code:find(ARMING, 1, true)
		helpers.assert_true(arm_at ~= nil,
			"the teardown arming must still be findable; without it this test would scan the "
			.. "whole file and report nothing meaningful")

		-- Deliberately NOT a blanket "guard every top-level require" rule. There are
		-- sixteen of them after the arming, and a blanket rule would require every
		-- downstream consumer to become nil-tolerant: a nil `menu` or `notifications`
		-- produces a cascade of nil-index errors that is harder to diagnose than a
		-- clean abort, so it would trade one bad failure mode for a worse one.
		--
		-- This targets the chain PROVEN to raise while loading. Nothing else in that
		-- block calls error() in its top-level body.
		local at = code:find(RISKY_MODULE, arm_at, true)
		helpers.assert_true(at ~= nil,
			"the karabiner require must still be in the boot block; a move would make the "
			.. "assertion below vacuous")

		local statement = line_at(code, at)
		helpers.assert_true(statement:find("pcall(", 1, true) ~= nil,
			"platform.remap reaches defaults.lua, which calls error() in its top-level "
			.. "body, and this require sits above the menubar, the panic-button eventtap and "
			.. "every other line of boot. Unguarded, a missing or truncated tap_hold "
			.. "defaults.toml costs the whole session instead of one feature. Statement: "
			.. statement)
	end)

	helpers.it("and no top-level call site assumes the module loaded", function()
		local code = boot_code()

		-- A guarded require is only half of it: the call sites below still run, and
		-- `karabiner.init(file_system)` on a nil raises one line further down with the
		-- menubar still never created.
		local offenders = {}
		local line_no = 0
		for line in (code .. "\n"):gmatch("([^\n]*)\n") do
			line_no = line_no + 1
			if line:match("^karabiner%.") then
				table.insert(offenders, line_no .. ": " .. line:gsub("^%s+", ""))
			end
		end

		helpers.assert_eq(#offenders, 0,
			"a top-level `karabiner.<something>` call raises when the guarded require "
			.. "returned nil, which puts boot back exactly where it started: "
			.. table.concat(offenders, " | "))
	end)

end)





-- ==================================================================
-- ==================================================================
-- ======= 2/ Lease revocation does not depend on the risky module ==
-- ==================================================================
-- ==================================================================

helpers.describe("boot: exact lease revocation survives a failed require", function()

	helpers.it("has a fallback that does not go through the karabiner module", function()
		local code = boot_code()
		local arm_at = code:find(ARMING, 1, true)
		helpers.assert_true(arm_at ~= nil, "the teardown arming must be findable")
		local declaration_at = code:find(SHUTDOWN_DECLARATION, 1, true)
		helpers.assert_true(declaration_at ~= nil and declaration_at < arm_at,
			"the complete shutdown body must be declared before it is armed")

		-- The exact-fence helper is deliberately declared before the small armed
		-- callback. Include both declarations, but stop before later boot loading so
		-- a match cannot come from a normal platform.remap initialization site.
		local revoke_at = code:find("local function request_exact_lease_revoke", 1, true)
		helpers.assert_true(revoke_at ~= nil and revoke_at < declaration_at)
		local body = code:sub(revoke_at, arm_at - 1)

		helpers.assert_true(body:find("karabiner.revoke", 1, true) ~= nil,
			"the normal exact-lease shutdown path must still be there — this test must not be "
				.. "satisfiable by deleting it")

		-- LeaseController is captured above the risky platform.remap require. Its stop
		-- operation targets only the already-known generation variables/watchdog, so
		-- the fallback neither depends on the failed module nor infers ownership from
		-- a stock process.
		helpers.assert_true(body:find("LeaseController.stop", 1, true) ~= nil,
			"when platform.remap never loaded, the early exact controller must still revoke "
				.. "the generation without touching stock Karabiner")

		helpers.assert_true(body:find("is_hs_owned_bridge", 1, true) == nil,
			"stock-process observation must never authorize teardown")
	end)

end)
