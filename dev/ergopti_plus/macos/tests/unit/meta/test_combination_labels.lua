--- tests/unit/meta/test_combination_labels.lua

--- ==============================================================================
--- MODULE: Shared Physical Combination Label Contract
--- DESCRIPTION:
--- Replays independent physical pairs across all driver catalogue columns.
--- Equal translations must not merge distinct first-key families, and an
--- unknown physical key must be refused rather than guessed from a raw label.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the independent corpus through the driver's codec.
--- @return table
local function corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/tap_hold/combination_labels.json"), "r"))
	local text = file:read("*a")
	file:close()
	return require("adapters.json_codec").decode(text)
end

helpers.describe("shared canonical combination label policy", function()
	for _, platform in ipairs({ "ahk", "hs", "linux" }) do
		helpers.it("resolves independent ordered physical pairs for " .. platform, function()
			local catalog = require("tap_hold.key_catalog").load(helpers.shared("tap_hold/defaults.toml"), platform)
			local native = {}
			for _, key in ipairs(catalog) do native[key.key] = key.id end
			local policy = require("tap_hold.combination_labels")
			local count = 0
			for _, vector in ipairs(corpus().vectors) do
				local supported = false
				for _, host in ipairs(vector.platforms) do supported = supported or host == platform end
				if not supported then goto continue end
				count = count + 1
				local result = policy.resolve(catalog, native[vector.first], native[vector.second], function(key)
					return "translated:" .. key
				end)
				helpers.assert_eq(result.group_id, native[vector.first])
				helpers.assert_eq(result.hand, vector.hand)
				helpers.assert_eq(result.group_label, "translated:" .. vector.first_label)
				helpers.assert_eq(result.label, "translated:" .. vector.first_label .. " + translated:" .. vector.second_label)
				::continue::
			end
			helpers.assert_true(count >= 4, "each driver executes independent supported physical pairs")
		end)
	end

	helpers.it("keeps physical family identities distinct when translations coincide", function()
		local catalog = require("tap_hold.key_catalog").load(helpers.shared("tap_hold/defaults.toml"), "hs")
		local policy = require("tap_hold.combination_labels")
		local first = policy.resolve(catalog, "left_option", "caps_lock", function() return "same" end)
		local second = policy.resolve(catalog, "right_option", "caps_lock", function() return "same" end)
		helpers.assert_eq(first.group_label, second.group_label)
		helpers.assert_true(first.group_id ~= second.group_id, "grouping belongs to physical identity")
		helpers.assert_eq(catalog[1].id, "escape", "the resolver does not mutate catalogue order")
	end)

	helpers.it("refuses unknown first or second physical keys and empty translations", function()
		local catalog = require("tap_hold.key_catalog").load(helpers.shared("tap_hold/defaults.toml"), "hs")
		local policy = require("tap_hold.combination_labels")
		for _, pair in ipairs({ { "future_key", "caps_lock" }, { "left_option", "future_key" } }) do
			local ok = pcall(policy.resolve, catalog, pair[1], pair[2], function(key) return key end)
			helpers.assert_eq(ok, false, "an unknown key cannot get a guessed display identity")
		end
		local ok = pcall(policy.resolve, catalog, "left_option", "caps_lock", function() return "" end)
		helpers.assert_eq(ok, false, "missing translated labels cannot produce a blank family")
	end)
end)
