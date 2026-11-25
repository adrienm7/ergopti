--- modules/ocr_capture.lua

--- ==============================================================================
--- MODULE: OCR Capture to Clipboard (Linux)
--- DESCRIPTION:
--- The « Capture → texte » action (sg_actions.ocr_screenshot, Ctrl+O): the
--- region the user draws, captured by the screenshot region cascade into a
--- private temporary folder, read by tesseract, and the text left on the
--- clipboard with a notification. The steps and outcomes are the shared
--- flow's (_shared/shortcuts/engine/ocr_capture.lua).
---
--- FEATURES & RATIONALE:
--- 1. The region cascade is the gesture manager's (grim and slurp under
---    Wayland, then GNOME, KDE and maim), so Ctrl+O selects as every Linux
---    capture does; it runs without blocking the keyboard loop.
--- 2. The capture shell removes its folder on a signal or an empty selection;
---    once it printed the path, this module removes the file and the folder.
--- 3. An empty selection is Escape: the selectors exit non-zero without a
---    file, and the clipboard stays as it was.
--- 4. One run at a time: two selectors would fight for the pointer.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Timings = require("core.timing.engine.timings")
local Flow = require("shortcuts.engine.ocr_capture")

local LOG = "modules.ocr_capture"

local _running = false
local _ports = nil

--- The shell that captures one region into a private folder and prints the file.
--- @param region_save string The region cascade with %s for the target file.
--- @return string command
function M.region_command(region_save)
	return 'd=$(mktemp -d "${TMPDIR:-/tmp}/ergopti-ocr.XXXXXXXX") || exit 1; f="$d/capture.png"; '
		.. [=[trap 'rm -f "$f"; rmdir "$d"; exit 1' HUP INT TERM; { ]=]
		.. region_save:gsub("%%s", '"$f"')
		.. [=[; } && [ -s "$f" ] && { printf '%s' "$f"; exit 0; }; rm -f "$f"; rmdir "$d"; exit 1]=]
end

--- Removes a capture file and its private folder.
local function remove_capture(path)
	os.remove(path)
	local folder = require("core.fs.engine.native_path").dirname(path)
	if folder and folder:match("/ergopti%-ocr%.[^/]+$") then os.remove(folder) end
end

--- The native ports of one run.
local function default_ports(region_save)
	local ShellRunner = require("core.process.adapters.shell_runner")
	local i18n = require("core.i18n.engine.i18n")
	return {
		select = function(callback)
			local handle = ShellRunner.run_async("sh", { "-c", M.region_command(region_save) },
				{ timeout_ms = Timings.ms("screen_vision", "region_select_timeout_ms") }, function(result)
					local path = result.ok and (result.stdout or ""):gsub("%s+$", "") or ""
					if path ~= "" then return callback(path) end
					if result.timed_out then Logger.warn(LOG, "The region selection timed out.") end
					callback(nil, "cancelled")
				end)
			if not handle then callback(nil, "capture_unavailable") end
		end,
		recognize = function(path, callback)
			require("platform.vision.tesseract_ocr").recognize_file(path, { layout = "block",
				locale = require("core.i18n.engine.locale").current_locale() }, callback)
		end,
		set_clipboard = function(text) return require("clipboard.adapters.clipboard").write(text) == true end,
		notify = function(key, level, lines)
			local body = i18n.get(key)
			if lines then body = body:gsub("{1}", tostring(lines)) end
			require("platform.focus.application_notifier").send(body, { level = level })
		end,
		remove = remove_capture,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	}
end

--- Binds test ports in place of the native ones.
function M._set_ports(ports)
	_ports = ports
	_running = false
end

--- Runs one capture (Ctrl+O).
--- @param region_save string The region cascade with %s for the target file.
--- @return boolean accepted
function M.run(region_save)
	assert(type(region_save) == "string" and region_save:find("%s", 1, true), "the region cascade names its file")
	if _running then
		Logger.info(LOG, "OCR capture refused: a selection is already open.")
		return false
	end
	_running = true
	local ok, err = pcall(Flow.run, _ports or default_ports(region_save), function() _running = false end)
	if not ok then
		_running = false
		Logger.error(LOG, "OCR capture raised: %s.", tostring(err))
		return false
	end
	return true
end

return M
