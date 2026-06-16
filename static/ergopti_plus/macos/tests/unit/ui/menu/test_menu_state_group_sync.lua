--- tests/unit/ui/menu/test_menu_state_group_sync.lua

--- ==============================================================================
--- MODULE: Menu State — Hotstring Group Sync (perf regression)
--- DESCRIPTION:
--- Locks down that MenuState.sync_state_to_modules applies ONLY the delta when
--- restoring saved hotstring-group state: an already-enabled group is left alone
--- (a single cheap enable_group no-op), never disabled-then-re-enabled.
---
--- ROOT CAUSE ENCODED: the boot state-restore used to run disable_group +
--- enable_group for EVERY enabled group. At startup all groups are already
--- enabled, so this purged and RE-PARSED each category TOML from disk and
--- re-sorted all ~5355 mappings ~16× for zero net change — the dominant ~2 s of
--- the "Menu + UI + script control start" boot phase. If a future edit
--- reintroduces the blind round-trip, the disable assertion below fails.
--- ==============================================================================

local helpers = require("tests.helpers")

local MenuState = helpers.load_with_stubs("ui.menu.menu_state")

--- True when `list` contains the string `needle`.
local function has(list, needle)
	for _, v in ipairs(list) do
		if v == needle then return true end
	end
	return false
end

--- Runs sync_state_to_modules with a spy keymap and returns the ordered list of
--- enable_group / disable_group calls it made.
--- @param hotstrings table Map of group name → desired enabled boolean.
--- @return table Array of "enable:<name>" / "disable:<name>" strings.
local function capture_group_calls(hotstrings)
	local calls = {}
	local fake_keymap = {
		enable_group     = function(n) calls[#calls + 1] = "enable:"  .. n end,
		disable_group    = function(n) calls[#calls + 1] = "disable:" .. n end,
		is_group_enabled = function() return true end,
	}
	local state = { hotstrings = hotstrings }
	MenuState.sync_state_to_modules(state, {}, false, {
		keymap           = fake_keymap,
		hotstring_editor = {},  -- empty: every type(...) guard skips it
		core_mods        = {},
		save_prefs       = function() end,
	})
	return calls
end

helpers.describe("menu_state: hotstring group sync applies only the delta", function()
	helpers.it("enables a wanted group WITHOUT disabling it first (no costly reload round-trip)", function()
		local calls = capture_group_calls({ magickey = true })
		helpers.assert_true(has(calls, "enable:magickey"),
			"an enabled group must be passed to enable_group")
		helpers.assert_true(not has(calls, "disable:magickey"),
			"an enabled group must NOT be disabled first — that forced a full TOML reload + re-sort")
	end)

	helpers.it("disables ONLY the groups the user turned off", function()
		local calls = capture_group_calls({ rolls = false })
		helpers.assert_true(has(calls, "disable:rolls"),
			"a disabled group must be passed to disable_group")
		helpers.assert_true(not has(calls, "enable:rolls"),
			"a disabled group must NOT be re-enabled")
	end)
end)
