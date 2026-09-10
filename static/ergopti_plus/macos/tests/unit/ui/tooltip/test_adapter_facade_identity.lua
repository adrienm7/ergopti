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
		local state = { visible = false, paints = 0, on_paint = nil, errors = 0, on_error = nil }
		local function hide()
			state.visible = false
			if state.on_hide then state.on_hide() end
			return true
		end
		local function paint()
			state.paints = state.paints + 1
			if state.on_paint then state.on_paint() end
			state.visible = true
			return state.paint_result ~= false
		end
		local logger = helpers.make_logger_stub()
		logger.error = function()
			state.errors = state.errors + 1
			if state.on_error then state.on_error() end
		end
		package.loaded["infra.logger"] = logger
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
	for _, route in ipairs({ "facade", "adapter" }) do
		for _, outcome in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it("(tooltip-adapter-refusal-owner) preserves " .. route .. " successor after " .. outcome, function()
				with_fixture(function(facade, adapter, state)
					local successor_visible
					facade.set_on_show_callback(function()
						facade.set_on_show_callback(nil)
						if route == "facade" then
							facade.show("successor", false, true)
						else
							adapter.show({ draw_calls = { { type = "text", text = "successor" } } })
						end
						successor_visible = state.visible
						if outcome == "throw" then error("superseded callback failure", 0) end
						if outcome == "nil" then return nil end
						return outcome == "true"
					end)
					adapter.show({ draw_calls = { { type = "text", text = "predecessor" } } })
					helpers.assert_eq(successor_visible, true, "successor must first become visible")
					helpers.assert_eq(state.paints, 2, "both real facade renders must execute")
					helpers.assert_eq(state.visible, true, "refused predecessor must not hide its successor")
				end)
			end)
		end
	end

	helpers.it("(tooltip-adapter-refusal-owner) preserves a successor opened by the error diagnostic", function()
		with_fixture(function(facade, adapter, state)
			helpers.assert_eq(facade.show("old", false, true), true)
			local old_hidden, committed
			state.on_error = function()
				state.on_error = nil
				old_hidden = not state.visible
				committed = facade.show("successor", false, true)
			end
			adapter.show({ draw_calls = {} })
			helpers.assert_eq(old_hidden, true, "exception cleanup must precede its diagnostic")
			helpers.assert_eq(committed, true)
			helpers.assert_eq(state.visible, true, "diagnostic successor must remain visible")
		end)
	end)

	for _, failure in ipairs({ "invalid payload", "render exception", "render refusal" }) do
		helpers.it("(tooltip-adapter-refusal-owner) still cleans up " .. failure .. " without a successor", function()
			with_fixture(function(facade, adapter, state)
				helpers.assert_eq(facade.show("old", false, true), true)
				local payload = { draw_calls = {} }
				if failure ~= "invalid payload" then
					state.on_paint = function()
						state.visible = true
						if failure == "render exception" then error("partial paint failure", 0) end
						state.paint_result = false
					end
					payload.draw_calls[1] = { type = "text", text = "partial" }
				end
				adapter.show(payload)
				helpers.assert_eq(state.visible, false, "failed pixels must still be removed")
				helpers.assert_eq(state.errors, 1, "the exception must remain observable")
			end)
		end)
	end

	for _, boundary in ipairs({ "render exception", "exception cleanup" }) do
		helpers.it("(tooltip-adapter-refusal-owner) preserves a successor inside " .. boundary, function()
			with_fixture(function(facade, adapter, state)
				local committed
				local payload = { draw_calls = {} }
				if boundary == "render exception" then
					state.on_paint = function()
						state.on_paint = nil
						committed = facade.show("successor", false, true)
						error("older renderer failed after successor", 0)
					end
					payload.draw_calls[1] = { type = "text", text = "predecessor" }
				else
					helpers.assert_eq(facade.show("old", false, true), true)
					state.on_hide = function()
						state.on_hide = nil
						committed = facade.show("successor", false, true)
					end
				end
				adapter.show(payload)
				helpers.assert_eq(committed, true, "the nested successor must commit")
				helpers.assert_eq(state.visible, true, "old exception must preserve the newer surface")
			end)
		end)
	end

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
