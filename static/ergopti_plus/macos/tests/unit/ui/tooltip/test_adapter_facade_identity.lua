--- tests/unit/ui/tooltip/test_adapter_facade_identity.lua

--- ==============================================================================
--- MODULE: Tooltip Adapter Facade Identity Tests
--- DESCRIPTION:
--- The port and direct callers must share surface revocation and show callbacks.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real facade and adapter around a reentrant shared-surface boundary.
--- @param callback function Receives the facade, adapter and surface controls.
local function with_fixture(callback)
	local names = { "adapters.tooltip_renderer", "ui.tooltip", "ui.tooltip.init",
		"ui.tooltip.config", "ui.tooltip.renderer", "ui.tooltip.tooltip_llm",
		"ui.tooltip.tooltip_hotstring", "infra.logger" }
	helpers.with_fresh_modules(names, function()
		for _, name in ipairs(names) do package.loaded[name] = nil end
		local state = { visible = false, paints = 0, on_paint = nil }
		local function hide() state.visible = false; return true end
		local function paint()
			state.paints = state.paints + 1
			if state.on_paint then state.on_paint() end
			state.visible = true
			return true
		end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.tooltip.config"] = {}
		package.loaded["ui.tooltip.renderer"] = {}
		package.loaded["ui.tooltip.tooltip_llm"] = {
			hide = hide, show_predictions = paint, is_visible = function() return state.visible end,
		}
		package.loaded["ui.tooltip.tooltip_hotstring"] = {
			hide = hide, hide_forced = hide, dismiss_silent = function() return true end,
			show = paint, show_loading = paint, is_visible = function() return state.visible end,
		}
		callback(require("ui.tooltip"), require("adapters.tooltip_renderer"), state)
	end)
end

helpers.describe("tooltip adapter identity (tooltip-adapter-single-owner)", function()
	for _, route in ipairs({ "loading", "prediction" }) do
		helpers.it("adapter forced hide invalidates an in-flight " .. route .. " render", function()
			with_fixture(function(facade, adapter, state)
				local shown = 0
				facade.set_on_show_callback(function() shown = shown + 1; return true end)
				local function show()
					if route == "loading" then return facade.show_loading("loading", true) end
					return facade.show_predictions({ "prediction" }, 1, true)
				end
				state.on_paint = function()
					state.on_paint = nil
					adapter.hide({ forced = true })
				end
				helpers.assert_eq(show(), false, "the revoked outer render must not commit")
				helpers.assert_eq(shown, 0, "the revoked render must not publish its interaction owner")
				helpers.assert_eq(show(), false, "pending forced cleanup must block successor paints")
				helpers.assert_eq(state.paints, 1)
				adapter.hide({ forced = true })
				helpers.assert_eq(state.visible, false, "retry must settle the retained surface cleanup")
				helpers.assert_eq(show(), true)
				helpers.assert_eq(state.paints, 2)
				helpers.assert_eq(shown, 1)
				helpers.assert_nil(package.loaded["ui.tooltip.init"], "no alternate facade may be constructed")
			end)
		end)
	end

	helpers.it("adapter show honors the canonical interaction acquisition callback", function()
		with_fixture(function(facade, adapter, state)
			local attempts = 0
			facade.set_on_show_callback(function() attempts = attempts + 1; return false end)
			adapter.show({ draw_calls = { { type = "text", text = "preview" } } })
			helpers.assert_eq(attempts, 1, "the adapter must acquire the registered interaction owner")
			helpers.assert_eq(state.paints, 1)
			helpers.assert_eq(state.visible, false, "refused interaction ownership must revoke visible pixels")
		end)
	end)
end)
