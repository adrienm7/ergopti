--- tests/unit/infra/logger/test_logger_file_write_receipts.lua

--- ==============================================================================
--- MODULE: Logger synchronous file-sink write receipts
--- DESCRIPTION:
--- Until the native log worker owns delivery (early boot, and every headless
--- run), the Lua logger writes the unified file, the topical sub-files and the
--- errors-only mirror itself. It ignored every write/flush/close result: on a
--- full disk (ENOSPC) each line was lost, the refusing handle stayed cached and
--- nothing said so (logger-write-receipt-2026-10-21). A refused channel is now
--- retired, reported once on the console, and reopened on the next line, while
--- the other channels keep working.
--- ==============================================================================

local helpers = require("tests.helpers")

local Logger = helpers.load_with_stubs("infra.logger")

--- Captures sinks with io.open doubles whose results follow real Lua files:
--- write/flush return the file, or nil plus message and errno on refusal.
--- @param refuse function(path, operation) -> boolean
--- @param body function
--- @return table state { opens, closes, writes, console }
local function capture(refuse, body)
	local hs = _G.hs
	local saved = { attrs = hs.fs and hs.fs.attributes, open = io.open, print = _G.print,
		level = Logger.current_level }
	local state = { opens = {}, closes = {}, writes = {}, console = {} }
	Logger.set_level("DEBUG")
	Logger.reset_dedup()
	if hs.fs then hs.fs.attributes = function() return { modification = os.time() } end end
	_G.print = function(line) state.console[#state.console + 1] = tostring(line) end
	io.open = function(path)
		local key = tostring(path)
		state.opens[key] = (state.opens[key] or 0) + 1
		local file = {}
		function file:write(chunk)
			if refuse(key, "write") then return nil, "No space left on device", 28 end
			state.writes[key] = (state.writes[key] or "") .. tostring(chunk)
			return self
		end
		function file:flush()
			if refuse(key, "flush") then return nil, "No space left on device", 28 end
			return self
		end
		function file:close()
			state.closes[key] = (state.closes[key] or 0) + 1
			if refuse(key, "close") then return nil, "No space left on device", 28 end
			return true
		end
		return file
	end
	Logger.init_log_path("/virtual/logs/", 14)
	local ok, err = pcall(body, state)
	io.open, _G.print = saved.open, saved.print
	if hs.fs then hs.fs.attributes = saved.attrs end
	Logger.set_level(saved.level)
	Logger.reset_dedup()
	if not ok then error(err, 0) end
	return state
end

local function count_matching(lines, needle)
	local count = 0
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then count = count + 1 end
	end
	return count
end

local function unified_path(state)
	for path in pairs(state.opens) do
		if not path:find("error", 1, true) and not path:find("karabiner", 1, true) then return path end
	end
end


helpers.describe("Logger file sinks honour write receipts (logger-write-receipt-2026-10-21)", function()
	helpers.it("retires and reports a unified log that refuses writes, then reopens it", function()
		local full = true
		local state = capture(function(path, operation)
			return full and operation == "write" and not path:find("error", 1, true)
		end, function()
			Logger.info("zzz_unrouted", "first line on a full disk")
			Logger.info("zzz_unrouted", "second line on a full disk")
			full = false
			Logger.info("zzz_unrouted", "line after space returned")
		end)
		local path = unified_path(state)
		helpers.assert_true(path ~= nil, "the unified log must have been opened")
		helpers.assert_true((state.closes[path] or 0) >= 1, "a refusing handle must be retired")
		helpers.assert_true(state.opens[path] >= 2, "the next line must reopen the retired channel")
		helpers.assert_true((state.writes[path] or ""):find("line after space returned", 1, true) ~= nil,
			"the reopened channel must receive later lines")
		helpers.assert_true(count_matching(state.console, "log write refused") >= 1,
			"the loss must be reported on the console")
	end)

	helpers.it("keeps the errors-only mirror when the unified log refuses", function()
		local state = capture(function(path, operation)
			return operation == "flush" and not path:find("error", 1, true)
		end, function()
			Logger.error("zzz_unrouted", "an error on a full unified log")
		end)
		local mirrored = false
		for path, text in pairs(state.writes) do
			if path:find("error", 1, true) and text:find("an error on a full unified log", 1, true) then mirrored = true end
		end
		helpers.assert_true(mirrored, "one refusing channel must not silence the errors-only mirror")
		helpers.assert_true(count_matching(state.console, "log write refused") >= 1)
	end)

	helpers.it("reports an errors-only mirror whose close refuses", function()
		local state = capture(function(path, operation)
			return operation == "close" and path:find("error", 1, true) ~= nil
		end, function()
			Logger.error("zzz_unrouted", "an error whose mirror cannot close")
		end)
		helpers.assert_true(count_matching(state.console, "log write refused") >= 1,
			"a buffered mirror write lost at close must be reported")
	end)
end)
