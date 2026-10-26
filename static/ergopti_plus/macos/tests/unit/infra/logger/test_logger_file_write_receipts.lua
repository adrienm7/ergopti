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
		local open_refused, open_detail = refuse(key, "open")
		if open_refused == "throw" then error(open_detail, 0) end
		if open_refused then return nil, open_detail or "Permission denied", 13 end
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

	for _, case in ipairs({
		{ channel = "unified" }, { channel = "topical" }, { channel = "errors-only" },
		{ channel = "unified", throws = true }, { channel = "topical", throws = true },
		{ channel = "errors-only", throws = true },
	}) do
		local channel = case.channel
		helpers.it("reports and retries refused " .. channel .. " opens" .. (case.throws and " with exception" or " with nil") .. " (logger-open-receipt)", function()
			local denied = true
			local function matches(path)
				if channel == "errors-only" then return path:find("error", 1, true) ~= nil end
				if channel == "topical" then return path:find("karabiner", 1, true) ~= nil end
				return not path:find("error", 1, true) and not path:find("karabiner", 1, true)
			end
			local state = capture(function(path, operation)
				if denied and operation == "open" and matches(path) then
					return case.throws and "throw" or true,
						"/Users/PrivateUser/private/logs: Permission denied password=secret12345"
				end
				return false
			end, function(state)
				Logger.warn("karabiner", "first denied open")
				Logger.warn("karabiner", "second denied open")
				helpers.assert_eq(count_matching(state.console, channel .. " log write refused"), 1,
					"one diagnostic must report the refusal episode")
				helpers.assert_eq(count_matching(state.console, "Permission denied"), 1,
					"the native refusal detail must survive")
				helpers.assert_eq(count_matching(state.console, "~/private/logs"), 1)
				helpers.assert_eq(count_matching(state.console, "/Users/PrivateUser"), 0)
				helpers.assert_eq(count_matching(state.console, "secret12345"), 0)
				denied = false
				Logger.warn("karabiner", "open recovered")
				local accepted = false
				for path, text in pairs(state.writes) do
					if matches(path) and text:find("open recovered", 1, true) then accepted = true end
				end
				helpers.assert_true(accepted, "the repaired channel must receive the next line")
			end)
			helpers.assert_eq(count_matching(state.console, channel .. " log write refused"), 1)
		end)
	end

end)
