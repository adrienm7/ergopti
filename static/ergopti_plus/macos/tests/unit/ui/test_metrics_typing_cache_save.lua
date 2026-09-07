--- tests/unit/ui/test_metrics_typing_cache_save.lua

--- ==============================================================================
--- MODULE: Typing Metrics Cache Save Outcomes
--- DESCRIPTION:
--- Optional cache persistence must report failures without blocking live delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_dashboard = require("tests.support.metrics_typing_fixture")

local function with_save(mode, callback)
	local previous_open, previous_hs = io.open, _G.hs
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({ "adapters.file_system", "modules.keylogger.sqlite_reader",
			"adapters.timer_scheduler", "infra.logger", "hs.fs", "hs.json", "ui.ui_builder",
			"modules.keylogger.log_manager", "ui.metrics_typing", "ui.metrics_typing.init" }, function()
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
			local state = { mode = mode, opens = 0, writes = 0, closes = 0, codes = {} }
			window.webview.evaluateJavaScript = function(self, code)
				window.evaluated = window.evaluated + 1
				state.codes[#state.codes + 1] = code
				return self
			end
			package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function() return nil end
			package.loaded["infra.logger"].warn = function(_, message, ...)
				warnings[#warnings + 1] = string.format(message, ...)
			end
			package.loaded["hs.json"].encode = function(value)
				if type(value.manifest) == "string" then
					if state.mode == "encode_throw" then error("PRIVATE_PAYLOAD") end
					if state.mode == "encode_nil" then return nil end
					if state.mode == "encode_number" then return 42 end
				end
				return "{}"
			end
			io.open = function(_, access)
				if access == "r" then return nil, "missing", 2 end
				helpers.assert_eq(access, "w")
				state.opens = state.opens + 1
				if state.mode == "open_nil" then return nil, "PRIVATE_PATH", 13 end
				if state.mode == "open_throw" then error("PRIVATE_PATH") end
				return {
					write = function(self, content)
						state.writes = state.writes + 1
						helpers.assert_eq(content, "{}")
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
	io.open, _G.hs = previous_open, previous_hs
	if not ok then error(err, 0) end
end

helpers.describe("typing metrics cache save", function()
	for _, mode in ipairs({ "success", "encode_throw", "encode_nil", "encode_number", "open_nil", "open_throw",
		"write_nil", "write_throw", "close_nil", "close_throw", "both_nil" }) do
		helpers.it("(typing-cache-save) keeps live readiness after " .. mode, function()
			with_save(mode, function(_, state, window, warnings, refresh)
				refresh()
				helpers.assert_eq(window.evaluated, 1, "live readiness must still be submitted")
				helpers.assert_eq(state.codes[1], "typeof window.publishTypingMetricsData")
				helpers.assert_eq(#warnings, mode == "success" and 0 or 1)
				local encoded = mode:sub(1, 7) ~= "encode_"
				local acquired = encoded and mode ~= "open_nil" and mode ~= "open_throw"
				helpers.assert_eq(state.opens, encoded and 1 or 0)
				helpers.assert_eq(state.writes, acquired and 1 or 0)
				helpers.assert_eq(state.closes, acquired and 1 or 0, "write failure still requires exact cleanup")
				if #warnings > 0 then helpers.assert_nil(warnings[1]:find("PRIVATE_", 1, true)) end
			end)
		end)
	end
	helpers.it("(typing-cache-save) rearms diagnostics after a fully successful save", function()
		with_save("open_nil", function(dashboard, state, window, warnings, refresh)
			for index, mode in ipairs({ "open_nil", "open_nil", "success", "open_nil" }) do
				state.mode = mode
				refresh()
				helpers.assert_eq(window.evaluated, index)
				helpers.assert_eq(#warnings, index == 4 and 2 or 1)
				helpers.assert_true(dashboard.close())
			end
		end)
	end)
end)
