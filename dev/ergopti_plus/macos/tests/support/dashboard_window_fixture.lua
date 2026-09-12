--- tests/support/dashboard_window_fixture.lua

--- ==============================================================================
--- MODULE: Dashboard Window Native Fixture
--- DESCRIPTION:
--- Isolates real dashboard controllers behind deterministic native boundaries.
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

return with_window
