--- tests/unit/ui/test_metrics_typing_cache_reads.lua

--- ==============================================================================
--- MODULE: Typing Metrics Optional Cache Reads
--- DESCRIPTION:
--- Failed or invalid snapshot reads retain cleanup, are never painted, and do
--- not block the paced projection that publishes live data.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_dashboard = require("tests.support.metrics_typing_fixture")
local Scope = require("tests.support.metrics_typing_scope")
local safe_read = require("tests.support.file_system_write_stub").read_with_status

local PAYLOAD = '{"manifest":{},"app_icons":{},"initial_data":null,"kc_layout":{}}'
local VALID = "ERGOPTI_TYPING_METRICS_SNAPSHOT 2 1700000000 " .. #PAYLOAD .. "\n" .. PAYLOAD

--- File content served for each read mode that reaches the payload.
local CONTENT = {
	success = VALID,
	legacy_format = '{"manifest":"{}","app_icons":"{}","initial_data":"null","kc_layout":"{}"}',
	truncated = "ERGOPTI_TYPING_METRICS_SNAPSHOT 2 1700000000 " .. (#PAYLOAD + 7) .. "\n" .. PAYLOAD,
	old_version = "ERGOPTI_TYPING_METRICS_SNAPSHOT 1 1700000000 " .. #PAYLOAD .. "\n" .. PAYLOAD,
}

helpers.describe("typing metrics cache reads", function()
	for _, mode in ipairs({ "absent", "dependency", "unreported_error", "open_refused", "open_throw", "read_refused",
		"read_throw", "close_refused", "close_throw", "legacy_format", "truncated", "old_version", "success" }) do
		helpers.it("(typing-cache-read) preserves live data after " .. mode, function()
			local previous_open, previous_remove, previous_rename = io.open, os.remove, os.rename
			local ok, err = xpcall(function()
				Scope.run(function()
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
					local pending, warnings, closes, fresh_reads, unlinks = {}, {}, 0, 0, 0
					local codes = {}
					local dashboard, state = load_dashboard({
						after = function(_, callback)
							local handle = { timer = {} }
							pending[#pending + 1] = function() handle.timer = nil; callback() end
							return handle, true
						end,
						every = function() return { timer = {} }, true end,
						cancel = function(handle) handle.timer = nil; return true end,
					})
					state.webview.evaluateJavaScript = function(self, code)
						state.evaluated = state.evaluated + 1
						codes[#codes + 1] = code
						return self
					end
					package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function()
						fresh_reads = fresh_reads + 1
						return nil
					end
					package.loaded["infra.logger"].warn = function(_, message, ...)
						warnings[#warnings + 1] = string.format(message, ...)
					end
					os.remove = function() unlinks = unlinks + 1; return true end
					os.rename = function() return true end
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
								return CONTENT[mode] or VALID
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
					helpers.assert_eq(#pending, before + 1, "the bootstrap queues exactly the paced projection")
					helpers.assert_eq(fresh_reads, 0, "no aggregation runs on the open path")
					local acquired = mode ~= "absent" and mode ~= "open_refused" and mode ~= "open_throw"
						and mode ~= "dependency" and mode ~= "unreported_error"
					helpers.assert_eq(closes, acquired and 1 or 0)
					local invalid = CONTENT[mode] ~= nil and mode ~= "success"
					helpers.assert_eq(unlinks, invalid and 1 or 0, "an invalid snapshot is deleted, never kept")
					helpers.assert_eq(#warnings, (mode == "absent" or mode == "success") and 0 or 1,
						table.concat(warnings, " | "))
					helpers.assert_eq(table.concat(warnings):find("PRIVATE_CACHE", 1, true), nil)
					helpers.assert_eq(codes[1], mode == "success" and "typeof window.publishTypingMetricsData"
						or "typeof window.setTypingMetricsFreshness",
						"only a valid snapshot is painted; anything else shows the loading notice")
					pending[#pending]()
					helpers.assert_eq(fresh_reads, 1)
					helpers.assert_eq(codes[#codes], "typeof window.publishTypingMetricsData",
						"live publication readiness must be queried")
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
			io.open, os.remove, os.rename = previous_open, previous_remove, previous_rename
			if not ok then error(err, 0) end
		end)
	end
end)
