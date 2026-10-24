--- tests/unit/ui/download_window/test_download_window_controller_cleanup.lua

--- ==============================================================================
--- MODULE: Download Window Native Controller Cleanup
--- DESCRIPTION:
--- Owns callback registrations across window closure and native bind refusals.
--- The native controller retains its callback until explicit setCallback(nil).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Retains native callback registrations independently of the window owner.
--- @param scenario function Receives the real window and native observations.
local function with_window(scenario)
	local prior_hs = _G.hs
	local records = { bridges = {}, views = {}, deletes = 0, releases = 0 }
	local ok, err = xpcall(function()
		helpers.with_stub_scope({ "ui.download_window", "ui.download_window.javascript",
			"ui.download_window.pending_queue", "ui.ui_builder", "infra.logger", "infra.paths",
			"infra.i18n", "infra.deferred_work", "adapters.shell_runner",
			"adapters.timer_scheduler", "error_description", "number_policy" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.paths"] = { shared = function() return "/virtual/assets" end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.deferred_work"] = { after = function() return true end }
			package.loaded["adapters.shell_runner"] = {}
			_G.hs = {
				timer = { secondsSinceEpoch = function() return 1 end,
					absoluteTime = function() return 1000000000 end },
				screen = { mainScreen = function()
					return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
				end },
				webview = { usercontent = { new = function()
					local bridge = {}
					function bridge:setCallback(callback)
						if callback == nil then
							records.releases = records.releases + 1
							if records.release_throws then error("native callback release refused") end
						end
						self.callback = callback
						if callback ~= nil and records.bind_throws then error("native callback bind refused after registration") end
						return self
					end
					records.bridges[#records.bridges + 1] = bridge
					return bridge
				end } },
			}
			package.loaded["ui.ui_builder"] = {
				get_app_geometry = function() return { width = 460, height = 380 } end,
				show_webview = function(options)
					local view = { options = options, deleted = false }
					function view:evaluateJavaScript() return self end
					function view:delete()
						records.deletes = records.deletes + 1
						self.deleted = true
						options.on_close()
						return nil
					end
					records.views[#records.views + 1] = view
					helpers.assert_true(options.on_webview_created(view))
					return view
				end,
			}
			package.loaded["ui.download_window"] = nil
			scenario(require("ui.download_window"), records)
		end)
	end, debug.traceback)
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("download controller exact release ownership", function()
	helpers.it("releases the native callback when the producer hides its window (download-controller-cleanup)", function()
		with_window(function(window, records)
			helpers.assert_true(window.show({ kind = "mlx_model", model = "fixture" }))
			helpers.assert_type(records.bridges[1].callback, "function")
			helpers.assert_true(window.hide())
			helpers.assert_nil(records.bridges[1].callback, "deleting a WebView does not unregister its controller callback")
			helpers.assert_eq(records.releases, 1)
		end)
	end)

	helpers.it("releases native close before callbacks can open a successor (download-controller-cleanup)", function()
		with_window(function(window, records)
			local cancels = 0
			helpers.assert_true(window.show({ kind = "mlx_model", on_abort = function()
				helpers.assert_nil(records.bridges[1].callback, "close controllers must not retain predecessor callbacks")
				helpers.assert_true(window.show({ kind = "mlx_model", model = "successor" }))
			end, on_cancel = function() cancels = cancels + 1 end }))
			records.views[1].options.on_close()
			helpers.assert_nil(records.bridges[1].callback)
			helpers.assert_eq(#records.views, 2)
			helpers.assert_eq(cancels, 1)
			helpers.assert_true(window.is_active())
			helpers.assert_eq(records.deletes, 0, "a native close must not delete its closing window again")
		end)
	end)

	helpers.it("retains refused controller release without repeating native deletion (download-controller-cleanup)", function()
		with_window(function(window, records)
			helpers.assert_true(window.show({ kind = "mlx_model" }))
			records.release_throws = true
			helpers.assert_eq(window.hide(), false)
			helpers.assert_eq(window.is_active(), false)
			helpers.assert_eq(window.show({ kind = "mlx_model" }), false)
			helpers.assert_eq(#records.views, 1)
			helpers.assert_eq(records.deletes, 1)
			records.release_throws = false
			helpers.assert_true(window.hide())
			helpers.assert_nil(records.bridges[1].callback)
			helpers.assert_eq(records.deletes, 1)
			helpers.assert_true(window.show({ kind = "mlx_model" }))
			helpers.assert_eq(#records.views, 2)
		end)
	end)

	helpers.it("cleans a controller whose binding registers before throwing (download-controller-cleanup)", function()
		with_window(function(window, records)
			records.bind_throws = true
			helpers.assert_eq(window.show({ kind = "mlx_model" }), false)
			helpers.assert_nil(records.bridges[1].callback)
			helpers.assert_eq(records.releases, 1)
			helpers.assert_eq(#records.views, 0)
			records.bind_throws = false
			helpers.assert_true(window.show({ kind = "mlx_model" }))
			helpers.assert_eq(#records.views, 1)
		end)
	end)

	helpers.it("retains a refused native-close controller and delivers cancellation once (download-controller-cleanup)", function()
		with_window(function(window, records)
			local cancels = 0
			helpers.assert_true(window.show({ kind = "mlx_model", on_cancel = function() cancels = cancels + 1 end }))
			local closed = records.views[1].options.on_close
			records.release_throws = true
			closed()
			closed()
			helpers.assert_eq(cancels, 1)
			helpers.assert_eq(window.is_active(), false)
			helpers.assert_eq(window.show({ kind = "mlx_model" }), false)
			helpers.assert_eq(#records.views, 1)
			records.release_throws = false
			helpers.assert_true(window.hide())
			helpers.assert_nil(records.bridges[1].callback)
			helpers.assert_eq(records.deletes, 0)
			helpers.assert_true(window.show({ kind = "mlx_model" }))
			helpers.assert_eq(#records.views, 2)
		end)
	end)
end)
