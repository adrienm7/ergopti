--- modules/shortcuts/actions/system.lua

--- ==============================================================================
--- MODULE: Shortcuts — System Actions
--- DESCRIPTION:
--- Implements system-level shortcuts: keep-awake (mouse jiggler), pixel color
--- copy, interactive screenshot, instant window screenshot, volume control via
--- layer key + scroll wheel, mouse teleport, display mirror toggle, and mouse
--- spotlight (yellow ring indicator).
---
--- FEATURES & RATIONALE:
--- 1. Keep-Awake Jitter: Moves the mouse by small random offsets and taps an
---    unmapped key (F18) so the OS considers the session active without touching
---    any power-management settings permanently.
--- 2. EventTap Factories: bind_* functions return a fake-hotkey object exposing
---    a :delete() method, letting the bindings registry manage all shortcut
---    types uniformly, whether hs.hotkey or hs.eventtap underneath.
--- 3. Display Mirror: Calls CGBeginDisplayConfiguration / CGConfigureDisplayMirrorOfDisplay
---    via an inline Python script, bypassing keyboard shortcuts entirely so mirroring
---    toggles reliably regardless of F-key mode or system preferences.
--- ==============================================================================

local M = {}

local hs            = hs
local timer         = hs.timer
local eventtap      = hs.eventtap
local pasteboard    = hs.pasteboard
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")

local LOG = "shortcuts.actions.system"

local ok_gestures, gestures = pcall(require, "modules.gestures")
if not ok_gestures then gestures = nil end




-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Physical key-code for the @ / # key (position-based, not character-based)
local KEYCODE_AT_HASH        = 10

-- F18 is unmapped on most keyboards; used as a secondary wake signal for the OS
local KEYCODE_F18            = "f18"

-- Keep-awake jitter parameters
local AWAKE_TICK_MIN_SEC     = 1     -- Minimum interval between mouse-jitter ticks
local AWAKE_TICK_MAX_SEC     = 5     -- Maximum interval between mouse-jitter ticks
local AWAKE_JITTER_X         = 120   -- Max horizontal pixel offset per tick
local AWAKE_JITTER_Y         = 80    -- Max vertical pixel offset per tick
local AWAKE_RETURN_DELAY_SEC = 0.2   -- Seconds to hold offset before returning to origin

-- Mouse spotlight ring parameters (circle shown on the screen that holds the cursor)
local SPOTLIGHT_RADIUS_PX   = 60    -- Outer ring radius around the cursor center
local SPOTLIGHT_STROKE_PX   = 6     -- Ring stroke width
local SPOTLIGHT_FILL_ALPHA  = 0.40  -- Yellow fill opacity
local SPOTLIGHT_DURATION_S  = 3     -- Max seconds before auto-dismiss (overridden by mouse move)
local SPOTLIGHT_PADDING_PX  = 12    -- Canvas padding so the stroke is never clipped

-- Cross marker parameters (shown centered on every screen that does NOT hold the cursor)
local CROSS_ARM_HALF_PX  = 60   -- Half-length of each arm; total span = 120 px
local CROSS_ARM_WIDTH_PX = 14   -- Thickness of each bar
local CROSS_STROKE_PX    = 6    -- Border stroke width, matches the circle ring
local CROSS_FILL_ALPHA   = 0.40 -- Yellow fill opacity, matches the circle fill
local CROSS_PADDING_PX   = 12   -- Canvas padding so strokes are never clipped

-- Tap and teleport timing
local SPOTLIGHT_TAP_DELAY_SEC       = 0.05 -- Delay before arming the mouseMoved tap; prevents
                                            -- a programmatic warp from immediately dismissing spotlight
local SPOTLIGHT_TELEPORT_DURATION_S = 1.0  -- Shorter duration when triggered by teleport

local awake_timer      = nil
local awake_alert_id   = nil
local awake_active     = false
local awake_origin_pos = nil

-- Spotlight state
local _spotlight_dismiss = nil  -- Dismiss fn for the active spotlight; nil when none active

-- Forward declaration required because schedule_awake_tick calls itself recursively
local schedule_awake_tick




-- =============================================
-- =============================================
-- ======= 2/ Keep-Awake Implementation ========
-- =============================================
-- =============================================

--- Schedules the next keep-awake tick at a random interval.
--- Each tick moves the mouse slightly around the recorded origin, then returns.
schedule_awake_tick = function()
	if not awake_active then return end

	if awake_timer and type(awake_timer.stop) == "function" then
		pcall(function() awake_timer:stop() end)
		awake_timer = nil
	end

	local interval = math.random(AWAKE_TICK_MIN_SEC, AWAKE_TICK_MAX_SEC)
	awake_timer = timer.doAfter(interval, function()
		if not awake_active then return end

		local origin = awake_origin_pos
		if not origin then
			local ok, p = pcall(hs.mouse.absolutePosition)
			if ok and p then origin = {x = p.x, y = p.y} end
		end

		if origin then
			local ox = math.random(-AWAKE_JITTER_X, AWAKE_JITTER_X)
			local oy = math.random(-AWAKE_JITTER_Y, AWAKE_JITTER_Y)
			local tx = origin.x + ox
			local ty = origin.y + oy

			-- Clamp position to the current screen boundaries
			local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
			if screen and type(screen.frame) == "function" then
				local f = screen:frame()
				tx = math.max(f.x, math.min(f.x + f.w - 1, tx))
				ty = math.max(f.y, math.min(f.y + f.h - 1, ty))
			end

			pcall(hs.mouse.absolutePosition, {x = tx, y = ty})

			timer.doAfter(AWAKE_RETURN_DELAY_SEC, function()
				if origin then pcall(hs.mouse.absolutePosition, {x = origin.x, y = origin.y}) end
			end)

			-- Tap an unmapped key as an additional OS activity signal
			pcall(eventtap.keyStroke, {}, KEYCODE_F18, 0)
		end

		schedule_awake_tick()
	end)
end

--- Toggles keep-awake mode on or off.
--- When active, jiggles the mouse periodically to prevent the display from sleeping.
function M.toggle_awake()
	if awake_active then
		awake_active = false

		if awake_timer and type(awake_timer.stop) == "function" then
			pcall(function() awake_timer:stop() end)
			awake_timer = nil
		end

		if awake_alert_id then
			pcall(hs.alert.closeSpecific, awake_alert_id)
			awake_alert_id = nil
		end

		Logger.info(LOG, "Keep-awake disabled.")
		pcall(hs.alert.show, "☕ Keep-awake désactivé", 2)
	else
		awake_active = true
		math.randomseed(os.time())

		local ok, aid = pcall(hs.alert.show, "☕ Keep-awake actif — Ctrl+M pour désactiver", math.huge)
		if ok then awake_alert_id = aid end

		-- Record the current mouse position as the jitter origin
		local ok_pos, pos = pcall(hs.mouse.absolutePosition)
		if ok_pos and pos then
			awake_origin_pos = {x = pos.x, y = pos.y}

			-- Make a small initial move so the OS registers activity immediately
			local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
			local frame  = screen and type(screen.frame) == "function" and screen:frame() or nil
			local dx     = (math.random(0, 1) == 0) and -80 or 80
			local nx     = pos.x + dx
			if frame then
				nx = math.max(frame.x, math.min(frame.x + frame.w - 1, nx))
			end
			pcall(hs.mouse.absolutePosition, {x = nx, y = pos.y})
		end

		schedule_awake_tick()
		Logger.info(LOG, "Keep-awake enabled.")
	end
end

--- Stops keep-awake cleanly; called when the bindings module shuts down.
function M.stop_awake()
	awake_active = false

	if awake_timer and type(awake_timer.stop) == "function" then
		pcall(function() awake_timer:stop() end)
		awake_timer = nil
	end

	if awake_alert_id then
		pcall(hs.alert.closeSpecific, awake_alert_id)
		awake_alert_id = nil
	end
end




-- =============================================
-- =============================================
-- ======= 3/ Pixel Color Implementation =======
-- =============================================
-- =============================================

--- Reads the hex color of the pixel at (x, y) via a minimal inline Python PNG decoder.
--- Captures a 3×3-pixel region and samples the center pixel.
--- Python is used because Hammerspoon has no native per-pixel color API.
--- @param x number X screen coordinate.
--- @param y number Y screen coordinate.
--- @return string|nil Hex color string like "#a1b2c3", or nil on failure.
local function pixel_hex_at(x, y)
	Logger.trace(LOG, "Pixel color read started…")
	local tmpfile = "/tmp/_hs_pixel_cap.png"
	local safe_x  = math.floor(tonumber(x) or 0) - 1
	local safe_y  = math.floor(tonumber(y) or 0) - 1

	local cap_cmd = string.format("screencapture -x -R \"%d,%d,3,3\" \"%s\"", safe_x, safe_y, tmpfile)
	local ok_cap  = pcall(hs.execute, cap_cmd)
	if not ok_cap then
		Logger.error(LOG, "screencapture failed — pixel read aborted.")
		return nil
	end

	local py = string.format([[python3 -c "
import struct,zlib
try:
  data=open('%s','rb').read()
  w,h=struct.unpack('>II',data[16:24])
  ct=data[25];bpp=4 if ct==6 else 3
  i,chunks=8,b''
  while i<len(data)-12:
    l=struct.unpack('>I',data[i:i+4])[0];t=data[i+4:i+8]
    if t==b'IDAT':chunks+=data[i+8:i+8+l]
    elif t==b'IEND':break
    i+=l+12
  raw=zlib.decompress(chunks)
  cx=w//2;cy=h//2;off=cy*(1+w*bpp)+1+cx*bpp
  r,g,b=raw[off],raw[off+1],raw[off+2]
  print('#%%02x%%02x%%02x' %% (r,g,b))
except Exception:
  pass
"
]], tmpfile)

	local ok_py, out = pcall(hs.execute, py)
	if ok_py and out then
		local hex = out:match("(#%x%x%x%x%x%x)")
		if hex then
			Logger.done(LOG, "Pixel color read — %s.", hex)
			return hex
		end
	end

	Logger.warn(LOG, "Python pixel extractor returned no valid hex code.")
	return nil
end

--- Reads the color of the pixel currently under the mouse cursor and copies it to the clipboard.
function M.copy_pixel_color()
	local ok, pos = pcall(hs.mouse.absolutePosition)
	if not ok or not pos then
		Logger.error(LOG, "copy_pixel_color: failed to read mouse position.")
		return
	end

	local hex = pixel_hex_at(math.floor(pos.x), math.floor(pos.y))
	if not hex then
		notifications.notify("Impossible de lire la couleur du pixel")
		return
	end

	pcall(pasteboard.setContents, hex)
	notifications.notify("Couleur copiée : " .. hex)
end

--- Launches the native macOS interactive screenshot tool and copies the result to the clipboard.
function M.interactive_screenshot()
	Logger.trace(LOG, "Interactive screenshot started…")
	local ok, task = pcall(hs.task.new,
		"/usr/sbin/screencapture",
		function(exit_code, _, _)
			if exit_code == 0 then
				notifications.notify("Capture d'écran copiée dans le presse-papiers")
				Logger.done(LOG, "Interactive screenshot completed.")
			else
				Logger.warn(LOG, "Interactive screenshot failed or was cancelled.")
			end
		end,
		{"-i", "-c"}
	)
	if ok and task then
		task:start()
	else
		Logger.error(LOG, "Failed to create screenshot task.")
	end
end




-- ==========================================
-- ==========================================
-- ======= 4/ EventTap Factory Functions ====
-- ==========================================
-- ==========================================

--- Wraps an already-started eventtap in a fake-hotkey object with a :delete() method.
--- This lets the bindings registry treat eventtaps and hs.hotkeys uniformly.
--- @param tap userdata The hs.eventtap to wrap (must already be started).
--- @return table Fake-hotkey compatible object.
local function wrap_tap(tap)
	return {
		delete = function()
			if tap and type(tap.stop) == "function" then
				pcall(function() tap:stop() end)
			end
		end
	}
end

--- Captures the frontmost window on the physical @/# key (key-code 10).
--- Uses a raw keyDown tap so the shortcut fires before macOS generates characters.
--- @return table Fake-hotkey object with :delete().
function M.bind_instant_screenshot()
	local tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
		if e:getKeyCode() ~= KEYCODE_AT_HASH then return false end

		local flags = e:getFlags()
		if flags.cmd or flags.alt or flags.ctrl or flags.shift then return false end

		local ok, w = pcall(hs.window.frontmostWindow)
		if not ok or not w then
			notifications.notify("Aucune fenêtre active")
			return true
		end

		local id       = w:id()
		local home     = os.getenv("HOME") or "~"
		local dir      = home .. "/Pictures/screenshots"
		pcall(hs.execute, "mkdir -p \"" .. dir .. "\"")

		local filename = string.format("%s/screenshot_%s.png", dir, os.date("%Y_%m_%d_%H_%M_%S"))
		pcall(hs.execute, "screencapture -l " .. id .. " \"" .. filename .. "\"")
		notifications.notify("Sauvegardé : " .. filename)
		return true
	end)
	tap:start()
	return wrap_tap(tap)
end

--- Maps F19 + scroll wheel to system volume up/down.
--- F19 is the physical "layer" key; holding it while scrolling bypasses page scroll.
--- @return table Fake-hotkey object with :delete().
function M.bind_layer_scroll()
	local layer_held  = false
	local f19_keycode = hs.keycodes.map["f19"]

	local key_tap = hs.eventtap.new(
		{hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp},
		function(event)
			if event:getKeyCode() ~= f19_keycode then return false end

			if event:getType() == hs.eventtap.event.types.keyDown then
				-- Release any in-progress left-click gesture that would conflict
				if gestures and type(gestures.isLeftClickPressed) == "function" then
					if gestures.isLeftClickPressed() then
						pcall(function() gestures.forceCleanup() end)
					end
				end
				layer_held = true
			else
				layer_held = false
			end
			return false
		end
	)

	local scroll_tap = hs.eventtap.new({hs.eventtap.event.types.scrollWheel}, function(event)
		if not layer_held then return false end

		if gestures and type(gestures.isLeftClickPressed) == "function" then
			if gestures.isLeftClickPressed() then
				pcall(function() gestures.forceCleanup() end)
			end
		end

		local delta = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
		if type(delta) ~= "number" then return false end

		local key  = delta > 0 and "SOUND_UP" or "SOUND_DOWN"
		local reps = math.max(1, math.floor(math.abs(delta)))
		for _ = 1, reps do
			pcall(function() hs.eventtap.event.newSystemKeyEvent(key, true):post() end)
			pcall(function() hs.eventtap.event.newSystemKeyEvent(key, false):post() end)
		end
		return true
	end)

	pcall(function() key_tap:start() end)
	pcall(function() scroll_tap:start() end)

	return {
		delete = function()
			if key_tap    and type(key_tap.stop)    == "function" then pcall(function() key_tap:stop() end) end
			if scroll_tap and type(scroll_tap.stop) == "function" then pcall(function() scroll_tap:stop() end) end
		end
	}
end

--- Intercepts Cmd+★ / Cmd+* and re-fires as Cmd+S, preserving any additional modifiers.
--- hs.hotkey.bind cannot reliably intercept ★ (Shift+8 on some layouts) because the
--- OS assigns the character after modifier processing; a raw tap fires first.
--- @param on_trigger function|nil Called as on_trigger(label, app_name) for shortcut logging.
--- @return table Fake-hotkey object with :delete().
function M.bind_cmd_star(on_trigger)
	local tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
		local flags = e:getFlags()
		if not flags.cmd then return false end

		local ok, ch = pcall(function() return e:getCharacters() end)
		if not ok or not ch then return false end
		if ch ~= "★" and ch ~= "*" and ch ~= "✱" then return false end

		-- Build the modifier list to re-fire the keystroke faithfully
		local mods = {}
		if flags.cmd   then table.insert(mods, "cmd")   end
		if flags.shift then table.insert(mods, "shift") end
		if flags.alt   then table.insert(mods, "alt")   end
		if flags.ctrl  then table.insert(mods, "ctrl")  end

		if type(on_trigger) == "function" then
			-- Construct the canonical label (e.g. "Cmd+Shift+S")
			local parts  = {}
			local order  = {"cmd", "ctrl", "alt", "shift"}
			local labels = {cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift"}
			for _, m in ipairs(order) do if flags[m] then table.insert(parts, labels[m]) end end
			table.insert(parts, "S")

			-- Resolve the frontmost application name for the log entry
			local ok_app, app = pcall(hs.application.frontmostApplication)
			local app_name    = (ok_app and app) and app:title() or nil
			if not app_name or app_name == "" then
				local win  = hs.window.focusedWindow()
				local wa   = win and win:application()
				app_name   = (wa and wa:title()) or "Unknown"
			end

			pcall(on_trigger, table.concat(parts, "+"), app_name)
		end

		if #mods > 0 then hs.eventtap.keyStroke(mods, "s") end
		return true
	end)
	tap:start()
	return wrap_tap(tap)
end






-- ==============================================
-- ==============================================
-- ======= 5/ Mouse & Display Utilities =========
-- ==============================================
-- ==============================================

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
		notifications.notify("Aucun autre moniteur détecté")
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
	local ok_move  = pcall(hs.mouse.absolutePosition, {
		x = f.x + math.floor(f.w / 2),
		y = f.y + math.floor(f.h / 2),
	})

	if ok_move then
		Logger.info(LOG, "Mouse teleported to screen '%s'.", target:name() or "unknown")
		-- Brief spotlight so the cursor is immediately visible at its new location
		M.spotlight_mouse(SPOTLIGHT_TELEPORT_DURATION_S)
	else
		Logger.error(LOG, "teleport_mouse: failed to set mouse position.")
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

	local ok_py, out = pcall(hs.execute, "python3 \"" .. tmpfile .. "\" 2>&1")
	if not ok_py or not out then
		Logger.error(LOG, "toggle_display_mirror: Python execution failed.")
		return
	end

	local result = (out or ""):match("(%S+)")
	if result == "mirror_enabled" then
		Logger.success(LOG, "Display mirroring enabled.")
	elseif result == "mirror_disabled" then
		Logger.success(LOG, "Display mirroring disabled.")
	elseif result == "single_screen" then
		Logger.info(LOG, "Display mirror toggle: single screen — nothing to do.")
	else
		Logger.error(LOG, "toggle_display_mirror: unexpected Python output: '%s'.", tostring(out):gsub("\n", " "))
	end
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

	local yellow  = {red = 1, green = 0.85, blue = 0}
	local ox      = side / 2
	local oy      = side / 2
	local sq2     = math.sqrt(2)

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
		fillColor   = {red = yellow.red, green = yellow.green, blue = yellow.blue, alpha = CROSS_FILL_ALPHA},
		strokeColor = {red = yellow.red, green = yellow.green, blue = yellow.blue, alpha = 0.9},
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

	local yellow = {red = 1, green = 0.85, blue = 0}
	circle[1] = {
		type        = "oval",
		fillColor   = {red = yellow.red, green = yellow.green, blue = yellow.blue, alpha = SPOTLIGHT_FILL_ALPHA},
		strokeColor = {red = yellow.red, green = yellow.green, blue = yellow.blue, alpha = 0.9},
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
		local ok_tap, tap = pcall(hs.eventtap.new, {hs.eventtap.event.types.mouseMoved}, function()
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
