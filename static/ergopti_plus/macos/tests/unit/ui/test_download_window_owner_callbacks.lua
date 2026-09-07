--- tests/unit/ui/test_download_window_owner_callbacks.lua

--- ==============================================================================
--- MODULE: Download Window Native Callback Ownership
--- DESCRIPTION:
--- Delivers callbacks after native replacement and during reentrant controllers.
--- A retired native owner must never mutate its successor's operation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a scenario with retained native callbacks and restores module overrides.
--- @param scenario function Callback receiving the window and native records.
local function with_window(scenario)
	local keys = { "ui.download_window", "ui.ui_builder", "infra.deferred_work", "infra.logger" }
	local saved, prior_hs = {}, _G.hs
	for _, key in ipairs(keys) do saved[key] = package.loaded[key] end
	local records = { windows = {}, timers = {}, bridges = {} }
	package.loaded["infra.logger"] = nil
	package.loaded["infra.deferred_work"] = {
		after = function(_, callback)
			records.timers[#records.timers + 1] = callback
			return true
		end,
	}
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 460, height = 380 } end,
		show_webview = function(opts)
			local native = { opts = opts, codes = {} }
			function native:delete()
				if records.delete_throws then error("injected native delete failure") end
			end
			function native:evaluateJavaScript(code) self.codes[#self.codes + 1] = code end
			records.windows[#records.windows + 1] = native
			if opts.on_webview_created then opts.on_webview_created(native) end
			if records.close_during_create then opts.on_close() end
			return native
		end,
	}
	local ok, err = xpcall(function()
		local window = helpers.load_with_stubs("ui.download_window", {
			webview = { usercontent = { new = function()
				return { setCallback = function(_, callback)
					records.bridges[#records.bridges + 1] = callback
				end }
			end } },
		})
		scenario(window, records)
	end, debug.traceback)
	for _, key in ipairs(keys) do package.loaded[key] = saved[key] end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("download window exact native owners", function()
	helpers.it("ignores a retired close callback without cancelling the successor", function()
		with_window(function(window, records)
			local cancelled = 0
			helpers.assert_true(window.show({ kind = "mlx_install" }))
			local retired = records.windows[1]
			helpers.assert_true(window.hide())
			helpers.assert_true(window.show({ kind = "ollama_install", on_cancel = function()
				cancelled = cancelled + 1
			end }))
			retired.opts.on_close()
			helpers.assert_eq(cancelled, 0)
			helpers.assert_true(window.is_active())
		end)
	end)

	for _, delivery in ipairs({ "navigation", "fallback" }) do
		helpers.it("ignores retired " .. delivery .. " readiness", function()
			with_window(function(window, records)
				helpers.assert_true(window.show({ kind = "mlx_install" }))
				local retired = records.windows[1]
				local fallback = records.timers[1]
				helpers.assert_true(window.hide())
				helpers.assert_true(window.show({ kind = "ollama_install" }))
				local current = records.windows[2]
				if delivery == "navigation" then retired.opts.on_navigation("didFinishNavigation")
				else fallback() end
				helpers.assert_eq(#current.codes, 0, "successor page is still loading")
				current.opts.on_navigation("didFinishNavigation")
				helpers.assert_true(#current.codes > 0, "current owner must deliver its payload")
			end)
		end)
	end

	for _, action in ipairs({ "cancel", "retry" }) do
		helpers.it("snapshots the " .. action .. " controller pair before reentry", function()
			with_window(function(window, records)
				local old_calls, new_calls = 0, 0
				local successor = { kind = "ollama_install" }
				local first, second = "on_abort", "on_cancel"
				if action == "retry" then first, second = "on_retry_start", "on_retry" end
				successor[second] = function() new_calls = new_calls + 1 end
				local opts = { kind = "mlx_install" }
				opts[first] = function() helpers.assert_true(window.show(successor)) end
				opts[second] = function() old_calls = old_calls + 1 end
				helpers.assert_true(window.show(opts))
				records.bridges[#records.bridges]({ body = action })
				helpers.assert_eq(old_calls, 1)
				helpers.assert_eq(new_calls, 0)
			end)
		end)
	end

	helpers.it("does not publish a candidate closed during construction", function()
		with_window(function(window, records)
			records.close_during_create = true
			helpers.assert_eq(window.show({ kind = "mlx_install" }), false)
			helpers.assert_eq(window.is_active(), false)
		end)
	end)

	helpers.it("ignores bridge deliveries from deleted and cleanup-only native owners", function()
		with_window(function(window, records)
			local calls = 0
			local opts = { kind = "mlx_install", on_cancel = function() calls = calls + 1 end }
			helpers.assert_true(window.show(opts))
			local retired = records.bridges[1]
			records.delete_throws = true
			helpers.assert_eq(window.hide(), false)
			helpers.assert_eq(records.windows[1].opts.is_current(), false,
				"builder focus and i18n retries must reject a cleanup-only owner")
			retired({ body = "cancel" })
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(window.show(opts), false)
			records.delete_throws = false
			helpers.assert_true(window.hide())
			helpers.assert_true(window.show(opts))
			retired({ body = "cancel" })
			helpers.assert_eq(calls, 0)
			records.bridges[2]({ body = "cancel" })
			helpers.assert_eq(calls, 1)
		end)
	end)

	helpers.it("delivers native close once even when the abort callback opens a successor", function()
		with_window(function(window, records)
			local old_calls, new_calls = 0, 0
			helpers.assert_true(window.show({ kind = "mlx_install", on_abort = function()
				helpers.assert_true(window.show({ kind = "ollama_install", on_cancel = function()
					new_calls = new_calls + 1
				end }))
			end, on_cancel = function() old_calls = old_calls + 1 end }))
			local retired = records.windows[1]
			retired.opts.on_close()
			retired.opts.on_close()
			helpers.assert_true(window.is_active())
			helpers.assert_eq(old_calls, 1)
			helpers.assert_eq(new_calls, 0)
		end)
	end)
end)
