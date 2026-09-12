--- tests/unit/ui/tooltip/test_adapter_dependency_recovery.lua

--- ==============================================================================
--- MODULE: Tooltip Adapter Dependency Recovery Tests
--- DESCRIPTION:
--- Failed lazy acquisition must remain retryable without dispatching partial owners.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Exercises one real adapter against initially failing dependency constructors.
--- @param failed_name string Dependency whose loader fails twice.
--- @param callback function Receives the adapter and observed acquisition state.
local function with_fixture(failed_name, callback)
	local dependencies = { "ui.tooltip.renderer", "ui.tooltip" }
	helpers.with_fresh_modules({ "adapters.tooltip_renderer", "infra.logger",
		"ui.tooltip.renderer", "ui.tooltip" }, function()
		local state = { attempts = 0, calls = 0, errors = {} }
		local function accepted() state.calls = state.calls + 1; return true end
		local exports = {
			["ui.tooltip.renderer"] = { ELEM_PREDS = 3, set_element_text = accepted },
			["ui.tooltip"] = { show = accepted, hide = accepted, hide_forced = accepted, is_visible = accepted,
				capture_cleanup = function() return accepted end },
		}
		local saved = {}
		for _, name in ipairs(dependencies) do
			saved[name] = package.preload[name]
			package.loaded[name] = nil
			package.preload[name] = function()
				if name == failed_name then
					state.attempts = state.attempts + 1
					if state.attempts <= 2 then error("dependency acquisition refused", 0) end
				end
				return exports[name]
			end
		end
		local ok, err = xpcall(function()
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message, ...) state.errors[#state.errors + 1] = string.format(message, ...) end
			package.loaded["infra.logger"] = logger
			package.loaded["adapters.tooltip_renderer"] = nil
			callback(require("adapters.tooltip_renderer"), state)
		end, debug.traceback)
		for _, name in ipairs(dependencies) do package.preload[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("tooltip dependency recovery (tooltip-dependency-retry)", function()
	for _, dependency in ipairs({ "ui.tooltip.renderer", "ui.tooltip" }) do
		for _, route in ipairs({ "show", "hide", "forced hide", "isVisible", "updateElement" }) do
			helpers.it(route .. " recovers after repeated " .. dependency .. " load failure", function()
				with_fixture(dependency, function(adapter, state)
					local function invoke()
						if route == "show" then return adapter.show({ draw_calls = { { type = "text", text = "preview" } } }) end
						if route == "hide" then return adapter.hide() end
						if route == "forced hide" then return adapter.hide({ forced = true }) end
						if route == "isVisible" then return adapter.isVisible() end
						return adapter.updateElement({ id = "preds", text = {} })
					end
					invoke()
					invoke()
					helpers.assert_eq(state.attempts, 2, "failed acquisition must not install a permanent substitute")
					helpers.assert_eq(state.calls, 0, "no operation may reach a partially acquired dependency pair")
					helpers.assert_eq(#state.errors, 2, "each refused acquisition must report its cause")
					local result = invoke()
					helpers.assert_eq(state.attempts, 3)
					helpers.assert_eq(state.calls, 1, "the recovered dependency must receive the pending operation")
					if route == "isVisible" then helpers.assert_eq(result, true) end
					invoke()
					helpers.assert_eq(state.attempts, 3, "committed dependencies must remain cached")
					helpers.assert_eq(state.calls, 2)
				end)
			end)
		end
	end
end)
