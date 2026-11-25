--- _shared/tests/lua/workflows/workflow_screen_contract.lua

--- ==============================================================================
--- MODULE: User Workflow Screen Steps Contract
--- DESCRIPTION:
--- Drives the shared screen steps over a recording vision adapter on the macOS
--- and Linux runtimes: an embedded image is decoded and matched in the front
--- window, a text target goes through the OCR words and the shared text match,
--- wait_for polls until it sees the target or its timeout, a hit is clicked at
--- the matcher's click point, OCR words become lines of text, a capture's file
--- is the step's value, a service refusal maps to its run reason, and a late
--- answer after a cancel is dropped.
---
--- ROOT CAUSE ENCODED:
--- Every screen step stopped with screen_service_missing: nothing turned a
--- workflow's wait_for, click_target, capture, ocr or « visible » into calls
--- on the screen vision service.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Screen = require("shortcuts.engine.workflows.screen")
local Effects = require("shortcuts.engine.workflows.effects")

local M = {}

local PNG_BYTES = "\137PNG fake"
local PNG_BASE64 = "iVBORyBmYWtl"

--- A recording vision adapter.
--- @param script table { found = { boolean… } per look, words, refuse, template_refuse }
--- @return table vision, table world
local function vision_of(script)
	local world = { looks = 0, clicks = {}, timers = {}, templates = {}, now = 0, saved = nil }
	local frame = { x = 100, y = 200, width = 50, height = 50 }
	local vision = {
		window_image = function(done)
			if script.refuse then return done(nil, script.refuse) end
			world.looks = world.looks + 1
			done({ width = 50, height = 50, frame = frame, scale = 2 })
		end,
		capture = function(mode, done)
			world.mode = mode
			if script.refuse then return done(nil, script.refuse) end
			done({ image = { frame = frame, scale = 1 }, path = nil })
		end,
		template = function(bytes, key, done)
			world.templates[#world.templates + 1] = { bytes = bytes, key = key }
			if script.template_refuse then return done(nil, script.template_refuse) end
			done({ image = { width = 4, height = 4 } })
		end,
		match = function(_, templates, done)
			local found = script.found and script.found[world.looks]
			if found then
				return done({ { id = templates[1].id, x = 10, y = 20, width = 4, height = 6, score = 1, scale = 1 } }, {})
			end
			done({}, {})
		end,
		recognize = function(_, done)
			if script.ocr_refuse then return done(nil, script.ocr_refuse) end
			done(script.words or {})
		end,
		save = function(_, done) world.saved = true; done("/cache/capture.png") end,
		click = function(x, y, button, done)
			world.clicks[#world.clicks + 1] = { x = x, y = y, button = button }
			done(true)
		end,
		click_point = function(f, scale, hit)
			return math.floor(f.x + (hit.x + hit.width / 2) / scale), math.floor(f.y + (hit.y + hit.height / 2) / scale)
		end,
		find_text = function(words, targets)
			for _, word in ipairs(words) do
				if word.text == targets[1].variants[1] then
					return { { id = targets[1].id, x = word.x, y = word.y, width = word.width, height = word.height } }
				end
			end
			return {}
		end,
		after = function(ms, fn)
			local timer = { ms = ms, fn = fn, live = true }
			world.timers[#world.timers + 1] = timer
			return function() timer.live = false end
		end,
		now_ms = function() return world.now end,
	}
	return vision, world
end

--- Fires the pending timer, advancing the clock by its delay.
local function tick(world)
	for _, timer in ipairs(world.timers) do
		if timer.live then
			timer.live = false
			world.now = world.now + timer.ms
			timer.fn()
			return true
		end
	end
	return false
end

--- @param helpers table
--- @param shared_path function
function M.register(helpers, shared_path)
	local file = assert(io.open(shared_path("shortcuts/data/workflows/steps.json"), "rb"))
	local catalogue = assert(Json.decode(assert(file:read("*a")))); file:close()
	local options = { catalogue = catalogue, poll_ms = 250, text_max_distance = 1, threshold = 0.9 }
	local workflow = { id = "wf_1", images = { send = PNG_BASE64 } }
	local function screen_of(script)
		local vision, world = vision_of(script)
		return Screen.new(vision, options), world
	end

	helpers.describe("workflow screen steps (workflow-screen)", function()
		helpers.it("an embedded image seen in the front window is visible (workflow-screen)", function()
			local screen, world = screen_of({ found = { true } })
			local result
			screen.visible({ condition = { type = "visible", target = { type = "image", image = "send" } } },
				function(r) result = r end, workflow)
			helpers.assert_eq(result.ok, true)
			helpers.assert_eq(result.value, true)
			helpers.assert_eq(world.templates[1].bytes, PNG_BYTES, "the embedded base64 is decoded")
			helpers.assert_eq(world.templates[1].key, "wf_1/send")
		end)

		helpers.it("an image not seen is not visible, without failing (workflow-screen)", function()
			local screen = screen_of({ found = {} })
			local result
			screen.visible({ condition = { type = "visible", target = { type = "image", image = "send" } } },
				function(r) result = r end, workflow)
			helpers.assert_eq(result.ok, true)
			helpers.assert_eq(result.value, false)
		end)

		helpers.it("wait_for polls until the image shows (workflow-screen)", function()
			local screen, world = screen_of({ found = { false, false, true } })
			local result
			screen.wait_for({ target = { type = "image", image = "send" }, timeout_ms = 5000 },
				function(r) result = r end, workflow)
			helpers.assert_eq(result, nil)
			helpers.assert_true(tick(world)); helpers.assert_eq(result, nil)
			helpers.assert_eq(world.timers[1].ms, 250, "the poll interval of the timing registry")
			helpers.assert_true(tick(world))
			helpers.assert_eq(result.ok, true)
			helpers.assert_eq(world.looks, 3)
		end)

		helpers.it("wait_for gives up at its timeout with text_not_found (workflow-screen)", function()
			local screen, world = screen_of({ words = {} })
			local result
			screen.wait_for({ target = { type = "text", text = "OK" }, timeout_ms = 600 },
				function(r) result = r end, workflow)
			while result == nil and tick(world) do end
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.reason, "text_not_found")
			helpers.assert_true(world.now <= 600, "no look starts past the timeout")
		end)

		helpers.it("click_target clicks a text target at the matcher's click point (workflow-screen)", function()
			local screen, world = screen_of({ words = { { text = "Send", x = 20, y = 40, width = 10, height = 10, line = 1 } } })
			local result
			screen.click_target({ target = { type = "text", text = "Send" } }, function(r) result = r end, workflow)
			helpers.assert_eq(result.ok, true)
			helpers.assert_eq(world.clicks[1].x, 112)
			helpers.assert_eq(world.clicks[1].y, 222)
			helpers.assert_eq(world.clicks[1].button, "left")
		end)

		helpers.it("click_target on an absent image fails with image_not_found (workflow-screen)", function()
			local screen, world = screen_of({ found = {} })
			local result
			screen.click_target({ target = { type = "image", image = "send" }, button = "right" },
				function(r) result = r end, workflow)
			helpers.assert_eq(result.reason, "image_not_found")
			helpers.assert_eq(#world.clicks, 0)
		end)

		helpers.it("a service refusal maps to its run reason (workflow-screen)", function()
			local screen = screen_of({ refuse = "capture_permission_missing" })
			local result
			screen.visible({ condition = { type = "visible", target = { type = "image", image = "send" } } },
				function(r) result = r end, workflow)
			helpers.assert_eq(result.reason, "screen_permission_missing")
			helpers.assert_eq(Screen.run_reason(catalogue, "ocr_engine_missing"), "ocr_unavailable")
			helpers.assert_eq(Screen.run_reason(catalogue, "not_in_the_vocabulary"), "screen_read_failed")
			for _, reason in pairs(catalogue.screen_reasons) do
				local known = false
				for _, run_reason in ipairs(catalogue.run_reasons) do known = known or run_reason == reason end
				helpers.assert_true(known, reason .. " is a run reason with a notice")
			end
		end)

		helpers.it("ocr joins words by line and capture stores its file (workflow-screen)", function()
			local screen, world = screen_of({ words = {
				{ text = "Hello", line = 1 }, { text = "world", line = 1 }, { text = "Bye", line = 2 } } })
			local read, captured
			screen.ocr({ mode = "region" }, function(r) read = r end, workflow)
			helpers.assert_eq(read.value, "Hello world\nBye")
			helpers.assert_eq(world.mode, "region")
			screen.capture({ mode = "full" }, function(r) captured = r end, workflow)
			helpers.assert_eq(captured.value, "/cache/capture.png")
		end)

		helpers.it("a cancel drops the late answer and stops polling (workflow-screen)", function()
			local screen, world = screen_of({ found = {} })
			local result
			local cancel = screen.wait_for({ target = { type = "image", image = "send" }, timeout_ms = 5000 },
				function(r) result = r end, workflow)
			cancel()
			helpers.assert_eq(tick(world), false, "the poll timer is cancelled")
			helpers.assert_eq(result, nil)
		end)

		helpers.it("the effects hand the running workflow to the screen port (workflow-screen)", function()
			local seen
			local ports = { screen = { visible = function(_, done, wf) seen = wf; done({ ok = true, value = true }) end } }
			for _, name in ipairs({ "send_shortcut", "type_text", "after", "open", "focus_app", "clipboard_get",
				"clipboard_set", "mouse_move", "mouse_click", "run_action", "notify", "shell", "app_front" }) do
				ports[name] = function() end
			end
			local effects = Effects.new(ports)
			local result
			effects.perform({ op = "probe", condition = { type = "visible", target = { type = "text", text = "x" } } },
				function(r) result = r end, workflow)
			helpers.assert_eq(seen, workflow)
			helpers.assert_eq(result.value, true)
		end)
	end)
end

return M
