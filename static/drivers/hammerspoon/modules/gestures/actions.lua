--- modules/gestures/actions.lua

--- ==============================================================================
--- MODULE: Gestures Actions Registry
--- DESCRIPTION:
--- Maps internal logic representations to human-readable labels and executable
--- functions. Handles macOS window, space, and volume navigations.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Logic: Isolates action definitions from gesture detection.
--- 2. Scalable Actions: Supports both single-fire and continuous adjustments.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "gestures.actions"

local leftClickPressed = false
local mouseEventTap    = nil





-- =========================================
-- =========================================
-- ======= 1/ Interaction Primitives =======
-- =========================================
-- =========================================

--- Safely terminates the custom selection drag mode.
function M.force_cleanup()
	Logger.debug(LOG, "Forcefully disabling drag selection mode…")
	if mouseEventTap and type(mouseEventTap.stop) == "function" then
		pcall(function() mouseEventTap:stop() end)
		mouseEventTap = nil
	end
	
	if leftClickPressed then
		pcall(function()
			hs.eventtap.event.newMouseEvent(
				hs.eventtap.event.types.leftMouseUp,
				hs.mouse.absolutePosition()
			):post()
		end)
	end
	leftClickPressed = false
	Logger.info(LOG, "Drag selection mode forcefully disabled.")
end

--- Toggles click-and-drag selection mode mimicking physical trackpad clicks.
function M.toggle_selection()
	if leftClickPressed then M.force_cleanup(); return end
	
	Logger.debug(LOG, "Enabling drag selection mode…")
	pcall(function()
		hs.eventtap.event.newMouseEvent(
			hs.eventtap.event.types.leftMouseDown,
			hs.mouse.absolutePosition()
		):post()
	end)
	leftClickPressed = true
	
	local evTypes = hs.eventtap.event.types
	mouseEventTap = hs.eventtap.new(
		{ evTypes.mouseMoved, evTypes.leftMouseDragged, evTypes.leftMouseUp },
		function(e)
			local t = e:getType()
			if t == evTypes.leftMouseDragged then
				pcall(function()
					hs.eventtap.event.newMouseEvent(evTypes.leftMouseDragged, e:location()):post()
				end)
				return true
			elseif t == evTypes.leftMouseUp then
				hs.timer.doAfter(0, M.force_cleanup)
				return true
			end
			return false
		end)
		
	if mouseEventTap then 
		pcall(function() mouseEventTap:start() end) 
		Logger.info(LOG, "Drag selection mode enabled.")
	end
end

--- Triggers macOS Dictionary Lookup (Cmd+Ctrl+D).
function M.trigger_lookup()
	Logger.debug(LOG, "Triggering dictionary lookup…")
	pcall(function() hs.eventtap.keyStroke({"ctrl", "cmd"}, "d", 0) end)
	Logger.info(LOG, "Dictionary lookup triggered.")
end

--- Posts system media keys safely.
--- @param name string The system key name.
local function sysKey(name)
	pcall(function()
		hs.eventtap.event.newSystemKeyEvent(name, true):post()
		hs.eventtap.event.newSystemKeyEvent(name, false):post()
	end)
end

--- Cycles through standard windows of the frontmost application.
--- @param goNext boolean True to navigate forward, false to navigate backward.
local function winNav(goNext)
	local ok, app = pcall(hs.application.frontmostApplication)
	if not ok or not app then return end
	
	local ok_wins, wins = pcall(function() return app:allWindows() end)
	if not ok_wins or type(wins) ~= "table" then return end
	
	local visible = {}
	for _, w in ipairs(wins) do
		if w:isStandard() and not w:isMinimized() then table.insert(visible, w) end
	end
	
	if #visible <= 1 then return end
	table.sort(visible, function(a, b) return a:id() < b:id() end)
	
	local ok_cur, cur = pcall(hs.window.focusedWindow)
	local idx = 1
	for i, w in ipairs(visible) do
		if ok_cur and cur and w:id() == cur:id() then idx = i; break end
	end
	
	local target_idx = goNext and (idx % #visible + 1) or ((idx - 2) % #visible + 1)
	pcall(function() visible[target_idx]:focus() end)
end

--- Cycles through macOS Spaces.
--- @param goNext boolean True to navigate forward, false to navigate backward.
local function spaceNav(goNext)
	local ok, spaces = pcall(function() return require("hs.spaces") end)
	if ok and type(spaces) == "table" then
		local screen = hs.screen.mainScreen()
		local uuid = screen and screen:getUUID()
		
		if uuid then
			local ok_all, all = pcall(function() return spaces.allSpaces() end)
			if ok_all and type(all) == "table" and all[uuid] and #all[uuid] > 0 then
				local sps = all[uuid]
				local active = nil
				
				if type(spaces.activeSpace) == "function" then
					pcall(function() active = spaces.activeSpace() end)
				else
					local fw = hs.window.frontmostWindow()
					if fw and type(spaces.windowSpaces) == "function" then
						local okw, ws = pcall(function() return spaces.windowSpaces(fw) end)
						if okw and type(ws) == "table" and #ws > 0 then active = ws[1] end
					end
				end
				
				if active then
					local idx = nil
					for i, id in ipairs(sps) do 
						if tostring(id) == tostring(active) then idx = i; break end 
					end
					
					if idx then
						local total = #sps
						local delta = goNext and 1 or -1
						local newIdx = ((idx - 1 + delta) % total) + 1
						pcall(function() hs.eventtap.keyStroke({"ctrl"}, tostring(newIdx), 0) end)
						return
					end
				end
			end
		end
	end
	
	-- Absolute fallback via AppleScript using raw keycodes (123=Left, 124=Right)
	pcall(hs.osascript.applescript, string.format(
		"tell application \"System Events\" to key code %d using {control down}",
		goNext and 124 or 123
	))
end





-- ==================================
-- ==================================
-- ======= 2/ Action Registry =======
-- ==================================
-- ==================================

local AX, SG = {}, {}
local function ax(n, lbl, p, nx, scalable) AX[n] = {label = lbl, prev = p, next = nx, scalable = scalable} end
local function sg(n, lbl, fn)              SG[n] = {label = lbl, fn = fn} end

-- Axis actions (prev / next) — scalable=true for continuous actions
ax("tabs",       "Onglets",
	function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end,
	function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end)

ax("windows",    "Fenêtres",
	function() winNav(false) end, 
	function() winNav(true) end)

ax("spaces",     "Spaces",
	function() spaceNav(false) end, 
	function() spaceNav(true) end)

ax("volume",     "Volume",
	function() sysKey("SOUND_DOWN") end, 
	function() sysKey("SOUND_UP") end, true)

ax("brightness", "Luminosité",
	function() sysKey("BRIGHTNESS_DOWN") end, 
	function() sysKey("BRIGHTNESS_UP") end, true)

ax("tracks",     "Pistes",
	function() sysKey("PREVIOUS") end, 
	function() sysKey("NEXT") end)

ax("words",      "Mots",
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "left") end,
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "right") end, true)

ax("lines",      "Lignes",
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end,
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end, true)

ax("line_bounds","Ligne (début/fin)",
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end,
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end)

ax("paragraphs", "Paragraphes",
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end,
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end, true)

ax("document",   "Document (début/fin)",
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end,
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)

-- Single actions
sg("none",             "Désactivé",            function() end)
sg("selection_toggle", "Toggle sélection",     M.toggle_selection)
sg("lookup",           "Définition du mot",    M.trigger_lookup)

sg("tab_new",          "Nouvel onglet",        function() pcall(hs.eventtap.keyStroke, {"cmd"}, "t") end)
sg("tab_close",        "Fermer onglet",        function() pcall(hs.eventtap.keyStroke, {"cmd"}, "w") end)
sg("tab_prev",         "Onglet précédent",     function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end)
sg("tab_next",         "Onglet suivant",       function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end)

sg("win_prev",         "Fenêtre précédente",   function() winNav(false) end)
sg("win_next",         "Fenêtre suivante",     function() winNav(true) end)

sg("space_prev",       "Space précédent",      function() spaceNav(false) end)
sg("space_next",       "Space suivant",        function() spaceNav(true) end)

sg("mission_control",  "Mission Control",      function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 160") end)
sg("app_expose",       "App Exposé",           function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 125 using {control down}") end)

sg("vol_up",           "Volume +",             function() sysKey("SOUND_UP") end)
sg("vol_down",         "Volume -",             function() sysKey("SOUND_DOWN") end)

sg("brightness_up",    "Luminosité +",         function() sysKey("BRIGHTNESS_UP") end)
sg("brightness_down",  "Luminosité -",         function() sysKey("BRIGHTNESS_DOWN") end)

sg("mute",             "Muet/Unmute",          function() sysKey("MUTE") end)
sg("track_play",       "Lecture/Pause",        function() sysKey("PLAY") end)
sg("track_next",       "Piste suivante",       function() sysKey("NEXT") end)
sg("track_prev",       "Piste précédente",     function() sysKey("PREVIOUS") end)

sg("word_prev",        "Mot précédent",        function() pcall(hs.eventtap.keyStroke, {"alt"}, "left") end)
sg("word_next",        "Mot suivant",          function() pcall(hs.eventtap.keyStroke, {"alt"}, "right") end)

sg("line_start",       "Début de ligne",       function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end)
sg("line_end",         "Fin de ligne",         function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end)

sg("para_prev",        "Paragraphe précédent", function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end)
sg("para_next",        "Paragraphe suivant",   function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end)

sg("doc_start",        "Début du document",    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end)
sg("doc_end",          "Fin du document",      function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

M.AX_NAMES = {
	"none", "tabs", "windows", "spaces",
	"volume", "brightness", "tracks",
	"words", "lines", "line_bounds", "paragraphs", "document",
}

M.SG_NAMES = {
	"none", "selection_toggle", "lookup",
	"tab_new", "tab_close", "tab_prev", "tab_next",
	"win_prev", "win_next", "space_prev", "space_next",
	"mission_control", "app_expose",
	"vol_up", "vol_down", "brightness_up", "brightness_down", "mute",
	"track_play", "track_next", "track_prev",
	"word_prev", "word_next", "line_start", "line_end",
	"para_prev", "para_next", "doc_start", "doc_end",
}

--- Retrieves the localized label for a given action ID.
--- @param name string The action ID.
--- @return string The human-readable label.
function M.get_label(name)
	if not name or name == "none" then return "Désactivé" end
	if AX[name] then return AX[name].label end
	if SG[name] then return SG[name].label end
	return name
end

--- Executes a single-fire action based on its identifier.
--- @param name string The action ID.
function M.execute_single(name)
	local s = SG[name]
	if s and type(s.fn) == "function" then
		Logger.debug(LOG, string.format("Executing single action: %s…", name))
		pcall(s.fn)
		Logger.info(LOG, string.format("Action %s executed successfully.", name))
	end
end

--- Executes an axis-based action (forward or backward).
--- @param name string The action ID.
--- @param goNext boolean The direction to move.
function M.execute_axis(name, goNext)
	local a = AX[name]
	if not a then return end
	local fn = goNext and a.next or a.prev
	if type(fn) == "function" then
		Logger.debug(LOG, string.format("Executing axis action: %s (direction: %s)…", name, tostring(goNext)))
		pcall(fn)
		Logger.info(LOG, string.format("Axis action %s executed successfully.", name))
	end
end

--- Checks if an action scales continuously.
--- @param name string The action ID.
--- @return boolean True if scalable.
function M.is_scalable(name)
	local a = AX[name]
	return a and a.scalable == true
end

--- Returns whether the fake trackpad drag mode is currently active.
--- @return boolean True if active.
function M.is_left_click_pressed()
	return leftClickPressed
end

return M
