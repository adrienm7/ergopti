--- ui/tooltip/preview.lua

--- ==============================================================================
--- MODULE: Hotstring Preview (Linux)
--- DESCRIPTION:
--- Decides what the tooltip shows: which hotstrings could still fire from what
--- the user has typed so far, in the order the engine would pick them, dimmed
--- where they would not fire.
---
--- WHY A PREVIEW AND NOT A COMPLETION LIST:
--- It is not offering choices. It is showing what the driver is ABOUT to do,
--- which is the only way a user can learn a trigger they half-remember and the
--- only way they can tell "nothing happened" from "something else won". A
--- candidate that will not fire is therefore shown dimmed rather than hidden:
--- absent looks like the driver failing to notice it.
---
--- WHERE THE PIECES LIVE:
---   the anchor        — this file's cascade, below
---   where it goes     — _shared/lua/tooltip/layout.lua, shared with macOS
---   what colour it is — _shared/lua/tooltip/tint.lua, same
---   how it is drawn   — adapters/graphics_renderer.lua
---   whether to show   — the four preview toggles, and the per-category
---                       show_tooltip the delay cascade resolves
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Renderer = require("adapters.graphics_renderer")
local Scheduler = require("adapters.timer_scheduler")
local Shell = require("adapters.shell_runner")
local DisplayServer = require("infra.display_server")

local LOG = "ui.tooltip.preview"

-- How many candidates a preview shows. Beyond this the panel is taller than it
-- is useful and covers the text it annotates.
local MAX_ROWS = 6

-- Fallback screen frame, used only when no geometry can be read at all. A
-- tooltip drawn against a wrong-but-plausible frame is still on screen; one
-- drawn against nothing is at 0,0.
local FALLBACK_SCREEN = { x = 0, y = 0, w = 1920, h = 1080 }




-- =============================================
-- =============================================
-- ======= 1/ State ============================
-- =============================================
-- =============================================

local _style = nil
local _config = nil

-- The handle of the pending auto-hide, so a new bubble cancels the previous
-- one's timer rather than letting it fire over the top of the replacement.
local _expiry = nil
local _enabled = {
	star = true,
	autocorrect = true,
	ai = true,
	colored = true,
}

--- Initialises the preview.
--- @param opts table { style = table, config = table }
function M.init(opts)
	opts = opts or {}
	_style = opts.style
	_config = opts.config
	if not _style then
		Logger.error(LOG, "init() without a style — the preview cannot draw.")
	end
end

--- Sets one of the four preview toggles.
--- @param name string "star" | "autocorrect" | "ai" | "colored"
--- @param value boolean
function M.set_enabled(name, value)
	if _enabled[name] == nil then
		Logger.error(LOG, "set_enabled(): '%s' is not a preview toggle.", tostring(name))
		return
	end
	_enabled[name] = value and true or false
	Logger.debug(LOG, "Preview toggle %s: %s.", name, tostring(_enabled[name]))
end

--- @param name string
--- @return boolean
function M.is_enabled(name)
	return _enabled[name] == true
end




-- =============================================
-- =============================================
-- ======= 2/ Where to put it ==================
-- =============================================
-- =============================================

--- The screen geometry to clamp inside.
---
--- xdotool under X11; under Wayland there is no portable way to ask, so the
--- fallback is used and stated rather than guessed at per compositor.
--- @return table { x, y, w, h }
function M.screen_frame()
	if DisplayServer.is_x11() then
		local out = Shell.exec_line("xdotool getdisplaygeometry 2>/dev/null")
		local w, h = tostring(out or ""):match("^(%d+)%s+(%d+)$")
		if w and h then
			return { x = 0, y = 0, w = tonumber(w), h = tonumber(h) }
		end
	end
	return FALLBACK_SCREEN
end

--- Resolves where the caret is, as well as this session can.
---
--- A cascade, and every rung is weaker than the one above:
---   1. AT-SPI2 — the accessibility bus. The only interface that reports a real
---      caret position, and it is off by default on several desktops, so it is
---      tried and not relied on.
---   2. the focused window's frame — no caret, but the right window. The
---      tooltip goes at the bottom of it, inset, which is where a status line
---      would be.
---   3. the screen — nothing could be resolved. Centre-bottom, which is visible
---      without claiming to point at anything.
--- There is no rung between 1 and 2 on Wayland: a compositor does not expose
--- window geometry to another process, by design.
--- @return table|nil anchor
function M.resolve_anchor()
	-- 1. AT-SPI2. GetTextAtOffset on the focused accessible would give the caret
	-- rectangle; asking costs a D-Bus round trip, so it is only attempted when
	-- the bus is actually there.
	if Shell.has_command("gdbus") then
		local out = Shell.exec_line(
			"gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus "
			.. "--method org.a11y.Bus.GetAddress 2>/dev/null")
		if out and out ~= "" and not out:find("Error", 1, true) then
			-- The bus exists. A full caret query needs an AT-SPI client binding
			-- rather than a one-shot call, so this rung reports only that the
			-- capability is present; the window rung below still runs.
			Logger.debug(LOG, "AT-SPI2 bus present; caret geometry not queried through gdbus alone.")
		end
	end

	-- 2. The focused window's frame, X11 only.
	if DisplayServer.is_x11() then
		local geometry = Shell.exec("xdotool getactivewindow getwindowgeometry --shell 2>/dev/null")
		local x = tonumber(geometry:match("X=(%-?%d+)"))
		local y = tonumber(geometry:match("Y=(%-?%d+)"))
		local w = tonumber(geometry:match("WIDTH=(%d+)"))
		local h = tonumber(geometry:match("HEIGHT=(%d+)"))
		if x and y and w and h then
			return {
				type = "window",
				x = x + w / 2,
				y = y + h - (_style and _style.positioning.window_bottom_inset or 0),
				h = 0,
			}
		end
	end

	-- 3. Nothing. The layout module centres on the screen for a nil anchor.
	return nil
end




-- =============================================
-- =============================================
-- ======= 3/ What to show =====================
-- =============================================
-- =============================================

--- Whether a candidate's category wants a preview at all.
--- @param group string|nil
--- @return boolean
local function category_shows_tooltip(group, section)
	if not _config or type(_config.resolve) ~= "function" or not group then return true end
	-- The SECTION, not nil. The settings window keys its per-section "hide the
	-- bubble" override by exactly this name, so resolving without it consults only
	-- the category level and keeps drawing for a section the user just silenced.
	-- macOS hit this same bug and its comment says the same thing.
	local ok, resolved = pcall(_config.resolve, group, section)
	if not ok or type(resolved) ~= "table" then return true end
	return resolved.show_tooltip ~= false
end

--- The accent colour for a group, or nil when colouring is off.
--- @param group string|nil
--- @return table|nil { red, green, blue }
local function accent_for(group, section)
	if not _enabled.colored then return nil end
	if not _config or type(_config.resolve) ~= "function" or not group then return nil end
	local ok, resolved = pcall(_config.resolve, group, section)
	if not ok or type(resolved) ~= "table" or type(resolved.color) ~= "string" then return nil end
	local r, g, b = resolved.color:match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then return nil end
	return {
		red = tonumber(r, 16) / 255,
		green = tonumber(g, 16) / 255,
		blue = tonumber(b, 16) / 255,
	}
end

--- Schedules the bubble's own disappearance.
---
--- Without this the panel was hidden only by the next keystroke or by a click,
--- so a user who typed half a trigger and then stopped thinking was left with it
--- on screen indefinitely — offering an expansion the engine would by then
--- REFUSE, because the same delay that governs the bubble governs whether the
--- trigger is still live. The bubble outlived the thing it was describing.
---
--- The timeout is that same per-category delay, read through the same cascade
--- the keystroke path reads, so the two cannot disagree. A delay of 0 means "the
--- trigger never expires", and a bubble for it is left up.
--- @param group string|nil
--- @param section string|nil
local function arm_expiry(group, section)
	if _expiry then
		Scheduler.cancel(_expiry)
		_expiry = nil
	end
	if not _config or type(_config.resolve) ~= "function" or not group then return end

	local ok, resolved = pcall(_config.resolve, group, section)
	if not ok or type(resolved) ~= "table" then return end
	local delay = tonumber(resolved.delay)
	if not delay or delay <= 0 then return end

	_expiry = Scheduler.after(delay, function()
		_expiry = nil
		M.hide()
	end)
end

--- Turns engine candidates into the rows the renderer draws.
---
--- Pure, so the ordering and the dimming can be asserted without a display
--- server — which is the only part of this file a test can reach.
--- @param candidates table Array of { trigger, replacement, group, fires }.
--- @param opts table { max_rows = integer|nil }
--- @return table Array of { text, label, dimmed, struck }
function M.build_rows(candidates, opts)
	opts = opts or {}
	local rows = {}
	local limit = opts.max_rows or MAX_ROWS

	for _, candidate in ipairs(candidates or {}) do
		if #rows >= limit then break end
		rows[#rows + 1] = {
			-- The replacement is what the user is about to get; the trigger is the
			-- label, right-aligned, because a column of triggers down the right is
			-- how someone learns the one they half-remember.
			text   = candidate.replacement,
			label  = candidate.trigger,
			-- Dimmed rather than dropped: a candidate that will not fire is the
			-- answer to "why did nothing happen", and hiding it deletes the answer.
			dimmed = candidate.fires == false,
			struck = candidate.fires == false and candidate.blocked == true,
			-- Each row carries its OWN colour. The panel used to take one accent
			-- from the first candidate, so with several categories pending at once
			-- — the common case — every row after the first wore a colour belonging
			-- to a different category.
			accent = accent_for(candidate.group, candidate.section),
		}
	end

	return rows
end




-- =============================================
-- =============================================
-- ======= 4/ Showing it =======================
-- =============================================
-- =============================================

--- Shows a preview for a set of candidates.
--- @param candidates table Array of { trigger, replacement, group, fires }.
--- @param kind string "star" | "autocorrect" | "ai" — which toggle gates it.
--- @return boolean True when something was drawn.
function M.show(candidates, kind)
	if not _style then return false end
	if kind and _enabled[kind] == false then return false end
	if not Renderer.is_available() then return false end

	local rows = M.build_rows(candidates)
	if #rows == 0 then
		M.hide()
		return false
	end

	-- The candidate that will actually FIRE decides both questions below, falling
	-- back to the first listed when none will. Taking the first unconditionally
	-- made a panel whose whole colour, and whose right to exist at all, came from
	-- a candidate the engine had already ruled out.
	local leading = candidates[1] or {}
	for _, candidate in ipairs(candidates) do
		if candidate.fires then leading = candidate ; break end
	end

	local group, section = leading.group, leading.section
	if not category_shows_tooltip(group, section) then
		M.hide()
		return false
	end

	local drawn = Renderer.show(rows, {
		style = _style,
		-- The panel takes the firing candidate's colour; each row carries its own
		-- as a bar, so a bubble holding several categories says so.
		accent = accent_for(group, section),
		anchor = M.resolve_anchor(),
		screen = M.screen_frame(),
	})

	if drawn then arm_expiry(group, section) end
	return drawn
end

--- Hides the preview.
function M.hide()
	-- The pending expiry goes with it, so a bubble hidden by the next keystroke
	-- does not leave a timer that fires over the top of its replacement.
	if _expiry then
		Scheduler.cancel(_expiry)
		_expiry = nil
	end
	Renderer.hide()
end

--- @return boolean
function M.is_visible()
	return Renderer.is_visible()
end

--- Tears the window down.
function M.destroy()
	Renderer.destroy()
end

return M
