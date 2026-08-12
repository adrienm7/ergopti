--- tests/unit/modules/keymap/test_noop_expansion_passthrough.lua

--- ==============================================================================
--- MODULE: No-op expansion pass-through
--- DESCRIPTION:
--- An identity mapping must preserve the physical trigger or terminator and
--- construct no synthetic transaction. A real mapping is the positive control:
--- it consumes the trigger and returns one explicitly tagged replacement batch.
--- ==============================================================================

local helpers = require("tests.helpers")


local function make_state(buffer)
	local state = {
		buffer = buffer or "",
		magic_key = "\226\152\133",
		start_is_word_boundary = true,
	}
	function state.is_repeat_feature_enabled() return false end
	function state.suppress_rescan() end
	return state
end


local function make_registry()
	return {
		is_terminator = function(value) return value == " " or value == "," end,
		terminator_is_consumed = function() return false end,
		mappings_for_tail = function() return {} end,
	}
end


local function make_llm()
	return {
		update_preview = function() end,
		get_llm_enabled = function() return false end,
		start_timer = function() end,
	}
end


local function mapping(trigger, replacement, auto, plain_replacement)
	return {
		trigger = trigger,
		trigger_bytes = #trigger,
		tlen = #trigger,
		repl = replacement,
		plain_repl = plain_replacement or replacement,
		is_word = false,
		auto = auto == true,
		match_mode = "exact",
		final_result = false,
	}
end


local function load_fixture(buffer)
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
	package.loaded["modules.keylogger"] = {
		notify_synthetic = function() end,
		set_buffer = function() end,
		log_hotstring = function() end,
	}
	package.loaded["adapters.tooltip_renderer"] = { hide = function() end }

	local synthetic = require("adapters.synthetic_input")
	local expander = require("modules.keymap.expander")
	local state = make_state(buffer)
	expander.init(state, make_registry(), make_llm())
	return {
		hs = hs_stub,
		synthetic = synthetic,
		expander = expander,
		state = state,
	}
end


local function run_callback(fixture, action)
	fixture.synthetic.enter_callback()
	local before = fixture.synthetic.stats().generation
	local fired = action()
	local consume, events = fixture.synthetic.leave_callback(fired)
	return fired, consume, events, before, fixture.synthetic.stats().generation
end


local function metadata(fixture, event)
	local property = fixture.hs.eventtap.event.properties.eventSourceUserData
	return fixture.synthetic.lookup_tag(event:getProperty(property))
end


helpers.describe("keymap.expander: no-op identity mapping pass-through", function()
	helpers.it("passes an automatic identity mapping through", function()
		local fixture = load_fixture("ok")
		local entry = mapping("ok", "ok", true)
		local fired, consume, events = run_callback(fixture, function()
			return fixture.expander.try_auto_expand(entry, 1, false)
		end)

		helpers.assert_eq(fired, false)
		helpers.assert_eq(consume, false,
			"the physical final character must remain visible")
		helpers.assert_nil(events)
	end)

	helpers.it("does not open a transaction for an automatic identity mapping", function()
		local fixture = load_fixture("ok")
		local entry = mapping("ok", "ok", true)
		local _, _, events, before, after = run_callback(fixture, function()
			return fixture.expander.try_auto_expand(entry, 1, false)
		end)

		helpers.assert_nil(events)
		helpers.assert_eq(after, before,
			"a no-op must not allocate tags or rely on later echo suppression")
	end)

	helpers.it("passes a terminator identity mapping through without tagged output", function()
		local fixture = load_fixture("btw ")
		local entry = mapping("btw", "btw", false)
		local fired, consume, events, before, after = run_callback(fixture, function()
			return fixture.expander.try_terminator_expand(entry, " ", 1, false)
		end)

		helpers.assert_eq(fired, false)
		helpers.assert_eq(consume, false,
			"the physical terminator must remain visible")
		helpers.assert_nil(events)
		helpers.assert_eq(after, before)
	end)

	helpers.it("returns a tagged replacement batch for a real expansion", function()
		local fixture = load_fixture("btw")
		local entry = mapping("btw", "by the way", true)
		local fired, consume, events = run_callback(fixture, function()
			return fixture.expander.try_auto_expand(entry, 1, false)
		end)

		helpers.assert_true(fired)
		helpers.assert_true(consume)
		helpers.assert_not_nil(events,
			"the positive control must prove the collector can observe real output")
		local first = metadata(fixture, events[1])
		local last = metadata(fixture, events[#events])
		helpers.assert_eq(first.owner, "hotstring")
		helpers.assert_eq(first.effect, "replacement")
		helpers.assert_eq(first.generation, last.generation)
		helpers.assert_eq(first.batch, last.batch)
	end)

	helpers.it("does not erase a key-token side effect as a visible-text no-op", function()
		local fixture = load_fixture("go")
		local entry = mapping("go", "go{Tab}", true, "go")
		local fired, consume, events = run_callback(fixture, function()
			return fixture.expander.try_auto_expand(entry, 1, false)
		end)

		helpers.assert_true(fired,
			"equal plain text must not suppress the raw {Tab} action")
		helpers.assert_true(consume)
		helpers.assert_not_nil(events)
		local saw_tab = false
		for _, event in ipairs(events) do
			if event.isDown and event.key == "tab" then saw_tab = true end
		end
		helpers.assert_true(saw_tab,
			"the production replacement transaction must contain the Tab keydown")
		helpers.assert_eq(fixture.state.buffer, "go",
			"non-text directives must not corrupt the logical text buffer")
	end)
end)
