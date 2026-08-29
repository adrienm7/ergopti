--- tests/meta/test_factory_reset_boot_reconciliation.lua

--- ==============================================================================
--- MODULE: Factory-Reset Boot Reconciliation Boundary
--- DESCRIPTION:
--- HS-052 requires the durable reset journal to settle before any boot consumer
--- reads, merges, or seeds the configuration paths it protects. The journal's
--- behavior is covered directly by its unit test; this guard pins only the root
--- ordering that a module-level test cannot observe.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Removes line and long-bracket comments before executable ordering checks.
--- @param source string
--- @return string code
local function strip_lua_comments(source)
	local code = source
	local cursor = 1
	while true do
		local open_at, open_end, equals = code:find("%-%-%[(=*)%[", cursor)
		if not open_at then break end
		local close_token = "]" .. equals .. "]"
		local _, close_end = code:find(close_token, open_end + 1, true)
		if not close_end then
			code = code:sub(1, open_at - 1)
			break
		end
		local block = code:sub(open_at, close_end)
		local newlines = block:gsub("[^\n]", "")
		code = code:sub(1, open_at - 1) .. newlines .. code:sub(close_end + 1)
		cursor = open_at + #newlines
	end
	return (code:gsub("%-%-[^\n]*", ""))
end

--- Proves reconciliation precedes every root configuration consumer.
--- @param source string
--- @return boolean safe
local function reconciliation_precedes_consumers(source)
	local code = strip_lua_comments(source)
	local reconcile_at = code:find("owner:reconcile()", 1, true)
	local onboarding_at = code:find('pcall(require, "ui.onboarding")', 1, true)
	local overrides_at = code:find("config_overrides.apply(", 1, true)
	local preferences_at = code:find("Preferences.load(", 1, true)
	return type(reconcile_at) == "number"
		and type(onboarding_at) == "number"
		and type(overrides_at) == "number"
		and type(preferences_at) == "number"
		and reconcile_at < onboarding_at
		and reconcile_at < overrides_at
		and reconcile_at < preferences_at
end

helpers.describe("factory-reset recovery precedes every configuration consumer", function()
	helpers.it("runs exact reconciliation before onboarding, overrides, and preferences", function()
		-- The selector is unique to init.lua. read_driver_source keeps the source
		-- movable while still making relative order authoritative inside that file.
		local source = helpers.read_driver_source("Factory-reset recovery reconciled")
		helpers.assert_true(type(source) == "string" and source ~= "", "root source must be readable")
		helpers.assert_true(reconciliation_precedes_consumers(source),
			"the executable reconciliation call must precede every configuration consumer")
	end)

	helpers.it("rejects a reconciliation call preserved only inside a comment", function()
		local source = helpers.read_driver_source("Factory-reset recovery reconciled")
		local call = "\tif owner:reconcile() ~= true then"
		local call_at = source:find(call, 1, true)
		helpers.assert_true(type(call_at) == "number", "mutation precondition must find the root call")
		local line_end = source:find("\n", call_at, true) or (#source + 1)
		local original_line = source:sub(call_at, line_end - 1)
		local mutant = source:sub(1, call_at - 1) .. "\t--[[\n" .. original_line
			.. "\n\t]]" .. source:sub(line_end)
		helpers.assert_eq(false, reconciliation_precedes_consumers(mutant),
			"a commented call cannot certify the boot boundary")
	end)
end)
