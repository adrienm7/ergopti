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
-- ===========================
-- ======= 1/ Settings =======
-- ===========================
-- ===========================

local SETTINGS_STORE = {}

M.settings = {
	get = function(key) return SETTINGS_STORE[key] end,
	set = function(key, value) SETTINGS_STORE[key] = value end,
	clear = function(key) SETTINGS_STORE[key] = nil end,
	__store = SETTINGS_STORE,
}





-- ========================
-- ========================
-- ======= 2/ Timer =======
-- ========================
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
			function t:start(next_delay)
				if next_delay ~= nil then self.delay = next_delay end
				self.running = true
				return self
			end
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
	-- All real locale JSON files are UTF-8-with-BOM by convention. The real
	-- (native) hs.json.decode tolerates a leading BOM transparently; this
	-- hand-rolled stub parser does not skip it, so it silently returned 0 keys
	-- for every locale file (PF-3 fix). Strip it before parsing.
	s = s:gsub("^\239\187\191", "")
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





--- =============================
--- =============================
--- ======= 6/ Filesystem =======
--- =============================
--- =============================

-- Per-path directory listings a test can populate: __entries["/abs/path"] = { "a.toml", "b.toml" }.
-- Empty by default so an un-populated directory simply iterates to nothing.
local FS_ENTRIES = {}

--- Builds an hs.fs.dir-faithful (iterator, dirObject) pair.
--- Real Hammerspoon's hs.fs.dir() returns TWO values — an iterator function AND
--- a directory userdata object — and the iterator REQUIRES that object as its
--- first argument (it checks the "directory" metatable and aborts with "directory
--- metatable expected, got nil" otherwise). Modelling that faithfully here is
--- what lets the suite catch the dropped-second-return-value bug: code that does
--- `local ok, it = pcall(hs.fs.dir, d); for x in it do` passes nil as state and
--- fails EXACTLY as it does against real Hammerspoon (init-fsdir-drops-state).
--- The old lenient stub (`function(_) return function() return nil end end`)
--- returned a single, stateless iterator and so masked that whole class of bug.
--- @param entries table|nil Array of entry names to yield.
--- @return function, table The iterator and its mandatory directory-object state.
local function make_fs_dir_iterator(entries)
	entries = entries or {}
	local index = 0
	local dir_object = setmetatable({}, { __name = "hs.fs.dir directory object" })
	local function iterator(state)
		if state ~= dir_object then
			error("bad argument #1 to 'for iterator' (directory metatable expected, got "
				.. (state == nil and "nil" or type(state)) .. ")", 2)
		end
		index = index + 1
		return entries[index]
	end
	return iterator, dir_object
end

-- Pure-Lua existence probe used when LuaFileSystem is unavailable (e.g. a
-- Windows dev box without lfs). Exposed as hs.fs.__probe_no_lfs so a regression
-- test can pin it directly on every OS. Two platform asymmetries meet here:
--   - POSIX opens DIRECTORIES read-only too, so io.open succeeding does not
--     mean "file". read(0) disambiguates portably: "" for a regular file,
--     nil (EISDIR) for a directory. (First CI run of this probe classified
--     every Linux directory as a file for exactly this reason.)
--   - Windows io.open fails on directories, so fall through to os.rename:
--     a no-op rename SUCCEEDS on POSIX but FAILS on Windows because the
--     target exists — accept any failure whose errno is not ENOENT (2).
--     errno is the third os.rename return and, unlike the message string, is
--     NOT localized (critical on French Windows, where os.rename(dir, dir)
--     previously left _shared/ undiscoverable).
local function probe_fs_without_lfs(path)
	local fh = io.open(path, "r")
	if fh then
		local zero = fh:read(0)
		fh:close()
		if zero then return { mode = "file" } end
		return { mode = "directory" }
	end
	local ok, _, code = os.rename(path, path)
	if ok or (code and code ~= 2) then return { mode = "directory" } end
	return nil
end

M.fs = {
	-- Returns (iterator, dirObject) like real Hammerspoon — see make_fs_dir_iterator.
	dir = function(path) return make_fs_dir_iterator(FS_ENTRIES[path]) end,
	-- Honest existence probe against the real filesystem: lib.paths walks the
	-- repo with hs.fs.attributes to locate _shared/, and lib.timings/TomlReader
	-- then read real repo files. A constant-nil stub only ever worked because
	-- some earlier test file had cached those modules under a real-fs override —
	-- a warm-cache accident the runner's per-file cold start deliberately ended
	attributes = function(path)
		if type(path) ~= "string" or path == "" then return nil end
		local ok_lfs, lfs = pcall(require, "lfs")
		if ok_lfs and lfs and lfs.attributes then return lfs.attributes(path) end
		return probe_fs_without_lfs(path)
	end,
	-- Test hook: the lfs-free probe above, so a regression test can assert it
	-- classifies an existing directory / file / missing path correctly on any OS.
	__probe_no_lfs = probe_fs_without_lfs,
	-- Honest, for the same reason `attributes` above is. It used to return true
	-- without creating anything, which made every directory-creation invariant
	-- untestable: production code that verifies its own mkdir with
	-- hs.fs.attributes — as ensure_dir does, deliberately, because LuaFileSystem
	-- returns nil rather than raising — saw the create "succeed" and the
	-- directory stay missing. A stub that reports success for work it did not do
	-- is the harness-stubs-the-subject false green, and the one class the
	-- detector cannot see.
	mkdir = function(path)
		if type(path) ~= "string" or path == "" then return nil, "invalid path" end
		local ok_lfs, lfs = pcall(require, "lfs")
		if ok_lfs and lfs and lfs.mkdir then return lfs.mkdir(path) end
		local is_windows = package.config:sub(1, 1) == "\\"
		local quoted = '"' .. path:gsub('"', '') .. '"'
		local cmd = is_windows
			and ('cmd /c if not exist ' .. quoted .. ' mkdir ' .. quoted .. ' 2>nul')
			or ('mkdir -p ' .. quoted .. ' 2>/dev/null')
		os.execute(cmd)
		return M.fs.attributes(path) ~= nil
	end,
	pathToAbsolute = function(p) return p end,
	displayName = function(p) return p end,
	-- Test hook: register the names a given absolute path should list.
	__set_entries = function(path, names) FS_ENTRIES[path] = names end,
	__entries = FS_ENTRIES,
	__reset_entries = function() for k in pairs(FS_ENTRIES) do FS_ENTRIES[k] = nil end end,
}





-- ================================
-- ================================
-- ======= 6b/ SQLite3 Stub =======
-- ================================
-- ================================

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
-- Every eventtap built through this stub, in creation order, with the event
-- types it was asked to watch and its start/stop counts.
local TAPS = {}

M.mouse = {
	absolutePosition = function() return { x = 0, y = 0 } end,
	setAbsolutePosition = function() end,
}

M.eventtap = {
	-- The third argument is recorded so tests can assert an explicit delay was passed.
	-- Real hs.eventtap.keyStroke() defaults it to a BLOCKING 200 000 us usleep on the
	-- main run loop; dropping it here made the harness structurally unable to observe
	-- the omission (see tests/meta/test_keystroke_explicit_delay.lua).
	keyStroke = function(mods, key, delay) table.insert(KEYSTROKES, { mods = mods, key = key, delay = delay }) end,
	keyStrokes = function(s) table.insert(KEYSTROKES, { text = s }) end,
	-- Both arguments are recorded, for the same reason the keyStroke delay is:
	-- a stub that discards what it was given makes the harness structurally
	-- unable to observe a caller that gets it wrong. This one dropped the event
	-- type list, so "creates an event watcher with the correct events" could only
	-- ever be written as assert_true(true) — and it was.
	new = function(types, fn)
		local tap = { types = types, fn = fn, started = 0, stopped = 0, enabled = false }
		tap.start = function(self)
			local t = self or tap
			t.started = t.started + 1
			t.enabled = true
			return t
		end
		tap.stop  = function(self)
			local t = self or tap
			t.stopped = t.stopped + 1
			t.enabled = false
			return t
		end
		tap.isEnabled = function(self) return (self or tap).enabled end
		table.insert(TAPS, tap)
		return tap
	end,
	event = {
		-- Quartz event fields used to distinguish hardware input from events
		-- synthesized by this Hammerspoon process. Keep the values opaque: tests
		-- must address them through the same names as production code.
		properties = {
			eventSourceUnixProcessID = 1,
			eventSourceUserData      = 2,
			eventSourceStateID       = 3,
			scrollWheelEventDeltaAxis1 = 4,
			mouseEventButtonNumber = 5,
		},
		-- Every type the driver actually names. It used to carry five, and the
		-- gap was invisible in the worst way: keep-awake builds its watch list as
		-- a table CONSTRUCTOR whose first element is ev.scrollWheel, so a missing
		-- type left a nil at index 1 and `ipairs` over the list yielded nothing.
		-- The watcher was created watching an empty set, and no test could see it
		-- because the stub discarded the argument anyway.
		--
		-- The numbers are opaque handles here, not CGEventType values: three of
		-- them predate this list and are relied on by tests that compare against
		-- hs.eventtap.event.types themselves, so they keep the values they had.
		types = {
			keyDown = 10, keyUp = 11, flagsChanged = 12,
			leftMouseUp = 1, rightMouseUp = 2,
			leftMouseDown = 3, rightMouseDown = 4, mouseMoved = 5,
			middleMouseDown = 6, otherMouseDown = 25, otherMouseUp = 26,
			scrollWheel = 22,
			tapDisabledByTimeout = 0xFFFFFFFE, tapDisabledByUserInput = 0xFFFFFFFF,
		},
		newKeyEvent   = function(mods, key, isDown)
			local properties = {}
			local event = {
				mods = mods, key = key, isDown = isDown,
				getProperty = function(_, prop)
					if prop == M.eventtap.event.properties.eventSourceUnixProcessID then
						return M.processInfo and M.processInfo.processID or 0
					end
					return properties[prop] or 0
				end,
				setProperty = function(self, prop, value) properties[prop] = value; return self end,
				setUnicodeString = function(self, value) self.unicode = value; return self end,
				getUnicodeString = function(self) return self.unicode or "" end,
				post = function() end,
			}
			return event
		end,
		newMouseEvent = function(t, pos, mods)
			local properties = {}
			return {
				t = t, pos = pos, mods = mods,
				getProperty = function(_, prop) return properties[prop] or 0 end,
				setProperty = function(self, prop, value) properties[prop] = value; return self end,
				post = function(self) return self end,
			}
		end,
	},
	checkKeyboardModifiers = function() return {} end,
	keyRepeatInterval = function() return 0.05 end,
	keyRepeatDelay = function() return 0.5 end,
	__keystrokes = KEYSTROKES,
	__taps = TAPS,
	__reset = function()
		for i = #KEYSTROKES, 1, -1 do KEYSTROKES[i] = nil end
		for i = #TAPS, 1, -1 do TAPS[i] = nil end
		-- Tests that overwrite hs.keycodes.map (e.g. test_keycodes.lua) would
		-- otherwise leak a stripped-down map into later tests. Rebuild the
		-- metatabled map on every __reset so each test starts from the canonical
		-- DEFAULT_KEYCODES_MAP.
		if M.keycodes and M.keycodes.__rebuild_map then
			M.keycodes.__rebuild_map()
		end
	end,
}

-- Identity of the Hammerspoon process. Quartz writes this value into
-- eventSourceUnixProcessID for hs.eventtap.keyStroke/keyStrokes echoes.
M.processInfo = { processID = 7001 }

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

M.drawing = {
	windowLevels = setmetatable({}, { __index = function() return 0 end }),
}

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

-- Screen geometry for the tooltip anchor step. Without hs.screen every render
-- path aborted at renderer.lua's `hs.screen.mainScreen():frame()` INSIDE M.render's
-- pcall, so canvas:frame()/show() were never reached and any test asserting on a
-- completed render was a false green (test_tooltip_stacked_panel could not see a
-- crash at the draw site because the render never got that far).
local STUB_SCREEN_W = 1920  -- Nominal test display width in points
local STUB_SCREEN_H = 1080  -- Nominal test display height in points

local function make_screen()
	local screen = {}
	function screen:frame()      return { x = 0, y = 0, w = STUB_SCREEN_W, h = STUB_SCREEN_H } end
	function screen:fullFrame()  return { x = 0, y = 0, w = STUB_SCREEN_W, h = STUB_SCREEN_H } end
	function screen:name()       return "StubDisplay" end
	function screen:id()         return 1 end
	-- The healthcheck collector probes currentMode(); its API contract test asserts
	-- every probed symbol exists, so the stub must carry it too.
	function screen:currentMode() return { w = STUB_SCREEN_W, h = STUB_SCREEN_H, scale = 2 } end
	return screen
end

M.screen = {
	mainScreen  = function() return make_screen() end,
	primaryScreen = function() return make_screen() end,
	allScreens  = function() return { make_screen() } end,
}

M.styledtext = { new = function(s, _) return s end }
M.console = { printStyledtext = function(_) end }
M.notify = {
	new = function(arg1, arg2)
		local opts = type(arg1) == "function" and arg2 or arg1
		return {
			send = function() end,
			release = function() end,
			opts = opts,
		}
	end,
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
	filter = {
		default = {
			subscribe   = function(self, events, cb) end,
			unsubscribe = function(self, cb) end,
		},
		windowFocused      = "windowFocused",
		windowTitleChanged = "windowTitleChanged",
	},
}

M.pathwatcher = {
	new = function(_, _) return { start = function(self) return self end, stop = function() end } end,
}

-- openURL is recorded rather than dropped so a test can assert that an action
-- which is SUPPOSED to open a link actually did — the difference between a
-- working binding and a silent no-op is invisible to a stub that ignores it.
M.urlevent = {
	bind      = function() end,
	__opened  = {},
	openURL   = function(url)
		table.insert(M.urlevent.__opened, tostring(url))
	end,
	__reset   = function() M.urlevent.__opened = {} end,
}
M.pasteboard = {
	getContents  = function() return "" end,
	setContents  = function(_) return true end,
	readAllData  = function() return {} end,
	writeAllData = function(_) return true end,
}
M.osascript = { applescript = function(_) return false, nil, "" end }
M.spaces = {
	focusedSpace = function() return 1 end,
	gotoSpace = function(_) end,
}
M.openConsole = function() end
M.focus = function() end
-- A hotkey stub that returned a bare {delete = noop} could not tell a test
-- whether the binding was ever enabled, disabled, or released — every lifecycle
-- assertion against it was vacuously true. This one records what it was asked to
-- do and exposes the live set, so a leaked hotkey is visible to the suite.
M.hotkey = {
	_bound = {},
	bind = function(mods, key, pressed_fn)
		local entry = {
			mods = mods, key = key, pressed_fn = pressed_fn,
			enabled = true, deleted = false,
		}
		entry.enable = function(self)
			local target = self or entry
			target.enabled = true
			return target
		end
		entry.disable = function(self)
			local target = self or entry
			target.enabled = false
			return target
		end
		entry.delete = function(self)
			local target = self or entry
			target.deleted = true
			target.enabled = false
			for i, held in ipairs(M.hotkey._bound) do
				if held == target then table.remove(M.hotkey._bound, i); break end
			end
			return nil
		end
		table.insert(M.hotkey._bound, entry)
		return entry
	end,
}
M.menubar = { new = function() return {
	setTitle = function() end, setMenu = function() end,
	delete = function() end, setIcon = function() end,
} end }
M.image = { imageFromPath = function(_) return nil end, imageFromName = function(_) return nil end }
M.task = { new = function(_, _) return { start = function() end, terminate = function() end } end }
-- usercontent is the JavaScript bridge every webview UI builds at module load
-- time (ui/download_window, ui/model_browser, …). Omitting it made those modules
-- unloadable under the harness, so their logic could only ever be source-guarded.
M.webview = {
	new = function() return {} end,
	usercontent = {
		new = function(_name)
			return {
				setCallback     = function(self) return self end,
				injectScript    = function(self) return self end,
				removeCallback  = function(self) return self end,
			}
		end,
	},
}
M.distributednotifications = { new = function() return { start = function() end, stop = function() end } end }
M.alert = setmetatable({
	show = function() return "uuid" end,
	closeAll = function() end,
	closeSpecific = function() end,
}, { __call = function(_, _) end })
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
	interfaceStyle = function() return "Dark" end,
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
	if M.fs and M.fs.__reset_entries then M.fs.__reset_entries() end
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
