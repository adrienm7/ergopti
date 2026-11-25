--- modules/shortcuts/actions/ocr_capture.lua

--- ==============================================================================
--- MODULE: OCR Capture to Clipboard (macOS)
--- DESCRIPTION:
--- The « Capture → texte » action (sg_actions.ocr_screenshot, Ctrl+O): the
--- user selects a region with screencapture, the launcher's vision worker
--- reads it with Vision, and the text goes to the clipboard with a
--- notification. The steps and outcomes are the shared flow's
--- (_shared/shortcuts/engine/ocr_capture.lua).
---
--- FEATURES & RATIONALE:
--- 1. Screen Recording is checked first through screen_capture_flow, the one
---    owner of that refusal, so a missing grant is explained, never a silent
---    empty capture.
--- 2. Escape is told from a failure by screen_capture_flow's settle rules.
--- 3. One run at a time: a second Ctrl+O while the selection is open is
---    refused, since two selectors would fight for the pointer.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Flow = require("shortcuts.engine.ocr_capture")

local LOG = "modules.shortcuts.ocr_capture"

local _running = false
local _ports = nil

--- The native ports of one run.
local function default_ports()
	local Vision = require("modules.shortcuts.actions.auto_click").vision()
	local Native = require("adapters.screen_text_ports")
	local CaptureFlow = require("modules.shortcuts.actions.screen_capture_flow")
	local FileSystem = require("core.fs.adapters.file_system")
	local i18n = require("core.i18n.engine.i18n")
	return {
		select = function(callback)
			if not CaptureFlow.ensure_permission("Text capture") then
				callback(nil, "capture_permission_missing")
				return
			end
			local path = Vision.new_capture_path()
			local mark = CaptureFlow.clipboard_mark()
			local started = Native.select_region(path, function(exit_code, stderr)
				local outcome, detail = CaptureFlow.settle({ path = path, mark = mark, exit_code = exit_code,
					stderr = stderr, interactive = true, destination = "file" })
				if outcome == CaptureFlow.OUTCOME_SAVED then return callback(path) end
				FileSystem.remove_exact(path)
				if outcome == CaptureFlow.OUTCOME_CANCELLED then return callback(nil, "cancelled") end
				Logger.warn(LOG, "The region capture failed: %s.", tostring(detail))
				callback(nil, "capture_refused")
			end)
			if not started then callback(nil, "capture_unavailable") end
		end,
		recognize = function(path, callback)
			Vision.recognize_file(path, { layout = "block", languages = require("adapters.auto_click_ports").languages() },
				callback)
		end,
		set_clipboard = Native.set_clipboard,
		notify = function(key, level, lines)
			local body = i18n.get(key)
			if lines then body = body:gsub("{1}", tostring(lines)) end
			require("core.ui.engine.notifications").notify(body, nil, level)
		end,
		remove = function(path) FileSystem.remove_exact(path) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	}
end

--- Binds test ports in place of the native ones.
function M._set_ports(ports)
	_ports = ports
	_running = false
end

--- Runs one capture (Ctrl+O).
--- @return boolean accepted
function M.run()
	if _running then
		Logger.info(LOG, "OCR capture refused: a selection is already open.")
		return false
	end
	_running = true
	local ok, err = pcall(Flow.run, _ports or default_ports(), function() _running = false end)
	if not ok then
		_running = false
		Logger.error(LOG, "OCR capture raised: %s.", tostring(err))
		return false
	end
	return true
end

return M
