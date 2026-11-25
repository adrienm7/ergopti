--- platform/vision/screen_vision.lua

--- ==============================================================================
--- MODULE: Screen Vision Service (macOS)
--- DESCRIPTION:
--- The macOS implementation of the screen vision service
--- (docs/design/screen-vision.md). Capture, image matching and Vision text
--- recognition run in the signed launcher's headless worker
--- (launcher/Sources/ErgoptiPlus/ScreenVisionWorker.swift); this module sends
--- it one JSON request per call and reads one JSON answer. Text targets are
--- matched here, through the shared module, on the words the worker returns.
---
--- FEATURES & RATIONALE:
--- 1. Native speed: the shared Lua matcher took about 0.8 s per scale on
---    Hammerspoon's Lua 5.4; the worker's Swift port does a whole window in
---    a few hundred milliseconds, and scan_window captures, matches and reads
---    in one run.
--- 2. Never blocks Hammerspoon's run loop: every call is a child process with
---    a deadline from the timings registry, answered through its callback once.
--- 3. Images stay in the launcher: a capture is a private PNG under the user's
---    Caches folder, named in the image's `source`, and it carries no pixels.
---    Callers only pass it back to the service.
--- 4. Every refusal is a reason of the closed vocabulary; a missing Screen
---    Recording grant is "capture_permission_missing", which the menu shows
---    as a red component_status row.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local Timings = require("core.timing.engine.timings")
local TimerScheduler = require("core.events.timer_scheduler")
local ShellRunner = require("core.process.adapters.shell_runner")
local LauncherHelper = require("platform.remap.lease_helper")
local TextTarget = require("shortcuts.engine.text_target")
local Paths = require("core.fs.engine.paths")
local FileSystem = require("core.fs.adapters.file_system")

local LOG = "platform.vision.screen_vision"
local WORKER_FLAG = "--screen-vision"

local _initialized = false
local _cache_dir = nil
local _capture_counter = 0
local _availability = nil
local _runner = nil




-- =========================================
-- =========================================
-- ======= 1/ Worker ========================
-- =========================================
-- =========================================

--- Runs one worker request with a deadline and answers once.
--- @param request table The JSON request.
--- @param callback function (answer|nil, reason)
local function run_worker(request, callback)
	local answered = false
	local function answer(result, reason)
		if answered then return end
		answered = true
		local ok, err = pcall(callback, result, reason)
		if not ok then Logger.error(LOG, "A screen vision callback raised: %s.", tostring(err)) end
	end
	if _runner then
		_runner(request, answer)
		return
	end
	local resolved, executable, detail, environment = xpcall(LauncherHelper.resolve, debug.traceback)
	if not resolved or type(executable) ~= "string" or executable == "" then
		Logger.error(LOG, "The launcher worker is unavailable: %s.", tostring(resolved and detail or executable))
		answer(nil, "capture_unavailable")
		return
	end
	local timer = nil
	local task = ShellRunner.spawn(executable, { WORKER_FLAG }, function(exit_code, stdout)
		if timer then TimerScheduler.cancel(timer) end
		if exit_code ~= 0 then
			Logger.error(LOG, "The screen vision worker (%s) exited with %s.", tostring(request.op), tostring(exit_code))
			answer(nil, "ocr_failed")
			return
		end
		local decoded = Json.decode(stdout or "")
		if type(decoded) ~= "table" then
			Logger.error(LOG, "The screen vision worker (%s) answered no JSON.", tostring(request.op))
			answer(nil, "ocr_failed")
			return
		end
		if decoded.ok ~= true then
			answer(nil, type(decoded.reason) == "string" and decoded.reason or "ocr_failed")
			return
		end
		answer(decoded)
	end, nil, environment, true)
	if type(task) ~= "table" or task.set_input(Json.encode(request)) ~= true then
		Logger.error(LOG, "The screen vision worker (%s) could not be started.", tostring(request.op))
		answer(nil, "capture_unavailable")
		return
	end
	timer = TimerScheduler.after(Timings.sec("screen_vision", "ocr_timeout_ms"), function()
		if answered then return end
		Logger.error(LOG, "The screen vision worker (%s) timed out.", tostring(request.op))
		task.terminate()
		answer(nil, "ocr_timeout")
	end)
	if task.start() ~= true then
		if timer then TimerScheduler.cancel(timer) end
		Logger.error(LOG, "The screen vision worker (%s) refused to start.", tostring(request.op))
		answer(nil, "capture_unavailable")
	end
end

--- A private path for one kept capture.
local function capture_path()
	_capture_counter = _capture_counter + 1
	return string.format("%s/capture-%d-%d.png", _cache_dir, os.time(), _capture_counter)
end

--- Builds an image from a worker answer.
local function image_of(answer, source)
	return { width = answer.width, height = answer.height, scale = answer.scale, frame = answer.frame,
		source = source }
end




-- =========================================
-- =========================================
-- ======= 2/ Lifecycle ====================
-- =========================================
-- =========================================

--- Starts the service once.
--- @param options table { cache_dir = string, runner = test double (request, answer) }
--- @return boolean ok
function M.init(options)
	assert(not _initialized, "the screen vision service is already initialised")
	assert(type(options) == "table" and type(options.cache_dir) == "string" and options.cache_dir ~= "",
		"the screen vision service needs its private cache folder")
	Logger.start(LOG, "Starting the screen vision service.")
	_cache_dir = options.cache_dir
	_runner = options.runner
	assert(require("settings.engine.paths").ensure_dir(_cache_dir .. "/"),
		"the screen vision cache folder cannot be created")
	local raw = FileSystem.read(Paths.shared("core/text/data/text_fold.json"))
	local fold = type(raw) == "string" and Json.decode(raw) or nil
	TextTarget.set_fold(assert(fold, "text_fold.json is not valid JSON").fold)
	_initialized = true
	Logger.success(LOG, "Screen vision service started.")
	return true
end

--- Stops the service; init() may run again.
function M.stop()
	if not _initialized then return end
	_initialized, _cache_dir, _runner, _availability = false, nil, nil, nil
	Logger.info(LOG, "Screen vision service stopped.")
end

local function require_init()
	assert(_initialized, "the screen vision service is not initialised")
end




-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Refreshes what works now; the answer is cached until the next refresh.
--- @param callback function|nil (availability)
function M.refresh_availability(callback)
	require_init()
	run_worker({ op = "availability" }, function(answer, reason)
		if answer then
			_availability = { capture = answer.capture, region = answer.capture, ocr = answer.ocr }
		else
			_availability = { capture = { ok = false, reason = reason }, region = { ok = false, reason = reason },
				ocr = { ok = false, reason = reason } }
		end
		Logger.info(LOG, "Screen vision availability: capture %s, ocr %s.",
			_availability.capture.ok and "ready" or tostring(_availability.capture.reason),
			_availability.ocr.ok and "ready" or tostring(_availability.ocr.reason))
		if callback then callback(_availability) end
	end)
end

--- What works now, as last refreshed; unknown until the first refresh.
--- @return table { capture, region, ocr }, each { ok, reason }
function M.availability()
	require_init()
	return _availability or { capture = { ok = false, reason = "capture_unavailable" },
		region = { ok = false, reason = "capture_unavailable" }, ocr = { ok = false, reason = "ocr_failed" } }
end

--- A private path in the vision cache for a capture the caller writes.
--- @return string path
function M.new_capture_path()
	require_init()
	return capture_path()
end

--- Captures one window into a private file.
--- @param window number The CGWindowID (hs.window:id()).
--- @param callback function (image|nil, reason)
function M.capture_window(window, callback)
	require_init()
	local path = capture_path()
	run_worker({ op = "capture", window_id = window, out_path = path }, function(answer, reason)
		if not answer then callback(nil, reason); return end
		callback(image_of(answer, path))
	end)
end

--- Captures a rectangle of the screen, in points, into a private file.
--- @param rect table { x, y, width, height }
--- @param callback function (image|nil, reason)
function M.capture_region(rect, callback)
	require_init()
	local path = capture_path()
	run_worker({ op = "capture", rect = rect, out_path = path }, function(answer, reason)
		if not answer then callback(nil, reason); return end
		callback(image_of(answer, path))
	end)
end

--- Finds library images in a captured image.
--- @param image table As capture_* returns it.
--- @param templates table { { id, path, threshold } }: library PNG files.
--- @param options table The matcher options.
--- @param callback function (hits, refused)
function M.match(image, templates, options, callback)
	require_init()
	run_worker({ op = "match", source = image.source, templates = templates, options = options },
		function(answer, reason)
			if not answer then
				local refused = {}
				for _, template in ipairs(templates) do refused[template.id] = reason end
				callback({}, refused)
				return
			end
			callback(answer.hits or {}, answer.refused or {})
		end)
end

--- Recognises the text of a captured image.
--- @param image table As capture_* returns it.
--- @param options table { layout, languages = { BCP 47 tags } }
--- @param callback function (words|nil, reason)
function M.recognize_text(image, options, callback)
	require_init()
	M.recognize_file(image.source, options, callback)
end

--- Recognises the text of an image file.
--- @param path string
--- @param options table As recognize_text.
--- @param callback function (words|nil, reason)
function M.recognize_file(path, options, callback)
	require_init()
	run_worker({ op = "ocr", source = path, ocr = options }, function(answer, reason)
		if not answer then callback(nil, reason); return end
		callback(answer.words or {})
	end)
end

--- Captures a window, matches its library images and reads its text targets in one worker run.
--- @param window number The CGWindowID.
--- @param request table { templates, options, text_targets, ocr }
--- @param callback function (result|nil, reason)
function M.scan_window(window, request, callback)
	require_init()
	local targets = request.text_targets or {}
	run_worker({ op = "scan", window_id = window, templates = request.templates or {}, options = request.options,
		ocr = #targets > 0 and request.ocr or nil }, function(answer, reason)
		if not answer then callback(nil, reason); return end
		local image = image_of(answer, nil)
		local text_hits = (#targets > 0 and answer.words) and M.find_text(answer.words, targets) or {}
		callback({ image = image, hits = answer.hits or {}, refused = answer.refused or {}, text_hits = text_hits,
			text_reason = answer.text_reason })
	end)
end

--- Converts an image file of any format macOS decodes into a library PNG.
--- @param path string The user's file.
--- @param out_path string The library file to write.
--- @param callback function (info|nil, reason): info { width, height }
function M.import_image(path, out_path, callback)
	require_init()
	run_worker({ op = "import", path = path, out_path = out_path }, function(answer, reason)
		if not answer then callback(nil, reason); return end
		callback({ width = answer.width, height = answer.height })
	end)
end

--- Finds text targets among recognised words.
--- @param words table
--- @param targets table { { id, variants, max_distance } }
--- @return table hits
function M.find_text(words, targets)
	require_init()
	return TextTarget.find_all(words, targets)
end

return M
