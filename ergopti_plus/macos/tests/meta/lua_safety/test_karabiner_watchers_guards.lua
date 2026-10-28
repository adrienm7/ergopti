--- tests/meta/lua_safety/test_karabiner_watchers_guards.lua

--- ==============================================================================
--- MODULE: Karabiner watchers guard their natives (meta)
--- DESCRIPTION:
--- karabiner/watchers.lua must guard allWindows(), nil-check its hs.task and pcall-wrap the F17 hotkeys.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local s = helpers.read_driver_source(selector)
	return s
end

helpers.describe("karabiner watchers guard their natives", function()

	-- =======================================================================
	-- ===== 6a) karabiner/watchers.lua: allWindows() nil-crash fixed
	-- =======================================================================

	helpers.it("karabiner/watchers.lua must guard allWindows() against nil return", function()
		local src = read_src("local function parse_layout_name") -- platform/remap/watchers.lua
		assert(src, "platform/remap/watchers.lua must be readable")
		-- The bug: app:allWindows() can return nil if the app exits mid-call.
		-- ipairs(nil) would crash with "bad argument #1".
		assert(
			src:find("allWindows%(%)" .. "%s*or%s*{}", 1, false),
			"karabiner/watchers.lua: allWindows() must be guarded with `or {}` to prevent nil crash"
		)
	end)

	-- =======================================================================
	-- ===== 6b) karabiner/watchers.lua: inner hs.task nil-check added
	-- =======================================================================

	helpers.it("karabiner/watchers.lua inner hs.task must be nil-checked before :start()", function()
		local src = read_src("local function parse_layout_name") -- platform/remap/watchers.lua
		assert(src, "platform/remap/watchers.lua must be readable")
		-- The bug: hs.task.new(...):start() chained with no nil-check — crashes
		-- if the CLI binary is missing and hs.task.new() returns nil.
		-- Use [^\n]* (not .-) because in Lua 5.4 the dot matches newlines,
		-- which would bridge the %b() close paren to a :start() call many lines later.
		assert(
			not src:find("hs%.task%.new%b()[^\n]*:start%(%)", 1, false),
			"karabiner/watchers.lua: hs.task.new() result must not chain directly to :start() — nil-check required"
		)
	end)

	-- =======================================================================
	-- ===== 6c) karabiner/watchers.lua: F17 hotkey wrapped in pcall
	-- =======================================================================

	helpers.it("karabiner/watchers.lua F17 hotkeys must use a pcall wrapper", function()
		local src = read_src("local function parse_layout_name") -- platform/remap/watchers.lua
		assert(src, "platform/remap/watchers.lua must be readable")
		-- This started as "the plain F17 hotkey must wrap its callback in pcall
		-- like Shift+F17 and Alt+F17 already do" — three separately written
		-- wrappers, and the one that was forgotten is what the audit found. The
		-- four bindings now share bind_f17, so the wrapper is written once and a
		-- fourth chord cannot arrive without it. The assertion follows it there,
		-- and asserts the property that replaced the consistency it was policing.
		assert(
			src:find("local function bind_f17", 1, true),
			"karabiner/watchers.lua: the F17 bindings must go through one bind_f17 helper — three "
			.. "hand-written pcall wrappers is what let the third one be forgotten"
		)
		assert(
			src:find("local%s+[%w_]+%s*,%s*[%w_]+%s*=%s*pcall%(action%)", 1, false),
			"karabiner/watchers.lua: bind_f17 must pcall the action — an exception in a hotkey "
			.. "callback is delivered to the Hammerspoon Console, never to the driver's log"
		)
		for _, starter in ipairs({
			"start_cycle_windows_hotkey", "start_alt_tab_windows_hotkey",
			"start_alt_tab_apps_hotkey", "start_alt_tab_monitor_hotkey",
		}) do
			local body = src:match("function M%." .. starter .. "%(%)(.-)\nend")
			assert(body and body:find("bind_f17(", 1, true),
				"karabiner/watchers.lua: " .. starter .. " must delegate to bind_f17 — a binding that "
				.. "creates its own hotkey is the unguarded sibling this assertion exists to catch")
		end
	end)

end)
