--- tests/support/metrics_delivery_fixture.lua

--- ==============================================================================
--- MODULE: Metrics Publication Native Fixture
--- DESCRIPTION:
--- Owns isolated dashboard publication observations without real disk writes.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

local function with_delivery(cached, callback)
	helpers.with_fresh_modules({ "adapters.file_system", "modules.keystats.sqlite_reader",
		"modules.keystats.context_tracker" }, function()
		package.loaded["adapters.file_system"] = {
			read_with_status = function(path)
				if path:find("ergopti_metrics_apps_cache.json", 1, true) then
					if cached then return "cache", "ok" end
					return nil, "absent"
				end
				return "{}", "ok"
			end,
		}
		package.loaded["modules.keystats.sqlite_reader"] = { read_manifest = function() return {}, true end }
		package.loaded["modules.keystats.context_tracker"] = { get_active_app_snapshot = function() end }
		with_window("ui.metrics_apps", function(dashboard, state)
			local pending, evaluations, errors, successes = {}, {}, {}, {}
			local original_open = io.open
			local ok, err = xpcall(function()
				io.open = function(_, mode)
					if mode == "w" then
						return { write = function(self) return self end, close = function() return true end }
					end
					if cached then return { read = function() return "cache" end, close = function() end } end
					return nil
				end
				package.loaded["hs.fs"].attributes = function() return true end
				package.loaded["hs.json"].encode = function() return "{}" end
				package.loaded["hs.json"].decode = function(value)
					return value == "cache" and { manifest = "{}" } or {}
				end
				local manager = package.loaded["modules.keystats.log_manager"]
				manager.get_sqlite_path = function() return "/virtual/db.sqlite" end
				manager.get_db_rev = function() return 1 end
				-- A refresh is cut into bounded slices, one zero-delay timer turn
				-- each (2f09c429): delivering a turn from the test also delivers
				-- the zero-delay turns it arms, so one call still stands for one
				-- refresh. Delayed retries and the fresh load stay queued.
				local delivering, slices = false, nil
				package.loaded["adapters.timer_scheduler"].after = function(delay, fn)
					local handle = { timer = {} }
					local entry = function() handle.timer = nil; fn() end
					if delivering and delay == 0 then
						slices[#slices + 1] = entry
						return handle, true
					end
					pending[#pending + 1] = function()
						if delivering then return entry() end
						delivering = true
						slices = {}
						local ok, detail = xpcall(function()
							entry()
							local index = 0
							while index < #slices do
								index = index + 1
								slices[index]()
							end
						end, debug.traceback)
						delivering, slices = false, nil
						if not ok then error(detail, 0) end
					end
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
