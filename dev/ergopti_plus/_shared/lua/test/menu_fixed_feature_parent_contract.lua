--- _shared/lua/test/menu_fixed_feature_parent_contract.lua

--- Canonical fixed parents retain the original independent translated/count contract.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")
local KEYS = { keyboard_layout = "menu.layout.title", hotstrings = "menu.hotstrings.title",
	shortcuts = "menu.shortcuts.title", tap_holds = "menu.tapholds.title", gestures = "menu.gestures.title" }
local STATES = { keyboard_layout = "layout_enabled", hotstrings = "hotstrings_enabled",
	shortcuts = "shortcuts_enabled", tap_holds = "tapholds_enabled", gestures = "gestures_enabled" }

local function read_json(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return assert(Json.decode(text))
end

local function with_actual_parent(driver, language, body)
	local Paths = require("infra.paths")
	local captions = read_json(Paths.shared("data/locales/" .. language .. ".json"))
	local menu = assert(Renderer.new({platform = driver == "macos" and "hs" or "linux",
		manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
		json_decode = Json.decode, i18n = {get = function(key) return captions[key] or key end,
			section = function(key) return captions[key] or key end},
		logger = {error = function() end, warn = function() end}}))
	local rows = menu.get_array("top_level")
	local owned
	for _, row in ipairs(rows) do if row.id == "hotstrings" then assert(not owned); owned = row end end
	assert(owned, "The actual declared hotstring parent must exist")
	body(menu, owned)
end

local function receipts(state, total, present, reads)
	return {hotstrings_enabled = function() reads.state = reads.state + 1; return state end,
		hotstrings_parent_total = function() reads.total = reads.total + 1; return total end,
		hotstrings_parent_count_present = function() reads.present = reads.present + 1; return present end}
end

function M.register(helpers, driver)
	local Paths = require("infra.paths")
	local oracle = read_json(Paths.shared("tests/corpus/menus/fixed_feature_parents.json"))
	local platform = driver == "macos" and "hs" or "linux"
	helpers.describe("canonical fixed feature parents (fixed-feature-parent-contract)", function()
		local languages = 0
		for code, captions in pairs(oracle.captions) do
			languages = languages + 1
			local language, expected = code, captions
			helpers.it("preserves all five original fixed captions in " .. language .. " (fixed-feature-parent-contract)", function()
				with_actual_parent(driver, language, function(menu)
					for id, key in pairs(KEYS) do
						if id ~= "hotstrings" then
							local reads, calls = 0, 0
							local child = {{title = "Existing native child", fn = function() calls = calls + 1 end}}
							local receive = assert(menu.group_receiver("top_level", id))
							helpers.assert_eq(reads, 0)
							local row = assert(receive(child, {[STATES[id]] = function() reads = reads + 1; return nil end}))
							helpers.assert_eq(row.label, expected[id], key)
							helpers.assert_true(rawequal(row.submenu, child))
							helpers.assert_eq(reads, 1); helpers.assert_nil(row.checked); helpers.assert_eq(calls, 0)
						end
					end
					for _, vector in ipairs(oracle.count_cases) do
						if vector.driver == platform then
							local reads, calls = {state = 0, total = 0, present = 0}, 0
							local child = {{title = "Existing native child", fn = function() calls = calls + 1 end}}
							local receive = assert(menu.group_receiver("top_level", "hotstrings"))
							local row = assert(receive(child, receipts(false, vector.total, vector.aggregate_available, reads)))
							helpers.assert_eq(row.label, expected.hotstrings .. vector.suffix)
							helpers.assert_eq(row.checked, false); helpers.assert_eq(reads.state, 1)
							helpers.assert_eq(reads.total, 1); helpers.assert_eq(reads.present, 1)
							helpers.assert_true(rawequal(row.submenu, child)); helpers.assert_eq(calls, 0)
						end
					end
				end)
			end)
		end
		helpers.it("uses the independent original 21-language oracle (fixed-feature-parent-contract)", function()
			helpers.assert_eq(languages, 21)
			helpers.assert_eq(oracle.original_sha, "98572fe1a57dde86c6e8591e79112fc5400ec819")
		end)
		for _, name in ipairs({"numeric string", "fraction", "negative", "infinite", "nan", "above maximum", "absent count",
			"present string", "present number", "present absent", "value throws", "present throws", "missing value getter", "missing present getter"}) do
			local case = name
			helpers.it("refuses " .. case .. " typed receipt through real projection owners (fixed-feature-parent-contract)", function()
				with_actual_parent(driver, "en", function(menu)
					local reads = {state = 0, total = 0, present = 0}
					local total, present = 1234, true
					if case == "numeric string" then total = "1234"
					elseif case == "fraction" then total = 1.5
					elseif case == "negative" then total = -1
					elseif case == "infinite" then total = math.huge
					elseif case == "nan" then total = 0/0
					elseif case == "above maximum" then total = 2^53
					elseif case == "absent count" then total = nil
					elseif case == "present string" then present = "true"
					elseif case == "present number" then present = 1
					elseif case == "present absent" then present = nil end
					local getters = receipts(false, total, present, reads)
					if case == "value throws" then getters.hotstrings_parent_total = function() error("value failed") end
					elseif case == "present throws" then getters.hotstrings_parent_count_present = function() error("presence failed") end
					elseif case == "missing value getter" then getters.hotstrings_parent_total = nil
					elseif case == "missing present getter" then getters.hotstrings_parent_count_present = nil end
					local receive = assert(menu.group_receiver("top_level", "hotstrings"))
					helpers.assert_nil(receive({}, getters))
					helpers.assert_nil(menu.group_row("top_level", "hotstrings", {}, getters))
					local root = menu.get_root(); local section = root.top_level
					local selected
					for _, row in ipairs(section) do if row.id == "hotstrings" then selected = row end end
					-- Use the actual declared row with the actual template/build projections.
					root.fixed_parent_probe = {selected}
					helpers.assert_nil(menu.template_rows("fixed_parent_probe", {}, getters, {hotstrings = {}}))
					helpers.assert_eq(#menu.build("fixed_parent_probe", "Hotstrings", {}, {hotstrings = function() return {menu = {}} end},
						{commands = {}, state_getters = getters}, {}), 0)
					helpers.assert_eq(reads.state, 0)
				end)
			end)
		end
		for _, name in ipairs({"withdrawn", "renamed", "wrong kind", "foreign platform", "duplicate", "policy mutation", "owner replacement", "getter replacement"}) do
			local case = name
			helpers.it("refuses " .. case .. " actual cohort before publication (fixed-feature-parent-contract)", function()
				with_actual_parent(driver, "en", function(menu, selected)
					local reads, calls = {state = 0, total = 0, present = 0}, 0
					local getters = receipts(false, 1234, true, reads)
					local receive = assert(menu.group_receiver("top_level", "hotstrings"))
					if case == "withdrawn" then menu.get_root().top_level = {}
					elseif case == "renamed" then selected.id = "unowned"
					elseif case == "wrong kind" then selected.type = "command"
					elseif case == "foreign platform" then selected.platforms = {"foreign"}
					elseif case == "duplicate" then local rows = menu.get_array("top_level"); rows[#rows + 1] = selected
					elseif case == "policy mutation" then selected.caption_count_policy.format = "%s%s"
					elseif case == "owner replacement" then menu.group_row = function() error("foreign owner must never run") end
					else getters.hotstrings_parent_total = function()
						reads.total = reads.total + 1; getters.hotstrings_parent_count_present = function() return true end; return 1234
					end end
					helpers.assert_nil(receive({{title = "Native child", fn = function() calls = calls + 1 end}}, getters))
					helpers.assert_eq(calls, 0)
					if case ~= "getter replacement" then helpers.assert_eq(reads.total, 0); helpers.assert_eq(reads.state, 0) end
				end)
			end)
		end
		if platform == "linux" then
			helpers.it("retains the genuinely absent TapHold disabled leaf declaration (fixed-feature-parent-contract)", function()
				with_actual_parent(driver, "en", function(menu)
					local rows = assert(menu.template_rows("linux_tap_holds_absent_parent", {}, {}, {}))
					helpers.assert_eq(#rows, 1); helpers.assert_eq(rows[1].label, oracle.captions.en.tap_holds)
					helpers.assert_eq(rows[1].disabled, true); helpers.assert_nil(rows[1].submenu)
					helpers.assert_nil(rows[1].items); helpers.assert_nil(rows[1].action); helpers.assert_nil(rows[1].checked)
				end)
			end)
		end
	end)
end

return M
