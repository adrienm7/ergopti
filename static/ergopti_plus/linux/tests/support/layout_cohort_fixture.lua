--- tests/support/layout_cohort_fixture.lua

--- ==============================================================================
--- MODULE: Controlled Layout Cohort Fixture
--- DESCRIPTION:
--- Uses the actual KeyboardLayout planner through its explicit table test seam.
--- Source-selection tests can separately acknowledge a controlled Capture map.
--- Neither fixture acquires a native keymap, input descriptor or output lease.
--- ==============================================================================

local M = {}
local Utf8 = require("compat.utf8")
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local driver = source:match("^(.*)/tests/support/layout_cohort_fixture%.lua$") or "."

--- Copies controlled map data without sharing mutable steps or modifier arrays.
--- @param built table
--- @return table
local function copy_map(built)
	local owned = {}
	for char, step in pairs(built) do
		local mods = {}
		for index, mod in ipairs(step.mods) do mods[index] = mod end
		owned[char] = { keycode = step.keycode, level = step.level, mods = mods }
	end
	return owned
end

--- Creates a scripted layout with actual plan, view and currency receipts.
--- @param code_for function Controlled character-to-code allocator.
--- @return table layout
--- @return table scope Explicit non-native fixture description.
function M.layout(code_for)
	assert(type(code_for) == "function", "a controlled code allocator is required")
	local layout = assert(loadfile(driver .. "/adapters/keyboard_layout.lua"))()
	local publish = layout._set_table_for_test
	local plan, resolve = layout.plan, layout.resolve
	local built = {}
	publish(built)
	local function ensure(char)
		if type(char) ~= "string" or char == "" or not Utf8.len(char) then return false end
		local code = code_for(char)
		if type(code) ~= "number" or code % 1 ~= 0 then return false end
		if not built[char] or built[char].keycode ~= code then
			built[char] = { keycode = code, level = 1, mods = {} }
			publish(built)
		end
		return true
	end
	layout.plan = function(text)
		if type(text) ~= "string" or not Utf8.len(text) then return nil, nil end
		for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			if not ensure(char) then return nil, char end
		end
		return plan(text)
	end
	layout.resolve = function(char)
		return ensure(char) and resolve(char) or nil
	end
	layout.refresh = function()
		publish(built)
		return true
	end
	layout.source = function() return "scripted" end
	layout.shortcut_keycode = function(_, us_code) return us_code, {} end
	layout._set_table_for_test = function(value)
		built = value and copy_map(value) or {}
		publish(value and built or nil)
	end
	return layout, { kind = "controlled-layout-table", native_reason = "no-native-source-acknowledgement" }
end

--- Creates the controlled map acknowledgement used only by source-order tests.
--- @param build function Actual textual map parser used by those tests.
--- @return table capture
--- @return table scope Explicit non-native fixture description.
function M.capture(build)
	assert(type(build) == "function", "a controlled map parser is required")
	local capture, generation, built = {}, 0, nil
	local receipts = setmetatable({}, { __mode = "k" })
	local load, ready, inverse, current
	load = function(text)
		generation = generation + 1
		built = nil
		if type(text) ~= "string" or text == "" then return false end
		local offered = build(text)
		if type(offered) ~= "table" or next(offered) == nil then return false end
		built = copy_map(offered)
		return true
	end
	ready = function() return built ~= nil end
	inverse = function()
		if not built or capture.load ~= load or capture.is_ready ~= ready
			or capture.inverse_table ~= inverse or capture.inverse_current ~= current then return nil end
		local receipt = {}
		receipts[receipt] = { generation = generation, built = built }
		return copy_map(built), nil, receipt
	end
	current = function(receipt)
		local owned = receipts[receipt]
		local accepted = owned ~= nil and not owned.revoked and owned.generation == generation and owned.built == built
			and capture.load == load and capture.is_ready == ready
			and capture.inverse_table == inverse and capture.inverse_current == current
		if owned and not accepted then owned.revoked = true end
		return accepted
	end
	capture.load, capture.is_ready, capture.inverse_table, capture.inverse_current = load, ready, inverse, current
	return capture, { kind = "controlled-capture-acknowledgement", native_reason = "source-selection-protocol-only" }
end

return M
