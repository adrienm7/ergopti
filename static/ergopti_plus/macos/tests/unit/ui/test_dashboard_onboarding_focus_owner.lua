--- tests/unit/ui/test_dashboard_onboarding_focus_owner.lua

--- ==============================================================================
--- MODULE: Dashboard and Onboarding Deferred Focus Ownership
--- DESCRIPTION:
--- Exercises real open and close paths while a native focus retry remains pending.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_window(module_name, callback)
	local previous_hs = rawget(_G, "hs")
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({
			module_name, "tests.stubs.hs", "hs", "hs.fs", "hs.json", "ui.ui_builder",
			"infra.logger", "infra.paths", "infra.i18n", "infra.deferred_work",
			"infra.dialog_util", "adapters.timer_scheduler", "modules.keylogger.log_manager",
		}, function()
			local native = require("tests.stubs.hs")
			native.__reset()
			_G.hs = native
			package.loaded["hs"] = native
			package.loaded["hs.fs"] = native.fs
			package.loaded["hs.json"] = native.json
			native.fs.dir = function() return function() end, {} end
			native.webview.windowMasks = { titled = 1, closable = 2 }
			local state = { deleted = 0 }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.paths"] = { shared = function(relative) return "/virtual/" .. relative end }
			package.loaded["infra.i18n"] = {
				get = function(key) return key end,
				set_locale_no_reload = function() return true end,
				persist_locale = function() return false end,
			}
			package.loaded["infra.dialog_util"] = { block_alert = function() return true end }
			package.loaded["infra.deferred_work"] = { after = function() return true end }
			package.loaded["modules.keylogger.log_manager"] = { on_ingest_done = function() return true end }
			package.loaded["adapters.timer_scheduler"] = {
				after = function() return { timer = {} }, true end,
				cancel = function(handle) handle.timer = nil; return true end,
			}
			native.webview.usercontent.new = function()
				return { setCallback = function(self, receiver) state.receiver = receiver; return self end }
			end
			package.loaded["ui.ui_builder"] = {
				get_app_geometry = function() return { width = 640, height = 480 } end,
				get_centered_frame = function() return {} end,
				show_webview = function(options)
					local view = { options = options }
					function view:show() return self end
					function view:bringToFront() return self end
					function view:hswindow() return nil end
					function view:delete()
						state.deleted = state.deleted + 1
						if state.refused then error("native deletion refused") end
					end
					state.view = view
					if state.close_during_create then options.on_close() end
					return view
				end,
			}
			callback(require(module_name), state)
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end

helpers.describe("dashboard and onboarding focus ownership", function()
	for _, refused in ipairs({ false, true }) do
		helpers.it("(webview-focus-owner) dashboard retirement revokes focus, delete refused=" .. tostring(refused), function()
			with_window("ui.metrics_apps", function(dashboard, state)
				helpers.assert_true(dashboard.show())
				require("tests.support.webview_focus_fixture").check(state.view,
					function() return dashboard.show() end,
					function() state.refused = refused; helpers.assert_eq(dashboard.close(), not refused) end,
					state.view.options)
			end)
		end)
		helpers.it("(webview-focus-owner) onboarding retirement revokes focus, delete refused=" .. tostring(refused), function()
			with_window("ui.onboarding", function(onboarding, state)
				helpers.assert_true(onboarding.run("/virtual/config.toml"))
				require("tests.support.webview_focus_fixture").check(state.view,
					function() return onboarding.run("/virtual/config.toml") end,
					function()
						if refused then
							state.refused = true
							state.receiver({ body = { action = "finish", answers = { locale = "en" } } })
							helpers.assert_eq(state.deleted, 1)
						else
							state.view.options.on_close()
						end
					end, state.view.options)
			end)
		end)
	end
	helpers.it("(webview-focus-owner) onboarding constructor close revokes factory focus", function()
		with_window("ui.onboarding", function(onboarding, state)
			state.close_during_create = true
			helpers.assert_eq(onboarding.run("/virtual/config.toml"), false)
			helpers.assert_eq(state.view.options.is_current(), false)
		end)
	end)
end)
