--- modules/shortcuts/actions/system_mouse.lua

--- ==============================================================================
--- MODULE: Shortcuts — System Actions — Mouse & Display Utilities
--- DESCRIPTION:
--- Mouse teleport, display mirroring, emoji picker, and mouse spotlight helpers
--- extracted from system.lua. Merged back into the system module table at load time.
---
--- FEATURES & RATIONALE:
--- 1. Screen Teleport: Cycles the cursor across all connected screens and shows a
---    brief spotlight so the new cursor position is immediately visible.
--- 2. Display Mirror: Uses CoreGraphics via inline Python so mirroring toggles
---    reliably without depending on the fragile Cmd+F1 media-key route.
--- 3. Mouse Spotlight: Draws a yellow ring on the cursor'·s screen and a red ×
---    on every other screen; auto-dismisses on mouse move or timeout.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local EventTapGuard = require("adapters.event_tap_guard")
local text_utils = require("infra.text_utils")
local notifications = require("infra.notifications")
local i18n          = require("infra.i18n")
local MouseControl  = require("adapters.mouse_control")
local ShellRunner   = require("adapters.shell_runner")
local SyntheticInput = require("adapters.synthetic_input")

local LOG = "shortcuts.actions.system"

-- Absolute path: the interactive layer must not inherit its binaries from PATH,
-- which differs between a login shell and the Hammerspoon process.
local PYTHON_BIN = "/usr/bin/python3"

-- Spotlight ring color (circle on the screen that holds the cursor)
local SPOTLIGHT_COLOR = {red = 1, green = 0.85, blue = 0}    -- Yellow

-- Cross marker color (× shown on every screen NOT holding the cursor)
local CROSS_COLOR     = {red = 0.9, green = 0.1, blue = 0.05} -- Red

-- Shared stroke alpha for all overlay shapes (circle and crosses)
local OVERLAY_STROKE_ALPHA = 0.9  -- High opacity so the border reads against any background

-- Mouse spotlight ring parameters (circle shown on the screen that holds the cursor)
local SPOTLIGHT_RADIUS_PX   = 60    -- Outer ring radius around the cursor center
local SPOTLIGHT_STROKE_PX   = 6     -- Ring stroke width
local SPOTLIGHT_FILL_ALPHA  = 0.40  -- Fill opacity for the ring
local SPOTLIGHT_DURATION_S  = 5     -- Max seconds before auto-dismiss (overridden by mouse move)
local SPOTLIGHT_PADDING_PX  = 12    -- Canvas padding so the stroke is never clipped

-- Cross marker parameters (shown centered on every screen that does NOT hold the cursor)
local CROSS_ARM_HALF_PX  = 60   -- Half-length of each arm; total span = 120 px
local CROSS_ARM_WIDTH_PX = 14   -- Thickness of each bar
local CROSS_STROKE_PX    = 6    -- Border stroke width, matches the circle ring
local CROSS_FILL_ALPHA   = 0.40 -- Fill opacity for the cross markers
local CROSS_PADDING_PX   = 12   -- Canvas padding so strokes are never clipped

-- Tap and teleport timing
local SPOTLIGHT_TAP_DELAY_SEC       = 0.05 -- Delay before arming the mouseMoved tap; prevents
                                           -- a programmatic warp from immediately dismissing spotlight
local SPOTLIGHT_TELEPORT_DURATION_S = 3    -- Shorter duration when triggered by teleport

-- Internal state: holds the active spotlight dismiss callback for uniqueness enforcement
local _spotlight_dismiss = nil





-- ============================================
-- ============================================
-- ======= 1/ Mouse & Display Utilities =======
-- ============================================
-- ============================================

--- Teleports the mouse cursor to the center of the next screen (cycles through all screens).
--- Shows a 1-second spotlight at the destination so the cursor is easy to locate.
--- Notifies the user when only one screen is available.
function M.teleport_mouse()
	local ok_cur, current = pcall(hs.mouse.getCurrentScreen)
	if not ok_cur or not current then
		Logger.warn(LOG, "teleport_mouse: could not determine current screen.")
		return
	end

	local all = hs.screen.allScreens()
	if #all < 2 then
		notifications.notify(i18n.get("shortcuts.no_other_monitor"), nil, "warning")
		Logger.info(LOG, "teleport_mouse: single screen — nothing to do.")
		return
	end

	-- Find the next screen in the list, wrapping around
	local target     = nil
	local current_id = current:id()
	for i, s in ipairs(all) do
		if s:id() == current_id then
			target = all[(i % #all) + 1]
			break
		end
	end
	if not target then target = all[1] end

	local f        = target:frame()
	local ok_move = MouseControl.setPos(
		f.x + math.floor(f.w / 2),
		f.y + math.floor(f.h / 2)
	)

	if ok_move then
		Logger.info(LOG, "Mouse teleported to screen '%s'.", target:name() or "unknown")
		-- Brief spotlight so the cursor is immediately visible at its new location
		M.spotlight_mouse(SPOTLIGHT_TELEPORT_DURATION_S)
	else
		Logger.error(LOG, "teleport_mouse: failed to set mouse position.")
	end
end

--- Locks the screen immediately using the system screensaver engine.
function M.lock_screen()
	Logger.start(LOG, "Locking screen…")
	local ok, err = pcall(hs.caffeinate.lockScreen)
	if ok then
		Logger.success(LOG, "Screen locked.")
	else
		Logger.error(LOG, "lock_screen: failed — %s.", tostring(err))
	end
end

--- Opens the macOS Character Viewer (emoji picker) via the system shortcut.
--- Mirrors Windows' native Win + . behaviour for cross-platform parity.
function M.open_emoji_picker()
	Logger.start(LOG, "Opening emoji picker…")
	local ok, err = pcall(function()
		SyntheticInput.emit_key_stroke({"ctrl", "cmd"}, "space", 0)
	end)
	if ok then
		Logger.success(LOG, "Emoji picker triggered.")
	else
		Logger.error(LOG, "open_emoji_picker: failed — %s.", tostring(err))
	end
end

--- Toggles display mirroring using CoreGraphics via an inline Python script.
--- CGBeginDisplayConfiguration / CGConfigureDisplayMirrorOfDisplay are the
--- official public APIs for this; the hs.eventtap Cmd+F1 approach is unreliable
--- because macOS maps that shortcut through the media-key layer, which Hammerspoon
--- cannot dependably replicate.
function M.toggle_display_mirror()
	Logger.start(LOG, "Toggling display mirror via CoreGraphics…")

	local py = [[
import ctypes, sys
CG = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
cg = ctypes.cdll.LoadLibrary(CG)
cg.CGGetOnlineDisplayList.restype = ctypes.c_int32
cg.CGMainDisplayID.restype        = ctypes.c_uint32
cg.CGDisplayIsInMirrorSet.restype = ctypes.c_bool
MAX = 16
n   = ctypes.c_uint32(0)
ids = (ctypes.c_uint32 * MAX)()
cg.CGGetOnlineDisplayList(MAX, ids, ctypes.byref(n))
count = n.value
if count < 2:
    print("single_screen")
    sys.exit(0)
main      = cg.CGMainDisplayID()
mirroring = any(cg.CGDisplayIsInMirrorSet(ids[i]) for i in range(count) if ids[i] != main)
cfg = ctypes.c_void_p()
cg.CGBeginDisplayConfiguration(ctypes.byref(cfg))
if mirroring:
    for i in range(count):
        if ids[i] != main:
            cg.CGConfigureDisplayMirrorOfDisplay(cfg, ids[i], 0)
    cg.CGCompleteDisplayConfiguration(cfg, 1)
    print("mirror_disabled")
else:
    for i in range(count):
        if ids[i] != main:
            cg.CGConfigureDisplayMirrorOfDisplay(cfg, ids[i], main)
    cg.CGCompleteDisplayConfiguration(cfg, 1)
    print("mirror_enabled")
]]

	local tmpfile  = "/tmp/_hs_mirror_toggle.py"
	local ok_write = pcall(function()
		local f = io.open(tmpfile, "w")
		if not f then error("io.open failed") end
		f:write(py)
		f:close()
	end)
	if not ok_write then
		Logger.error(LOG, "toggle_display_mirror: could not write Python script to temp file.")
		return
	end

	-- Asynchronous: a Python interpreter start plus a display-configuration round
	-- trip is hundreds of milliseconds, and this runs from a shortcut — the
	-- blocking form froze every keystroke for that whole window.
	ShellRunner.spawn(PYTHON_BIN, { tmpfile }, function(exit_code, stdout, stderr)
		if exit_code ~= 0 then
			Logger.error(LOG, "toggle_display_mirror: Python exited with code %s — %s.",
				tostring(exit_code), (tostring(stderr):gsub("%s+$", "")))
			return
		end
		local result = (stdout or ""):match("(%S+)")
		if result == "mirror_enabled" then
			Logger.success(LOG, "Display mirroring enabled.")
		elseif result == "mirror_disabled" then
			Logger.success(LOG, "Display mirroring disabled.")
		elseif result == "single_screen" then
			Logger.info(LOG, "Display mirror toggle: single screen — nothing to do.")
		else
			Logger.error(LOG, "toggle_display_mirror: unexpected Python output: '%s'.",
				(tostring(stdout):gsub("\n", " ")))
		end
	end).start()
end

--- Builds and immediately shows a yellow × marker centered on the given screen.
--- The × is defined as a 12-vertex closed polygon with the arm tips computed
--- directly in diagonal coordinates, so each tip edge is perfectly perpendicular
--- to its arm direction (flat square ends, no triangular artefacts).
--- Single polygon = uniform fill, stroke only on the outer perimeter.
--- @param screen userdata The hs.screen to draw on.
--- @return userdata|nil The hs.canvas object, or nil on error.
local function create_cross_canvas(screen)
	local f    = screen:frame()
	local H    = CROSS_ARM_HALF_PX
	local W    = CROSS_ARM_WIDTH_PX
	local pad  = CROSS_PADDING_PX
	local hw   = W / 2
	local side = H * 2 + pad * 2
	local cx   = f.x + math.floor((f.w - side) / 2)
	local cy   = f.y + math.floor((f.h - side) / 2)

	local ok_c, cv = pcall(hs.canvas.new, {x = cx, y = cy, w = side, h = side})
	if not ok_c or not cv then
		Logger.warn(LOG, "create_cross_canvas: failed to create canvas for screen '%s'.", screen:name() or "?")
		return nil
	end

	local ox  = side / 2
	local oy  = side / 2
	local sq2 = math.sqrt(2)

	-- Each × arm points along a 45° diagonal. The arm tip edges are perpendicular
	-- to that diagonal, so they are themselves diagonal — giving flat square ends.
	-- The three distances (in axis-aligned pixels from the centre) that fully
	-- describe the shape:
	local tip_far  = (H + hw) / sq2  -- far  corner of each arm tip (cardinal extent)
	local tip_near = (H - hw) / sq2  -- near corner of each arm tip (cardinal extent)
	local concave  = hw * sq2        -- concave inner corner (cardinal extent)

	-- 12 vertices, clockwise from the upper-left corner of the NE arm tip.
	-- The pattern repeats 4× with 90° rotational symmetry.
	local pts = {
		{x = ox + tip_near, y = oy - tip_far },  --  1: NE tip — leading corner (CW)
		{x = ox + tip_far,  y = oy - tip_near},  --  2: NE tip — trailing corner
		{x = ox + concave,  y = oy            },  --  3: right inner concave corner
		{x = ox + tip_far,  y = oy + tip_near},  --  4: SE tip — leading corner
		{x = ox + tip_near, y = oy + tip_far },  --  5: SE tip — trailing corner
		{x = ox,            y = oy + concave  },  --  6: bottom inner concave corner
		{x = ox - tip_near, y = oy + tip_far },  --  7: SW tip — leading corner
		{x = ox - tip_far,  y = oy + tip_near},  --  8: SW tip — trailing corner
		{x = ox - concave,  y = oy            },  --  9: left inner concave corner
		{x = ox - tip_far,  y = oy - tip_near},  -- 10: NW tip — leading corner
		{x = ox - tip_near, y = oy - tip_far },  -- 11: NW tip — trailing corner
		{x = ox,            y = oy - concave  },  -- 12: top inner concave corner
	}

	cv[1] = {
		type        = "segments",
		closed      = true,
		action      = "strokeAndFill",
		fillColor   = {red = CROSS_COLOR.red, green = CROSS_COLOR.green, blue = CROSS_COLOR.blue, alpha = CROSS_FILL_ALPHA},
		strokeColor = {red = CROSS_COLOR.red, green = CROSS_COLOR.green, blue = CROSS_COLOR.blue, alpha = OVERLAY_STROKE_ALPHA},
		strokeWidth = CROSS_STROKE_PX,
		coordinates = pts,
	}

	cv:level(hs.canvas.windowLevels.overlay)
	cv:show()
	return cv
end

--- Shows a yellow filled ring around the current mouse position and a yellow cross
--- centered on every other connected screen.
--- Auto-dismisses after `duration_s` seconds OR immediately when the mouse moves.
--- All overlays (circle + crosses) are dismissed together.
--- Calling this while a spotlight is already active cancels the previous one first,
--- so canvases never stack and opacity never compounds.
--- @param duration_s number|nil Override for the auto-dismiss delay (defaults to SPOTLIGHT_DURATION_S).
function M.spotlight_mouse(duration_s)
	-- Enforce uniqueness: cancel any previously active spotlight before creating a new one
	if _spotlight_dismiss then
		pcall(_spotlight_dismiss)
		_spotlight_dismiss = nil
	end

	local dur = (type(duration_s) == "number" and duration_s > 0) and duration_s or SPOTLIGHT_DURATION_S

	local ok, pos = pcall(hs.mouse.absolutePosition)
	if not ok or not pos then
		Logger.error(LOG, "spotlight_mouse: failed to read mouse position.")
		return
	end

	local r   = SPOTLIGHT_RADIUS_PX
	local pad = SPOTLIGHT_PADDING_PX
	local d   = r * 2

	-- Circle canvas on the screen holding the cursor
	local ok_c, circle = pcall(hs.canvas.new, {
		x = math.floor(pos.x) - r - pad,
		y = math.floor(pos.y) - r - pad,
		w = d + pad * 2,
		h = d + pad * 2,
	})
	if not ok_c or not circle then
		Logger.error(LOG, "spotlight_mouse: failed to create circle canvas.")
		return
	end

	circle[1] = {
		type        = "oval",
		fillColor   = {red = SPOTLIGHT_COLOR.red, green = SPOTLIGHT_COLOR.green, blue = SPOTLIGHT_COLOR.blue, alpha = SPOTLIGHT_FILL_ALPHA},
		strokeColor = {red = SPOTLIGHT_COLOR.red, green = SPOTLIGHT_COLOR.green, blue = SPOTLIGHT_COLOR.blue, alpha = OVERLAY_STROKE_ALPHA},
		strokeWidth = SPOTLIGHT_STROKE_PX,
		frame       = {x = pad, y = pad, w = d, h = d},
	}
	circle:level(hs.canvas.windowLevels.overlay)
	circle:show()

	-- Cross canvases on every screen that does NOT hold the cursor
	local crosses      = {}
	local ok_ms, ms    = pcall(hs.mouse.getCurrentScreen)
	local mouse_scr_id = (ok_ms and ms) and ms:id() or nil
	for _, s in ipairs(hs.screen.allScreens()) do
		if s:id() ~= mouse_scr_id then
			local cv = create_cross_canvas(s)
			if cv then table.insert(crosses, cv) end
		end
	end

	Logger.debug(LOG, "Mouse spotlight shown at (%.0f, %.0f); %d cross(es); %.1fs duration.", pos.x, pos.y, #crosses, dur)

	-- Shared dismissal guard: cleans up all overlays, watchers, and cursor zoom exactly once
	local dismissed = false
	local timer_ref = nil
	local move_tap  = nil

	local function dismiss()
		if dismissed then return end
		dismissed = true
		_spotlight_dismiss = nil
		if timer_ref then pcall(function() timer_ref:stop() end); timer_ref = nil end
		if move_tap  then pcall(function() move_tap:stop()  end); move_tap  = nil end
		pcall(function() circle:delete() end)
		for _, cv in ipairs(crosses) do pcall(function() cv:delete() end) end
		Logger.debug(LOG, "Mouse spotlight dismissed.")
	end

	_spotlight_dismiss = dismiss

	-- Arm the mouseMoved tap after a brief delay so a programmatic cursor warp
	-- (e.g. from teleport_mouse) does not fire and immediately dismiss the spotlight
	hs.timer.doAfter(SPOTLIGHT_TAP_DELAY_SEC, function()
		if dismissed then return end
		local ok_tap, tap
		ok_tap, tap = pcall(hs.eventtap.new, {hs.eventtap.event.types.mouseMoved}, function(e)
			if EventTapGuard.handle_disabled(e, tap, "shortcuts.spotlight_mouse") then return false end
			dismiss()
			return false  -- Do not consume the event; the cursor must keep moving normally
		end)
		if ok_tap and tap then
			move_tap = tap
			pcall(function() move_tap:start() end)
		else
			Logger.warn(LOG, "spotlight_mouse: could not create move watcher — timeout only.")
		end
	end)

	-- Fallback: auto-dismiss after the configured duration even without movement
	timer_ref = hs.timer.doAfter(dur, dismiss)
end

return M
