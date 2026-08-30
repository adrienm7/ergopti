--- tests/unit/adapters/test_tray_menu_native_failures.lua

--- ==============================================================================
--- MODULE: TrayMenu Native Failure Regression
--- DESCRIPTION:
--- Verifies that every mutable menubar boundary distinguishes a native
--- commitment from false/throw refusal, reports the exact operation, and leaves
--- callers with an explicit boolean result.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads the real adapter around a controllable native menubar object.
--- @return table fixture Adapter, failure plan, calls, and captured log lines.
local function load_fixture()
	local failure = { operation = nil, mode = nil }
	local calls = {}
	local lines = {}
	local menubar = {}

	local function native_call(operation)
		calls[#calls + 1] = operation
		if failure.operation == operation then
			if failure.mode == "throw" then error("injected " .. operation .. " failure") end
			if failure.mode == "false" then return false end
		end
		return menubar
	end

	function menubar:setMenu(_) return native_call("setMenu") end
	function menubar:setTooltip(_) return native_call("setTooltip") end
	function menubar:setIcon(_) return native_call("setIcon") end
	function menubar:setTitle(_) return native_call("setTitle") end
	function menubar:delete() return native_call("delete") end

	package.loaded["infra.logger"] = nil
	local Logger = helpers.load_with_stubs("infra.logger")
	Logger.set_level("DEBUG")
	Logger.set_sink(function(line) lines[#lines + 1] = line end)
	local adapter = helpers.load_with_stubs("adapters.tray_menu", {
		image = { imageFromPath = function(path) return { path = path } end },
	})
	helpers.assert_eq(adapter.adopt(menubar), true)

	return {
		adapter = adapter,
		failure = failure,
		calls = calls,
		lines = lines,
		close = function() Logger.set_sink(nil) end,
	}
end





-- ==========================================
-- ==========================================
-- ======= 1/ Exact Native Commitment =======
-- ==========================================
-- ==========================================

helpers.describe("TrayMenu native setters expose refusal", function()
	helpers.it("accepts exact native capabilities for menu, tooltip, icon, and title", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.adapter.setMenu({}), true)
		helpers.assert_eq(fixture.adapter.setTooltip("Ergopti+"), true)
		helpers.assert_eq(fixture.adapter.setIcon({ imageData = {}, title = "E" }), true)
		helpers.assert_eq(fixture.calls,
			{ "setMenu", "setTooltip", "setIcon", "setTitle" })
		fixture.close()
	end)

	helpers.it("returns false and logs every false or throwing native setter", function()
		local fixture = load_fixture()
		local operations = {
			{ name = "setMenu", call = function() return fixture.adapter.setMenu({}) end },
			{ name = "setTooltip", call = function() return fixture.adapter.setTooltip("E") end },
			{ name = "setIcon", call = function()
				return fixture.adapter.setIcon({ imageData = {} })
			end },
		}

		for _, operation in ipairs(operations) do
			for _, mode in ipairs({ "false", "throw" }) do
				fixture.failure.operation = operation.name
				fixture.failure.mode = mode
				local before = #fixture.lines
				helpers.assert_eq(operation.call(), false,
					operation.name .. " must expose " .. mode .. " refusal")
				local rendered = table.concat(fixture.lines, "\n", before + 1)
				helpers.assert_contains(rendered, operation.name,
					"the ERROR log must name the native operation that refused")
			end
		end
		fixture.close()
	end)
end)

helpers.describe("TrayMenu native destruction retains exact ownership", function()
	helpers.it("retries the same menubar after a throwing delete", function()
		local fixture = load_fixture()
		fixture.failure.operation = "delete"
		fixture.failure.mode = "throw"
		helpers.assert_eq(fixture.adapter.destroy(), false,
			"a throwing native delete must refuse logical destruction")
		helpers.assert_eq(fixture.calls, {"delete"})

		fixture.failure.operation = nil
		fixture.failure.mode = nil
		helpers.assert_true(fixture.adapter.destroy(),
			"the exact retained menubar must remain retryable")
		helpers.assert_eq(fixture.calls, {"delete", "delete"},
			"the retry must reach the same adopted native owner")
		helpers.assert_true(fixture.adapter.destroy(),
			"destruction must remain idempotent after commitment")
		fixture.close()
	end)
end)

return true
