--- ui/wpm/tray_readout.lua

--- ==============================================================================
--- MODULE: WPM Tray Readout (Linux)
--- DESCRIPTION:
--- The live typing speed in the panel, beside the Ergopti+ icon: the Linux
--- counterpart of the macOS menu bar readout. A second tray item that appears
--- while the user types, shows the number on the source's colour, and leaves
--- the panel when typing stops.
---
--- FEATURES & RATIONALE:
--- 1. An icon, not a label. A StatusNotifier label is drawn by some panels and
---    ignored by others (KDE among them); an icon is drawn by all of them, so
---    the number is painted into the icon itself.
--- 2. Everything it decides is shared: the label, the colour, when to show —
---    _shared/lua/wpm_widget/model.lua, the same code the macOS menu bar
---    readout runs, from the same canon.
--- 3. Two icon files, alternated. Panels cache an icon by its path, so writing
---    a new number to the same file does not always redraw it; a new path does.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Constants = require("infra.wpm_constants")
local Timings   = require("infra.timings")
local Manifest  = require("infra.manifest_reader")
local Preferences = require("infra.metrics_preferences")
local ConfigPaths = require("infra.config_paths")
local Shell     = require("adapters.shell_runner")
local Model     = require("wpm_widget.model")
local Widget    = require("ui.wpm.widget")

local LOG = "ui.wpm.tray_readout"

local PREF_PATHS = {
	visible = "metrics.wpm_menubar_visible",
	colors = "metrics.wpm_menubar_colors",
}


local ITEM_ID = "ergopti-plus-wpm"
local UPDATE_S = Timings.sec("ui", "wpm_menubar_update_ms")

-- The icon's side in pixels: twice a 22 px panel slot, so it stays sharp on a
-- HiDPI panel and is scaled down cleanly on a standard one.
local ICON_PX = 44
-- The number's largest size in the icon, and the inset it keeps from the edges.
local ICON_FONT_PX = 24
local ICON_INSET_PX = 3
-- The icon's corner radius.
local ICON_RADIUS_PX = 8

local function shipped(path)
	local value = Manifest.default_for(path)
	if type(value) ~= "boolean" then error("no boolean manifest default for " .. path) end
	return value
end

local DEFAULTS = {
	visible = shipped("metrics.wpm_menubar_visible"),
	colors = shipped("metrics.wpm_menubar_colors"),
}

local _state = {
	running = false,
	use_colors = DEFAULTS.colors,
	handle = nil,
	last_update_s = nil,
	last_key = nil,
	flip = false,
	presentation = nil,
}

-- The tray backend and the icon painter; replaceable by tests.
local _tray = nil
local _painter = nil
local _restore_debt = nil
local ensure_item

local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end




-- =========================================
-- =========================================
-- ======= 1/ Choices ======================
-- =========================================
-- =========================================

--- Persists one canonical sparse boolean.
--- @param key string Readout preference name.
--- @param value boolean Desired value.
--- @return boolean committed
local function store_bool(key, value)
	return Preferences.set(assert(PREF_PATHS[key]), value)
end

local function tray()
	if _tray then return _tray end
	local ok, Indicator = pcall(require, "platform.tray.appindicator")
	if not ok or type(Indicator) ~= "table" then return nil end
	_tray = Indicator
	return _tray
end




-- =========================================
-- =========================================
-- ======= 2/ The icon =====================
-- =========================================
-- =========================================

--- Paints the readout into a PNG: the number on a rounded fill.
--- @param frame table From Model.menubar_frame().
--- @param path string
--- @return boolean
local function paint_png(frame, path)
	local ok_lgi, lgi = pcall(require, "lgi")
	if not ok_lgi then return false end
	local cairo = lgi.cairo
	local Pango = lgi.require("Pango")
	local PangoCairo = lgi.require("PangoCairo")
	local surface = cairo.ImageSurface.create("ARGB32", ICON_PX, ICON_PX)
	local cr = cairo.Context.create(surface)
	local fill = frame.background or frame.neutral_background
	local alpha = frame.background and frame.background_alpha or 1
	local rgb = Model.rgb(fill)
	local pi = math.pi
	local r = ICON_RADIUS_PX
	cr:new_sub_path()
	cr:arc(ICON_PX - r, r, r, -pi / 2, 0)
	cr:arc(ICON_PX - r, ICON_PX - r, r, 0, pi / 2)
	cr:arc(r, ICON_PX - r, r, pi / 2, pi)
	cr:arc(r, r, r, pi, 3 * pi / 2)
	cr:close_path()
	cr:set_source_rgba(rgb.red, rgb.green, rgb.blue, alpha)
	cr:fill()
	local layout = PangoCairo.create_layout(cr)
	-- Greyscale edges: a panel scales and composites the icon, where subpixel
	-- antialiasing shows as colour fringes.
	local options = cairo.FontOptions.create()
	options:set_antialias("GRAY")
	PangoCairo.context_set_font_options(layout:get_context(), options)
	layout:context_changed()
	local px = ICON_FONT_PX
	local width, height
	repeat
		local description = Pango.FontDescription.from_string("Sans Bold")
		description:set_absolute_size(px * Pango.SCALE)
		layout:set_font_description(description)
		layout:set_text(frame.number, -1)
		local _, logical = layout:get_pixel_extents()
		width, height = logical.width, logical.height
		px = px - 1
	until width <= ICON_PX - 2 * ICON_INSET_PX or px < 8
	local text = Model.rgb(frame.text)
	cr:set_source_rgba(text.red, text.green, text.blue, 1)
	cr:move_to((ICON_PX - width) / 2, (ICON_PX - height) / 2)
	PangoCairo.show_layout(cr, layout)
	return surface:write_to_png(path) == "SUCCESS"
end

local function icon_dir()
	return ConfigPaths.data("tray_readout")
end

--- Writes the icon for `frame` and returns its path.
--- @param frame table
--- @return string|nil
local function write_icon(frame)
	local dir = icon_dir()
	if not Shell.run("mkdir -p " .. Shell.quote(dir)) then
		Logger.error(LOG, "Cannot create '%s' — no tray readout icon.", dir)
		return nil
	end
	_state.flip = not _state.flip
	local path = dir .. (_state.flip and "/wpm-a.png" or "/wpm-b.png")
	local painter = _painter or paint_png
	local ok, written = pcall(painter, frame, path)
	if not ok or written ~= true then
		Logger.error(LOG, "The tray readout icon could not be painted: %s.", tostring(ok and "refused" or written))
		return nil
	end
	return path
end




-- =========================================
-- =========================================
-- ======= 3/ Lifecycle ====================
-- =========================================
-- =========================================

--- @return boolean
function M.is_running()
	return _state.running
end

local function remove_item()
	local Tray = tray()
	if _state.handle then
		if not Tray then return false end
		local called, removed = pcall(Tray.remove_item, _state.handle)
		if not called or removed ~= true then return false end
	end
	_state.handle = nil
	_state.last_key = nil
	_state.presentation = nil
	return true
end

local function start_readout(persist)
	if _state.running then return true end
	if not Constants.load() then
		Logger.error(LOG, "The shared canon could not be read — the tray readout stays off.")
		return false
	end
	if persist and not store_bool("visible", true) then
		Logger.error(LOG, "The visible state could not be persisted — the tray readout stays off.")
		return false
	end
	_state.running = true
	_state.last_update_s = nil
	Logger.info(LOG, "WPM tray readout started.")
	return true
end

--- Applies the persisted choices at boot.
--- @return boolean True when the readout is running after this call.
function M.restore()
	if _restore_debt or not Preferences.admit() then return false end
	local preferences = Preferences.snapshot()
	_state.use_colors = preferences[PREF_PATHS.colors]
	if not preferences[PREF_PATHS.visible] then return false end
	return start_readout(false)
end

function M.start()
	if _restore_debt or not Preferences.admit() then return false end
	return start_readout(true)
end

--- Captures choices and presentation independently of the mutable native handle.
--- @return table snapshot Detached runtime state.
function M.configuration_snapshot()
	if _restore_debt then return nil end
	local copy = {}
	for key, value in pairs(_state) do
		if key ~= "handle" then copy[key] = clone(value) end
	end
	return copy
end

--- Applies native presentation without ordinary persistence or metric mutation.
--- @param candidate table Detached configuration snapshot.
--- @return boolean acknowledged Native presentation settled.
function M.apply_configuration(candidate)
	if type(candidate) ~= "table" or type(candidate.running) ~= "boolean"
		or type(candidate.use_colors) ~= "boolean" then return false end
	local presentation = candidate.presentation
	if presentation ~= nil then
		if not candidate.running or type(presentation) ~= "table" or type(presentation.icon) ~= "string"
			or type(presentation.title) ~= "string" or type(presentation.active) ~= "boolean" then return false end
		local Tray = tray()
		local handle = ensure_item(presentation.icon)
		if not Tray or not handle then return false end
		local called, updated = pcall(Tray.update_item, handle, clone(presentation))
		if not called or updated ~= true then return false end
	elseif remove_item() ~= true then
		return false
	end
	local handle = _state.handle
	_state = clone(candidate)
	_state.handle = handle
	return true
end

--- Retains the exact inverse until native restoration acknowledges completion.
--- @return boolean restored
function M.retry_configuration_restore()
	if not _restore_debt then return true end
	local called, restored = pcall(M.apply_configuration, _restore_debt)
	if not called or restored ~= true then return false end
	_restore_debt = nil
	return true
end

--- @return boolean
function M.stop()
	if _restore_debt or not Preferences.admit() then return false end
	if not _state.running then return true end
	local candidate = M.configuration_snapshot()
	_restore_debt = M.configuration_snapshot()
	candidate.running, candidate.presentation = false, nil
	if M.apply_configuration(candidate) ~= true or not store_bool("visible", false) then
		M.retry_configuration_restore()
		Logger.error(LOG, "The tray readout stop was refused; its previous state is retained for restoration.")
		return false
	end
	_restore_debt = nil
	Logger.info(LOG, "WPM tray readout stopped.")
	return true
end

--- @param enabled boolean
--- @return boolean
function M.set_use_source_colors(enabled)
	if _restore_debt or not Preferences.admit() then return false end
	local wanted = enabled and true or false
	if not store_bool("colors", wanted) then
		Logger.error(LOG, "The colour state could not be persisted — it was not changed.")
		return false
	end
	_state.use_colors = wanted
	_state.last_key = nil
	return true
end

--- @return boolean
function M.uses_source_colors()
	return _state.use_colors
end

--- The readout's own tray item, created on first need.
ensure_item = function(icon)
	if _state.handle then return _state.handle end
	local Tray = tray()
	if not Tray or type(Tray.new_item) ~= "function" then return nil end
	-- No rows, as on macOS, where the readout does nothing on a click: the
	-- metrics menu is where it is switched off. The menu exists only because
	-- most panels do not show an item without one.
	_state.handle = Tray.new_item(ITEM_ID, icon, {})
	return _state.handle
end

--- Refreshes the readout. Called from the daemon's periodic tick.
--- @param stats table|nil From keylogger.get_live_stats().
--- @param now_s number Monotonic seconds.
--- @return table|nil The frame shown, or nil when hidden.
function M.tick(stats, now_s)
	if _restore_debt or not Preferences.admit() then return nil end
	if not _state.running then return nil end
	if _state.last_update_s and (now_s - _state.last_update_s) < UPDATE_S then return nil end
	_state.last_update_s = now_s
	local canon = Constants.load()
	if not canon then return nil end
	local frame = Model.menubar_frame(canon, stats, Widget.frame_options(now_s, _state.use_colors))
	local Tray = tray()
	if not Model.menubar_visible(stats, frame.source, Widget.tooltip_visible()) then
		if _state.handle and Tray then
			local called, updated = pcall(Tray.update_item, _state.handle, { active = false })
			if not called or updated ~= true then return nil end
			if _state.presentation then _state.presentation.active = false end
		end
		_state.last_key = nil
		return nil
	end
	local key = frame.number .. "|" .. tostring(frame.background)
	if key == _state.last_key then return frame end
	local icon = write_icon(frame)
	if not icon then return nil end
	local handle = ensure_item(icon)
	if not handle or not Tray then return nil end
	local presentation = { icon = icon, title = frame.label, active = true }
	local called, updated = pcall(Tray.update_item, handle, presentation)
	if not called or updated ~= true then return nil end
	_state.presentation = presentation
	_state.last_key = key
	return frame
end

--- Test seams.
function M._set_tray(value) _tray = value end
function M._set_painter(value) _painter = value end
function M._defaults()
	local copy = {}
	for key, value in pairs(DEFAULTS) do copy[key] = value end
	return copy
end
function M._reset()
	_restore_debt = nil
	_state.presentation = nil
	_state.running = false
	_state.use_colors = DEFAULTS.colors
	_state.handle = nil
	_state.last_update_s = nil
	_state.last_key = nil
	_state.flip = false
	_tray = nil
	_painter = nil
end

return M
