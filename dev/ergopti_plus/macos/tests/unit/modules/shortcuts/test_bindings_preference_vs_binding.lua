--- tests/unit/modules/shortcuts/test_bindings_preference_vs_binding.lua

--- ==============================================================================
--- MODULE: Shortcut Preference Versus Live Binding Regression
--- DESCRIPTION:
--- The named-shortcut registry reported `enabled = hotkeys[name] ~= nil`, the
--- live native binding, where every consumer expected the user's preference.
--- A pause, Disable All or Shortcuts OFF releases every hotkey, so each save
--- made in that window persisted every [shortcuts.keys] entry as false, and the
--- Enable All rollback turned every shortcut off for the rest of the session.
--- Bindings.enable() also refused outright while the layer was paused, so a
--- saved preference could not even be re-applied behind the pause fence.
---
--- FEATURES & RATIONALE:
--- 1. Two Axes: `enabled` is the preference, `bound` the native state; both are
---    asserted on every lifecycle edge that releases hotkeys.
--- 2. Paused Edits: a preference edited behind the pause fence is recorded, no
---    native hotkey is acquired, and the layer honours it on resume.
--- 3. Refusal Is No Change: a refused enable leaves the preference untouched.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")

-- Preference and binding asserted against every listed shortcut. The fixture
-- index refuses an empty registry, so none of these loops can pass vacuously.
local DISABLED_ID = "ctrl_d"

--- Asserts the user preference of every listed shortcut.
--- @param bindings table Real Bindings module.
--- @param expect function Returns the expected preference for a shortcut id.
--- @param context string Diagnostic context.
local function assert_preferences(bindings, expect, context)
	for id, entry in pairs(Fixture.index(bindings)) do
		helpers.assert_eq(entry.enabled, expect(id),
			context .. ": '" .. id .. "' listed preference")
		helpers.assert_eq(bindings.is_enabled(id), expect(id),
			context .. ": '" .. id .. "' is_enabled must report the preference")
	end
end

--- Asserts the live native binding of every listed shortcut.
--- @param bindings table Real Bindings module.
--- @param expect function Returns the expected binding for a shortcut id.
--- @param context string Diagnostic context.
local function assert_bindings(bindings, expect, context)
	for id, entry in pairs(Fixture.index(bindings)) do
		helpers.assert_eq(entry.bound, expect(id),
			context .. ": '" .. id .. "' listed binding")
		helpers.assert_eq(bindings.is_bound(id), expect(id),
			context .. ": '" .. id .. "' is_bound must report the native owner")
	end
end





-- ===============================================================
-- ===============================================================
-- ======= 1/ Every Release Edge Keeps The User Preference =======
-- ===============================================================
-- ===============================================================

helpers.describe("shortcut bindings: preference survives every release edge (shortcut-preference-vs-binding)", function()
	for _, edge in ipairs({ "pause", "stop", "pause_hotkeys_only" }) do
		helpers.it("keeps every preference through " .. edge, function()
			Fixture.with_recommended_bindings(function(bindings, ctx)
				helpers.assert_eq(bindings.start(), true)
				helpers.assert_eq(bindings.disable(DISABLED_ID), true)
				local function wanted(id) return id ~= DISABLED_ID end
				assert_preferences(bindings, wanted, "started")

				helpers.assert_eq(bindings[edge](), true, edge .. " must settle")
				helpers.assert_eq(Fixture.live_count(ctx), 0,
					edge .. " must release every native hotkey")
				assert_preferences(bindings, wanted, "after " .. edge)
				assert_bindings(bindings, function() return false end, "after " .. edge)
			end)
		end)
	end
end)





-- ============================================================
-- ============================================================
-- ======= 2/ Preferences Edited Behind The Pause Fence =======
-- ============================================================
-- ============================================================

helpers.describe("shortcut bindings: paused preference edits (shortcut-preference-vs-binding)", function()
	helpers.it("records an enable while paused, binds nothing, and binds it on resume", function()
		Fixture.with_recommended_bindings(function(bindings, ctx)
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.disable(DISABLED_ID), true)
			helpers.assert_eq(bindings.pause(), true)
			local created_before = ctx.created

			helpers.assert_eq(bindings.enable(DISABLED_ID), true,
				"a preference edit behind the pause fence must commit")
			helpers.assert_eq(ctx.created, created_before,
				"no native hotkey may be acquired while the layer is paused")
			helpers.assert_eq(#ctx.errors, 0,
				"re-applying a saved preference while paused is not an error: "
					.. table.concat(ctx.errors, " | "))
			assert_preferences(bindings, function() return true end, "paused")
			assert_bindings(bindings, function() return false end, "paused")

			helpers.assert_eq(bindings.resume_after_pause(), true)
			assert_bindings(bindings, function() return true end, "resumed")
		end)
	end)

	helpers.it("keeps a shortcut disabled while paused unbound after resume", function()
		Fixture.with_recommended_bindings(function(bindings)
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.pause(), true)
			helpers.assert_eq(bindings.disable(DISABLED_ID), true)
			helpers.assert_eq(bindings.resume_after_pause(), true)
			local function wanted(id) return id ~= DISABLED_ID end
			assert_preferences(bindings, wanted, "resumed")
			assert_bindings(bindings, wanted, "resumed")
		end)
	end)
end)





-- ===================================================
-- ===================================================
-- ======= 3/ A Refused Enable Changes Nothing =======
-- ===================================================
-- ===================================================

helpers.describe("shortcut bindings: a refused enable keeps the preference (shortcut-preference-vs-binding)", function()
	helpers.it("keeps a disabled preference disabled", function()
		Fixture.with_recommended_bindings(function(bindings, ctx)
			helpers.assert_eq(bindings.start(), true)
			helpers.assert_eq(bindings.disable("cmd_star"), true)
			ctx.refuse.cmd_star = true
			helpers.assert_eq(bindings.enable("cmd_star"), false)
			helpers.assert_eq(bindings.is_enabled("cmd_star"), false)
			helpers.assert_eq(bindings.is_bound("cmd_star"), false)
		end)
	end)

	helpers.it("keeps an enabled preference enabled", function()
		Fixture.with_recommended_bindings(function(bindings, ctx)
			ctx.refuse.cmd_star = true
			helpers.assert_eq(bindings.enable("cmd_star"), false)
			helpers.assert_eq(bindings.is_enabled("cmd_star"), true,
				"a factory refusal must not rewrite the user's saved preference")
			helpers.assert_eq(bindings.is_bound("cmd_star"), false)
		end)
	end)

	helpers.it("refuses an unknown id without inventing a preference", function()
		Fixture.with_recommended_bindings(function(bindings)
			helpers.assert_eq(bindings.pause(), true)
			helpers.assert_eq(bindings.enable("no_such_shortcut_id"), false)
			helpers.assert_eq(bindings.is_enabled("no_such_shortcut_id"), false)
		end)
	end)
end)

return true
