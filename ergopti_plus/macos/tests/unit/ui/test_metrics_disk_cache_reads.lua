--- tests/unit/ui/test_metrics_disk_cache_reads.lua

--- ==============================================================================
--- MODULE: Metrics Disk Cache Read Outcomes
--- DESCRIPTION:
--- Classified cache failures must not interrupt scheduling the initial live load.
--- Native read/close transactions are covered by the filesystem adapter tests.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

helpers.describe("metrics disk cache reads", function()
	helpers.it("(metrics-cache-read) rearms bounded diagnostics after a successful read", function()
		helpers.with_fresh_modules({ "adapters.file_system" }, function()
			local adapter = {}
			package.loaded["adapters.file_system"] = adapter
			with_window("ui.metrics_apps", function(dashboard)
				local mode, warnings, pending = "read", 0, {}
				adapter.read_with_status = function(_, report)
					if mode == "success" then return "{}", "ok" end
					report("read")
					return nil, "error"
				end
				package.loaded["hs.json"].decode = function() return {} end
				package.loaded["infra.logger"].warn = function() warnings = warnings + 1 end
				package.loaded["adapters.timer_scheduler"].after = function(_, callback)
					local handle = { timer = {} }
					pending[#pending + 1] = function() handle.timer = nil; callback() end
					return handle, true
				end
				for index, next_mode in ipairs({ "read", "read", "success", "read" }) do
					mode = next_mode
					helpers.assert_true(dashboard.show())
					pending[#pending]()
					helpers.assert_eq(warnings, index == 4 and 2 or 1)
					helpers.assert_true(dashboard.close())
				end
			end)
		end)
	end)
	for _, mode in ipairs({ "absent", "inspect", "open", "read", "close", "path_changed",
		"identity_changed", "dependency", "unreported_error", "decode_refused", "decode_throw", "success" }) do
		helpers.it("(metrics-cache-read) executes fresh data after " .. mode, function()
			helpers.with_fresh_modules({ "adapters.file_system", "modules.keylogger.sqlite_reader" }, function()
				local adapter = {}
				package.loaded["adapters.file_system"] = adapter
				package.loaded["modules.keylogger.sqlite_reader"] = {}
				with_window("ui.metrics_apps", function(dashboard)
					local pending, warnings, reads = {}, {}, 0
					package.loaded["infra.logger"].warn = function(_, message, ...)
						warnings[#warnings + 1] = string.format(message, ...)
					end
					package.loaded["adapters.timer_scheduler"].after = function(_, callback)
						local handle = { timer = {} }
						pending[#pending + 1] = function() handle.timer = nil; callback() end
						return handle, true
					end
					adapter.read_with_status = function(path, report)
						reads = reads + 1
						helpers.assert_true(path:find("ergopti_metrics_apps_cache.json", 1, true) ~= nil)
						helpers.assert_type(report, "function")
						if mode == "absent" then return nil, "absent" end
						if mode == "dependency" then error("PRIVATE_CACHE_PATH") end
						if mode == "unreported_error" then return nil, "error", "PRIVATE_CACHE_PATH" end
						if mode == "success" or mode == "decode_refused" or mode == "decode_throw" then
							return "PRIVATE_CACHE_PAYLOAD", "ok"
						end
						report(mode)
						return nil, "error", "PRIVATE_CACHE_PATH"
					end
					package.loaded["hs.json"].decode = function(content)
						helpers.assert_eq(content, "PRIVATE_CACHE_PAYLOAD")
						if mode == "decode_throw" then error("PRIVATE_CACHE_PAYLOAD") end
						if mode == "decode_refused" then return nil end
						return {}
					end
					helpers.assert_true(dashboard.show())
					local before = #pending
					pending[before]()
					helpers.assert_eq(reads, 1)
					helpers.assert_eq(#pending, before + 1, "live data must still be scheduled")
					helpers.assert_eq(#warnings, (mode == "absent" or mode == "success") and 0 or 1)
					if #warnings > 0 then
						helpers.assert_true(warnings[1]:find("cache", 1, true) ~= nil)
						helpers.assert_eq(warnings[1]:find("PRIVATE_CACHE", 1, true), nil)
					end
					local fresh_reads = 0
					package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function()
						fresh_reads = fresh_reads + 1
						return nil
					end
					pending[#pending]()
					helpers.assert_eq(fresh_reads, 1, "the fresh callback must reach the live data source")
				end)
			end)
		end)
	end
end)
