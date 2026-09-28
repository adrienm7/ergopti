--- _shared/lua/test/config_scope_plan_contract.lua

--- Plans carry dynamic ownership and separate-file requirements explicitly.
return function(helpers)
	local Manifest = require("infra.manifest_reader")
	helpers.describe("scoped configuration planning", function()
		helpers.it("collects exact runtime-owned leaves once without claiming static or unknown siblings", function()
			local calls = 0
			helpers.assert_not_nil(Manifest.find_entry_by_path("gestures.enabled"))
			local owned = Manifest.scope_inventory("hotstrings", {
				language = function()
					calls = calls + 1
					return { "hotstrings.groups.french_probe", "hotstrings.modules.french_probe.accents",
						"gestures.enabled" }
				end,
				extension = function()
					calls = calls + 1
					return { "hotstrings.modules.ext:ergopti:rolls.custom", "hotstrings.groups.french_probe",
						"shortcuts.personal.other_scope" }
				end,
			})
			helpers.assert_eq(calls, 2)
			helpers.assert_eq(owned, { "hotstrings.groups.french_probe",
				"hotstrings.modules.ext:ergopti:rolls.custom", "hotstrings.modules.french_probe.accents" })
			local plan = Manifest.scope_plan("hotstrings", "clear", owned)
			local indexed = {}
			for _, row in ipairs(plan.operations) do indexed[row.section .. "." .. row.key] = row end
			for _, path in ipairs(owned) do helpers.assert_eq(indexed[path].delete, true) end
			helpers.assert_eq(indexed["hotstrings.modules.ext:ergopti:rolls.unknown"], nil)
			helpers.assert_eq(indexed["shortcuts.personal.other_scope"], nil)
		end)
		helpers.it("refuses incomplete inventory instead of returning a partial successful plan", function()
			helpers.assert_type(Manifest.scope_inventory, "function")
			for _, paths in ipairs({ { "hotstrings.modules.group.section.expert" }, { "future.setting" },
				{ [1] = "hotstrings.groups.valid", [3] = "hotstrings.groups.hole" },
				{ named = "hotstrings.groups.valid" }, { "hotstrings.groups..invalid" } }) do
				local ok = pcall(Manifest.scope_inventory, "hotstrings", { runtime = function() return paths end })
				helpers.assert_eq(ok, false)
			end
			helpers.assert_eq(pcall(Manifest.scope_inventory, "hotstrings", {
				first = function() return { "hotstrings.groups.valid" } end,
				second = function() error("runtime inventory unavailable") end,
			}), false)
			helpers.assert_eq(pcall(Manifest.scope_inventory, "hotstrings", { invalid = false }), false)
		end)
		helpers.it("routes separate-file presets for restore and clear without inventing config rows", function()
			for _, mode in ipairs({ "recommended", "clear" }) do
				local plan = Manifest.scope_plan("global", mode, {})
				helpers.assert_eq(plan.scope, "global")
				helpers.assert_eq(plan.mode, mode)
				helpers.assert_eq(plan.presets, { { scope = "tap_holds", preset = "tap_hold", mode = mode } })
				helpers.assert_true(#plan.operations > 100)
				plan.presets[1].preset = "mutated"
				helpers.assert_eq(Manifest.scope_plan("global", mode).presets[1].preset, "tap_hold")
				helpers.assert_eq(#Manifest.scope_plan("gestures", mode).presets, 0)
			end
		end)
	end)
end
