--- tests/unit/ui/test_metrics_typing_cache_save.lua

--- ==============================================================================
--- MODULE: Typing Metrics Cache Save Outcomes
--- DESCRIPTION:
--- Optional snapshot persistence must report failures without blocking live
--- delivery, and must replace the previous snapshot only by an atomic rename.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_dashboard = require("tests.support.metrics_typing_fixture")
local Scope = require("tests.support.metrics_typing_scope")

local function with_save(mode, callback)
	local previous_open, previous_rename, previous_remove = io.open, os.rename, os.remove
	local ok, err = xpcall(function()
		Scope.run(function()
			package.loaded["adapters.file_system"] = { read_with_status = function() return nil, "absent" end }
			package.loaded["modules.keylogger.sqlite_reader"] = {}
			local pending, warnings = {}, {}
			local dashboard, window = load_dashboard({
				after = function(_, fn)
					local handle = { timer = {} }
					pending[#pending + 1] = function() handle.timer = nil; fn() end
					return handle, true
				end,
				every = function() return { timer = {} }, true end,
				cancel = function(handle) handle.timer = nil; return true end,
			})
			local state = { mode = mode, opens = 0, writes = 0, closes = 0, renames = 0, unlinks = 0, codes = {} }
			window.webview.evaluateJavaScript = function(self, code)
				window.evaluated = window.evaluated + 1
				state.codes[#state.codes + 1] = code
				return self
			end
			package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function() return nil end
			package.loaded["infra.logger"].warn = function(_, message, ...)
				warnings[#warnings + 1] = string.format(message, ...)
			end
			os.remove = function() state.unlinks = state.unlinks + 1; return true end
			os.rename = function(from, to)
				state.renames = state.renames + 1
				helpers.assert_eq(from, to .. ".partial", "the snapshot is replaced from its sibling partial file")
				if state.mode == "rename_throw" then error("PRIVATE_PATH") end
				if state.mode == "rename_nil" then return nil, "PRIVATE_PATH", 18 end
				return true
			end
			io.open = function(path, access)
				if access == "r" then return nil, "missing", 2 end
				helpers.assert_eq(access, "w")
				helpers.assert_true(path:sub(-8) == ".partial", "a save never writes the live snapshot in place")
				state.opens = state.opens + 1
				if state.mode == "open_nil" then return nil, "PRIVATE_PATH", 13 end
				if state.mode == "open_throw" then error("PRIVATE_PATH") end
				return {
					write = function(self, header, payload)
						state.writes = state.writes + 1
						helpers.assert_true(header:find("^ERGOPTI_TYPING_METRICS_SNAPSHOT 2 %d+ " .. #payload .. "\n$") ~= nil,
							"the header carries the format version, the time and the payload length")
						helpers.assert_eq(payload:sub(1, 12), '{"manifest":')
						if state.mode == "write_throw" then error("PRIVATE_PAYLOAD") end
						if state.mode == "write_nil" or state.mode == "both_nil" then return nil, "PRIVATE_PAYLOAD", 28 end
						return self
					end,
					close = function()
						state.closes = state.closes + 1
						if state.mode == "close_throw" then error("PRIVATE_PATH") end
						if state.mode == "close_nil" or state.mode == "both_nil" then return nil, "PRIVATE_PATH", 28 end
						return true
					end,
				}
			end
			local function refresh()
				helpers.assert_true(dashboard.show())
				pending[#pending]()
				pending[#pending]()
			end
			callback(dashboard, state, window, warnings, refresh)
		end)
	end, debug.traceback)
	io.open, os.rename, os.remove = previous_open, previous_rename, previous_remove
	if not ok then error(err, 0) end
end

helpers.describe("typing metrics cache save", function()
	for _, mode in ipairs({ "success", "open_nil", "open_throw", "write_nil", "write_throw", "close_nil",
		"close_throw", "both_nil", "rename_nil", "rename_throw" }) do
		helpers.it("(typing-cache-save) keeps live readiness after " .. mode, function()
			with_save(mode, function(_, state, window, warnings, refresh)
				refresh()
				-- The loading notice, then the fresh publication
				helpers.assert_eq(window.evaluated, 2, "live readiness must still be submitted")
				helpers.assert_eq(state.codes[2], "typeof window.publishTypingMetricsData")
				helpers.assert_eq(#warnings, mode == "success" and 0 or 1, table.concat(warnings, " | "))
				local acquired = mode ~= "open_nil" and mode ~= "open_throw"
				local written = acquired and mode ~= "write_nil" and mode ~= "write_throw" and mode ~= "close_nil"
					and mode ~= "close_throw" and mode ~= "both_nil"
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.writes, acquired and 1 or 0)
				helpers.assert_eq(state.closes, acquired and 1 or 0, "write failure still requires exact cleanup")
				helpers.assert_eq(state.renames, written and 1 or 0, "only a complete partial file is published")
				helpers.assert_eq(state.unlinks, (acquired and mode ~= "success") and 1 or 0,
					"a failed save removes its partial file")
				if #warnings > 0 then helpers.assert_nil(warnings[1]:find("PRIVATE_", 1, true)) end
			end)
		end)
	end
	helpers.it("(typing-cache-save) rearms diagnostics after a fully successful save", function()
		with_save("open_nil", function(dashboard, state, window, warnings, refresh)
			for index, mode in ipairs({ "open_nil", "open_nil", "success", "open_nil" }) do
				state.mode = mode
				refresh()
				helpers.assert_eq(window.evaluated, 2 * index)
				helpers.assert_eq(#warnings, index == 4 and 2 or 1)
				helpers.assert_true(dashboard.close())
			end
		end)
	end)
end)
