--- ui/wpm/widget.lua

--- ==============================================================================
--- MODULE: Floating WPM Widget (Linux)
--- DESCRIPTION:
--- The small always-on-top readout of the live typing speed, as on macOS: a
--- pill with the number over its unit, or a graph of the last seconds, coloured
--- by where the text came from, shown while typing, hidden when the user goes
--- back to the mouse, and left wherever the user drags it.
---
--- FEATURES & RATIONALE:
--- 1. Everything it decides is shared. What to draw, in which colour, when to
---    show and where by default comes from _shared/lua/wpm_widget/model.lua
---    and _shared/modules/wpm_widget/constants.toml, the same code and file
---    macOS uses; this module holds only the user's choices and the timing.
--- 2. It really draws. It used to call a renderer function that did not exist,
---    read a stats table that carried no speed and no source, and so drew
---    nothing on any desktop while its menu row ticked.
--- 3. Only a CHANGE from the shipped default is stored. Persisting the default
---    too would freeze today's default for everyone who ever toggled a row.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Constants = require("infra.wpm_constants")
local Timings   = require("infra.timings")
local Manifest  = require("infra.manifest_reader")
local Model     = require("wpm_widget.model")

local LOG = "ui.wpm.widget"

-- Where the choices are kept.
local PREF_PREFIX = "wpm_widget."
local POS_X_KEY = PREF_PREFIX .. "pos_x"
local POS_Y_KEY = PREF_PREFIX .. "pos_y"

-- The refresh, colour hold and idle hide, from the shared timings.
local UPDATE_S    = Timings.sec("ui", "wpm_widget_update_ms")
local HOLD_S      = Timings.sec("ui", "wpm_color_hold_ms")
local IDLE_HIDE_S = Timings.sec("ui", "wpm_widget_idle_hide_ms")

--- The manifest's shipped answer for one setting.
--- @param path string
--- @return boolean
local function shipped(path)
	local value = Manifest.default_for(path)
	if type(value) ~= "boolean" then error("no boolean manifest default for " .. path) end
	return value
end

local DEFAULTS = {
	visible = shipped("metrics.wpm_widget_visible"),
	source_colors = shipped("metrics.wpm_widget_colors"),
	graph = shipped("metrics.wpm_widget_graph"),
}

local _state = {
	running = false,
	use_source_colors = DEFAULTS.source_colors,
	graph = DEFAULTS.graph,
	anchor = nil,
	history = {},
	last_active_s = 0,
	last_mouse_s = 0,
	pointer = nil,
	last_draw_s = nil,
	last_frame = nil,
	shown = false,
}

-- The drawing surface; replaceable by tests.
local _surface = nil




-- =========================================
-- =========================================
-- ======= 1/ Choices ======================
-- =========================================
-- =========================================

local function storage()
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or type(Storage) ~= "table" then return nil end
	return Storage
end

--- A persisted boolean, or the shipped default.
--- @param key string Suffix under PREF_PREFIX.
--- @return boolean
local function stored_bool(key)
	local Storage = storage()
	if not Storage then return DEFAULTS[key] end
	local value = Storage.get(PREF_PREFIX .. key, nil)
	-- Only a real boolean overrides the default: an unrecognisable value must
	-- not silently turn a setting off.
	if type(value) ~= "boolean" then return DEFAULTS[key] end
	return value
end

--- Writes a boolean, or clears the entry when it returns to the default.
--- @param key string
--- @param value boolean
--- @return boolean
local function store_bool(key, value)
	local Storage = storage()
	if not Storage then
		Logger.error(LOG, "No storage adapter — '%s' was not changed.", key)
		return false
	end
	if value == DEFAULTS[key] then return Storage.delete(PREF_PREFIX .. key) == true end
	return Storage.set(PREF_PREFIX .. key, value) == true
end

--- The pill's saved top-left corner, or nil for the default place.
local function stored_anchor()
	local Storage = storage()
	if not Storage then return nil end
	local x, y = tonumber(Storage.get(POS_X_KEY, nil)), tonumber(Storage.get(POS_Y_KEY, nil))
	if not x or not y then return nil end
	return { x = x, y = y }
end

local function surface()
	if _surface then return _surface end
	local ok, Surface = pcall(require, "adapters.wpm_surface")
	if not ok or type(Surface) ~= "table" then return nil end
	_surface = Surface
	return _surface
end

--- Keeps the place the user dropped the widget at.
--- @param x number The dropped frame's top-left corner.
--- @param y number
local function on_moved(x, y)
	local frame = _state.last_frame
	local canon = Constants.load()
	if not frame or not canon then return end
	local ax, ay = Model.anchor_from_origin(canon, frame, x, y)
	_state.anchor = { x = ax, y = ay }
	local Storage = storage()
	if not Storage or Storage.set(POS_X_KEY, ax) ~= true or Storage.set(POS_Y_KEY, ay) ~= true then
		Logger.error(LOG, "The widget's new place could not be saved — it returns to the last one on restart.")
		return
	end
	Logger.debug(LOG, "Widget moved to %d,%d.", ax, ay)
end




-- =========================================
-- =========================================
-- ======= 2/ Colours and text =============
-- =========================================
-- =========================================

--- A hotstring group's colour: its TOML _meta.color plus the user's override.
--- @param group string
--- @return string|nil
local function group_colour(group)
	local ok, Config = pcall(require, "modules.hotstrings.hotstrings_config")
	if not ok or type(Config) ~= "table" or type(Config.resolve) ~= "function" then return nil end
	local resolved = Config.resolve(group, nil)
	return type(resolved) == "table" and resolved.color or nil
end

--- The unit under the number, in the user's language, as on macOS and Windows.
local function unit_label()
	local ok, I18n = pcall(require, "infra.i18n")
	if not ok or type(I18n.get) ~= "function" then error("i18n is unavailable") end
	return I18n.get("menu.metrics.wpm_unit")
end

--- The options every readout frame is computed with — the tray readout's too.
--- @param now_s number
--- @param use_colors boolean
--- @return table
function M.frame_options(now_s, use_colors)
	return {
		now_s = now_s,
		hold_s = HOLD_S,
		use_colors = use_colors,
		resolve = group_colour,
		unit = unit_label(),
	}
end

--- Whether a hotstring preview or an AI suggestion is on screen: the readouts
--- stay up while one is.
--- @return boolean
function M.tooltip_visible()
	local ok, Preview = pcall(require, "ui.tooltip.preview")
	if ok and type(Preview) == "table" and type(Preview.is_visible) == "function" and Preview.is_visible() then
		return true
	end
	local ok_llm, Llm = pcall(require, "ui.tooltip.llm")
	return ok_llm and type(Llm) == "table" and type(Llm.is_showing) == "function" and Llm.is_showing() == true
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

local function start_widget(persist)
	if _state.running then return true end
	if not Constants.load() then
		Logger.error(LOG, "The shared canon could not be read — the widget stays off.")
		return false
	end
	if persist and not store_bool("visible", true) then
		Logger.error(LOG, "The visible state could not be persisted — the widget stays off.")
		return false
	end
	local Surface = surface()
	if Surface and type(Surface.on_moved) == "function" then Surface.on_moved(on_moved) end
	_state.running = true
	_state.last_draw_s = nil
	_state.last_frame = nil
	Logger.info(LOG, "WPM widget started (%s).", _state.graph and "graph" or "compact")
	return true
end

--- Applies the persisted choices and shows the widget if it was left on.
--- @return boolean True when the widget is running after this call.
function M.restore()
	_state.use_source_colors = stored_bool("source_colors")
	_state.graph = stored_bool("graph")
	_state.anchor = stored_anchor()
	local visible = stored_bool("visible")
	Logger.info(LOG, "Restored: visible=%s, source colours=%s, graph=%s.",
		tostring(visible), tostring(_state.use_source_colors), tostring(_state.graph))
	if not visible then return false end
	return start_widget(false)
end

function M.start()
	return start_widget(true)
end

local function hide()
	local Surface = surface()
	if Surface and type(Surface.hide) == "function" then Surface.hide() end
	_state.shown = false
end

--- Stops the widget and hides its window.
--- @return boolean
function M.stop()
	if not _state.running then return true end
	if not store_bool("visible", false) then
		Logger.error(LOG, "The hidden state could not be persisted — the widget stays on.")
		return false
	end
	_state.running = false
	_state.last_frame = nil
	_state.history = {}
	hide()
	Logger.info(LOG, "WPM widget stopped.")
	return true
end

--- @param enabled boolean
--- @return boolean
function M.set_use_source_colors(enabled)
	local wanted = enabled and true or false
	if not store_bool("source_colors", wanted) then
		Logger.error(LOG, "The source-colour state could not be persisted — it was not changed.")
		return false
	end
	_state.use_source_colors = wanted
	_state.last_draw_s = nil
	return true
end

--- @return boolean
function M.uses_source_colors()
	return _state.use_source_colors
end

--- Switches between the pill and the real-time graph.
--- @param enabled boolean
--- @return boolean
function M.set_graph(enabled)
	local wanted = enabled and true or false
	if not store_bool("graph", wanted) then
		Logger.error(LOG, "The graph state could not be persisted — it was not changed.")
		return false
	end
	_state.graph = wanted
	_state.last_draw_s = nil
	return true
end

--- @return boolean
function M.uses_graph()
	return _state.graph
end

--- Puts the widget back in its default place.
--- @return boolean
function M.reset_position()
	local Storage = storage()
	if not Storage then
		Logger.error(LOG, "No storage adapter — the widget's place was not reset.")
		return false
	end
	if Storage.delete(POS_X_KEY) ~= true or Storage.delete(POS_Y_KEY) ~= true then
		Logger.error(LOG, "The widget's saved place could not be cleared.")
		return false
	end
	_state.anchor = nil
	_state.last_draw_s = nil
	Logger.info(LOG, "Widget position reset to the default place.")
	return true
end




-- =========================================
-- =========================================
-- ======= 4/ The refresh ==================
-- =========================================
-- =========================================

--- Records whether the pointer moved since the last refresh.
local function watch_pointer(Surface, now_s)
	if type(Surface.pointer_position) ~= "function" then return end
	local x, y = Surface.pointer_position()
	if not x then return end
	local last = _state.pointer
	if last and (last.x ~= x or last.y ~= y) then _state.last_mouse_s = now_s end
	_state.pointer = { x = x, y = y }
end

--- Refreshes the widget. Called from the daemon's periodic tick; it redraws
--- at the shared refresh rate however often it is called.
--- @param stats table|nil From keylogger.get_live_stats().
--- @param now_s number Monotonic seconds.
--- @return table|nil The frame drawn, for tests and diagnostics.
function M.tick(stats, now_s)
	if not _state.running then return nil end
	if _state.last_draw_s and (now_s - _state.last_draw_s) < UPDATE_S then return nil end
	_state.last_draw_s = now_s
	local canon = Constants.load()
	local Surface = surface()
	if not canon or not Surface or not Surface.is_available() then return nil end

	local opts = M.frame_options(now_s, _state.use_source_colors)
	local source = Model.active_source(stats, HOLD_S, now_s)
	local wpm = tonumber(stats and stats.wpm) or 0
	Model.push_history(canon, _state.history, wpm, source)
	watch_pointer(Surface, now_s)

	local show, last_active = Model.widget_visible({
		wpm = wpm, source = source, tooltip_visible = M.tooltip_visible(), now_s = now_s,
		last_active_s = _state.last_active_s, last_mouse_s = _state.last_mouse_s,
		idle_hide_s = IDLE_HIDE_S,
	})
	_state.last_active_s = last_active
	-- A drag moves the pointer; the widget the user is holding must not vanish.
	if Surface.is_dragging() then show = true end
	if not show then
		if _state.shown then hide() end
		return nil
	end

	local frame = _state.graph and Model.graph_frame(canon, _state.history, stats, opts)
		or Model.compact_frame(canon, stats, opts)
	if not _state.anchor then
		local screen = Surface.screen_frame()
		if not screen then
			Logger.debug(LOG, "No screen geometry yet — nothing drawn.")
			return nil
		end
		local x, y = Model.default_anchor(canon, screen)
		_state.anchor = { x = x, y = y }
	end
	local x, y = Model.frame_origin(canon, frame, _state.anchor.x, _state.anchor.y)
	_state.last_frame = frame
	_state.shown = Surface.draw(frame, x, y) == true
	return frame
end

--- Test seam: replaces the drawing surface.
--- @param value table|nil
function M._set_surface(value)
	_surface = value
end

--- Test seam: the shipped answers.
--- @return table
function M._defaults()
	local copy = {}
	for key, value in pairs(DEFAULTS) do copy[key] = value end
	return copy
end

--- Clears module state. Tests only.
function M._reset()
	_state.running = false
	_state.use_source_colors = DEFAULTS.source_colors
	_state.graph = DEFAULTS.graph
	_state.anchor = nil
	_state.history = {}
	_state.last_active_s = 0
	_state.last_mouse_s = 0
	_state.pointer = nil
	_state.last_draw_s = nil
	_state.last_frame = nil
	_state.shown = false
	_surface = nil
end

return M
