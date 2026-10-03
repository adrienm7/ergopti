--- adapters/screen_capture.lua

--- ==============================================================================
--- MODULE: Private Screen Capture (Linux)
--- DESCRIPTION:
--- Captures a region the user draws, or the whole screen, to a PNG in a fresh
--- private directory for the llm_screen_region / llm_screen_full actions, and
--- downscales it when ImageMagick is installed. Never the clipboard.
---
--- FEATURES & RATIONALE:
--- 1. The same tools as the screenshot_*_save actions (gestures/manager.lua),
---    Wayland ones first: grim + slurp on wlroots compositors, then
---    gnome-screenshot, spectacle and maim. Under Wayland the X11 tools talk to
---    nothing, so the order matters for the same reason it does there.
--- 2. A region is interactive: only ONE drawing tool runs, so cancelling it
---    cannot open the next one. slurp and maim say "cancelled"; gnome-screenshot
---    and spectacle exit without writing the file. Both read as cancelled.
--- 3. The whole screen is the pointer's monitor with spectacle (--current);
---    grim, gnome-screenshot and maim have no such option and capture every
---    monitor.
--- 4. The capture runs as an asynchronous child: drawing a region takes seconds,
---    and the daemon owns the grabbed keyboard meanwhile.
--- 5. The directory is created mode 0700 by mktemp -d, under $XDG_RUNTIME_DIR
---    when the session has one: the screenshot may show private messages.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ShellRunner = require("adapters.shell_runner")

local LOG = "adapters.screen_capture"




-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- How long the user may take to draw a region before the tool is stopped
local REGION_TIMEOUT_MS = 120000

-- How long a whole-screen capture and its downscale may take
local FULL_TIMEOUT_MS = 15000

-- The capture modes, by the name the actions use
M.MODES = { region = true, full = true }

-- The exit codes the capture script reports besides 0 (captured)
M.EXIT_CANCELLED = 3
M.EXIT_NO_TOOL = 4
M.EXIT_NO_FILE = 5

-- What the script prints when no tool could downscale the image
M.UNSCALED_MARKER = "ergopti-unscaled"

-- The capture script. $1 is the PNG path, $2 the longest edge allowed, $3 the
-- mode. The positional arguments carry every value: nothing is interpolated.
M.SCRIPT = table.concat({
	'out=$1; edge=$2; mode=$3',
	'has() { command -v "$1" >/dev/null 2>&1; }',
	'shot() {',
	'	if [ "$mode" = region ]; then',
	'		if [ -n "$WAYLAND_DISPLAY" ] && has slurp && has grim; then',
	'			if g=$(slurp 2>&1); then grim -g "$g" "$out"; return; fi',
	'			case "$g" in *ancel*) return ' .. M.EXIT_CANCELLED .. ';; esac',
	'		fi',
	'		if has gnome-screenshot; then gnome-screenshot -a -f "$out"; return; fi',
	'		if has spectacle; then spectacle -b -n -r -o "$out"; return; fi',
	'		if has maim; then',
	'			m=$(maim -s "$out" 2>&1) && return 0',
	'			case "$m" in *ancel*) return ' .. M.EXIT_CANCELLED .. ';; esac',
	'			return 1',
	'		fi',
	'		return ' .. M.EXIT_NO_TOOL,
	'	fi',
	'	tried=0',
	'	if has grim; then tried=1; grim "$out" 2>/dev/null && return 0; fi',
	'	if has spectacle; then tried=1; spectacle -b -n -m -o "$out" && return 0; fi',
	'	if has gnome-screenshot; then tried=1; gnome-screenshot -f "$out" && return 0; fi',
	'	if has maim; then tried=1; maim "$out" && return 0; fi',
	'	[ "$tried" = 1 ] && return 1',
	'	return ' .. M.EXIT_NO_TOOL,
	'}',
	'shot; s=$?',
	'[ "$s" -eq 0 ] || exit "$s"',
	'[ -s "$out" ] || exit ' .. M.EXIT_NO_FILE,
	'if has magick; then magick "$out" -resize "${edge}x${edge}>" "$out" && exit 0',
	'elif has convert; then convert "$out" -resize "${edge}x${edge}>" "$out" && exit 0',
	'fi',
	'echo ' .. M.UNSCALED_MARKER,
}, "\n")




-- =========================================
-- =========================================
-- ======= 2/ Outcome ======================
-- =========================================
-- =========================================

--- Reads the capture script's outcome.
--- @param mode string "region" or "full".
--- @param code integer|nil Exit code, nil when the child did not exit (timeout).
--- @param stdout string|nil What the script printed.
--- @param err string|nil The runner's error.
--- @return table { status = "ok"|"cancelled"|"failed", scaled = boolean, reason = string|nil }
function M.classify(mode, code, stdout, err)
	if code == 0 then
		local unscaled = type(stdout) == "string" and stdout:find(M.UNSCALED_MARKER, 1, true) ~= nil
		return { status = "ok", scaled = not unscaled }
	end
	if code == M.EXIT_CANCELLED or (code == M.EXIT_NO_FILE and mode == "region") then
		return { status = "cancelled", scaled = false }
	end
	local reason
	if code == M.EXIT_NO_TOOL then
		reason = "no screenshot tool is installed (grim, gnome-screenshot, spectacle or maim)"
	elseif code == M.EXIT_NO_FILE then
		reason = "the screenshot tool wrote no image"
	elseif code == nil then
		reason = tostring(err or "the capture did not finish")
	else
		reason = "the screenshot tool failed (exit code " .. tostring(code) .. ")"
	end
	return { status = "failed", scaled = false, reason = reason }
end




-- =========================================
-- =========================================
-- ======= 3/ Capture ======================
-- =========================================
-- =========================================

--- Creates a fresh directory only the user can read.
--- @return string|nil dir
local function private_dir()
	local base = os.getenv("XDG_RUNTIME_DIR")
	if not base or base == "" then base = os.getenv("TMPDIR") end
	if not base or base == "" then base = "/tmp" end
	-- mktemp prints one protocol newline after the complete literal path.
	-- exec_line would cut at CR/LF inside a valid Linux directory name.
	local created, output = ShellRunner.exec_checked(
		"mktemp -d " .. ShellRunner.quote(base .. "/ergopti-screen.XXXXXXXX"), { output_dir = base })
	if not created or type(output) ~= "string" then return nil end
	local path = output:gsub("\n$", "")
	return path ~= "" and path or nil
end

--- Captures the screen to a private PNG.
--- on_done({ status, scaled, reason }) is called once, unless the returned
--- handle's cancel() stops the capture first. The caller owns handle.path and
--- handle.dir and deletes both, whatever the outcome.
--- @param mode string "region" (the user draws it) or "full".
--- @param max_edge integer Longest edge the image may keep.
--- @param on_done function
--- @return table|nil handle { path, dir, cancel }, string|nil reason
function M.capture(mode, max_edge, on_done)
	if not M.MODES[mode] then error("screen_capture.capture: unknown mode " .. tostring(mode)) end
	if type(max_edge) ~= "number" or max_edge < 1 or max_edge % 1 ~= 0 then
		error("screen_capture.capture: max_edge must be a positive integer")
	end
	if type(on_done) ~= "function" then error("screen_capture.capture: on_done must be a function") end
	local dir = private_dir()
	if not dir then return nil, "no private directory could be created" end
	local path = dir .. "/screen.png"
	local run, reason = ShellRunner.run_async("sh", { "-c", M.SCRIPT, "sh", path, tostring(max_edge), mode },
		{ timeout_ms = mode == "region" and REGION_TIMEOUT_MS or FULL_TIMEOUT_MS }, function(result)
			local outcome = M.classify(mode, result.code, result.stdout, result.error)
			if outcome.status == "failed" and type(result.stderr) == "string" and result.stderr ~= "" then
				Logger.debug(LOG, "Capture tool said: %s", result.stderr:sub(1, 200))
			end
			on_done(outcome)
		end)
	if not run then
		os.remove(dir)
		return nil, "the capture could not start: " .. tostring(reason)
	end
	Logger.debug(LOG, "Screen capture started (mode=%s).", mode)
	return { path = path, dir = dir, cancel = run.cancel }, nil
end

return M
