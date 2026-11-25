--- modules/shortcuts/actions/auto_click.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Mode and Auto-Clicker (macOS)
--- DESCRIPTION:
--- The macOS owner of the anti-sleep mode's presets and auto-clicker. Ctrl+M
--- (sg_actions.activity_simulation) calls toggle_mode(): the active preset's
--- keep-awake part is the existing activity simulation
--- (modules/shortcuts/actions/system.lua), its auto-click part the shared
--- session (_shared/shortcuts/engine/auto_click_session.lua) with macOS ports.
--- The presets document is the shared library store's.
---
--- FEATURES & RATIONALE:
--- 1. system.lua is left as it was: the coordinator starts and stops its
---    session, and the auto-clicker ends when that session ends, so the first
---    physical input still ends the whole mode (agent decision of 2026-11-25).
--- 2. The click is two Ergopti-tagged mouse events (adapters/
---    auto_click_ports.lua), so the keep-awake watcher never takes it for the
---    user's input, then the pointer goes back where it was.
--- 3. Fail closed: an unreadable lock state, pause state or secure-field
---    answer counts as "do not click".
--- 4. Capture, matching and OCR run in the launcher's vision worker
---    (platform/vision/screen_vision.lua); a missing Screen Recording grant is
---    a red row of the « Anti-veille » submenu, never a silent failure.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local ConfigPaths = require("settings.engine.paths")
local AppDirs = require("core.fs.engine.app_dirs")
local FileSystem = require("core.fs.adapters.file_system")
local Timings = require("core.timing.engine.timings")
local TimerScheduler = require("core.events.timer_scheduler")
local Library = require("shortcuts.engine.keep_awake_library")
local Session = require("shortcuts.engine.auto_click_session")

local LOG = "modules.shortcuts.auto_click"

local _library = nil
local _session = nil
local _timer = nil
local _coupled = false
local _clicks_total = 0
local _ports = nil
local _vision_started = false




-- =========================================
-- =========================================
-- ======= 1/ Library ======================
-- =========================================
-- =========================================

local function read_shared(relative)
	local raw = FileSystem.read(Paths.shared(relative))
	local decoded = type(raw) == "string" and Json.decode(raw) or nil
	assert(type(decoded) == "table", relative .. " is unreadable")
	return decoded
end

local function vision()
	local Vision = require("platform.vision.screen_vision")
	if not _vision_started then
		Vision.init({ cache_dir = os.getenv("HOME") .. "/" .. AppDirs.macos.cache_relative .. "/vision" })
		Vision.refresh_availability(function() if _library then _library.changed() end end)
		_vision_started = true
	end
	return Vision
end

--- The capture and OCR problems the menu shows, as reasons.
local function problems()
	if not _vision_started then return {} end
	local state = vision().availability()
	local out = {}
	if not state.capture.ok and state.capture.reason then out[#out + 1] = state.capture.reason end
	if state.capture.ok and not state.ocr.ok and state.ocr.reason then out[#out + 1] = state.ocr.reason end
	return out
end

--- The shared library store with the macOS ports.
local function library()
	if _library then return _library end
	_library = Library.new({
		os_name = "macos", separator = "/",
		read_shared = read_shared,
		config_dir = function() return (ConfigPaths.get_config_dir():gsub("/+$", "")) end,
		-- A file-system port without `exists` (a test double) has no saved document.
		exists = function(path) return type(FileSystem.exists) == "function" and FileSystem.exists(path) == true end,
		read = FileSystem.read,
		ensure_dirs = function(folder, images)
			return ConfigPaths.ensure_dir(folder .. "/") ~= false and ConfigPaths.ensure_dir(images .. "/") ~= false
		end,
		write_atomic = function(path, text) return FileSystem.write(path, text) == true end,
		encode = Json.encode, decode = Json.decode,
		text = function(key) return require("core.i18n.engine.i18n").get(key) end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
		unavailable_reason = function() return nil end,
		problems = problems,
		clicks = function() return _clicks_total end,
	})
	return _library
end

--- The presets document.
function M.document() return library().document() end

--- Applies one edit of the shared store and writes the document after it.
function M.edit(op, ...) return library().edit(op, ...) end

--- Subscribes to every change (the menu redraws its rows).
function M.on_change(fn) library().on_change(fn) end

--- What the active preset runs on macOS.
function M.active_plan() return library().active_plan() end

--- The rows of the menu's presets list.
function M.preset_rows() return library().preset_rows() end

--- The rows of the menu's options list.
function M.option_rows() return library().option_rows() end




-- =========================================
-- =========================================
-- ======= 2/ Ports ========================
-- =========================================
-- =========================================

local function default_ports()
	return require("adapters.auto_click_ports").ports(vision)
end

--- Binds test ports in place of the native ones.
function M._set_ports(ports)
	_ports = ports
end

--- Forgets the cached document and session (tests).
function M._reset()
	if _session then M.stop() end
	if _library then _library.reset() end
	_library, _ports, _clicks_total, _coupled = nil, nil, 0, false
end




-- =========================================
-- =========================================
-- ======= 3/ Session and mode =============
-- =========================================
-- =========================================

--- Whether the auto-clicker runs.
function M.running()
	return _session ~= nil
end

--- The clicks since the driver started, for the menu row.
function M.clicks()
	return _clicks_total
end

local function system()
	return require("modules.shortcuts.actions.system")
end

--- Starts the auto-clicker for a plan.
--- @param plan table As active_plan returns it.
--- @param coupled boolean Whether it ends with the keep-awake session.
--- @return boolean started
function M.start(plan, coupled)
	if _session then return true end
	if not plan.auto_click then return false end
	local ports = _ports or default_ports()
	local base_click = ports.on_click
	ports.on_click = function(count, target)
		_clicks_total = _clicks_total + 1
		if base_click then base_click(count, target) end
		library().changed()
	end
	local defaults = read_shared("shortcuts/data/auto_click_defaults.json")
	_session = Session.new(ports, plan, {
		options = defaults, cooldown_ms = Timings.ms("keep_awake", "auto_click_cooldown_ms"),
		ocr = { layout = "sparse", languages = ports.languages and ports.languages() or {} },
	})
	_coupled = coupled == true
	_timer = TimerScheduler.every(Timings.sec("keep_awake", "auto_click_tick_ms"), function()
		if not _session then return end
		-- The keep-awake session ended (physical input, pause): the mode ends.
		if _coupled and not system().is_awake_active() then
			Logger.info(LOG, "The keep-awake session ended; automatic clicks stop with it.")
			M.stop()
			return
		end
		_session.tick()
	end)
	Logger.info(LOG, "Auto-click started: %d image(s), %d text target(s).", #plan.templates, #plan.text_targets)
	return true
end

--- Stops the auto-clicker; a scan still running is ignored when it answers.
function M.stop()
	if not _session then return true end
	_session.stop()
	_session = nil
	if _timer then TimerScheduler.cancel(_timer) end
	_timer = nil
	Logger.info(LOG, "Auto-click stopped.")
	return true
end

--- Toggles the anti-sleep mode with the active preset (Ctrl+M).
--- @return boolean admitted
function M.toggle_mode()
	local Sys = system()
	if _session or Sys.is_awake_active() then
		local clicked = M.stop()
		if Sys.is_awake_active() then return Sys.toggle_awake() and clicked end
		return clicked
	end
	local plan = M.active_plan()
	if not plan.keep_awake and not plan.auto_click then
		Logger.warn(LOG, "The active anti-sleep preset keeps nothing awake and clicks nothing.")
		require("core.ui.engine.notifications").notify(require("core.i18n.engine.i18n").get("keepawake.preset_empty"),
			nil, "warning")
		return false
	end
	local admitted = true
	if plan.keep_awake then admitted = Sys.toggle_awake() == true end
	if plan.auto_click then
		if not _ports then vision() end
		admitted = M.start(plan, plan.keep_awake) and admitted
	end
	return admitted
end

return M
