--- tests/meta/test_tooltip_mousemoved_lag.lua

--- ==============================================================================
--- MODULE: Tooltip mouseMoved Lag Guard
--- DESCRIPTION:
--- Static-source regression guard for the AI-menu scroll/typing lag bug.
---
--- ROOT CAUSE ENCODED:
--- Both tooltip_llm.lua and tooltip_hotstring.lua included `mouseMoved` in the
--- dismiss watcher created by start_watchers(). On macOS, a trackpad fires
--- mouseMoved at up to 200+ Hz. Each invocation synchronously enters the
--- Hammerspoon Lua callback path on the HID event thread, adding latency to
--- every pointer event delivered to the system while the LLM tooltip is
--- visible. Activating the AI menu causes the LLM loading spinner to appear
--- (start_watchers() called), which registers this high-frequency tap, causing
--- noticeable scroll and typing lag in all other apps.
---
--- THE FIX:
--- Remove `mouseMoved` from the event types table in both tooltip watchers.
--- Tooltip dismissal on click (leftMouseDown / rightMouseDown), scroll
--- (scrollWheel), and keystroke (separate keyDown watcher) is still intact.
--- Pure mouse movement never needed to dismiss the tooltip.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end

local function start_watchers_body(src)
	local idx = src:find("local function start_watchers()", 1, true)
	if not idx then return "" end
	local rest = src:sub(idx)
	local _, stop = rest:find("\nend\n")
	return stop and rest:sub(1, stop) or rest
end





-- =============================================================================
-- =============================================================================
-- ======= 1/ tooltip_llm.lua — mouseMoved excluded from dismiss watcher =======
-- =============================================================================
-- =============================================================================

helpers.describe("tooltip_llm.lua: mouseMoved excluded from dismiss watcher (lag fix)", function()

	helpers.it("start_watchers() does not include event_types.mouseMoved", function()
		local src  = read_source("ui/tooltip/tooltip_llm.lua")
		local body = start_watchers_body(src)
		helpers.assert_true(body ~= "",
			"start_watchers must exist in tooltip_llm.lua")
		helpers.assert_true(
			body:find("event_types.mouseMoved", 1, true) == nil,
			"tooltip_llm start_watchers must NOT watch mouseMoved (causes 200+ Hz HID lag)")
	end)

	helpers.it("dismiss watcher still watches leftMouseDown", function()
		local src  = read_source("ui/tooltip/tooltip_llm.lua")
		local body = start_watchers_body(src)
		helpers.assert_true(
			body:find("leftMouseDown", 1, true) ~= nil,
			"tooltip_llm dismiss watcher must still include leftMouseDown")
	end)

	helpers.it("dismiss watcher still watches scrollWheel", function()
		local src  = read_source("ui/tooltip/tooltip_llm.lua")
		local body = start_watchers_body(src)
		helpers.assert_true(
			body:find("scrollWheel", 1, true) ~= nil,
			"tooltip_llm dismiss watcher must still include scrollWheel")
	end)

end)





-- ===================================================================================
-- ===================================================================================
-- ======= 2/ tooltip_hotstring.lua — mouseMoved excluded from dismiss watcher =======
-- ===================================================================================
-- ===================================================================================

helpers.describe("tooltip_hotstring.lua: mouseMoved excluded from dismiss watcher (lag fix)", function()

	helpers.it("start_watchers() does not include event_types.mouseMoved", function()
		local src  = read_source("ui/tooltip/tooltip_hotstring.lua")
		local body = start_watchers_body(src)
		helpers.assert_true(body ~= "",
			"start_watchers must exist in tooltip_hotstring.lua")
		helpers.assert_true(
			body:find("event_types.mouseMoved", 1, true) == nil,
			"tooltip_hotstring start_watchers must NOT watch mouseMoved (causes 200+ Hz HID lag)")
	end)

	helpers.it("dismiss watcher still watches leftMouseDown", function()
		local src  = read_source("ui/tooltip/tooltip_hotstring.lua")
		local body = start_watchers_body(src)
		helpers.assert_true(
			body:find("leftMouseDown", 1, true) ~= nil,
			"tooltip_hotstring dismiss watcher must still include leftMouseDown")
	end)

	helpers.it("dismiss watcher still watches scrollWheel", function()
		local src  = read_source("ui/tooltip/tooltip_hotstring.lua")
		local body = start_watchers_body(src)
		helpers.assert_true(
			body:find("scrollWheel", 1, true) ~= nil,
			"tooltip_hotstring dismiss watcher must still include scrollWheel")
	end)

end)
