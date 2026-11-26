--- tests/unit/platform/system/test_screen_vision.lua

--- ==============================================================================
--- MODULE: Screen Vision Service Tests (macOS)
--- DESCRIPTION:
--- Drives the macOS screen vision service through a scripted launcher worker:
--- each call sends the worker the request its op names, a scan reads text
--- targets on the words the worker returned, captures stay private files the
--- image only names, and a refusal reaches the caller as its reason.
--- ==============================================================================

local helpers = require("tests.helpers")

local OPTIONS = { threshold = 0.92, scales = { 1, 0.5, 2 }, coarse_min_px = 6, coarse_margin = 0.15,
	coarse_candidates = 8 }

local function fresh_service(script)
	local requests = {}
	package.loaded["platform.system.vision.screen_vision"] = nil
	local Service = require("platform.system.vision.screen_vision")
	local dir = os.tmpname()
	os.remove(dir)
	Service.init({ cache_dir = dir, runner = function(request, answer)
		requests[#requests + 1] = request
		answer(script(request))
	end })
	return Service, requests
end

local function now(call, ...)
	local result
	local args = { ... }
	args[#args + 1] = function(...) result = { ... } end
	call(table.unpack(args))
	assert(result, "the call did not answer")
	return table.unpack(result)
end

helpers.describe("screen vision service (macOS)", function()
	helpers.it("screen vision: scans a window in one worker run and finds its text targets", function()
		local Service, requests = fresh_service(function()
			return { ok = true, width = 800, height = 600, scale = 1, frame = { x = 10, y = 20, width = 800, height = 600 },
				hits = { { id = "button", x = 5, y = 6, width = 40, height = 12, score = 0.97, scale = 1 } },
				refused = {},
				words = {
					{ text = "Allow", x = 600, y = 500, width = 40, height = 14, confidence = 1, line = "3" },
					{ text = "once", x = 645, y = 500, width = 35, height = 14, confidence = 1, line = "3" },
				} }
		end)
		local result = now(Service.scan_window, 4711, {
			templates = { { id = "button", path = "/library/button.png" } }, options = OPTIONS,
			text_targets = { { id = "allow", variants = { "Allow once" }, max_distance = 0 } },
			ocr = { layout = "sparse", languages = { "fr-FR", "en-US" } },
		})
		helpers.assert_eq(#requests, 1, "one worker run")
		helpers.assert_eq(requests[1].op, "scan", "the scan op")
		helpers.assert_eq(requests[1].window_id, 4711, "the window")
		helpers.assert_not_nil(requests[1].ocr, "text targets ask for OCR")
		helpers.assert_eq(#result.hits, 1, "the image hit")
		helpers.assert_eq(#result.text_hits, 1, "the caption")
		helpers.assert_eq(result.text_hits[1].x, 600, "caption x")
		helpers.assert_eq(result.text_hits[1].width, 80, "caption spans both words")
		helpers.assert_eq(result.image.frame.x, 10, "the frame")
		Service.stop()
	end)

	helpers.it("screen vision: skips OCR when no text target is asked", function()
		local Service, requests = fresh_service(function()
			return { ok = true, width = 1, height = 1, scale = 2, frame = { x = 0, y = 0, width = 1, height = 1 },
				hits = {}, refused = {} }
		end)
		now(Service.scan_window, 1, { templates = {}, options = OPTIONS, text_targets = {} })
		helpers.assert_nil(requests[1].ocr, "no OCR without a text target")
		Service.stop()
	end)

	helpers.it("screen vision: keeps a capture as a private file the image names", function()
		local Service, requests = fresh_service(function()
			return { ok = true, width = 200, height = 100, scale = 2, frame = { x = 0, y = 0, width = 100, height = 50 } }
		end)
		local image = now(Service.capture_region, { x = 0, y = 0, width = 100, height = 50 })
		helpers.assert_eq(requests[1].op, "capture", "the capture op")
		helpers.assert_eq(image.source, requests[1].out_path, "the image names its file")
		helpers.assert_nil(image.pixels, "no pixels cross into Lua")
		now(Service.recognize_text, image, { layout = "block", languages = { "en-US" } })
		helpers.assert_eq(requests[2].op, "ocr", "the OCR op")
		helpers.assert_eq(requests[2].source, image.source, "OCR reads the kept capture")
		Service.stop()
	end)

	helpers.it("screen vision: passes a refusal to the caller as its reason", function()
		local Service = fresh_service(function() return nil, "capture_permission_missing" end)
		local image, reason = now(Service.capture_window, 9)
		helpers.assert_nil(image, "no image")
		helpers.assert_eq(reason, "capture_permission_missing", "the reason")
		local hits, refused = now(Service.match, { source = "/x.png" }, { { id = "a", path = "/a.png" } }, OPTIONS)
		helpers.assert_eq(#hits, 0, "no hit")
		helpers.assert_eq(refused.a, "capture_permission_missing", "each template names the refusal")
		local state
		Service.refresh_availability(function(s) state = s end)
		helpers.assert_eq(state.capture.ok, false, "capture greyed")
		helpers.assert_eq(state.capture.reason, "capture_permission_missing", "for the permission")
		Service.stop()
	end)

	helpers.it("screen vision: refuses a second initialisation", function()
		local Service = fresh_service(function() return { ok = true } end)
		helpers.assert_throws(function() Service.init({ cache_dir = "/tmp/x" }) end, "a second init")
		Service.stop()
	end)
end)
