--- tests/unit/adapters/test_file_system_append_outcome.lua

--- ==============================================================================
--- MODULE: FileSystem Append Outcomes
--- DESCRIPTION:
--- Checks native write and close outcomes without touching real files.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("FileSystem append outcomes", function()
	for _, mode in ipairs({ "success", "open_nil", "open_throw", "write_nil", "write_throw",
		"close_nil", "close_throw", "write_and_close_nil" }) do
		helpers.it("(append-native-outcome) handles " .. mode, function()
			local previous_hs, previous_open = _G.hs, io.open
			local ok, err = xpcall(function()
				helpers.with_fresh_modules({ "adapters.file_system", "infra.logger" }, function()
					local errors, writes, closes, opened, content = {}, 0, 0, nil, nil
					local logger = helpers.make_logger_stub()
					logger.error = function(_, message, ...)
						errors[#errors + 1] = string.format(message, ...)
					end
					package.loaded["infra.logger"] = logger
					local adapter = helpers.load_with_stubs("adapters.file_system")
					local file = {}
					function file:write(value)
						writes, content = writes + 1, value
						if mode == "write_throw" then error("PRIVATE_WRITE_ERROR") end
						if mode == "write_nil" or mode == "write_and_close_nil" then
							return nil, "PRIVATE_WRITE_ERROR", 28
						end
						return self
					end
					function file:close()
						closes = closes + 1
						if mode == "close_throw" then error("PRIVATE_CLOSE_ERROR") end
						if mode == "close_nil" or mode == "write_and_close_nil" then
							return nil, "PRIVATE_CLOSE_ERROR", 28
						end
						return true
					end
					io.open = function(path, access)
						opened = { path, access }
						if mode == "open_throw" then error("synthetic open refusal") end
						if mode == "open_nil" then return nil, "synthetic open refusal", 13 end
						return file
					end
					local result = adapter.append("/virtual/output", "sentinel")
					io.open = previous_open
					helpers.assert_eq(result, mode == "success")
					helpers.assert_eq(opened[1], "/virtual/output")
					helpers.assert_eq(opened[2], "a")
					local acquired = mode ~= "open_nil" and mode ~= "open_throw"
					helpers.assert_eq(writes, acquired and 1 or 0)
					helpers.assert_eq(closes, acquired and 1 or 0,
						"every acquired handle must be closed even after a write exception")
					if acquired then helpers.assert_eq(content, "sentinel") end
					helpers.assert_eq(#errors > 0, mode ~= "success")
					if acquired then
						helpers.assert_eq(table.concat(errors):find("PRIVATE_", 1, true), nil)
					end
				end)
			end, debug.traceback)
			io.open, _G.hs = previous_open, previous_hs
			if not ok then error(err, 0) end
		end)
	end
end)
