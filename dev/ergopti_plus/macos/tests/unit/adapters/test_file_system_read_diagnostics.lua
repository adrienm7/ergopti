--- tests/unit/adapters/test_file_system_read_diagnostics.lua

--- ==============================================================================
--- MODULE: FileSystem Read Diagnostic Ownership
--- DESCRIPTION:
--- Exercises the real read transaction with private-safe caller diagnostics.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("FileSystem read diagnostic ownership", function()
	for _, mode in ipairs({ "invalid_owner", "owner_throws" }) do
		helpers.it("(read-owned-diagnostic) rejects " .. mode .. " visibly", function()
			helpers.with_fresh_modules({ "adapters.file_system", "infra.logger" }, function()
				local messages, calls = {}, 0
				local logger = helpers.make_logger_stub()
				logger.error = function(_, message) messages[#messages + 1] = message end
				package.loaded["infra.logger"] = logger
				local adapter = require("adapters.file_system")
				local owner = function(category)
					calls = calls + 1
					helpers.assert_eq(category, "validation")
					error("PRIVATE_DIAGNOSTIC_DETAIL")
				end
				if mode == "invalid_owner" then owner = false end
				local content, status = adapter.read_with_status("", owner)
				helpers.assert_eq(content, nil)
				helpers.assert_eq(status, "error")
				helpers.assert_eq(calls, mode == "owner_throws" and 1 or 0)
				helpers.assert_eq(#messages, 1)
				helpers.assert_eq(messages[1]:find("PRIVATE_", 1, true), nil)
			end)
		end)
	end
	for _, mode in ipairs({ "success", "validation", "inspect", "open_nil", "open_throw",
		"read_nil", "read_throw", "close_nil", "close_throw", "path_changed", "identity_changed" }) do
		helpers.it("(read-owned-diagnostic) reports " .. mode .. " without exposing native details", function()
			local previous_open, previous_hs = io.open, _G.hs
			local ok, err = xpcall(function()
				helpers.with_fresh_modules({ "adapters.file_system", "infra.logger" }, function()
					local messages, categories = {}, {}
					local logger = helpers.make_logger_stub()
					logger.error = function(_, message, ...)
						messages[#messages + 1] = string.format(message, ...)
					end
					package.loaded["infra.logger"] = logger
					local changed, opens, reads, closes, shell_calls = false, 0, 0, 0, 0
					local adapter = helpers.load_with_stubs("adapters.file_system", {
						fs = { symlinkAttributes = function(path)
							if mode == "inspect" then return { mode = "directory" } end
							if changed and mode == "path_changed" and path == "/PRIVATE_FILE" then
								return { mode = "link", target = "/OTHER_PRIVATE_FILE" }
							end
							return { mode = "file", dev = 1, ino = changed and mode == "identity_changed" and 2 or 1, size = 7 }
						end },
						execute = function() shell_calls = shell_calls + 1; error("no shell authorized") end,
					})
					io.open = function(path, access)
						opens = opens + 1
						helpers.assert_eq(path, "/PRIVATE_FILE")
						helpers.assert_eq(access, "r")
						if mode == "open_nil" then return nil, "PRIVATE_NATIVE_DETAIL", 13 end
						if mode == "open_throw" then error("PRIVATE_NATIVE_DETAIL") end
						return {
							read = function(_, format)
								reads = reads + 1
								helpers.assert_eq(format, "*a")
								if mode == "read_nil" then return nil, "PRIVATE_NATIVE_DETAIL", 5 end
								if mode == "read_throw" then error("PRIVATE_NATIVE_DETAIL") end
								return "payload"
							end,
							close = function()
								closes, changed = closes + 1, true
								if mode == "close_nil" then return nil, "PRIVATE_NATIVE_DETAIL", 5 end
								if mode == "close_throw" then error("PRIVATE_NATIVE_DETAIL") end
								return true
							end,
						}
					end
					local content, status = adapter.read_with_status(mode == "validation" and "" or "/PRIVATE_FILE",
						function(category, ...)
							helpers.assert_eq(select("#", ...), 0, "only a fixed category may cross the diagnostic boundary")
							categories[#categories + 1] = category
						end)
					io.open = previous_open
					helpers.assert_eq(status, mode == "success" and "ok" or "error")
					helpers.assert_eq(content, mode == "success" and "payload" or nil)
					local acquired = mode ~= "validation" and mode ~= "inspect" and mode ~= "open_nil" and mode ~= "open_throw"
					helpers.assert_eq(opens, (mode == "validation" or mode == "inspect") and 0 or 1)
					helpers.assert_eq(reads, acquired and 1 or 0)
					helpers.assert_eq(closes, acquired and 1 or 0)
					helpers.assert_eq(shell_calls, 0)
					helpers.assert_eq(#messages, 0, "caller ownership must prevent the adapter's raw path diagnostics")
					helpers.assert_eq(#categories, mode == "success" and 0 or 1)
					if mode ~= "success" then helpers.assert_eq(categories[1], mode:gsub("_nil$", ""):gsub("_throw$", "")) end
				end)
			end, debug.traceback)
			io.open, _G.hs = previous_open, previous_hs
			if not ok then error(err, 0) end
		end)
	end
end)
