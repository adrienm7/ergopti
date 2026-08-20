--- ui/wpm/widget.lua

--- ==============================================================================
--- MODULE: Floating WPM Widget (Linux)
--- DESCRIPTION:
--- A small always-on-top pill showing live typing speed, coloured by where the
--- last characters came from — the user's own hands, a hotstring, or the LLM.
--- macOS draws it with hs.canvas and Windows with a layered Gui; this draws it
--- with the same GTK surface the preview bubble already uses.
---
--- FEATURES & RATIONALE:
--- 1. The arithmetic is separated from the drawing, and only the drawing needs a
---    display. `frame_for` turns the keylogger's stats into everything the
---    renderer needs — text, colours, opacity — and returns a plain table, so
---    every decision the widget makes is testable on a machine with no screen.
---    That split is why the preview bubble's logic could be tested at all, and
---    the same reasoning applies here.
--- 2. Geometry and colours come from _shared/modules/wpm_widget/constants.toml,
---    read rather than mirrored. The other two drivers each restate that table by
---    hand; a third hand-copy would be a third thing to drift.
--- 3. Idle is a state, not an absence. A widget that vanishes when the user stops
---    typing reads as a crash, so it dims to the idle colour and keeps its last
---    value — which is also the number the user wants to see after they stop.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Constants = require("infra.wpm_constants")

local LOG = "ui.wpm.widget"

-- How long a keystroke's origin keeps colouring the pill. Beyond it the widget
-- returns to the neutral colour, so a single AI completion does not leave the
-- pill purple for the rest of the session. Mirrors the macOS default.
local SOURCE_COLOR_DURATION_SEC = 1.0

-- The unit under the number. Not translated, deliberately: "MPM" is what the
-- other two drivers show, the metrics UI uses it as a column header, and a unit
-- that changes per locale cannot be compared against a screenshot in an issue.
local UNIT_LABEL = "MPM"

-- Which colour key a source paints with. Anything not listed here is a source
-- this widget has no opinion about and falls back to the manual colour, which is
-- the honest answer: it was still typing.
local COLOR_KEY_FOR_SOURCE = {
	llm       = "bg_ai",
	manual    = "bg_manual",
	hotstring = "bg_manual",
}

-- Populated from DEFAULTS below, once they are read. Declared here because the
-- rest of the module reads it, and initialised there because the shipped answer
-- is the manifest's to give.
local _state = {
	running        = false,
	use_source_colors = false,
	last_frame     = nil,
}

-- Where the two user choices are kept, and the shape of that keeping: only a
-- CHANGE from the shipped default is stored. Persisting the default too would
-- freeze today's default for anyone who had already run the driver — a later
-- change to what ships would reach new installs and nobody else. The metrics
-- toggles and the dynamic-hotstring families are stored the same way for the
-- same reason.
--
-- Nothing was stored at all until now. A user who turned the widget on found it
-- gone after the next restart, with the menu row unticked and no sign that
-- anything had been forgotten — which reads as a control that does not work
-- rather than one whose answer is not kept.
local PREF_PREFIX = "wpm_widget."

-- The shipped answers, read from the shared manifest rather than restated.
--
-- The colour mode used to be a literal `true` here while the manifest ships
-- `false` for the same setting on Windows: two drivers disagreeing about what a
-- fresh install looks like, with nothing anywhere saying which was intended.
-- The manifest is the single source for a default; a driver that writes its own
-- is not configurable, it is merely coincidentally similar.
local Manifest = require("infra.manifest_reader")

--- The manifest's answer for one of the two settings.
--- @param path string Feature path.
--- @param fallback boolean Used only when the manifest cannot be read at all.
--- @return boolean
local function shipped(path, fallback)
	local ok, value = pcall(Manifest.default_for, path)
	if not ok or type(value) ~= "boolean" then
		Logger.warn(LOG, "No manifest default for '%s' — using %s.", path, tostring(fallback))
		return fallback
	end
	return value
end

local DEFAULTS = {
	visible = shipped("metrics.wpm_widget_visible", false),
	source_colors = shipped("metrics.wpm_widget_colors", false),
}

_state.use_source_colors = DEFAULTS.source_colors

--- Reads a persisted boolean, falling back to the shipped default.
--- @param key string Suffix under PREF_PREFIX.
--- @return boolean
local function stored_bool(key)
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then return DEFAULTS[key] end
	local value = Storage.get(PREF_PREFIX .. key, nil)
	-- Only a real boolean overrides the default. `value == true` collapses every
	-- other stored shape to false — a string from a hand-edited store, a number
	-- from a foreign writer — which would silently turn a setting off because its
	-- value was unrecognisable.
	if type(value) ~= "boolean" then return DEFAULTS[key] end
	return value
end

--- Writes a boolean, or clears the entry when it returns to the default.
--- @param key string Suffix under PREF_PREFIX.
--- @param value boolean
local function store_bool(key, value)
	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then return end
	if value == DEFAULTS[key] then
		-- Back to the default means back to no entry, so the default stays live
		-- for this user rather than being pinned at the moment they toggled.
		Storage.delete(PREF_PREFIX .. key)
		return
	end
	Storage.set(PREF_PREFIX .. key, value)
end




-- =========================================
-- =========================================
-- ======= 1/ Colour helpers ===============
-- =========================================
-- =========================================

--- Turns "#RRGGBB" into the renderer's {red, green, blue} in 0..1.
--- @param hex string
--- @return table|nil
local function rgb(hex)
	if type(hex) ~= "string" then return nil end
	local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then return nil end
	return {
		red   = tonumber(r, 16) / 255,
		green = tonumber(g, 16) / 255,
		blue  = tonumber(b, 16) / 255,
	}
end

--- Darkens a colour by a factor, per channel.
---
--- The unit strip under the number is the same colour as the pill, one shade
--- down; the canon carries the factor rather than a second colour so the two can
--- never be changed apart.
--- @param color table|nil
--- @param factor number
--- @return table|nil
local function darken(color, factor)
	if type(color) ~= "table" then return nil end
	local keep = 1 - (tonumber(factor) or 0)
	return { red = color.red * keep, green = color.green * keep, blue = color.blue * keep }
end




-- =========================================
-- =========================================
-- ======= 2/ The frame ====================
-- =========================================
-- =========================================

--- Which source is currently colouring the pill.
---
--- Same rule as macOS: a source colours the widget for a short window after the
--- keystroke that produced it, then the widget goes neutral. Passing `now` in
--- rather than reading a clock is what makes the decision testable — the whole
--- behaviour is "has enough time passed", and a test that cannot move time can
--- only assert the two extremes.
--- @param stats table|nil From keylogger.get_session_stats().
--- @param now number Seconds, monotonic.
--- @return string The source name, or "none".
function M.active_source(stats, now)
	if type(stats) ~= "table" then return "none" end
	local source = stats.source_variant or stats.source or "none"
	local since  = tonumber(stats.source_time) or 0
	if source == "none" then return "none" end
	if (now - since) > SOURCE_COLOR_DURATION_SEC then return "none" end
	return source
end

--- Everything the renderer needs to draw one frame.
---
--- Pure. Returns nil only when the shared constants could not be read, which is
--- the one condition under which there is nothing sensible to draw.
--- @param stats table|nil From keylogger.get_session_stats().
--- @param now number Seconds, monotonic.
--- @return table|nil { number, unit, width, height, background, strip, text, alpha }
function M.frame_for(stats, now)
	local canon = Constants.load()
	if not canon then return nil end

	local wpm = math.floor(tonumber(stats and stats.wpm) or 0)
	local source = _state.use_source_colors and M.active_source(stats, now) or "none"
	local idle = source == "none"

	local key = COLOR_KEY_FOR_SOURCE[source] or (idle and "bg_idle" or "bg_manual")
	local background = rgb(canon.colors[key]) or rgb(canon.colors.bg_idle)

	return {
		-- The number alone, with the unit on its own strip: the pill is 80 px wide
		-- and "123 MPM" at the number's font size does not fit in it.
		number     = tostring(wpm),
		unit       = UNIT_LABEL,
		width      = canon.compact.width,
		height     = canon.compact.height,
		background = background,
		strip      = darken(background, canon.compact.unit_strip_darken_factor),
		text       = rgb(idle and canon.colors.text_idle or canon.colors.text_active),
		-- 0..255 in the canon, 0..1 here: the GTK surface takes a fraction, and
		-- converting at the boundary keeps the canon readable as what the other two
		-- drivers already use.
		alpha      = (idle and canon.transparency.alpha_idle or canon.transparency.alpha_active) / 255,
		idle       = idle,
		source     = source,
	}
end




-- =========================================
-- =========================================
-- ======= 3/ Lifecycle ====================
-- =========================================
-- =========================================

--- Whether the widget is currently shown.
--- @return boolean
function M.is_running()
	return _state.running
end

--- Starts the widget.
---
--- Does NOT draw by itself: `tick` is called from the daemon's periodic
--- callback, the same one that already drives the tray refresh. A widget with
--- its own timer is a second clock to stop on shutdown and a second thing to
--- leak.
--- @return boolean True when the widget can draw.
--- Applies the persisted choices and shows the widget if it was left on.
---
--- Called by the daemon at boot, before the first tick. Separate from `start`
--- because `start` is also what the menu row calls, and a menu click must not
--- re-read storage — the user just told it what they want.
--- @return boolean True when the widget is running after this call.
function M.restore()
	_state.use_source_colors = stored_bool("source_colors")
	local visible = stored_bool("visible")
	Logger.info(LOG, "Restored: visible=%s, source colours=%s.",
		tostring(visible), tostring(_state.use_source_colors))
	if not visible then return false end
	return M.start()
end

function M.start()
	if _state.running then
		Logger.debug(LOG, "start(): already running.")
		return true
	end
	if not Constants.load() then
		Logger.error(LOG, "The shared constants could not be read — the widget stays off.")
		return false
	end
	_state.running = true
	store_bool("visible", true)
	Logger.info(LOG, "WPM widget started.")
	return true
end

--- Stops the widget and hides its window.
function M.stop()
	if not _state.running then return end
	_state.running = false
	_state.last_frame = nil
	store_bool("visible", false)
	local ok, Renderer = pcall(require, "adapters.graphics_renderer")
	if ok and type(Renderer.hide) == "function" then pcall(Renderer.hide) end
	Logger.info(LOG, "WPM widget stopped.")
end

--- Whether the pill is coloured by keystroke origin, or always neutral.
--- @param enabled boolean
function M.set_use_source_colors(enabled)
	_state.use_source_colors = enabled and true or false
	store_bool("source_colors", _state.use_source_colors)
	Logger.debug(LOG, "Source colours: %s.", tostring(_state.use_source_colors))
end

--- @return boolean
function M.uses_source_colors()
	return _state.use_source_colors
end

--- Recomputes and redraws. Called from the daemon's periodic tick.
--- @param stats table|nil From keylogger.get_session_stats().
--- @param now number Seconds, monotonic.
--- @return table|nil The frame that was drawn, for tests and diagnostics.
function M.tick(stats, now)
	if not _state.running then return nil end

	local frame = M.frame_for(stats, now)
	if not frame then return nil end

	-- Redraw only when something a user could see has changed. The tick runs
	-- several times a second and each draw is a GTK round trip; a widget that
	-- repaints an identical pill is spending a display server's time to show the
	-- same thing.
	local last = _state.last_frame
	if last and last.number == frame.number and last.source == frame.source then
		return frame
	end
	_state.last_frame = frame

	local ok, Renderer = pcall(require, "adapters.graphics_renderer")
	if not ok or type(Renderer.show_widget) ~= "function" then
		-- Not an error worth repeating on every tick: a machine with no lgi has no
		-- preview bubble either, and that is reported once at startup.
		Logger.debug(LOG, "No widget surface available — nothing drawn.")
		return frame
	end
	pcall(Renderer.show_widget, frame)
	return frame
end

--- Clears module state. Tests only.
--- Test seam: the shipped answers, so a test cannot restate them and drift.
--- @return table
function M._defaults()
	local copy = {}
	for key, value in pairs(DEFAULTS) do copy[key] = value end
	return copy
end

function M._reset()
	_state.running = false
	_state.use_source_colors = DEFAULTS.source_colors
	_state.last_frame = nil
end

return M
