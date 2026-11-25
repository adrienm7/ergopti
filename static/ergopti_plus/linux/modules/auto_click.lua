--- modules/auto_click.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Auto-Clicker (Linux)
--- DESCRIPTION:
--- The Linux half of the anti-sleep mode's presets and auto-clicker: it keeps
--- the user's presets document (auto_click/presets.json in the configuration
--- folder), and while Ctrl+M has the mode on with an auto-click preset it runs
--- the shared session (_shared/shortcuts/engine/auto_click_session.lua) on the
--- timings registry's tick, with Linux ports: the X11 focus query, logind's
--- lock state, the secure field detector, the screen vision service and an
--- xdotool click.
---
--- FEATURES & RATIONALE:
--- 1. X11 only for the click: Wayland gives no client a way to move the
---    pointer, so under Wayland the auto-click switch is refused with
---    "auto_click_wayland" and the menu greys it with that reason.
--- 2. Fail closed on the lock: logind's LockedHint is read before each tick,
---    asynchronously; an unanswered or unknown state counts as locked.
--- 3. One click, then the pointer goes back: `xdotool mousemove X Y click 1
---    mousemove restore`, one child per click.
--- 4. The document is written only after an edit the shared store accepted,
---    to a temporary file then renamed, so a crash never leaves half a library.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local ConfigPaths = require("settings.engine.paths")
local FileSystem = require("core.fs.adapters.file_system")
local ShellRunner = require("core.process.adapters.shell_runner")
local Timings = require("core.timing.engine.timings")
local TimerScheduler = require("core.events.timer_scheduler")
local Library = require("shortcuts.engine.keep_awake_library")
local Session = require("shortcuts.engine.auto_click_session")

local LOG = "modules.auto_click"

local _session = nil
local _runner = Library.runner({
	every = TimerScheduler.every, cancel = TimerScheduler.cancel,
	log = function(level, message, ...) Logger[level](LOG, message, ...) end,
})
local _locked = true
local _lock_probe = false
local _clicks_total = 0
local _ports = nil




-- =========================================
-- =========================================
-- ======= 1/ Library ======================
-- =========================================
-- =========================================

local function read_shared(relative)
	return Library.read_shared_json(FileSystem.read, Paths.shared, Json.decode, relative)
end

local _library = nil

--- The shared library store with the Linux ports.
local function library()
	if _library then return _library end
	_library = Library.new({
		os_name = "linux", separator = "/",
		read_shared = read_shared,
		config_dir = function() return ConfigPaths.get_config_dir() end,
		exists = FileSystem.exists,
		read = FileSystem.read,
		ensure_dirs = function(folder, images)
			return ShellRunner.run("mkdir -p -m 700 " .. ShellRunner.quote(folder) .. " " .. ShellRunner.quote(images))
		end,
		write_atomic = function(path, text)
			local partial = path .. ".partial"
			return FileSystem.write(partial, text) and os.rename(partial, path) == true
		end,
		encode = Json.encode, decode = Json.decode,
		text = function(key) return require("core.i18n.engine.i18n").get(key) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
		unavailable_reason = function() return M.unavailable_reason() end,
		problems = function()
			if M.unavailable_reason() or require("platform.vision.tesseract_ocr").available() then return {} end
			return { "ocr_engine_missing" }
		end,
		clicks = function() return _clicks_total end,
	})
	return _library
end

--- The library store (the library window edits through it).
M.library = library

--- The screen vision service, started once by this owner (the library window uses it too).
--- @return table service
function M.vision()
	-- One session starts the service for the auto-clicker and the workflows.
	return require("platform.vision.vision_session").service()
end

--- The presets document.
function M.document() return library().document() end

--- Applies one edit of the shared store and writes the document after it.
function M.edit(op, ...) return library().edit(op, ...) end

--- Subscribes to every change (the menu redraws its rows).
function M.on_change(fn) library().on_change(fn) end

--- What the active preset runs on Linux.
function M.active_plan() return library().active_plan() end

--- The rows of the menu's presets list.
function M.preset_rows() return library().preset_rows() end

--- Whether one switch of the active preset is on.
function M.switch_on(name) return library().switch_on(name) end

--- Flips one switch of the active preset.
function M.toggle_switch(name) return library().toggle_switch(name) end

--- Whether the auto-click switch can run here.
function M.auto_click_available() return library().auto_click_available() end

--- The rows of the menu's status list.
function M.status_rows() return library().status_rows() end




-- =========================================
-- =========================================
-- ======= 2/ Ports ========================
-- =========================================
-- =========================================

local function is_wayland()
	return os.getenv("XDG_SESSION_TYPE") == "wayland" or (os.getenv("WAYLAND_DISPLAY") or "") ~= ""
end

--- Why the auto-click switch cannot run here, or nil.
--- @return string|nil reason
function M.unavailable_reason()
	if is_wayland() then return "auto_click_wayland" end
	if not ShellRunner.has_command("xdotool", true) then return "auto_click_tool_missing" end
	return nil
end

--- Reads logind's lock state asynchronously; unknown is locked.
local function probe_lock()
	if _lock_probe then return end
	_lock_probe = true
	local handle = ShellRunner.run_async("sh", { "-c",
		"loginctl show-session \"$(loginctl show-user \"$USER\" -p Display --value)\" -p LockedHint --value" },
		{ timeout_ms = Timings.ms("keep_awake", "auto_click_tick_ms") }, function(result)
			_lock_probe = false
			local answer = result.ok and (result.stdout or ""):gsub("%s+", "") or ""
			_locked = answer ~= "no"
		end)
	if not handle then _lock_probe, _locked = false, true end
end

local function default_ports()
	local Focus = require("platform.focus.x11_focus")
	local Secure = require("platform.focus.secure_field_detector")
	local Vision = require("platform.vision.screen_vision")
	return {
		foreground = function()
			local window = Focus.query()
			if not window then return nil end
			return { window = window, app_id = Focus.window_class(window) }
		end,
		state = function()
			probe_lock()
			local ok, secure = pcall(Secure.isSecureField)
			return { locked = _locked, paused = false, secure_field = not ok or secure == true }
		end,
		scan = function(window, request, callback) Vision.scan_window(window, request, callback) end,
		click = function(x, y)
			return ShellRunner.run_async("xdotool", { "mousemove", tostring(x), tostring(y), "click", "1",
				"mousemove", "restore" }, { timeout_ms = Timings.ms("keep_awake", "auto_click_tick_ms") },
				function(result)
					if not result.ok then Logger.warn(LOG, "xdotool click failed: %s.", tostring(result.error)) end
				end) ~= nil
		end,
		now_ms = require("core.logger.engine.monotonic").now_ms,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	}
end

--- Binds test ports in place of the native ones.
function M._set_ports(ports)
	_ports = ports
end

--- Forgets the cached document and session (tests).
function M._reset()
	if _session then M.stop() end
	if _library then _library.reset() end
	_library, _ports, _clicks_total, _locked = nil, nil, 0, true
end




-- =========================================
-- =========================================
-- ======= 3/ Session ======================
-- =========================================
-- =========================================

--- Whether a session runs.
function M.running()
	return _session ~= nil
end

--- The clicks since the driver started, for the menu row.
function M.clicks()
	return _clicks_total
end

--- Starts the auto-clicker for a plan.
--- @param plan table As active_plan returns it.
--- @return boolean started, string|nil reason
function M.start(plan)
	if _session then return true end
	if not plan.auto_click then return false, "auto_click_off" end
	local reason = not _ports and M.unavailable_reason() or nil
	if reason then
		Logger.warn(LOG, "Auto-click refused: reason=%s.", reason)
		return false, reason
	end
	local ports = _ports or default_ports()
	if not _ports then
		local Vision = M.vision()
		Vision.report_problem("capture")
		if #plan.text_targets > 0 then Vision.report_problem("ocr") end
	end
	local base_click = ports.on_click
	ports.on_click = function(count, target)
		_clicks_total = _clicks_total + 1
		if base_click then base_click(count, target) end
		library().changed()
	end
	local defaults = read_shared("shortcuts/data/auto_click_defaults.json")
	local locale = require("core.i18n.engine.locale").current_locale()
	_session = Session.new(ports, plan, {
		options = defaults, cooldown_ms = Timings.ms("keep_awake", "auto_click_cooldown_ms"),
		ocr = { layout = "sparse", locale = locale },
	})
	_runner.start(_session, Timings.sec("keep_awake", "auto_click_tick_ms"))
	Logger.info(LOG, "Auto-click started: %d image(s), %d text target(s).", #plan.templates, #plan.text_targets)
	return true
end

--- Stops the auto-clicker; a scan still running is ignored when it answers.
function M.stop()
	_session = nil
	return _runner.stop()
end

return M
