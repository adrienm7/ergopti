--- tests/stubs/hs.lua

--- ==============================================================================
--- MODULE: Hammerspoon API Stub
--- DESCRIPTION:
--- Minimal in-memory shim of the Hammerspoon (`hs.*`) API surface used by the
--- driver source tree. Exposes only the entry points actually referenced by the
--- code under test, plus a few introspection helpers (`__reset`, `__set`) so
--- individual test files can override behavior on a case-by-case basis.
---
--- FEATURES & RATIONALE:
--- 1. Test Isolation: Each test loads a fresh copy via `helpers.load_with_stubs`,
---    so global mutations made by one test never leak into the next.
--- 2. Inspectable State: Stubs record their interactions (timers scheduled,
---    notifications sent, files written) so assertions can check side effects
---    without relying on real OS behavior.
--- 3. No Network / No Disk: All I/O paths default to in-memory implementations
---    or return safe empty values so tests cannot accidentally hit the host.
--- ==============================================================================

local M = {}




-- ===========================
--- ===========================
-- ======= 1/ Settings =======
--- ===========================
-- ===========================

local SETTINGS_STORE = {}

M.settings = {
	get = function(key) return SETTINGS_STORE[key] end,
	set = function(key, value) SETTINGS_STORE[key] = value end,
	clear = function(key) SETTINGS_STORE[key] = nil end,
	__store = SETTINGS_STORE,
}




-- ========================
--- ========================
-- ======= 2/ Timer =======
--- ========================
-- ========================

local TIMERS = {}

local function make_timer(delay, fn, recurring)
	local t = {
		delay = delay,
		fn = fn,
		running = true,
		recurring = recurring or false,
		fired = 0,
	}
	function t:stop() self.running = false end
	function t:start() self.running = true ; return self end
	function t:fire()
		if self.running and self.fn then self.fired = self.fired + 1 ; self.fn() end
		if not self.recurring then self.running = false end
	end
	table.insert(TIMERS, t)
	return t
end

M.timer = {
	doAfter = function(delay, fn) return make_timer(delay, fn, false) end,
	doEvery = function(delay, fn) return make_timer(delay, fn, true) end,
	new = function(delay, fn) return make_timer(delay, fn, true) end,
	secondsSinceEpoch = function() return os.time() end,
	-- absoluteTime returns nanoseconds since an arbitrary epoch, matching macOS semantics
	absoluteTime = function() return math.floor(os.clock() * 1e9) end,
	usleep = function(_) end,
	-- delayed is a one-shot timer that can be restarted/stopped by the caller
	delayed = {
		new = function(delay, fn)
			local t = make_timer(delay, fn, false)
			t.running = false  -- delayed timers don't auto-run until setDelay/start
			function t:setDelay(d) self.delay = d end
			function t:start() self.running = true ; return self end
			function t:stop()  self.running = false ; return self end
			function t:running_() return self.running end
			return t
		end,
	},
	__timers = TIMERS,
	__fire_all = function()
		for _, t in ipairs(TIMERS) do if t.running then t:fire() end end
	end,
}




-- ========================
-- ========================
-- ======= 3/ JSON ========
-- ========================
-- ========================

-- The driver only uses hs.json.decode / hs.json.encode. We provide a thin
-- pass-through that delegates to a pure-Lua JSON if available, or a minimal
-- fallback that handles the limited shapes used in tests.
local function _json_decode(s)
	if type(s) ~= "string" or s == "" then return nil end
	-- Minimal JSON parser sufficient for fixture-based tests
	local pos = 1
	local function skip_ws() while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end end
	local parse_value
	local function parse_string()
		assert(s:sub(pos, pos) == '"') ; pos = pos + 1
		local buf = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then pos = pos + 1 ; return table.concat(buf) end
			if c == '\\' then
				local e = s:sub(pos + 1, pos + 1)
				if e == 'n' then buf[#buf + 1] = '\n'
				elseif e == 't' then buf[#buf + 1] = '\t'
				elseif e == 'r' then buf[#buf + 1] = '\r'
				elseif e == '"' or e == '\\' or e == '/' then buf[#buf + 1] = e
				else buf[#buf + 1] = '\\' ; buf[#buf + 1] = e end
				pos = pos + 2
			else buf[#buf + 1] = c ; pos = pos + 1 end
		end
		error("unterminated string")
	end
	local function parse_number()
		local s_pos = pos
		while pos <= #s and s:sub(pos, pos):match("[%-%d%.eE+]") do pos = pos + 1 end
		return tonumber(s:sub(s_pos, pos - 1))
	end
	local function parse_array()
		pos = pos + 1 ; skip_ws()
		local arr = {}
		if s:sub(pos, pos) == ']' then pos = pos + 1 ; return arr end
		while true do
			skip_ws() ; arr[#arr + 1] = parse_value() ; skip_ws()
			local c = s:sub(pos, pos)
			if c == ',' then pos = pos + 1
			elseif c == ']' then pos = pos + 1 ; return arr
			else error("expected , or ] at " .. pos) end
		end
	end
	local function parse_object()
		pos = pos + 1 ; skip_ws()
		local obj = {}
		if s:sub(pos, pos) == '}' then pos = pos + 1 ; return obj end
		while true do
			skip_ws() ; local k = parse_string() ; skip_ws()
			assert(s:sub(pos, pos) == ':') ; pos = pos + 1 ; skip_ws()
			obj[k] = parse_value() ; skip_ws()
			local c = s:sub(pos, pos)
			if c == ',' then pos = pos + 1
			elseif c == '}' then pos = pos + 1 ; return obj
			else error("expected , or } at " .. pos) end
		end
	end
	parse_value = function()
		skip_ws()
		local c = s:sub(pos, pos)
		if c == '"' then return parse_string() end
		if c == '{' then return parse_object() end
		if c == '[' then return parse_array() end
		if c == 't' then pos = pos + 4 ; return true end
		if c == 'f' then pos = pos + 5 ; return false end
		if c == 'n' then pos = pos + 4 ; return nil end
		return parse_number()
	end
	local ok, result = pcall(parse_value)
	if not ok then return nil end
	return result
end

local function _json_encode(v)
	local t = type(v)
	if t == "nil" then return "null" end
	if t == "boolean" then return tostring(v) end
	if t == "number" then return tostring(v) end
	if t == "string" then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"' end
	if t == "table" then
		-- Detect array vs object
		local is_array = (#v > 0)
		if is_array then
			local parts = {}
			for i = 1, #v do parts[i] = _json_encode(v[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = '"' .. tostring(k) .. '":' .. _json_encode(val)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

M.json = {
	decode = _json_decode,
	encode = _json_encode,
}




-- ========================
-- ========================
-- ======= 4/ HTTP ========
-- ========================
-- ========================

local HTTP_RESPONSES = {}
local HTTP_CALLS = {}

M.http = {
	asyncPost = function(url, body, headers, callback)
		table.insert(HTTP_CALLS, { url = url, body = body, headers = headers, method = "POST" })
		local r = HTTP_RESPONSES[url] or { status = 200, body = "", headers = {} }
		if callback then callback(r.status, r.body, r.headers) end
	end,
	asyncGet = function(url, headers, callback)
		table.insert(HTTP_CALLS, { url = url, headers = headers, method = "GET" })
		local r = HTTP_RESPONSES[url] or { status = 200, body = "", headers = {} }
		if callback then callback(r.status, r.body, r.headers) end
	end,
	get = function(url, headers)
		table.insert(HTTP_CALLS, { url = url, headers = headers, method = "GET" })
		local r = HTTP_RESPONSES[url] or { status = 200, body = "", headers = {} }
		return r.status, r.body, r.headers
	end,
	post = function(url, body, headers)
		table.insert(HTTP_CALLS, { url = url, body = body, headers = headers, method = "POST" })
		local r = HTTP_RESPONSES[url] or { status = 200, body = "", headers = {} }
		return r.status, r.body, r.headers
	end,
	__set_response = function(url, status, body, headers)
		HTTP_RESPONSES[url] = { status = status, body = body, headers = headers or {} }
	end,
	__calls = HTTP_CALLS,
	__reset = function()
		for k in pairs(HTTP_RESPONSES) do HTTP_RESPONSES[k] = nil end
		for i = #HTTP_CALLS, 1, -1 do HTTP_CALLS[i] = nil end
	end,
}




-- ===========================
-- ===========================
-- ======= 5/ Logger =========
-- ===========================
-- ===========================

M.logger = {
	new = function(_, _) return {
		i = function() end, w = function() end, e = function() end,
		d = function() end, v = function() end, f = function() end,
		setLogLevel = function() end,
	} end,
	defaultLogLevel = "warning",
	setGlobalLogLevel = function() end,
}





-- ============================
--- =============================
--- ======= 6/ Filesystem =======
--- =============================
-- ============================

M.fs = {
	dir = function(_) return function() return nil end end,
	attributes = function(_) return nil end,
	mkdir = function(_) return true end,
	pathToAbsolute = function(p) return p end,
	displayName = function(p) return p end,
}




-- =================================
--- ================================
-- ======= 6b/ SQLite3 Stub =======
--- ================================
-- =================================

-- Minimal stub for hs.sqlite3 — records open() calls; exec/prepare/close are no-ops.
-- Real DB logic is tested via integration tests with a temp SQLite file.
local SQLITE3_CALLS = {}

M.sqlite3 = {
	OK      = 0,
	ERROR   = 1,
	MISUSE  = 21,
	ROW     = 100,
	DONE    = 101,
	open = function(path)
		table.insert(SQLITE3_CALLS, { op = "open", path = path })
		-- Returns a stub db handle that succeeds on all calls
		local db = {
			exec       = function(_, _sql) return 0 end,
			prepare    = function(_, _sql)
				return {
					step        = function(_) return 101 end,  -- DONE
					bind_values = function(_, ...) return 0 end,
					finalize    = function(_) return 0 end,
					nrows       = function(_) return function() return nil end end,
				}
			end,
			-- nrows on the db handle itself: iterate over SELECT results
			nrows      = function(_, _sql) return function() return nil end end,
			close      = function(_) return 0 end,
			errmsg     = function(_) return "" end,
			last_insert_rowid = function(_) return 0 end,
		}
		return db, nil
	end,
	__calls = SQLITE3_CALLS,
}




-- ============================
-- ============================
-- ======= 7/ Eventtap ========
-- ============================
-- ============================

local KEYSTROKES = {}

M.mouse = {
	absolutePosition = function() return { x = 0, y = 0 } end,
	setAbsolutePosition = function() end,
}

M.eventtap = {
	keyStroke = function(mods, key) table.insert(KEYSTROKES, { mods = mods, key = key }) end,
	keyStrokes = function(s) table.insert(KEYSTROKES, { text = s }) end,
	new = function(_, _) return { start = function() end, stop = function() end } end,
	event = {
		types = { keyDown = 10, keyUp = 11, flagsChanged = 12, leftMouseUp = 1, rightMouseUp = 2 },
		newKeyEvent   = function(mods, key, isDown) return { mods = mods, key = key, isDown = isDown, post = function() end } end,
		newMouseEvent = function(t, pos) return { t = t, pos = pos, post = function() end } end,
	},
	checkKeyboardModifiers = function() return {} end,
	keyRepeatInterval = function() return 0.05 end,
	keyRepeatDelay = function() return 0.5 end,
	__keystrokes = KEYSTROKES,
	__reset = function()
		for i = #KEYSTROKES, 1, -1 do KEYSTROKES[i] = nil end
		-- Tests that overwrite hs.keycodes.map (e.g. test_keycodes.lua) would
		-- otherwise leak a stripped-down map into later tests. Rebuild the
		-- metatabled map on every __reset so each test starts from the canonical
		-- DEFAULT_KEYCODES_MAP.
		if M.keycodes and M.keycodes.__rebuild_map then
			M.keycodes.__rebuild_map()
		end
	end,
}

-- Concrete map for the F-key sentinels and core nav/edit keys, mirroring the
-- macOS HID codes that the production driver compiles into Karabiner JSON.
-- Without these, modules that call Keycodes.to_name() at top-load time (e.g.
-- karabiner.generator) crash before the test body ever runs.
local DEFAULT_KEYCODES_MAP = {
	-- F-key sentinels (Karabiner inverse-resolves these via to_name)
	f13 = 105, f14 = 107, f15 = 113, f16 = 106, f17 = 64, f18 = 79, f19 = 80, f20 = 90,
	-- Core navigation / edit
	["return"] = 36, ["delete"] = 51, escape = 53, tab = 48, padenter = 76,
	left = 123, right = 124, up = 126, down = 125, space = 49,
}

M.keycodes = {}

--- Rebuilds the metatabled keycodes.map. Called once at module load and again
--- from __reset() so that tests which assign `hs.keycodes.map = { ... }` to
--- a stripped-down literal table cannot leak that state into later tests.
M.keycodes.__rebuild_map = function()
	M.keycodes.map = setmetatable({}, {
		__index = function(_, k)
			local hit = DEFAULT_KEYCODES_MAP[k]
			if hit then return hit end
			return tonumber(k) or 0
		end,
		__pairs = function(_) return pairs(DEFAULT_KEYCODES_MAP) end,
	})
end

M.keycodes.__rebuild_map()




-- ============================
-- ============================
-- ======= 8/ Execute =========
-- ============================
-- ============================

local EXEC_RESPONSES = {}
local EXEC_CALLS = {}

M.execute = function(cmd, _withUserEnv)
	table.insert(EXEC_CALLS, cmd)
	for pattern, response in pairs(EXEC_RESPONSES) do
		if cmd:find(pattern, 1, true) then
			return response.output, response.success, response.exitType, response.rc
		end
	end
	return "", true, "exit", 0
end




-- ============================
-- ============================
-- ======= 9/ Misc UI =========
-- ============================
-- ============================

M.canvas = {
	new = function(_) return setmetatable({}, {
		__index = function() return function(self) return self end end,
	}) end,
	-- Level and behavior constants used by renderer.lua at load time; the stub
	-- must expose them as plain numbers so the canvas:level() / :behavior() calls
	-- on the mock canvas object do not crash on nil indexing.
	windowLevels    = setmetatable({}, { __index = function() return 0 end }),
	windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}

M.styledtext = { new = function(s, _) return s end }
M.console = { printStyledtext = function(_) end }
M.notify = {
	new = function(opts) return {
		send = function() end,
		release = function() end,
		opts = opts,
	} end,
	show = function(_) end,
}
M.dialog = {
	alert = function(_, _) return "OK" end,
	textPrompt = function() return "OK", "" end,
	chooseFromList = function() return nil end,
}

M.application = {
	frontmostApplication = function() return { name = function() return "Test" end, bundleID = function() return "test.bundle" end } end,
	get = function(_) return nil end,
	launchOrFocus = function(_) end,
	open = function(_) end,
	applicationsForBundleID = function(_) return {} end,
	watcher = {
		new = function(_) return { start = function(self) return self end, stop = function() end } end,
		activated = "activated",
		deactivated = "deactivated",
		launched = "launched",
		terminated = "terminated",
	},
}

M.window = {
	focusedWindow = function() return nil end,
	frontmostWindow = function() return nil end,
}

M.pathwatcher = {
	new = function(_, _) return { start = function(self) return self end, stop = function() end } end,
}

M.urlevent = { bind = function() end }
M.pasteboard = {
	getContents = function() return "" end,
	setContents = function(_) return true end,
}
M.osascript = { applescript = function(_) return false, nil, "" end }
M.spaces = {
	focusedSpace = function() return 1 end,
	gotoSpace = function(_) end,
}
M.openConsole = function() end
M.focus = function() end
M.hotkey = { bind = function() return { delete = function() end } end }
M.menubar = { new = function() return {
	setTitle = function() end, setMenu = function() end,
	delete = function() end, setIcon = function() end,
} end }
M.image = { imageFromPath = function(_) return nil end, imageFromName = function(_) return nil end }
M.task = { new = function(_, _) return { start = function() end, terminate = function() end } end }
M.webview = { new = function() return {} end }
M.distributednotifications = { new = function() return { start = function() end, stop = function() end } end }
M.alert = function(_) end
M.reload = function() end
M.configdir = "/tmp/test_hammerspoon"
M.shutdownCallback = nil

M.fnutils = {
	concat = function(a, b)
		local out = {}
		for _, v in ipairs(a or {}) do out[#out + 1] = v end
		for _, v in ipairs(b or {}) do out[#out + 1] = v end
		return out
	end,
	contains = function(t, v) for _, x in ipairs(t or {}) do if x == v then return true end end return false end,
	indexOf = function(t, v) for i, x in ipairs(t or {}) do if x == v then return i end end return nil end,
	copy = function(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end,
	map = function(t, fn) local c = {} for i, v in ipairs(t or {}) do c[i] = fn(v) end return c end,
	filter = function(t, fn) local c = {} for _, v in ipairs(t or {}) do if fn(v) then c[#c+1] = v end end return c end,
}

M.inspect = function(v) return tostring(v) end

M.host = {
	operatingSystemVersion = function() return { major = 14, minor = 0, patch = 0 } end,
	operatingSystemVersionString = function() return "macOS 14.0" end,
}




-- =====================================
-- =====================================
-- ======= 10/ Test Reset Hooks ========
-- =====================================
-- =====================================

--- Resets all in-memory stub state. Test helpers should call this before each
--- test to avoid cross-test pollution.
function M.__reset()
	for k in pairs(SETTINGS_STORE) do SETTINGS_STORE[k] = nil end
	for i = #TIMERS, 1, -1 do TIMERS[i] = nil end
	for i = #KEYSTROKES, 1, -1 do KEYSTROKES[i] = nil end
	for i = #EXEC_CALLS, 1, -1 do EXEC_CALLS[i] = nil end
	for k in pairs(EXEC_RESPONSES) do EXEC_RESPONSES[k] = nil end
	M.http.__reset()
	-- Rebuild the canonical keycodes.map: tests like test_keycodes deliberately
	-- assign a stripped-down literal table to hs.keycodes.map, which would
	-- otherwise leak into later tests that load modules calling Keycodes.to_name
	-- at module-load time (e.g. karabiner.generator).
	if M.keycodes and M.keycodes.__rebuild_map then
		M.keycodes.__rebuild_map()
	end
end

--- Registers a canned response for a shell command pattern (substring match).
--- @param pattern string Substring matched against the command line.
--- @param output string Stdout content the call should return.
--- @param success boolean|nil Whether the simulated process exited cleanly.
function M.__set_exec(pattern, output, success)
	EXEC_RESPONSES[pattern] = { output = output, success = success ~= false, exitType = "exit", rc = 0 }
end

M.__exec_calls = EXEC_CALLS

return M
