--- menu/ui/title_status.lua

--- ==============================================================================
--- MODULE: Submenu Title Status Dot
--- DESCRIPTION:
--- The coloured dot a top-level submenu title carries for the health of its
--- feature, and the watch that repaints it. The AI title introduced it
--- (maintainer, 2026-10-29); the Tap-Holds title shows the same dot
--- (maintainer, 2026-11-23), so both read one glyph declaration and share one
--- repaint watch.
---
--- FEATURES & RATIONALE:
--- 1. One Glyph Source: the glyphs are the ``health_dot`` table of the shared
---    manifest's top-level ``llm`` entry, the declaration the Windows and Linux
---    AI titles read too. No driver and no submenu owns a glyph or a colour.
--- 2. Three Statuses: ``ready`` (green, it works), ``warming`` (it is on its
---    way or waits on the user: a warning) and ``unreachable`` (red, it does
---    not work). A nil status draws no dot: the feature is off or paused.
--- 3. Repaint Watch: the menubar keeps a prebuilt menu, so a status that
---    changes after the build that painted it needs a rebuild. Each watch
---    re-reads its status on a timer and rebuilds once when the dot differs;
---    a build without a dot stops it.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")

local LOG = "ui.menu.title_status"

--- The statuses a title dot shows, keys of the manifest's ``health_dot``.
M.READY = "ready"
M.WARMING = "warming"
M.UNREACHABLE = "unreachable"

--- The manifest's top-level entry whose ``health_dot`` declares the glyphs.
local GLYPH_OWNER = "llm"




-- ===============================
-- ===============================
-- ======= 1/ Title Glyph ========
-- ===============================
-- ===============================

--- The dot a title carries for a status, read from the manifest.
--- @param status string|nil One of M.READY, M.WARMING, M.UNREACHABLE.
--- @return string|nil glyph Nil for a nil status or when the manifest declares none.
function M.dot(status)
	if status == nil then return nil end
	local ok_menu, ManifestMenu = pcall(require, "menu.engine.manifest_menu")
	if not ok_menu or type(ManifestMenu) ~= "table" or type(ManifestMenu.get_root) ~= "function" then
		Logger.error(LOG, "Manifest renderer unavailable — the menu titles have no status dot.")
		return nil
	end
	local root = ManifestMenu.get_root()
	local top = type(root) == "table" and root.top_level or nil
	if type(top) ~= "table" then return nil end
	for _, entry in ipairs(top) do
		if type(entry) == "table" and entry.id == GLYPH_OWNER then
			local dots = entry.health_dot
			local glyph = type(dots) == "table" and dots[status] or nil
			if type(glyph) == "string" and glyph ~= "" then return glyph end
			return nil
		end
	end
	return nil
end

--- Appends the status dot to a finished parent row's label.
--- @param row table|nil Parent row returned by the manifest renderer.
--- @param status string|nil Status to show; nil leaves the row as is.
--- @return table|nil row The same row.
function M.decorate(row, status)
	local glyph = M.dot(status)
	if glyph and type(row) == "table" and type(row.label) == "string" then
		row.label = row.label .. " " .. glyph
	end
	return row
end





-- ================================
-- ================================
-- ======= 2/ Repaint Watch =======
-- ================================
-- ================================

--- Creates the repaint watch of one title.
--- @param name string Title named in the log lines.
--- @param interval_sec number Seconds between two reads.
--- @return table watch { watch(painted, read, repaint), check(), stop() }.
function M.new_watch(name, interval_sec)
	assert(type(name) == "string" and name ~= "", "Missing title status watch name")
	assert(type(interval_sec) == "number" and interval_sec > 0, "Invalid title status watch interval")
	local state = { handle = nil, painted = nil, read = nil, repaint = nil }
	local watch = {}

	--- Stops the watch; the next build that paints a dot arms it again.
	function watch.stop()
		local handle = state.handle
		state.handle = nil
		state.read = nil
		state.repaint = nil
		-- Resolved at use: a test drives the timer through a scheduler double
		if handle then require("core.events.timer_scheduler").cancel(handle) end
	end

	--- One tick: rebuilds the menu once when the painted dot is out of date.
	function watch.check()
		local read, repaint = state.read, state.repaint
		if type(read) ~= "function" or type(repaint) ~= "function" then return end
		local ok, now = pcall(read)
		if not ok then
			Logger.error(LOG, "The %s status could not be read: %s.", name, tostring(now))
			return
		end
		if now == state.painted then return end
		Logger.debug(LOG, "%s status changed from %s to %s: repainting its title.",
			name, tostring(state.painted), tostring(now))
		-- Recorded before the repaint, so a coalesced rebuild never repaints twice
		state.painted = now
		if now == nil then watch.stop() end
		local repainted, err = pcall(repaint)
		if not repainted then Logger.error(LOG, "The %s title repaint failed: %s.", name, tostring(err)) end
	end

	--- Keeps the title's dot in step with its feature after this build.
	--- @param painted string|nil The status this build painted; nil stops the watch.
	--- @param read function Returns the status the dot should show now.
	--- @param repaint function Rebuilds the menu.
	function watch.watch(painted, read, repaint)
		state.painted = painted
		if painted == nil then watch.stop(); return end
		state.read = read
		state.repaint = repaint
		if state.handle then return end
		local handle, committed = require("core.events.timer_scheduler").every(interval_sec, watch.check)
		if committed ~= true then
			Logger.error(LOG, "The %s status watch could not start: its title dot follows menu rebuilds only.", name)
			return
		end
		state.handle = handle
	end

	return watch
end

return M
