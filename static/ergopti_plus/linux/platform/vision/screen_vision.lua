--- platform/vision/screen_vision.lua

--- ==============================================================================
--- MODULE: Screen Vision Service (Linux)
--- DESCRIPTION:
--- The Linux implementation of the screen vision service: capture a window or
--- a region into a grayscale image, find library images in it, recognise its
--- text, and find text targets among the recognised words. The anti-sleep
--- auto-clicker, the Ctrl+O text capture and the user workflows call only this
--- interface (docs/design/screen-vision.md), never the capture or OCR modules.
---
--- FEATURES & RATIONALE:
--- 1. One owner: init() binds the X transport and the shared folding table
---    once; a second init() is refused, and every call before init() fails
---    fast rather than answering "unavailable".
--- 2. availability() names what works and why the rest does not, as a reason
---    of the closed vocabulary: the menu greys an option with that reason and
---    component_status shows it in red, so nothing fails silently.
--- 3. Wayland: a window is captured through XWayland (VS Code's default), a
---    region of the screen is not: the root window of XWayland shows nothing
---    of native Wayland windows, so capture_region refuses with
---    "capture_wayland_region" and the Ctrl+O action keeps the screenshot tool
---    cascade, whose file recognize_file reads.
--- 4. Matching and text targets are the shared modules, so a hit means the
---    same thing on the three OS.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
local Matcher = require("shortcuts.engine.auto_click_matcher")
local TextTarget = require("shortcuts.engine.text_target")
local Capture = require("platform.vision.x11_capture")
local Ocr = require("platform.vision.tesseract_ocr")

local LOG = "platform.vision.screen_vision"

local _initialized = false
local _capture_reason = nil
local _environment = os.getenv




-- =========================================
-- =========================================
-- ======= 1/ Lifecycle ====================
-- =========================================
-- =========================================

--- Whether the session is Wayland.
local function is_wayland()
	local session = _environment("XDG_SESSION_TYPE")
	if session == "wayland" then return true end
	local display = _environment("WAYLAND_DISPLAY")
	return display ~= nil and display ~= ""
end

--- Starts the service once.
--- @param options table|nil { transport = test double, getenv = test seam }
--- @return boolean ok
function M.init(options)
	assert(not _initialized, "the screen vision service is already initialised")
	options = options or {}
	if options.getenv then _environment = options.getenv end
	Logger.start(LOG, "Starting the screen vision service.")
	local handle = assert(io.open(Paths.shared("core/text/data/text_fold.json"), "rb"))
	local text = handle:read("*a")
	handle:close()
	TextTarget.set_fold(assert(Json.decode(text), "text_fold.json is not valid JSON").fold)
	local display = _environment("DISPLAY")
	if not display or display == "" then
		_capture_reason = "capture_no_x_display"
	else
		local bound, reason = Capture.bind(options.transport)
		if not bound then
			Logger.warn(LOG, "Screen capture unavailable: %s.", tostring(reason))
			_capture_reason = "capture_unavailable"
		end
	end
	_initialized = true
	Logger.success(LOG, "Screen vision service started (capture %s).", _capture_reason or "ready")
	return true
end

--- Stops the service; init() may run again.
function M.stop()
	if not _initialized then return end
	Capture.close()
	_initialized, _capture_reason, _environment = false, nil, os.getenv
	Logger.info(LOG, "Screen vision service stopped.")
end

local function require_init()
	assert(_initialized, "the screen vision service is not initialised")
end




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- What works now.
--- @return table { capture = { ok, reason }, region = { ok, reason }, ocr = { ok, reason } }
function M.availability()
	require_init()
	local ocr_ok, ocr_reason = Ocr.available()
	local region_ok, region_reason = _capture_reason == nil, _capture_reason
	if region_ok and is_wayland() then region_ok, region_reason = false, "capture_wayland_region" end
	return {
		capture = { ok = _capture_reason == nil, reason = _capture_reason },
		region = { ok = region_ok, reason = region_reason },
		ocr = { ok = ocr_ok, reason = ocr_reason },
	}
end

-- The component_status code and row label of each service part that can fail.
local PROBLEMS = {
	capture = { code = "screen_vision_capture", label = "keepawake.reason.capture_unavailable" },
	ocr = { code = "screen_vision_ocr", label = "keepawake.reason.ocr_engine_missing" },
}

--- Names a part the user needs that does not work as a red tray row
--- (core.ui.engine.component_status), shown while it still does not work.
--- Called when a feature asks for the part, never at boot: OCR and capture
--- are optional, and a row for a feature nobody uses would be noise.
--- @param part string "capture" or "ocr".
--- @return boolean reported True when the part does not work.
function M.report_problem(part)
	local problem = assert(PROBLEMS[part], "unknown screen vision part " .. tostring(part))
	local state = M.availability()[part]
	if state.ok then return false end
	local text = require("core.i18n.engine.i18n").get("keepawake.reason." .. tostring(state.reason))
	require("core.ui.engine.component_status").report({
		code = problem.code,
		title = require("core.i18n.engine.i18n").get(problem.label),
		body = text,
		active = function() return not M.availability()[part].ok end,
	})
	return true
end

--- Captures one window.
--- @param window string|number The X window id the focus query returned.
--- @param callback function (image|nil, reason), called before this returns on Linux.
function M.capture_window(window, callback)
	require_init()
	if _capture_reason then callback(nil, _capture_reason); return end
	callback(Capture.capture({ window = window }, Matcher.gray))
end

--- Captures a rectangle of the screen, in root coordinates.
--- @param rect table { x, y, width, height }
--- @param callback function (image|nil, reason)
function M.capture_region(rect, callback)
	require_init()
	local state = M.availability().region
	if not state.ok then callback(nil, state.reason); return end
	callback(Capture.capture({ rect = rect }, Matcher.gray))
end

--- Captures the whole screen (the root window), on X11 only as a region is.
--- @param callback function (image|nil, reason)
function M.capture_screen(callback)
	require_init()
	local state = M.availability().region
	if not state.ok then callback(nil, state.reason); return end
	callback(Capture.capture({ root = true }, Matcher.gray))
end

--- Finds library images in a captured image, synchronously.
--- @return table hits, table refused
local function match_now(image, templates, options)
	local hits, refused = {}, {}
	for _, template in ipairs(templates) do
		local per = {}
		for key, value in pairs(options) do per[key] = value end
		per.threshold = template.threshold or options.threshold
		local hit, reason = Matcher.find(image, template.image, per)
		if hit then
			hit.id = template.id
			hits[#hits + 1] = hit
		elseif reason then
			refused[template.id] = reason
		end
	end
	return hits, refused
end

--- Finds library images in a captured image.
--- @param image table
--- @param templates table { { id, image, threshold } }
--- @param options table The matcher options (auto_click_defaults.json), threshold per template.
--- @param callback function (hits, refused): hits { id, x, y, width, height, score, scale }
---   in template order, refused { [id] = reason } for templates that cannot match.
function M.match(image, templates, options, callback)
	require_init()
	callback(match_now(image, templates, options))
end

--- Recognises the text of a captured image.
--- @param image table
--- @param options table { layout = "sparse"|"block", locale = string }
--- @param callback function (words|nil, reason)
function M.recognize_text(image, options, callback)
	require_init()
	local ok, reason = Ocr.available()
	if not ok then callback(nil, reason); return end
	Ocr.recognize(image, options, callback)
end

--- Recognises the text of an image file (a screenshot tool's capture).
--- @param path string
--- @param options table As recognize_text.
--- @param callback function (words|nil, reason)
function M.recognize_file(path, options, callback)
	require_init()
	local ok, reason = Ocr.available()
	if not ok then callback(nil, reason); return end
	Ocr.recognize_file(path, options, callback)
end

--- Captures a window and looks for library images and text targets in it,
--- the auto-clicker's tick in one call (on macOS, one launcher worker run).
--- @param window string|number The X window id.
--- @param request table { templates, options, text_targets, ocr = { layout, locale } }
---   text_targets may be empty; OCR runs only when it is not.
--- @param callback function (result|nil, reason): result { image, hits, text_hits, refused }
---   with hits and text_hits in image pixels; text_reason names why text was not read.
function M.scan_window(window, request, callback)
	require_init()
	M.capture_window(window, function(image, reason)
		if not image then callback(nil, reason); return end
		local hits, refused = match_now(image, request.templates or {}, request.options)
		local targets = request.text_targets or {}
		if #targets == 0 then
			callback({ image = image, hits = hits, text_hits = {}, refused = refused })
			return
		end
		M.recognize_text(image, request.ocr, function(words, ocr_reason)
			callback({ image = image, hits = hits, refused = refused,
				text_hits = words and M.find_text(words, targets) or {}, text_reason = ocr_reason })
		end)
	end)
end

--- Finds text targets among recognised words.
--- @param words table As recognize_text returns them.
--- @param targets table { { id, variants, max_distance } }
--- @return table hits { id, variant, text, x, y, width, height, distance }
function M.find_text(words, targets)
	require_init()
	return TextTarget.find_all(words, targets)
end

-- The shell that converts an image file of any format ImageMagick reads (the
-- first frame of a GIF or a multi-page TIFF) into a PNG, and checks that the
-- PNG is whole: ImageMagick 7 can exit 0 after a refused write.
local IMPORT_SCRIPT = table.concat({
	'src="$1"; out="$2"',
	'has() { command -v "$1" >/dev/null 2>&1; }',
	'whole_png() { [ "$(tail -c 8 -- "$1" | od -An -tx1 | tr -d \' \\n\')" = 49454e44ae426082 ]; }',
	'if has magick; then magick "${src}[0]" -strip "PNG32:$out" || exit 1',
	'elif has convert; then convert "${src}[0]" -strip "PNG32:$out" || exit 1',
	'else exit 3; fi',
	'whole_png "$out" || { rm -f -- "$out"; exit 1; }',
}, "\n")

--- Converts an image file of any common format into a library PNG.
--- @param path string The file the user picked.
--- @param out_path string The PNG to write.
--- @param callback function (out_path|nil, reason): import_tool_missing without ImageMagick.
function M.import_image(path, out_path, callback)
	require_init()
	local handle = require("core.process.adapters.shell_runner").run_async("sh",
		{ "-c", IMPORT_SCRIPT, "ergopti-import", path, out_path },
		{ timeout_ms = require("core.timing.engine.timings").ms("screen_vision", "ocr_timeout_ms") }, function(result)
			if result.ok then return callback(out_path) end
			if result.code == 3 then return callback(nil, "import_tool_missing") end
			Logger.warn(LOG, "The image could not be converted to PNG: %s.", tostring(result.error or result.code))
			callback(nil, "import_failed")
		end)
	if not handle then callback(nil, "import_failed") end
end

return M
