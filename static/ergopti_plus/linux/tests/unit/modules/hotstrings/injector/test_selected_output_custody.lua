--- tests/unit/modules/hotstrings/injector/test_selected_output_custody.lua

--- ==============================================================================
--- MODULE: Selected Output Custody Across Native Observations
--- DESCRIPTION:
--- Uses actual Writer, Hook, Broker and OutputTransaction through controlled byte
--- ports. Physical edges between phases retain their original source ownership.
--- ==============================================================================
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modifier_broker_fixture")

local function with_stage(body)
	local names = { "modules.hotstrings.device_finder", "adapters.evdev_reader", "adapters.uinput_writer",
		"adapters.keyboard_hook", "adapters.xkb_capture", "adapters.keyboard_layout", "modules.hotstrings.injector",
		"modules.hotstrings.selected_output" }
	local previous, stage, injector = {}, nil, nil
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local ok, detail = pcall(function()
		Fixture.with_session(nil, function(session)
			local saved_xkb = package.loaded["adapters.xkb_capture"]
			package.loaded["adapters.xkb_capture"] = { caps_locked = function() return false end }
			local layout = helpers.load_module("adapters.keyboard_layout")
			layout._set_table_for_test({ x = { keycode = 45, level = 1, mods = {} } })
			package.loaded["modules.hotstrings.selected_output"] = nil
			injector = helpers.load_module("modules.hotstrings.injector")
			package.loaded["adapters.xkb_capture"] = saved_xkb
			injector._set_uinput(session.writer)
			injector._set_nanosleep_for_test(function() end)
			stage = injector.prepare_selected("x", { current = function() return true end, cached = function() return true end })
			body(session, stage, layout)
		end)
	end)
	if stage then stage.close() end
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("selected output retains its original native custody", function()
	helpers.it("releases Broker custody during the cold span observation", function()
		with_stage(function(session, stage)
			helpers.assert_true(stage.prepare())
			helpers.assert_true(stage.payload().ok)
			local broker = assert(require("adapters.modifier_broker").for_channel(session.writer))
			helpers.assert_true(broker.output_current(), "the payload transaction must finish before the async probe")
			helpers.assert_true(stage.reselect().ok)
			helpers.assert_eq(session.view().down, {})
		end)
	end)
	for _, code in ipairs({ 42, 56 }) do
		helpers.it("preserves a genuine physical modifier UP between transactions for " .. code, function()
			with_stage(function(session, stage)
				session.queue("a", code, 1, 1); session.pump()
				helpers.assert_true(stage.prepare())
				helpers.assert_true(stage.payload().ok)
				session.queue("a", code, 0, 2); session.pump()
				local count = #session.rows
				helpers.assert_true(stage.reselect().ok)
				local expected = { { 42, 1 }, { 105, 1 }, { 105, 0 }, { 42, 0 } }
				local tail = {}; for i = count + 1, #session.rows do tail[#tail + 1] = session.rows[i] end
				helpers.assert_eq(tail, expected, "no restored DOWN may resurrect the physically released owner")
				helpers.assert_eq(session.view().down, {})
			end)
		end)
	end
	helpers.it("cannot adopt a close and reopen of the same Writer table after payload", function()
		with_stage(function(session, stage)
			helpers.assert_true(stage.prepare())
			helpers.assert_true(stage.payload().ok)
			helpers.assert_true(session.writer.close_owned(session.cap))
			helpers.assert_true(session.writer.open())
			local replacement = assert(session.writer.capture_output())
			local count = #session.rows
			local result = stage.reselect()
			helpers.assert_eq(result.ok, false)
			helpers.assert_true(result.payload_written)
			helpers.assert_eq(#session.rows, count)
			helpers.assert_true(session.writer.close_owned(replacement))
		end)
	end)
	helpers.it("cannot adopt a newly attached Broker after payload", function()
		with_stage(function(session, stage)
			helpers.assert_true(stage.prepare())
			helpers.assert_true(stage.payload().ok)
			local broker = require("adapters.modifier_broker")
			broker.detach(session.writer)
			helpers.assert_true(broker.attach(session.writer) ~= nil)
			local count = #session.rows
			helpers.assert_eq(stage.reselect().ok, false)
			helpers.assert_eq(#session.rows, count)
		end)
	end)
	helpers.it("refuses a changed output method even when its replacement reports success", function()
		with_stage(function(session, stage)
			helpers.assert_true(stage.prepare())
			helpers.assert_true(stage.payload().ok)
			local original = session.writer.emit
			session.writer.emit = function() return true end
			local count = #session.rows
			local result = stage.reselect()
			session.writer.emit = original
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(#session.rows, count)
		end)
	end)
end)
