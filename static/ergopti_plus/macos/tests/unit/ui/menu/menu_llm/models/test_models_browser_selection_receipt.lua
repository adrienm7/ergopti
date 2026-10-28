--- tests/unit/ui/menu/menu_llm/models/test_models_browser_selection_receipt.lua

--- ==============================================================================
--- MODULE: Model Browser Selection Receipt Composition
--- DESCRIPTION:
--- Drives the real model selector browser bridge and WebView factory over the
--- existing native reference fixture. Selection receipts are injected at the
--- selector page owner's action boundary (on_action), which runs the tray's
--- model switch; no backend or real native window is started.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.owned_window_close_fixture")

--- Opens the actual browser as the selector page owner does.
--- @param mode string First selection receipt: false, true or throw.
--- @param scenario function Receives browser, native observations and selection calls.
local function with_selection(mode, scenario)
	helpers.with_stub_scope({
		"ui.menu.menu_llm.backend_labels",
		"infra.manifest_menu", "menu.renderer", "logger.shim", "infra.paths",
		"adapters.own_window", "adapters.running_application", "error_description",
		"native_path", "number_policy",
	}, function()
		Fixture("ui.model_browser", function(browser, native)
			local controls = { attempts = {}, receipt = mode }
			local result = table.pack(xpcall(function()
				helpers.assert_true(browser.open({
					build_payload = function() return { backend = "ollama", active = "", models = {} } end,
					on_action = function(body)
						controls.attempts[#controls.attempts + 1] = body.name
						if controls.receipt == "throw" then error("MODEL_SELECTION_REFUSED") end
						return controls.receipt == "true"
					end,
				}))
				native.drain()
				helpers.assert_eq(#native.windows, 1, "the selector page opens one shared browser")
				scenario(browser, native, controls)
			end, debug.traceback))
			local closed = browser.close()
			native.drain()
			helpers.assert_true(closed, "the exact browser owner must settle during fixture cleanup")
			helpers.assert_eq(next(native.script_refs), nil, "cleanup releases every native script reference")
			helpers.assert_eq(next(native.retained), nil, "cleanup consumes every exact native window")
			if not result[1] then error(result[2], 0) end
		end)
	end)
end

--- Delivers the native-shaped message to the current browser operation.
--- @param native table Native reference observations.
--- @return function callback Exact retained native script callback.
local function selection_callback(native)
	local callback = native.script_refs[native.controllers[1]]
	helpers.assert_type(callback, "function")
	return callback
end

helpers.describe("model selector browser selection receipt", function()
	for _, receipt in ipairs({ "false", "throw" }) do
		helpers.it("keeps a " .. receipt .. " page selection open for a successful retry", function()
			with_selection(receipt, function(_, native, controls)
				local view, callback = native.windows[1], selection_callback(native)
				callback({ body = { action = "select_model", name = "retry-model", session = 1 } })
				helpers.assert_eq(#controls.attempts, 1)
				helpers.assert_eq(controls.attempts[1], "retry-model")
				helpers.assert_eq(view.deletes, 0, "a refused selection must not close the real browser")
				helpers.assert_eq(native.script_refs[native.controllers[1]], callback,
					"a refusal must preserve the exact bridge for retry")
				controls.receipt = "true"
				callback({ body = { action = "select_model", name = "retry-model", session = 1 } })
				helpers.assert_eq(#controls.attempts, 2)
				helpers.assert_eq(view.deletes, 1, "a committed retry closes the original browser once")
				native.drain()
				helpers.assert_true(view.disposed)
				callback({ body = { action = "select_model", name = "retired-model", session = 1 } })
				helpers.assert_eq(#controls.attempts, 2, "a retired script callback cannot select another model")
			end)
		end)
	end

	helpers.it("closes one native browser after the page selection commits", function()
		with_selection("true", function(_, native, controls)
			local view, callback = native.windows[1], selection_callback(native)
			callback({ body = { action = "select_model", name = "ready-model", session = 1 } })
			helpers.assert_eq(#controls.attempts, 1)
			helpers.assert_eq(controls.attempts[1], "ready-model")
			helpers.assert_eq(view.deletes, 1)
			native.drain()
			helpers.assert_true(view.disposed)
			helpers.assert_eq(next(native.script_refs), nil)
		end)
	end)
end)
