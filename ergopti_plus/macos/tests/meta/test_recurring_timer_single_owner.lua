--- tests/meta/test_recurring_timer_single_owner.lua

--- ==============================================================================
--- MODULE: Recurring Native Timer Ownership Guard
--- DESCRIPTION:
--- Walks every production Lua source and rejects direct recurring native timer
--- acquisition outside the TimerScheduler adapter and an explicit, reviewable
--- migration-debt allowlist.
---
--- FEATURES & RATIONALE:
--- 1. Whole-class inventory: every executable `doEvery` and `timer.new(`
---    acquisition is found after comments are removed. `timer.new` is itself a
---    repeating primitive even when a caller intends to stop it after one fire.
--- 2. Explicit exceptions: infra.logger references doEvery only to wrap native
---    callbacks; infra.launcher_guard runs before that wrapper exists and owns a
---    raw transactional timer.new/start sequence. Every remaining exception is
---    named as migration debt with a non-empty justification.
--- 3. Source floor: the production walk must remain broad enough that an empty
---    or accidentally narrowed inventory cannot report a false green.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()
local PRODUCTION_SOURCE_FLOOR = 200

-- Existing explicit native timer owners remain migration debt. Pinning the full
-- set keeps the guard useful today: a new sibling or a reintroduced ui_restore
-- poller fails instead of hiding behind one already-approved file.
local RAW_TIMER_NEW_OWNERS = {
	["adapters/timer_scheduler.lua"] = "canonical native timer owner",
	["infra/launcher_guard.lua"] = "runs before TimerScheduler and publishes before start",
	["modules/keylogger/init.lua"] = "legacy keylogger runtime transaction pending migration",
	["modules/keylogger/log_manager.lua"] = "legacy ingest owner pending migration",
	["modules/keymap/init.lua"] = "legacy tap-watchdog owner pending migration",
	["platform/remap/watchers.lua"] = "legacy layout-poll owner pending migration",
}

--- Lists production Lua files recursively without relying on LuaFileSystem.
--- @param directory string Absolute directory path.
--- @return table files Absolute source paths.
local function list_lua_files(directory)
	local files = {}
	local command
	if package.config:sub(1, 1) == "\\" then
		command = string.format('cmd /c dir /b /s /a-d "%s"', directory:gsub("/", "\\"))
	else
		command = string.format("find '%s' -type f", directory)
	end
	local pipe = io.popen(command)
	if not pipe then return files end
	for raw_line in pipe:lines() do
		local path = raw_line:gsub("\\", "/")
		if path:match("%.lua$") and not path:find("/tests/", 1, true) then
			files[#files + 1] = path
		end
	end
	pipe:close()
	return files
end

--- Reads one source file exactly.
--- @param path string Absolute path.
--- @return string|nil source File contents.
local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local source = handle:read("*a")
	handle:close()
	return source
end

--- Projects Lua source to executable tokens, removing comments and literals.
--- The hs.timer module literal is retained as a sentinel so aliases created by
--- require("hs.timer") remain discoverable without treating log messages as code.
--- @param source string Lua source text.
--- @return string code Executable-token projection.
local function project_executable(source)
	local output = {}
	local length = #source
	local index = 1
	local function append(value) output[#output + 1] = value end
	local function long_bracket(at)
		local equals = source:sub(at):match("^%[(=*)%[")
		if not equals then return nil end
		return equals, at + #equals + 2
	end
	while index <= length do
		local char = source:sub(index, index)
		local next_char = source:sub(index + 1, index + 1)
		if char == "-" and next_char == "-" then
			local equals, content_at = long_bracket(index + 2)
			if equals then
				local close_at = source:find("]" .. equals .. "]", content_at, true)
				index = close_at and (close_at + #equals + 2) or (length + 1)
				append(" ")
			else
				local newline_at = source:find("\n", index + 2, true)
				index = newline_at or (length + 1)
				if newline_at then append("\n"); index = index + 1 end
			end
		elseif char == "'" or char == '"' then
			local quote = char
			local cursor = index + 1
			local literal = {}
			while cursor <= length do
				local current = source:sub(cursor, cursor)
				if current == "\\" then
					literal[#literal + 1] = current
					cursor = cursor + 1
					if cursor <= length then literal[#literal + 1] = source:sub(cursor, cursor) end
				elseif current == quote then
					break
				else
					literal[#literal + 1] = current
				end
				cursor = cursor + 1
			end
			append(table.concat(literal) == "hs.timer" and " __HS_TIMER_MODULE__ " or " ")
			index = math.min(cursor + 1, length + 1)
		elseif char == "[" then
			local equals, content_at = long_bracket(index)
			if equals then
				local close = "]" .. equals .. "]"
				local close_at = source:find(close, content_at, true)
				local literal = close_at and source:sub(content_at, close_at - 1) or ""
				append(literal == "hs.timer" and " __HS_TIMER_MODULE__ " or " ")
				index = close_at and (close_at + #close) or (length + 1)
			else
				append(char)
				index = index + 1
			end
		else
			append(char)
			index = index + 1
		end
	end
	return table.concat(output)
end

--- Returns true when executable source acquires a raw repeating timer.
--- Covers direct hs.timer calls and local aliases sourced from hs.timer.
--- @param source string Lua source text.
--- @return boolean uses_raw
local function uses_raw_timer_new(source)
	local code = project_executable(source)
	if code:find("hs%s*%.%s*timer%s*%.%s*new%s*%(")
		or code:find("pcall%s*%(%s*hs%s*%.%s*timer%s*%.%s*new%s*,")
		or code:find("require%s*%(%s*__HS_TIMER_MODULE__%s*%)%s*%.%s*new%s*%(") then
		return true
	end

	local aliases = {}
	for line in code:gmatch("[^\n]+") do
		local alias, expression = line:match("local%s+([%a_][%w_]*)%s*=%s*(.+)")
		if alias and (expression:find("__HS_TIMER_MODULE__", 1, true)
			or expression:find("[%a_][%w_]*%s*%.%s*timer")) then
			aliases[alias] = true
		end
	end
	for alias in pairs(aliases) do
		local escaped = alias:gsub("([^%w])", "%%%1")
		if code:find("%f[%w_]" .. escaped .. "%f[^%w_]%s*%.%s*new%s*%(")
			or code:find("pcall%s*%(%s*" .. escaped .. "%s*%.%s*new%s*,") then
			return true
		end
	end
	return false
end

helpers.describe("recurring native timer single owner", function()
	helpers.it("routes production recurring timers through transactional owners", function()
		local files = list_lua_files(DRIVER_ROOT)
		helpers.assert_true(#files > PRODUCTION_SOURCE_FLOOR,
			"the production source walk must not be vacuous or accidentally narrowed")
		local owners = {}
		for _, path in ipairs(files) do
			local source = read_file(path)
			if source and project_executable(source):find("doEvery", 1, true) then
				owners[#owners + 1] = path:gsub("\\", "/")
			end
		end

		helpers.assert_eq(#owners, 1,
			"only the runtime callback wrapper may reference doEvery directly; got "
				.. table.concat(owners, ", "))
		helpers.assert_true(owners[1]:match("/infra/logger%.lua$") ~= nil,
			"the sole direct doEvery owner must be infra.logger, got " .. tostring(owners[1]))
	end)

	helpers.it("inventories every explicit repeating timer.new acquisition", function()
		local files = list_lua_files(DRIVER_ROOT)
		helpers.assert_true(#files > PRODUCTION_SOURCE_FLOOR,
			"the timer.new production walk must not be vacuous")
		local found = {}
		for _, path in ipairs(files) do
			local source = read_file(path)
			if source and uses_raw_timer_new(source) then
				local normalized = path:gsub("\\", "/")
				local relative = normalized:match("/macos/(.+)$")
				helpers.assert_true(relative ~= nil,
					"raw timer owner must resolve relative to the macOS driver: " .. normalized)
				found[relative] = true
			end
		end

		local extras = {}
		for relative in pairs(found) do
			if not RAW_TIMER_NEW_OWNERS[relative] then extras[#extras + 1] = relative end
		end
		local missing = {}
		for relative, justification in pairs(RAW_TIMER_NEW_OWNERS) do
			helpers.assert_true(type(justification) == "string" and justification ~= "",
				"every raw timer exception must carry a reviewable justification: " .. relative)
			if not found[relative] then missing[#missing + 1] = relative end
		end
		table.sort(extras)
		table.sort(missing)
		helpers.assert_eq(#extras, 0,
			"new raw repeating timer owner escaped TimerScheduler: " .. table.concat(extras, ", "))
		helpers.assert_eq(#missing, 0,
			"raw-timer debt inventory changed; migrate/delete the stale allowlist entry: "
				.. table.concat(missing, ", "))
	end)

	helpers.it("detects aliases without accepting comments or log strings as owners", function()
		helpers.assert_true(uses_raw_timer_new([[
			local timer = require("hs.timer")
			local candidate = timer.new(1, callback)
		]]), "an hs.timer module alias must remain in the whole-class inventory")
		helpers.assert_true(uses_raw_timer_new([[
			local timer_ref = hs_ref.timer
			local ok, candidate = pcall(timer_ref.new, 1, callback)
		]]), "an indirect hs timer alias passed to pcall must remain inventoried")
		helpers.assert_true(not uses_raw_timer_new([[
			-- hs.timer.new(1, callback)
			Logger.error(LOG, "hs.timer.new returned nil")
		]]), "comments and diagnostics must not manufacture a raw owner")
	end)

	helpers.it("keeps the early launcher exception on explicit publish-start-rollback", function()
		local source = helpers.read_driver_source("local function arm_backstop_timer")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"launcher guard source must be readable")
		local code = project_executable(source)
		helpers.assert_true(code:find("hs.timer.new", 1, true) ~= nil,
			"the pre-logger launcher guard must use an explicit unstarted timer candidate")
		helpers.assert_true(code:find("hs.timer.doEvery", 1, true) == nil,
			"the early guard must not hide acquisition inside the convenience constructor")
		local publish_at = code:find("_backstop_timer = candidate", 1, true)
		local start_at = code:find("candidate:start()", 1, true)
		helpers.assert_true(publish_at ~= nil and start_at ~= nil and publish_at < start_at,
			"the exact early-boot candidate must be published before native start")
		helpers.assert_true(code:find("release_resources()", start_at, true) ~= nil,
			"a start refusal or throw must enter exact retained cleanup")
	end)
end)
