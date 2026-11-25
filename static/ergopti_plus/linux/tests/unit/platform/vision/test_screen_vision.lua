--- tests/unit/platform/vision/test_screen_vision.lua

--- ==============================================================================
--- MODULE: Screen Vision Service Tests (Linux)
--- DESCRIPTION:
--- Drives the Linux screen vision service through a scripted X transport and a
--- scripted tesseract child: a window capture becomes the shared gray image
--- with its screen frame, a library image is found in it, a recognition's TSV
--- becomes words and a text target is found among them, and each refusal is a
--- reason rather than an empty answer.
--- ==============================================================================

local helpers = require("tests.helpers")

local ShellRunner = require("core.process.adapters.shell_runner")

-- A 40 x 20 window at (100, 50) on screen: background 200 with a 12 x 6
-- textured block at (20, 8), every pixel given as blue, green, red.
local WINDOW_W, WINDOW_H = 40, 20

local function block_value(x, y)
	return ((x * 7 + y * 13) % 5) * 40
end

local function scripted_transport()
	local transport = { connected = false }
	function transport.connect() transport.connected = true; return true end
	function transport.disconnect() transport.connected = false end
	function transport.healthy() return transport.connected end
	function transport.root() return 1 end
	function transport.geometry(window)
		if window ~= 4242 then return nil end
		return 100, 50, WINDOW_W, WINDOW_H
	end
	function transport.image(drawable, x, y, width, height, gray)
		local pixels = {}
		for row = 0, height - 1 do
			for col = 0, width - 1 do
				local v = 200
				if col >= 20 and col < 32 and row >= 8 and row < 14 then v = block_value(col, row) end
				pixels[#pixels + 1] = gray(v, v, v)
			end
		end
		return pixels
	end
	return transport
end

local TSV = table.concat({
	"level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext",
	"1\t1\t0\t0\t0\t0\t0\t0\t40\t20\t-1\t",
	"5\t1\t1\t1\t1\t1\t2\t3\t10\t6\t91.5\tAutoriser",
	"5\t1\t1\t1\t1\t2\t14\t3\t5\t6\t88\tune",
	"5\t1\t1\t1\t1\t3\t21\t3\t6\t6\t90\tfois",
	"5\t1\t2\t1\t1\t1\t2\t12\t9\t6\t-1\t ",
}, "\n") .. "\n"

local function fresh_service(env)
	package.loaded["platform.vision.x11_capture"] = nil
	package.loaded["platform.vision.tesseract_ocr"] = nil
	local Service = helpers.load_module("platform.vision.screen_vision")
	Service.init({ transport = scripted_transport(), getenv = function(name) return env[name] end })
	return Service
end

helpers.describe("screen vision service (Linux)", function()
	helpers.it("screen vision: captures a window as the shared gray image with its screen frame", function()
		local Service = fresh_service({ DISPLAY = ":0" })
		local image, reason = Service.capture_window("4242")
		helpers.assert_nil(reason, "no refusal")
		helpers.assert_eq(image.width, WINDOW_W, "width")
		helpers.assert_eq(image.height, WINDOW_H, "height")
		helpers.assert_eq(image.scale, 1, "X11 captures one pixel per screen unit")
		helpers.assert_eq(image.frame.x, 100, "frame x")
		helpers.assert_eq(image.frame.y, 50, "frame y")
		helpers.assert_eq(#image.pixels, WINDOW_W * WINDOW_H, "pixel count")
		Service.stop()
	end)

	helpers.it("screen vision: finds a library image in the capture and refuses a flat one", function()
		local Service = fresh_service({ DISPLAY = ":0" })
		local image = Service.capture_window(4242)
		local rows = {}
		for row = 8, 13 do
			rows[#rows + 1] = {}
			for col = 20, 31 do rows[#rows][#rows[#rows] + 1] = block_value(col, row) end
		end
		local Matcher = require("shortcuts.engine.auto_click_matcher")
		local flat = Matcher.from_rows({ { 9, 9 }, { 9, 9 } })
		local hits, refused = Service.match(image, {
			{ id = "button", image = Matcher.from_rows(rows), threshold = 0.95 },
			{ id = "flat", image = flat },
		}, { threshold = 0.92, scales = { 1 }, coarse_min_px = 6, coarse_margin = 0.15, coarse_candidates = 8 })
		helpers.assert_eq(#hits, 1, "one hit")
		helpers.assert_eq(hits[1].id, "button", "the button")
		helpers.assert_eq(hits[1].x, 20, "hit x")
		helpers.assert_eq(hits[1].y, 8, "hit y")
		helpers.assert_eq(refused.flat, "template_uniform", "the flat image is refused with its reason")
		Service.stop()
	end)

	helpers.it("screen vision: names each refusal instead of answering empty", function()
		local Service = fresh_service({ DISPLAY = ":0" })
		local image, reason = Service.capture_window("17")
		helpers.assert_nil(image, "an unknown window")
		helpers.assert_eq(reason, "no_foreground_window", "unknown window reason")
		Service.stop()

		Service = fresh_service({})
		local state = Service.availability()
		helpers.assert_eq(state.capture.ok, false, "no X display")
		helpers.assert_eq(state.capture.reason, "capture_no_x_display", "no X display reason")
		Service.stop()

		Service = fresh_service({ DISPLAY = ":0", XDG_SESSION_TYPE = "wayland" })
		state = Service.availability()
		helpers.assert_eq(state.capture.ok, true, "an XWayland window is still captured")
		helpers.assert_eq(state.region.reason, "capture_wayland_region", "a Wayland screen region is refused")
		local region, region_reason = Service.capture_region({ x = 0, y = 0, width = 10, height = 10 })
		helpers.assert_nil(region, "no Wayland region")
		helpers.assert_eq(region_reason, "capture_wayland_region", "region reason")
		Service.stop()
	end)

	helpers.it("screen vision: refuses a second initialisation", function()
		local Service = fresh_service({ DISPLAY = ":0" })
		helpers.assert_throws(function() Service.init({ transport = scripted_transport() }) end, "a second init")
		Service.stop()
	end)

	helpers.it("screen vision: recognises text through tesseract and finds a target among the words", function()
		local Service = fresh_service({ DISPLAY = ":0" })
		local calls = {}
		ShellRunner._set_runner(function() return true end)
		ShellRunner._set_async_runner(function(executable, args, options, callback)
			calls[#calls + 1] = { executable = executable, args = args, options = options }
			if args[1] == "--list-langs" then
				callback({ ok = true, stdout = "List of available languages (3):\neng\nfra\nosd\n" })
			else
				callback({ ok = true, stdout = TSV })
			end
			return { cancel = function() end, on_settled = function() end }
		end)
		local image = Service.capture_window(4242)
		local words, reason
		Service.recognize_text(image, { layout = "sparse", locale = "fr" }, function(w, r) words, reason = w, r end)
		ShellRunner._set_async_runner(nil)
		ShellRunner._reset_runner()
		helpers.assert_nil(reason, "no refusal")
		helpers.assert_eq(#words, 3, "three words, the empty row left out")
		helpers.assert_eq(words[1].confidence, 0.915, "confidence on 0 to 1")
		local ocr = calls[#calls]
		helpers.assert_eq(ocr.executable, "tesseract", "tesseract runs")
		helpers.assert_eq(ocr.args[3], "-l", "languages flag")
		helpers.assert_eq(ocr.args[4], "fra+eng", "interface language then English")
		helpers.assert_eq(ocr.args[6], "11", "sparse layout")
		local hits = Service.find_text(words, { { id = "allow", variants = { "Allow once", "Autoriser une fois" },
			max_distance = 0 } })
		helpers.assert_eq(#hits, 1, "one text hit")
		helpers.assert_eq(hits[1].x, 2, "hit x")
		helpers.assert_eq(hits[1].width, 25, "hit spans the three words")
		Service.stop()
	end)

	helpers.it("screen vision: greys text recognition when tesseract is missing", function()
		local Service = fresh_service({ DISPLAY = ":0" })
		ShellRunner._set_runner(function() return false end)
		local state = Service.availability()
		local words, reason
		Service.recognize_text({ width = 1, height = 1, pixels = { 0 } }, { layout = "block", locale = "en" },
			function(w, r) words, reason = w, r end)
		ShellRunner._reset_runner()
		helpers.assert_eq(state.ocr.ok, false, "no OCR")
		helpers.assert_eq(state.ocr.reason, "ocr_engine_missing", "OCR reason")
		helpers.assert_nil(words, "no words")
		helpers.assert_eq(reason, "ocr_engine_missing", "callback reason")
		Service.stop()
	end)
end)
