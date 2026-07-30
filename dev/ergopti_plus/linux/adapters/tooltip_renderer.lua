--- adapters/tooltip_renderer.lua

--- ==============================================================================
--- MODULE: TooltipRenderer Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TooltipRenderer port contract defined in
--- static/ergopti_plus/_shared/core/ports/TooltipRenderer.spec.js. Renders
--- floating tooltip overlays using yad (GTK+ popup) or zenity (fallback) as
--- borderless, always-on-top windows, without coupling domain modules to any
--- display-server API.
---
--- FEATURES & RATIONALE:
--- 1. yad primary path: yad --text-info or yad --info creates a GTK popup
---    that supports --undecorated (no title bar), --skip-taskbar,
---    --on-top (always above), and --close-on-unfocus (auto-dismiss).
---    Works on both X11 and XWayland.
--- 2. zenity fallback: when yad is absent, zenity --info provides a basic
---    notification popup. More limited (no undecorated, no positioning) but
---    available by default on GNOME/Ubuntu.
--- 3. updateElement(): re-launches the tooltip window with updated text
---    content. Since yad/zenity windows cannot be partially updated, this
---    is a full re-render — acceptable for tooltips that change rarely.
--- 4. xdotool positioning: when xdotool is available, the window is moved
---    to the requested screen position after creation via xdotool windowmove.
---    Fallback: the window appears at the cursor position (yad default).
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell  = require("adapters.shell_runner")

local LOG = "adapters.tooltip_renderer"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Whether a tooltip window is currently displayed.
local _visible  = false

-- PID of the yad/zenity subprocess (nil when hidden).
local _pid      = nil

-- The X11 window ID of the tooltip (parsed from yad output).
local _win_id   = nil

-- Cached draw_call data for re-renders.
local _cache    = nil

-- Which backend is available (checked once).
local _backend  = nil   -- "yad", "zenity", or nil


-- =========================================
-- =========================================
-- ======= 2/ Backend Detection ============
-- =========================================
-- =========================================

--- Selects the tooltip backend once.
--- Probing goes through Shell.has_command because comparing os.execute()'s
--- result against 0 is the Lua 5.1/LuaJIT spelling only: from Lua 5.2 on the
--- same success is reported as `true`, so both probes read as "absent" and the
--- adapter warned that neither tool was installed even when both were.
local function _detect_backend()
	if _backend then return _backend end
	if Shell.has_command("yad") then
		_backend = "yad"
	elseif Shell.has_command("zenity") then
		_backend = "zenity"
	else
		Logger.warn(LOG, "Neither yad nor zenity is installed — tooltips unavailable.")
		Logger.warn(LOG, "  Install: sudo apt-get install yad")
		_backend = false
	end
	return _backend
end


-- =========================================
-- =========================================
-- ======= 3/ Subprocess Management ========
-- =========================================
-- =========================================

--- Kills any running tooltip subprocess.
local function _kill()
	if _pid then
		os.execute(string.format("kill %d 2>/dev/null", _pid))
		_pid = nil
	end
	_win_id = nil
	_visible = false
end

--- Moves the tooltip window to a specific screen position via xdotool.
--- @param x number|nil Horizontal pixel coordinate.
--- @param y number|nil Vertical pixel coordinate.
local function _position_window(x, y)
	if not _win_id then return end
	if type(x) ~= "number" or type(y) ~= "number" then return end
	os.execute(string.format(
		"xdotool windowmove %d %d %d 2>/dev/null",
		_win_id, math.floor(x), math.floor(y)
	))
end

--- Extracts text from draw_calls for rendering.
--- @param draw_calls table Array of { id, type, text?, ... } draw calls.
--- @return string
local function _extract_text(draw_calls)
	if type(draw_calls) ~= "table" then return "" end
	local lines = {}
	for _, dc in ipairs(draw_calls) do
		if type(dc) == "table" and type(dc.text) == "string" then
			lines[#lines + 1] = dc.text
		end
	end
	return table.concat(lines, "\n")
end

--- Spawns the tooltip subprocess and optionally repositions it.
--- @param text     string    Text content to display.
--- @param x        number|nil Horizontal position.
--- @param y        number|nil Vertical position.
--- @param duration number|nil Auto-hide timeout in seconds.
--- @return boolean true on success.
local function _spawn(text, x, y, duration)
	_kill()

	local be = _detect_backend()
	if not be then return false end

	-- Build the command.
	local parts = {}
	if be == "yad" then
		-- yad --text-info: a borderless text display with auto-close.
		parts = {
			"yad", "--text-info",
			"--no-buttons",
			"--undecorated",
			"--skip-taskbar",
			"--on-top",
			"--close-on-unfocus",
			"--width=400",
			"--height=100",
			"--wrap",
			"--fontname=Monospace 10",
		}
		if duration and duration > 0 then
			parts[#parts + 1] = "--timeout=" .. math.floor(duration)
		end
		-- Pass text via stdin to avoid shell escaping issues.
		-- We use a temp file approach for reliability.
	else
		-- zenity fallback: basic info dialog.
		parts = {
			"zenity", "--info",
			"--no-wrap",
			"--width=400",
		}
		if duration and duration > 0 then
			parts[#parts + 1] = "--timeout=" .. math.floor(duration)
		end
	end

	-- Write text to a temp file and pipe it.
	local tmp_path = os.tmpname and os.tmpname() or "/tmp/ergopti_tooltip_" .. tostring(os.time())
	os.remove(tmp_path)  -- os.tmpname creates the file on some platforms
	tmp_path = tmp_path .. ".txt"

	local fh = io.open(tmp_path, "w")
	if fh then
		fh:write(text)
		fh:close()
	end

	-- Launch in background. For yad, we use --filename to read from the temp file.
	-- For zenity, we use --text with shell-escaped content.
	local cmd
	if be == "yad" then
		cmd = string.format("%s --filename='%s' & echo $!",
			table.concat(parts, " "), tmp_path:gsub("'", "'\\''"))
	else
		local safe_text = text:gsub("'", "'\\''"):gsub("\n", "\\n"):sub(1, 500)
		cmd = string.format("%s --text='%s' & echo $!",
			table.concat(parts, " "), safe_text)
	end

	Logger.debug(LOG, "Spawning tooltip: %s", cmd)

	local pipe = io.popen(cmd, "r")
	if not pipe then
		os.remove(tmp_path)
		Logger.error(LOG, "_spawn(): io.popen failed.")
		return false
	end

	local pid_str = pipe:read("*l")
	pipe:close()
	_pid = tonumber(pid_str)

	if not _pid then
		os.remove(tmp_path)
		Logger.error(LOG, "_spawn(): could not read PID.")
		return false
	end

	-- For yad, we can also capture the window ID for repositioning.
	if be == "yad" and x and y then
		-- yad prints the window ID to stdout (before PID with & echo $! above).
		-- Since we captured PID via & echo $!, the window ID is lost.
		-- Use xdotool search to find the yad window instead.
		local wid_pipe = io.popen(
			"sleep 0.3 && xdotool search --onlyvisible --pid " .. _pid .. " 2>/dev/null",
			"r"
		)
		if wid_pipe then
			local wid_str = wid_pipe:read("*l")
			wid_pipe:close()
			_win_id = tonumber(wid_str)
			if _win_id then
				_position_window(x, y)
			end
		end
	end

	_visible = true

	-- Clean up temp file after the yad process exits (not a fixed sleep).
	if tmp_path and _pid then
		os.execute(string.format("(while kill -0 %d 2>/dev/null; do sleep 0.5; done; rm -f '%s') &",
			_pid, tmp_path:gsub("'", "'\\''")))
	end

	return true
end


-- =========================================
-- =========================================
-- ======= 4/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Renders or updates the tooltip.
--- @param payload table { draw_calls, position?, duration_sec? }
---                draw_calls   table   Array of { id, type, text?, x?, y?, w?, h?, ... }
---                position     table   { x, y } screen coordinates.
---                duration_sec number  Auto-hide timeout in seconds.
function M.show(payload)
	local options = type(payload) == "table" and payload or {}

	local text = _extract_text(options.draw_calls)
	if text == "" then
		Logger.debug(LOG, "show(): no text content — skipping.")
		return
	end

	local pos = options.position
	local x = pos and type(pos.x) == "number" and pos.x or nil
	local y = pos and type(pos.y) == "number" and pos.y or nil
	local dur = type(options.duration_sec) == "number" and options.duration_sec or nil

	-- Cache for potential re-render on updateElement.
	_cache = {
		text = text,
		x = x,
		y = y,
		duration = dur,
	}

	local ok, err = pcall(_spawn, text, x, y, dur)
	if not ok then
		Logger.error(LOG, "show(): spawning failed — %s", tostring(err))
		_visible = false
	elseif not err then
		-- _spawn returned false (backend unavailable).
		_visible = false
	end
end

--- Removes the tooltip from the screen immediately.
function M.hide()
	_kill()
	_cache = nil
end

--- Returns true if the tooltip is currently visible.
--- @return boolean
function M.isVisible()
	return _visible
end

--- Replaces a single draw call by its stable id (streaming partial update).
--- Falls back to a full re-render since yad/zenity cannot be partially updated.
--- @param draw_call table The replacement draw call ({ id, type, … }).
function M.updateElement(draw_call)
	if type(draw_call) ~= "table" then return end
	if not _visible then return end
	if not _cache then return end

	-- Merge the updated draw call into the cached payload and re-render.
	local merged = { text = _cache.text, x = _cache.x, y = _cache.y }
	if type(draw_call.text) == "string" then
		merged.text = draw_call.text
	end

	Logger.debug(LOG, "updateElement(): id=%s — re-rendering tooltip.", tostring(draw_call.id))
	local ok, err = pcall(_spawn, merged.text, merged.x, merged.y, _cache.duration)
	if not ok then
		Logger.error(LOG, "updateElement(): re-render failed — %s", tostring(err))
		_visible = false
	end
end

return M
