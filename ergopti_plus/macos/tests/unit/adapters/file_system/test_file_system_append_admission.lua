--- tests/unit/adapters/file_system/test_file_system_append_admission.lua

--- ==============================================================================
--- MODULE: FileSystem Append Destination Admission
--- DESCRIPTION:
--- append() opened its destination with io.open(path, "a") whatever it was. On
--- a FIFO without a reader that open blocks Hammerspoon's main thread; on a
--- FIFO with a reader the bytes go to another process; a directory or socket
--- fails late. The atomic writer already admits only regular files; append now
--- does the same before opening (append-regular-file-2026-10-21).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs append() over a native metadata double and an io.open spy.
--- @param mode string|nil hs.fs.attributes mode for the destination, nil when absent.
--- @return boolean result, integer opens, table errors
local function append_to(mode)
	local previous_hs, previous_open = _G.hs, io.open
	local result, opens, errors = nil, 0, {}
	local ok, failure = xpcall(function()
		helpers.with_fresh_modules({ "adapters.file_system", "infra.logger" }, function()
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
			package.loaded["infra.logger"] = logger
			local adapter = helpers.load_with_stubs("adapters.file_system")
			hs.fs.attributes = function(path)
				if path ~= "/virtual/destination" then return nil end
				if mode == nil then return nil, "No such file or directory" end
				return { mode = mode, size = 0 }
			end
			io.open = function()
				opens = opens + 1
				if mode == "named pipe" then error("open(2) of a FIFO without a reader blocks the main thread") end
				local file = {}
				function file:write() return self end
				function file:close() return true end
				return file
			end
			result = adapter.append("/virtual/destination", "line\n")
			io.open = previous_open
		end)
	end, debug.traceback)
	io.open, _G.hs = previous_open, previous_hs
	if not ok then error(failure, 0) end
	return result, opens, errors
end


helpers.describe("FileSystem append admits only regular files (append-regular-file-2026-10-21)", function()
	for _, mode in ipairs({ "named pipe", "directory", "socket", "char device" }) do
		helpers.it("refuses a " .. mode .. " destination without opening it", function()
			local result, opens, errors = append_to(mode)
			helpers.assert_eq(result, false)
			helpers.assert_eq(opens, 0, "a non-regular destination must never be opened")
			helpers.assert_eq(#errors, 1, "the refusal must be logged")
			helpers.assert_true(errors[1]:find("not a regular file", 1, true) ~= nil, errors[1])
		end)
	end

	helpers.it("appends to an existing regular file", function()
		local result, opens = append_to("file")
		helpers.assert_eq(result, true)
		helpers.assert_eq(opens, 1)
	end)

	helpers.it("creates an absent destination", function()
		local result, opens = append_to(nil)
		helpers.assert_eq(result, true)
		helpers.assert_eq(opens, 1)
	end)
end)
