--- tests/unit/modules/gestures/test_mouse_event_provenance.lua

--- ==============================================================================
--- MODULE: Gesture Mouse Event Provenance Regression Tests
--- DESCRIPTION:
--- Drives the real lookup gesture through the production SyntheticInput ledger.
--- Both native mouse events must be independently recognizable as owned by every
--- consumer; a raw Quartz event or an ad-hoc user-data value remains foreign.
--- ==============================================================================

local helpers = require("tests.helpers")


local function clear_mouse_stack()
	for _, name in ipairs({
		"adapters.event_provenance",
		"adapters.synthetic_input",
		"adapters.timer_scheduler",
		"modules.gestures.actions",
		"modules.gestures.actions_click",
		"tests.stubs.hs",
	}) do
		package.loaded[name] = nil
	end
end


local function load_lookup_fixture()
	clear_mouse_stack()

	local eventtap = require("tests.stubs.hs").eventtap
	local new_mouse_event = eventtap.event.newMouseEvent
	local posted = {}
	eventtap.event.newMouseEvent = function(event_type, position, modifiers)
		local event = new_mouse_event(event_type, position, modifiers)
		local native_post = event.post
		event.post = function(self, ...)
			posted[#posted + 1] = self
			return native_post(self, ...)
		end
		return event
	end

	local actions = helpers.load_with_stubs("modules.gestures.actions", {
		eventtap = eventtap,
	})
	return {
		actions = actions,
		posted = posted,
		synthetic = require("adapters.synthetic_input"),
		provenance = require("adapters.event_provenance"),
		new_mouse_event = new_mouse_event,
		event_types = eventtap.event.types,
	}
end


local function load_click_fixture(options)
	clear_mouse_stack()
	options = options or {}
	local eventtap = require("tests.stubs.hs").eventtap
	eventtap.event.types.leftMouseDragged = 7
	eventtap.event.types.rightMouseDragged = 8
	local new_mouse_event = eventtap.event.newMouseEvent
	local constructed = {}
	local attempts = {}
	local posted = {}
	local failed_once = false
	local fenced_once = false
	eventtap.event.newMouseEvent = function(event_type, position, modifiers)
		local event = new_mouse_event(event_type, position, modifiers)
		constructed[#constructed + 1] = event
		local native_post = event.post
		local native_set_property = event.setProperty
		event.setProperty = function(self, property, value)
			if property == eventtap.event.properties.eventSourceUserData then
				if options.user_data_property == "false" then return false end
				if options.user_data_property == "nil" then return nil end
				if options.user_data_property == "throw" then
					error("injected user-data property failure")
				end
			end
			return native_set_property(self, property, value)
		end
		event.post = function(self, ...)
			attempts[#attempts + 1] = self
			if options.fence_on_first_type == event_type and not fenced_once then
				fenced_once = true
				options.fence_token = require("adapters.synthetic_input")
					.acquire_admission_fence("test.mouse-post")
			end
			if options.fail_first_type == event_type and not failed_once then
				failed_once = true
				if options.fail_first_mode == "nil" then return nil end
				if options.fail_first_mode == "throw" then
					error("injected mouse post failure")
				end
				return false
			end
			local result = native_post(self, ...)
			posted[#posted + 1] = self
			return result
		end
		return event
	end

	local click = helpers.load_with_stubs("modules.gestures.actions_click", {
		eventtap = eventtap,
	})
	return {
		click = click,
		constructed = constructed,
		attempts = attempts,
		posted = posted,
		taps = eventtap.__taps,
		eventtap = eventtap,
		timer = require("tests.stubs.hs").timer,
		synthetic = require("adapters.synthetic_input"),
		provenance = require("adapters.event_provenance"),
		event_types = eventtap.event.types,
		options = options,
	}
end


local function assert_owned(fixture, event, phase, owner)
	local first_metadata, first_status = fixture.provenance.classify_with_fence(
		event, "keymap.mouse")
	local second_metadata, second_status = fixture.provenance.classify_with_fence(
		event, "keylogger")
	helpers.assert_eq(first_status, fixture.provenance.STATUS_OWNED)
	helpers.assert_eq(second_status, fixture.provenance.STATUS_OWNED)
	helpers.assert_eq(first_metadata.owner, owner or "gestures")
	helpers.assert_eq(first_metadata.effect, "action")
	helpers.assert_eq(first_metadata.phase, phase)
	helpers.assert_eq(second_metadata.tag, first_metadata.tag)
	return first_metadata.tag
end


local function tap_watching(fixture, event_type)
	for _, tap in ipairs(fixture.taps) do
		for _, watched in ipairs(tap.types or {}) do
			if watched == event_type then return tap end
		end
	end
	return nil
end


helpers.describe("gestures.actions: mouse events have exact provenance", function()
	helpers.it("tags both lookup phases for independent consumers", function()
		local fixture = load_lookup_fixture()
		local epoch_before = fixture.synthetic.current_action_epoch()
		helpers.assert_eq(fixture.actions.trigger_lookup("gestures"), true)
		helpers.assert_eq(#fixture.posted, 2,
			"lookup must post one rightMouseDown/rightMouseUp pair")
		helpers.assert_eq(fixture.posted[1].t, fixture.event_types.rightMouseDown)
		helpers.assert_eq(fixture.posted[2].t, fixture.event_types.rightMouseUp)

		local tags = {}
		for index, event in ipairs(fixture.posted) do
			local keymap_metadata, keymap_status = fixture.provenance.classify_with_fence(
				event, "keymap.mouse")
			local keylogger_metadata, keylogger_status = fixture.provenance.classify_with_fence(
				event, "keylogger")
			helpers.assert_eq(keymap_status, fixture.provenance.STATUS_OWNED,
				"gesture mouse event must not enter keymap's physical-click path")
			helpers.assert_eq(keylogger_status, fixture.provenance.STATUS_OWNED,
				"gesture mouse event must not increment physical click metrics")
			helpers.assert_eq(keymap_metadata.owner, "gestures")
			helpers.assert_eq(keymap_metadata.effect, "action")
			helpers.assert_eq(keymap_metadata.phase, index == 1 and "down" or "up")
			helpers.assert_eq(keylogger_metadata.tag, keymap_metadata.tag)
			tags[index] = keymap_metadata.tag
		end
		helpers.assert_true(tags[1] ~= tags[2],
			"mouse-down and mouse-up require distinct immutable provenance tags")
		helpers.assert_eq(fixture.synthetic.current_action_epoch(), epoch_before,
			"provenance-only mouse actions must not invalidate typed context")

		local foreign = fixture.new_mouse_event(
			fixture.event_types.rightMouseDown, { x = 0, y = 0 })
		local foreign_metadata, foreign_status = fixture.provenance.classify_with_fence(
			foreign, "keymap.mouse")
		helpers.assert_eq(foreign_metadata, nil)
		helpers.assert_eq(foreign_status, fixture.provenance.STATUS_FOREIGN,
			"the consumer must still distinguish genuine untagged mouse input")
	end)
end)


helpers.describe("gestures.actions_click: every mouse phase has exact provenance", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rolls back a " .. mode .. " user-data tagging refusal", function()
			local fixture = load_click_fixture({ user_data_property = mode })
			local records_before = fixture.synthetic.stats().records
			local prepared = fixture.synthetic.prepare_mouse_event(
				"gestures",
				fixture.event_types.leftMouseDown,
				{ x = 1, y = 2 },
				{ phase = "down" })
			helpers.assert_eq(prepared, nil)
			helpers.assert_eq(fixture.synthetic.stats().records, records_before,
				"a refused tag must not remain in the bounded provenance ledger")
		end)
	end

	helpers.it("counts and discards one pre-handoff lifecycle owner", function()
		local discarded_fixture = load_click_fixture()
		local records_before = discarded_fixture.synthetic.stats().records
		local prepared, detail = discarded_fixture.synthetic.prepare_mouse_event(
			"gestures",
			discarded_fixture.event_types.leftMouseDown,
			{ x = 1, y = 2 },
			{ phase = "down" })
		helpers.assert_true(prepared ~= nil, tostring(detail))
		helpers.assert_eq(discarded_fixture.synthetic.stats().records, records_before + 1)
		helpers.assert_eq(discarded_fixture.synthetic.stats().prepared_mouse_events, 1)
		helpers.assert_eq(
			discarded_fixture.synthetic.acquire_admission_fence("test.prepared"), nil,
			"a prepared native capability must keep lifecycle admission open")
		helpers.assert_eq(discarded_fixture.synthetic.discard_mouse_event(prepared), true)
		helpers.assert_eq(discarded_fixture.synthetic.stats().records, records_before)
		helpers.assert_eq(discarded_fixture.synthetic.stats().prepared_mouse_events, 0)
		helpers.assert_eq(discarded_fixture.synthetic.discard_mouse_event(prepared), false)
		local fence = discarded_fixture.synthetic.acquire_admission_fence("test.prepared")
		helpers.assert_true(fence ~= nil)
		helpers.assert_eq(discarded_fixture.synthetic.release_admission_fence(fence), true)
	end)

	helpers.it("wakes an idle waiter only after the native post boundary", function()
		local fixture = load_click_fixture()
		local prepared, detail = fixture.synthetic.prepare_mouse_event(
			"gestures", fixture.event_types.leftMouseDown, { x = 1, y = 2 },
			{ phase = "down" })
		helpers.assert_true(prepared ~= nil, tostring(detail))
		local idle_calls = 0
		helpers.assert_eq(fixture.synthetic.when_idle(function()
			idle_calls = idle_calls + 1
		end), true)
		helpers.assert_eq(idle_calls, 0)
		helpers.assert_eq(fixture.synthetic.post_mouse_event(prepared), true)
		helpers.assert_eq(idle_calls, 0,
			"native handoff must finish before an idle callback can run")
		fixture.timer.__fire_all()
		helpers.assert_eq(idle_calls, 1)
		fixture.timer.__fire_all()
		helpers.assert_eq(idle_calls, 1, "idle callback must remain exactly-once")
	end)

	for _, refusal in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retries the exact event after a " .. refusal .. " post", function()
		clear_mouse_stack()
		package.loaded["tests.stubs.hs"] = nil
		local base_types = require("tests.stubs.hs").eventtap.event.types
		local retry_fixture = load_click_fixture({
			fail_first_type = base_types.rightMouseDown,
			fail_first_mode = refusal,
		})
		local retry_owner, retry_detail = retry_fixture.synthetic.prepare_mouse_event(
			"gestures",
			retry_fixture.event_types.rightMouseDown,
			{ x = 3, y = 4 },
			{ phase = "down" })
		helpers.assert_true(retry_owner ~= nil, tostring(retry_detail))
		local first_post = retry_fixture.synthetic.post_mouse_event(retry_owner)
		helpers.assert_eq(first_post, false)
		helpers.assert_eq(retry_fixture.synthetic.stats().prepared_mouse_events, 0,
			"the first native attempt must release pre-handoff lifecycle ownership")
		helpers.assert_eq(retry_fixture.synthetic.discard_mouse_event(retry_owner), false,
			"an attempted native event must retain provenance after uncertainty")
		helpers.assert_eq(retry_fixture.synthetic.post_mouse_event(retry_owner), true)
		helpers.assert_eq(#retry_fixture.attempts, 2)
		helpers.assert_eq(retry_fixture.attempts[1], retry_fixture.attempts[2],
			"retry must reuse the exact tagged native event")
		assert_owned(retry_fixture, retry_fixture.attempts[1], "down")
		end)
	end

	helpers.it("permits only mouseUp cleanup while admission is fenced", function()
		local fixture = load_click_fixture()
		helpers.assert_eq(fixture.click.toggle_left_click("gestures"), true)
		helpers.assert_eq(fixture.click.is_left_click_held(), true)
		local fence = fixture.synthetic.acquire_admission_fence("test.pause")
		helpers.assert_true(fence ~= nil)

		local forward, forward_detail = fixture.synthetic.prepare_mouse_event(
			"gestures", fixture.event_types.rightMouseDown, { x = 3, y = 4 },
			{ phase = "down" })
		helpers.assert_eq(forward, nil)
		helpers.assert_true(tostring(forward_detail):find("fenced", 1, true) ~= nil)
		local invalid_cleanup = fixture.synthetic.prepare_mouse_cleanup_event(
			"gestures", fixture.event_types.rightMouseDown, { x = 3, y = 4 },
			{ phase = "up" })
		helpers.assert_eq(invalid_cleanup, nil,
			"cleanup admission must never authorize a new mouseDown")

		helpers.assert_eq(fixture.click.force_cleanup("gestures"), true)
		helpers.assert_eq(fixture.click.is_left_click_held(), false)
		helpers.assert_eq(fixture.posted[#fixture.posted].t,
			fixture.event_types.leftMouseUp)
		assert_owned(fixture, fixture.posted[#fixture.posted], "up")
		helpers.assert_eq(fixture.synthetic.release_admission_fence(fence), true)
	end)

	helpers.it("posts an emergency mouseUp after a re-entrant pause fence", function()
		clear_mouse_stack()
		package.loaded["tests.stubs.hs"] = nil
		local base_types = require("tests.stubs.hs").eventtap.event.types
		local fixture = load_click_fixture({
			fail_first_type = base_types.leftMouseDown,
			fence_on_first_type = base_types.leftMouseDown,
		})
		helpers.assert_eq(fixture.click.toggle_left_click("gestures"), false)
		helpers.assert_true(fixture.options.fence_token ~= nil,
			"the re-entrant lifecycle fence must acquire at native handoff")
		helpers.assert_eq(#fixture.attempts, 2)
		helpers.assert_eq(fixture.attempts[2].t, fixture.event_types.leftMouseUp)
		assert_owned(fixture, fixture.attempts[2], "up")
		helpers.assert_eq(fixture.click.is_left_click_held(), false)
		helpers.assert_eq(fixture.synthetic.release_admission_fence(
			fixture.options.fence_token), true)
	end)

	for _, side in ipairs({ "left", "right" }) do
		helpers.it("tags " .. side .. " hold and ordinary release", function()
			local fixture = load_click_fixture()
			local epoch_before = fixture.synthetic.current_action_epoch()
			local toggle = side == "left" and fixture.click.toggle_left_click
				or fixture.click.toggle_right_click
			local down_type = side == "left" and fixture.event_types.leftMouseDown
				or fixture.event_types.rightMouseDown
			local up_type = side == "left" and fixture.event_types.leftMouseUp
				or fixture.event_types.rightMouseUp

			helpers.assert_eq(toggle("gestures"), true)
			helpers.assert_eq(fixture.posted[1].t, down_type)
			local down_tag = assert_owned(fixture, fixture.posted[1], "down")
			helpers.assert_eq(toggle("gestures"), true)
			helpers.assert_eq(fixture.posted[2].t, up_type)
			local up_tag = assert_owned(fixture, fixture.posted[2], "up")
			helpers.assert_true(down_tag ~= up_tag)
			helpers.assert_eq(fixture.synthetic.current_action_epoch(), epoch_before)
		end)
	end

	helpers.it("keeps uncertain mouseDown and emergency mouseUp independently owned", function()
		clear_mouse_stack()
		package.loaded["tests.stubs.hs"] = nil
		local base_types = require("tests.stubs.hs").eventtap.event.types
		local fixture = load_click_fixture({ fail_first_type = base_types.leftMouseDown })
		local epoch_before = fixture.synthetic.current_action_epoch()
		helpers.assert_eq(fixture.click.toggle_left_click("gestures"), false)
		helpers.assert_eq(#fixture.attempts, 2)
		helpers.assert_eq(fixture.attempts[1].t, fixture.event_types.leftMouseDown)
		helpers.assert_eq(fixture.attempts[2].t, fixture.event_types.leftMouseUp)
		assert_owned(fixture, fixture.attempts[1], "down")
		assert_owned(fixture, fixture.attempts[2], "up")
		helpers.assert_eq(fixture.synthetic.current_action_epoch(), epoch_before)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("returns the tagged release after a " .. mode .. " diagnostic defer", function()
			local fixture = load_click_fixture()
			helpers.assert_eq(fixture.click.toggle_left_click("gestures"), true)
			fixture.synthetic.defer_after_callback = function()
				if mode == "throw" then error("injected diagnostic defer failure") end
				if mode == "false" then return false end
				return nil
			end

			local key_tap = tap_watching(fixture, fixture.event_types.keyDown)
			helpers.assert_true(key_tap ~= nil)
			local physical_key = fixture.eventtap.event.newKeyEvent({}, "x", true)
			local callback_ok, consume_key, returned = pcall(key_tap.fn, physical_key)
			helpers.assert_eq(callback_ok, true,
				"best-effort diagnostics must not abort the native return boundary")
			helpers.assert_eq(consume_key, false)
			helpers.assert_eq(type(returned), "table")
			helpers.assert_eq(#returned, 1)
			helpers.assert_eq(returned[1].t, fixture.event_types.leftMouseUp)
			assert_owned(fixture, returned[1], "up")
			helpers.assert_eq(fixture.click.is_left_click_held(), false)
		end)
	end

	helpers.it("keeps admission closed until the callback reaches its final handoff", function()
		local fixture = load_click_fixture()
		helpers.assert_eq(fixture.click.toggle_left_click("gestures"), true)
		local drag_tap = tap_watching(fixture, fixture.event_types.mouseMoved)
		helpers.assert_true(drag_tap ~= nil)
		fixture.synthetic.defer_after_callback = function() return false end
		local native_stop = drag_tap.stop
		local fence_during_stop = "not-called"
		drag_tap.stop = function(self, ...)
			fence_during_stop = fixture.synthetic.acquire_admission_fence(
				"test.reentrant-stop")
			return native_stop(self, ...)
		end

		local key_tap = tap_watching(fixture, fixture.event_types.keyDown)
		local physical_key = fixture.eventtap.event.newKeyEvent({}, "x", true)
		local consume_key, returned = key_tap.fn(physical_key)
		helpers.assert_eq(fence_during_stop, nil,
			"native cleanup before callback return must still see handoff ownership")
		helpers.assert_eq(consume_key, false)
		helpers.assert_eq(type(returned), "table")
		helpers.assert_eq(#returned, 1)
		assert_owned(fixture, returned[1], "up")
		helpers.assert_eq(fixture.synthetic.stats().prepared_mouse_events, 0)

		local fence_after_return = fixture.synthetic.acquire_admission_fence(
			"test.after-return")
		helpers.assert_true(fence_after_return ~= nil,
			"the final handoff must release lifecycle ownership exactly once")
		helpers.assert_eq(fixture.synthetic.release_admission_fence(fence_after_return), true)
	end)

	helpers.it("tags drag posts and callback-returned keyboard release", function()
		local fixture = load_click_fixture()
		local epoch_before = fixture.synthetic.current_action_epoch()
		helpers.assert_eq(fixture.click.toggle_left_click("gestures"), true)

		local drag_tap = tap_watching(fixture, fixture.event_types.mouseMoved)
		helpers.assert_true(drag_tap ~= nil)
		local consume_drag = drag_tap.fn({
			getType = function() return fixture.event_types.mouseMoved end,
			location = function() return { x = 20, y = 30 } end,
		})
		helpers.assert_eq(consume_drag, false)
		local drag_event = fixture.posted[#fixture.posted]
		helpers.assert_eq(drag_event.t, fixture.event_types.leftMouseDragged)
		assert_owned(fixture, drag_event, "drag")

		local key_tap = tap_watching(fixture, fixture.event_types.keyDown)
		helpers.assert_true(key_tap ~= nil)
		local physical_key = fixture.eventtap.event.newKeyEvent({}, "x", true)
		local consume_key, returned = key_tap.fn(physical_key)
		helpers.assert_eq(consume_key, false)
		helpers.assert_eq(type(returned), "table")
		helpers.assert_eq(#returned, 1)
		helpers.assert_eq(returned[1].t, fixture.event_types.leftMouseUp)
		assert_owned(fixture, returned[1], "up")
		helpers.assert_eq(fixture.synthetic.current_action_epoch(), epoch_before)
	end)
end)
