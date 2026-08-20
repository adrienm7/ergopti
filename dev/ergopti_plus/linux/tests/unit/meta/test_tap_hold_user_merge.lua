--- tests/unit/meta/test_tap_hold_user_merge.lua

--- ==============================================================================
--- MODULE: A User File Adds To The Defaults, It Does Not Erase Them
--- DESCRIPTION:
--- How ~/.config/ergopti/tap_hold.toml combines with the shared defaults.
---
--- THE DEFECT THIS PINS:
--- The user file replaced the defaults wholesale. That reads as respectful of
--- the user\'s intent and is the opposite of it: a file naming ONE key silenced
--- every other key the layout defines, so customising the tap action of a single
--- thumb key disabled tap-hold across the rest of the keyboard. And every key
--- added to the shared defaults afterwards never reached anyone who had ever
--- opened the file — their layout froze on the day they first customised it.
---
--- The field-level half matters for the same reason at smaller scale: a user
--- file that names a key and sets only its tap action must keep the default hold
--- modifier, or a one-line edit turns a tap-hold key into a plain one.
---
--- macOS seeds per key and has done since its config loader existed. This is the
--- driver that did not.
--- ==============================================================================

local helpers = require("tests.helpers")

local Manager = helpers.load_module("platform.remap.manager")

--- Writes a temporary user tap_hold.toml and reads the merged result.
--- @param toml string File contents.
--- @return table keys_config
local function merged_with(toml)
	local path = os.tmpname()
	local handle = assert(io.open(path, "w"))
	handle:write(toml)
	handle:close()
	local keys = Manager._load_tap_hold_config_for_test(path)
	os.remove(path)
	return keys or {}
end

--- The shared defaults alone.
--- @return table
local function defaults_only()
	return Manager._load_tap_hold_config_for_test(nil) or {}
end

--- Any key id the shared defaults define, so the fixtures below do not have to
--- name one and go stale when the layout changes.
--- @param keys table
--- @return string|nil
local function some_key_id(keys)
	local ids = {}
	for id in pairs(keys) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids[1]
end




-- =================================================================
-- =================================================================
-- ======= 1/ The other keys survive ===============================
-- =================================================================
-- =================================================================

helpers.describe("tap-hold: a user file naming one key", function()

	helpers.it("keeps every key it did not mention", function()
		local defaults = defaults_only()
		helpers.assert_true(next(defaults) ~= nil,
			"the shared defaults must load, or this test compares two empty sets")

		local target = some_key_id(defaults)
		local merged = merged_with(string.format([[
[tap_hold.keys.%s]
tap_action = "z"
]], target))

		local default_count, merged_count = 0, 0
		for _ in pairs(defaults) do default_count = default_count + 1 end
		for _ in pairs(merged) do merged_count = merged_count + 1 end

		helpers.assert_eq(merged_count, default_count,
			"a file naming one key used to silence every other key the layout "
				.. "defines, so customising a single thumb key disabled tap-hold "
				.. "across the rest of the keyboard")
	end)

	helpers.it("still applies the change the user asked for", function()
		local target = some_key_id(defaults_only())
		local merged = merged_with(string.format([[
[tap_hold.keys.%s]
tap_action = "zzz"
]], target))
		helpers.assert_eq(merged[target].tap_action, "zzz",
			"a merge that preserved everything and applied nothing would pass the "
				.. "case above and be useless")
	end)

	helpers.it("keeps the fields of that key it did not set", function()
		local defaults = defaults_only()
		-- A key whose default declares a hold behaviour, so there is something to
		-- lose. Picking one with nothing to lose would make this vacuous.
		local target, expected = nil, nil
		for id, entry in pairs(defaults) do
			if entry.hold_modifier or entry.hold_layer then
				target = id
				expected = entry.hold_modifier or entry.hold_layer
				break
			end
		end
		helpers.assert_not_nil(target,
			"no default key declares a hold behaviour — nothing here can be lost, "
				.. "and this case would pass by having nothing to check")

		local merged = merged_with(string.format([[
[tap_hold.keys.%s]
tap_action = "q"
]], target))
		local kept = merged[target].hold_modifier or merged[target].hold_layer
		helpers.assert_eq(kept, expected,
			"a one-line edit that sets only the tap action must not turn a tap-hold "
				.. "key into a plain one")
	end)

	helpers.it("accepts a key the defaults do not define", function()
		local merged = merged_with([[
[tap_hold.keys.invented_by_the_user]
tap_action = "a"
hold_modifier = "lctl"
]])
		helpers.assert_not_nil(merged.invented_by_the_user,
			"merging must not become a whitelist: the user may bind a key the "
				.. "shipped layout says nothing about")
		helpers.assert_eq(merged.invented_by_the_user.hold_modifier, "lctl")
	end)

end)
