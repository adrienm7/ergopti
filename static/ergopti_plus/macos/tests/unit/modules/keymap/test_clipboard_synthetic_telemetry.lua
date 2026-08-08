--- tests/unit/modules/keymap/test_clipboard_synthetic_telemetry.lua

--- ==============================================================================
--- MODULE: Clipboard output telemetry and provenance
--- DESCRIPTION:
--- Clipboard text must reach logical keylogger telemetry even though Quartz only
--- carries a tagged Cmd+V pair. This suite checks both channels independently:
--- exact event tags for ownership, and the full logical payload for statistics.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture(keylogger)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name == "modules.keylogger"
			or name:match("^adapters%.")
			or name == "infra.logger"
			or name == "infra.timings"
		) then
			package.loaded[name] = nil
		end
	end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			return key == "clipboard_restore_ms" and 0.15 or 0.08
		end,
	}
	if keylogger then package.loaded["modules.keylogger"] = keylogger end

	return {
		hs = hs_stub,
		synthetic = require("adapters.synthetic_input"),
		utils = require("modules.keymap.utils"),
	}
end


local function collect(fixture, emitter)
	fixture.synthetic.enter_callback()
	local results = table.pack(emitter())
	local consume, events = fixture.synthetic.leave_callback(results[1] ~= false)
	return results, consume, events
end


local function metadata(fixture, event)
	local property = fixture.hs.eventtap.event.properties.eventSourceUserData
	return fixture.synthetic.lookup_tag(event:getProperty(property))
end


helpers.describe("clipboard output reaches synthetic telemetry", function()
	helpers.it("keeps paste echoes event-only while returning the full logical output", function()
		local fixture = load_fixture()
		local logical = ("p"):rep(60)
		local results, consume, events = collect(fixture, function()
			return fixture.utils.emit_text(logical)
		end)

		helpers.assert_true(consume)
		helpers.assert_eq(results[1], 60)
		helpers.assert_eq(results[2], "")
		helpers.assert_eq(results[3], logical)
		helpers.assert_eq(#events, 2, "a clipboard write emits only Cmd+V down/up")
		local down = metadata(fixture, events[1])
		local up = metadata(fixture, events[2])
		helpers.assert_eq(events[1].key, "v")
		helpers.assert_eq(down.generation, up.generation)
		helpers.assert_eq(down.ordinal, up.ordinal)
		helpers.assert_eq(down.phase, "down")
		helpers.assert_eq(up.phase, "up")
	end)

	helpers.it("keeps typed and pasted token output in one ordered generation", function()
		local fixture = load_fixture()
		local pasted = ("a"):rep(60)
		fixture.synthetic.enter_callback()
		local transaction = fixture.synthetic.begin("test.telemetry", "replacement")
		local results = table.pack(fixture.synthetic.with_transaction(transaction, function()
			return fixture.utils.emit_tokens({
				{ kind = "text", value = "Hi " },
				{ kind = "text", value = pasted },
			})
		end))
		fixture.synthetic.seal(transaction)
		local _, events = fixture.synthetic.leave_callback(true)

		helpers.assert_eq(results[1], 63)
		helpers.assert_eq(results[2], "Hi ")
		helpers.assert_eq(results[3], "Hi " .. pasted)
		helpers.assert_eq(#events, 8,
			"three character pairs followed by one Cmd+V pair must be returned")
		local first = metadata(fixture, events[1])
		local paste = metadata(fixture, events[7])
		helpers.assert_eq(first.owner, "test.telemetry")
		helpers.assert_eq(first.effect, "replacement")
		helpers.assert_eq(first.generation, paste.generation)
		helpers.assert_eq(first.batch, paste.batch)
		helpers.assert_eq(first.ordinal, 1)
		helpers.assert_eq(paste.ordinal, 4)
		helpers.assert_eq(events[7].key, "v")
	end)

	helpers.it("forwards logical clipboard output beside the replacement's exact tagged batch", function()
		local received = nil
		local fixture = load_fixture({
			notify_synthetic = function(text, source, deletes, variant, physical)
				received = {
					text = text, source = source, deletes = deletes,
					variant = variant, physical = physical,
				}
			end,
			set_buffer = function() end,
		})
		local expander = require("modules.keymap.expander")
		local state = {
			buffer = "abc",
			magic_key = "*",
			start_is_word_boundary = true,
			is_repeat_feature_enabled = function() return false end,
			suppress_rescan = function() end,
		}
		expander.init(state, { is_terminator = function() return false end }, {
			get_llm_enabled = function() return false end,
			update_preview = function() end,
		})
		local pasted = ("z"):rep(60)

		local results, consume, events = collect(fixture, function()
			return expander.perform_text_replacement(3,
				function() return fixture.utils.emit_text(pasted) end,
				function() state.buffer = pasted end,
				false, false, "llm", "test")
		end)

		helpers.assert_true(results[1])
		helpers.assert_true(consume)
		helpers.assert_eq(#events, 8,
			"three Delete pairs and one Cmd+V pair form one atomic replacement")
		local first = metadata(fixture, events[1])
		local paste = metadata(fixture, events[7])
		helpers.assert_eq(first.owner, "test")
		helpers.assert_eq(first.effect, "replacement")
		helpers.assert_eq(first.generation, paste.generation)
		helpers.assert_eq(first.batch, paste.batch)
		helpers.assert_eq(first.ordinal, 1)
		helpers.assert_eq(paste.ordinal, 4)
		helpers.assert_eq(events[7].key, "v")

		helpers.assert_not_nil(received, "keylogger must receive the logical paste")
		helpers.assert_eq(received.text, pasted)
		helpers.assert_eq(received.physical, "")
		helpers.assert_eq(received.deletes, 3)
		helpers.assert_eq(received.source, "llm")
		helpers.assert_eq(received.variant, "test")
	end)
end)
