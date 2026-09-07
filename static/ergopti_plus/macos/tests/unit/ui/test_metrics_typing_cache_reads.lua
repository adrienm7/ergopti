--- tests/unit/ui/test_metrics_typing_cache_reads.lua

--- ==============================================================================
--- MODULE: Typing Metrics Optional Cache Reads
--- DESCRIPTION:
--- Failed cache reads retain cleanup and do not block the actual live-data callback.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_dashboard = require("tests.support.metrics_typing_fixture")
local safe_read = require("tests.support.file_system_write_stub").read_with_status

helpers.describe("typing metrics cache reads", function()
	for _, mode in ipairs({ "absent", "dependency", "unreported_error", "open_refused", "open_throw", "read_refused", "read_throw",
		"close_refused", "close_throw", "decode_refused", "decode_throw", "success" }) do
		helpers.it("(typing-cache-read) preserves live data after " .. mode, function()
			local previous_open, previous_hs = io.open, _G.hs
			local ok, err = xpcall(function()
				helpers.with_fresh_modules({ "ui.metrics_typing.init", "adapters.file_system",
					"modules.keylogger.sqlite_reader", "modules.keylogger.log_manager", "infra.logger",
					"adapters.timer_scheduler", "ui.ui_builder", "hs.fs", "hs.json" }, function()
					package.loaded["adapters.file_system"] = {
						read_with_status = function(path, report)
							if mode == "dependency" then error("PRIVATE_CACHE_PATH") end
							if mode == "unreported_error" then return nil, "error", "PRIVATE_CACHE_PATH" end
							local content, status, detail = safe_read(path)
							if status == "error" then report("read") end
							return content, status, detail
						end,
					}
					package.loaded["modules.keylogger.sqlite_reader"] = {}
					local pending, warnings, closes, fresh_reads = {}, {}, 0, 0
					local dashboard, state = load_dashboard({
						after = function(_, callback)
							local handle = { timer = {} }
							pending[#pending + 1] = function() handle.timer = nil; callback() end
							return handle, true
						end,
						every = function() return { timer = {} }, true end,
						cancel = function(handle) handle.timer = nil; return true end,
					})
					package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function()
						fresh_reads = fresh_reads + 1
						return nil
					end
					package.loaded["infra.logger"].warn = function(_, message, ...)
						warnings[#warnings + 1] = string.format(message, ...)
					end
					package.loaded["hs.json"].decode = function()
						if mode == "decode_throw" then error("PRIVATE_CACHE_PAYLOAD") end
						if mode == "decode_refused" then return nil end
						return {}
					end
					io.open = function(_, access)
						if access == "w" then
							return { write = function(self) return self end, close = function() return true end }
						end
						helpers.assert_eq(access, "r")
						if mode == "absent" then return nil, "PRIVATE_CACHE_PATH", 2 end
						if mode == "open_refused" then return nil, "PRIVATE_CACHE_PATH", 13 end
						if mode == "open_throw" then error("PRIVATE_CACHE_PATH") end
						return {
							read = function()
								if mode == "read_throw" then error("PRIVATE_CACHE_PAYLOAD") end
								if mode == "read_refused" then return nil, "PRIVATE_CACHE_PATH", 5 end
								return "{}"
							end,
							close = function()
								closes = closes + 1
								if mode == "close_throw" then error("PRIVATE_CACHE_PATH") end
								if mode == "close_refused" then return nil, "PRIVATE_CACHE_PATH", 5 end
								return true
							end,
						}
					end
					helpers.assert_true(dashboard.show())
					local before = #pending
					pending[before]()
					helpers.assert_eq(#pending, before + 1)
					local acquired = mode ~= "absent" and mode ~= "open_refused" and mode ~= "open_throw"
						and mode ~= "dependency" and mode ~= "unreported_error"
					helpers.assert_eq(closes, acquired and 1 or 0)
					helpers.assert_eq(#warnings, (mode == "absent" or mode == "success") and 0 or 1)
					helpers.assert_eq(table.concat(warnings):find("PRIVATE_CACHE", 1, true), nil)
					pending[#pending]()
					helpers.assert_eq(fresh_reads, 1)
					helpers.assert_eq(state.evaluated, 1, "live publication readiness must be queried")
					if mode == "read_refused" then
						for index, next_mode in ipairs({ "read_refused", "success", "read_refused" }) do
							mode = next_mode
							helpers.assert_true(dashboard.close())
							helpers.assert_true(dashboard.show())
							pending[#pending]()
							helpers.assert_eq(#warnings, index == 3 and 2 or 1,
								"diagnostics stay bounded until a successful read rearms them")
						end
					end
				end)
			end, debug.traceback)
			io.open, _G.hs = previous_open, previous_hs
			if not ok then error(err, 0) end
		end)
	end
end)
