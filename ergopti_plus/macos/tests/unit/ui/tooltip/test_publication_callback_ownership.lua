--- tests/unit/ui/tooltip/test_publication_callback_ownership.lua

--- ==============================================================================
--- MODULE: Tooltip Publication Callback Ownership Tests
--- DESCRIPTION:
--- A superseded show callback must neither acknowledge nor revoke a newer tooltip.
--- ==============================================================================

local helpers = require("tests.helpers")
local ROUTES = { "standard", "stacked", "loading", "prediction" }

--- Runs a real facade around observable presentation and diagnostic boundaries.
--- @param callback function Receives the facade, surface and route dispatcher.
local function with_fixture(callback)
	local names = { "ui.tooltip", "ui.tooltip.config", "ui.tooltip.tooltip_llm",
		"ui.tooltip.tooltip_hotstring", "infra.logger" }
	helpers.with_fresh_modules(names, function()
		for _, name in ipairs(names) do package.loaded[name] = nil end
		local state = { visible = false, content = nil, errors = 0, on_error = nil }
		local function paint(content)
			if type(content) == "table" then
				content = type(content[1]) == "table" and content[1].text or content[1]
			end
			state.visible, state.content = true, content
			return true
		end
		local function hide() state.visible = false; return true end
		local logger = helpers.make_logger_stub()
		logger.error = function()
			state.errors = state.errors + 1
			if state.on_error then state.on_error() end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["ui.tooltip.config"] = {}
		package.loaded["ui.tooltip.tooltip_llm"] = {
			hide = hide, show_predictions = paint,
		}
		package.loaded["ui.tooltip.tooltip_hotstring"] = {
			hide = hide, hide_forced = hide, dismiss_silent = function() return true end,
			show = paint, show_stacked = paint, show_loading = paint,
		}
		local facade = require("ui.tooltip")
		local function show(route, content)
			if route == "standard" then return facade.show(content, false, true) end
			if route == "stacked" then return facade.show_stacked({ { text = content } }, true) end
			if route == "loading" then return facade.show_loading(content, true) end
			return facade.show_predictions({ content }, 1, true)
		end
		callback(facade, state, show)
	end)
end

helpers.describe("tooltip publication callback ownership (tooltip-publication-owner)", function()
	for _, predecessor in ipairs(ROUTES) do
		for _, successor in ipairs(ROUTES) do
			for _, outcome in ipairs({ "true", "false", "nil", "throw" }) do
				helpers.it(predecessor .. " preserves " .. successor .. " after callback " .. outcome, function()
					with_fixture(function(facade, state, show)
						local next_content, committed = "successor", nil
						facade.set_on_show_callback(function()
							facade.set_on_show_callback(function() return true end)
							committed = show(successor, next_content)
							if outcome == "throw" then error("old interaction owner refused", 0) end
							if outcome == "nil" then return nil end
							return outcome == "true"
						end)
						helpers.assert_eq(show(predecessor, "predecessor"), false, "a superseded publication cannot acknowledge success")
						helpers.assert_eq(committed, true)
						helpers.assert_eq(state.visible, true, "old callback cleanup must preserve the new surface")
						helpers.assert_true(rawequal(state.content, next_content))
						helpers.assert_eq(state.errors, outcome == "true" and 0 or 1)
					end)
				end)
			end
		end
	end

	for _, route in ipairs(ROUTES) do
		helpers.it(route .. " preserves a successor opened by its refusal diagnostic", function()
			with_fixture(function(facade, state, show)
				local next_content, committed = "successor", nil
				facade.set_on_show_callback(function() return false end)
				state.on_error = function()
					state.on_error = nil
					facade.set_on_show_callback(nil)
					committed = show(route, next_content)
				end
				helpers.assert_eq(show(route, "predecessor"), false)
				helpers.assert_eq(committed, true)
				helpers.assert_eq(state.visible, true)
				helpers.assert_true(rawequal(state.content, next_content))
			end)
		end)

		helpers.it(route .. " does not acknowledge a callback-hidden surface", function()
			with_fixture(function(facade, state, show)
				facade.set_on_show_callback(function() return facade.hide_forced() end)
				helpers.assert_eq(show(route, "predecessor"), false)
				helpers.assert_eq(state.visible, false)
			end)
		end)
	end
end)
