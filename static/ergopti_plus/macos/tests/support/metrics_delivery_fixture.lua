--- tests/support/metrics_delivery_fixture.lua

--- ==============================================================================
--- MODULE: Metrics Publication Native Fixture
--- DESCRIPTION:
--- Owns isolated dashboard publication observations without real disk writes.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

local function with_delivery(cached, callback)
	helpers.with_fresh_modules({ "adapters.file_system", "modules.keylogger.sqlite_reader",
		"modules.keylogger.context_tracker" }, function()
		package.loaded["adapters.file_system"] = { read_with_status = function() return "{}", "ok" end }
		package.loaded["modules.keylogger.sqlite_reader"] = { read_manifest = function() return {} end }
		package.loaded["modules.keylogger.context_tracker"] = { get_active_app_snapshot = function() end }
		with_window("ui.metrics_apps", function(dashboard, state)
			local pending, evaluations, errors, successes = {}, {}, {}, {}
			local original_open = io.open
			local ok, err = xpcall(function()
				io.open = function(_, mode)
					if mode == "w" then return { write = function() end, close = function() end } end
					if cached then return { read = function() return "cache" end, close = function() end } end
					return nil
				end
				package.loaded["hs.fs"].attributes = function() return true end
				package.loaded["hs.json"].encode = function() return "{}" end
				package.loaded["hs.json"].decode = function(value)
					return value == "cache" and { manifest = "{}" } or {}
				end
				local manager = package.loaded["modules.keylogger.log_manager"]
				manager.get_sqlite_path = function() return "/virtual/db.sqlite" end
				manager.get_db_rev = function() return 1 end
				package.loaded["adapters.timer_scheduler"].after = function(_, fn)
					local handle = { timer = {} }
					pending[#pending + 1] = function() handle.timer = nil; fn() end
					return handle, true
				end
				helpers.assert_true(dashboard.show())
				state.view.evaluateJavaScript = function(self, code, done)
					evaluations[#evaluations + 1] = { code = code, done = done }
					if state.submit then return state.submit(self, code, done) end
					return self
				end
				local logger = package.loaded["infra.logger"]
				logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
				logger.success = function(_, message, ...) successes[#successes + 1] = string.format(message, ...) end
				pending[#pending]()
				if not cached then pending[#pending]() end
				helpers.assert_eq(#evaluations, 1)
				callback(dashboard, state, evaluations, errors, successes, pending)
			end, debug.traceback)
			io.open = original_open
			if not ok then error(err, 0) end
		end)
	end)
end

return with_delivery
