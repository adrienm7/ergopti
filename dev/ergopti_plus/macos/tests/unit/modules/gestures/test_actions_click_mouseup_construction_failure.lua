--- tests/unit/modules/gestures/test_actions_click_mouseup_construction_failure.lua

--- ==============================================================================
--- MODULE: Regression — click-hold mouseUp construction is atomic
--- DESCRIPTION:
--- A keydown releases every synthetic click-hold at once. If construction of
--- either required mouseUp throws or returns nil, the callback must emit no
--- partial release, keep every hold recoverable, and report the failure only
--- after the eventtap callback has returned.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEPENDENCIES = {
	"infra.logger",
	"infra.timings",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"modules.gestures.actions_click",
}

local function with_fixture(failure_mode, body)
	local saved = {}
	for _, name in ipairs(DEPENDENCIES) do saved[name] = package.loaded[name] end
	local saved_hs = _G.hs

	local fixture = {
		constructed = {},
		posted = {},
		taps = {},
		deferred = {},
		errors = {},
		failure_mode = nil,
	}

	local types = {
		keyDown = 10,
		flagsChanged = 12,
		leftMouseUp = 1,
		rightMouseUp = 2,
		leftMouseDown = 3,
		rightMouseDown = 4,
		mouseMoved = 5,
		leftMouseDragged = 6,
		rightMouseDragged = 7,
	}

	local hs_stub = {
		mouse = {
			absolutePosition = function() return { x = 120, y = 80 } end,
		},
		timer = {
			secondsSinceEpoch = function() return 100 end,
			doAfter = function(_, callback)
				return { callback = callback }
			end,
		},
		eventtap = {
			new = function(watched_types, callback)
				local tap = {
					types = watched_types,
					callback = callback,
					started = 0,
					stopped = 0,
				}
				function tap:start()
					self.started = self.started + 1
					return self
				end
				function tap:stop()
					self.stopped = self.stopped + 1
					return self
				end
				function tap:isEnabled()
					return self.started > self.stopped
				end
				fixture.taps[#fixture.taps + 1] = tap
				return tap
			end,
			event = {
				types = types,
				properties = { eventSourceStateID = 30 },
				newMouseEvent = function(event_type, position)
					local is_mouse_up = event_type == types.leftMouseUp
						or event_type == types.rightMouseUp
					if is_mouse_up and fixture.failure_mode == "throw" then
						error("injected mouseUp constructor failure")
					end
					if is_mouse_up and fixture.failure_mode == "nil" then return nil end
					fixture.constructed[#fixture.constructed + 1] = event_type
					local event = { event_type = event_type, position = position }
					function event:setProperty() return self end
					function event:post()
						fixture.posted[#fixture.posted + 1] = self.event_type
						return self
					end
					return event
				end,
			},
		},
	}

	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function(_, format_string, ...)
			fixture.errors[#fixture.errors + 1] = string.format(format_string, ...)
		end,
	}
	package.loaded["infra.timings"] = {
		sec = function() return 0.25 end,
	}
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function()
			return nil, "foreign", { events = {} }
		end,
	}
	package.loaded["adapters.synthetic_input"] = {
		prepare_mouse_event = function(_, event_type, position, options)
			local event = hs_stub.eventtap.event.newMouseEvent(event_type, position)
			if event == nil or event == false then return nil, "newMouseEvent returned nil" end
			if options and options.source_state_id ~= nil then
				local result = event:setProperty(30, options.source_state_id)
				if result == nil or result == false then return nil, "property refused" end
			end
			event:setProperty(31, #fixture.constructed)
			return { event = event, active = true, attempted = false }
		end,
		prepare_mouse_cleanup_event = function(_, event_type, position, options)
			local event = hs_stub.eventtap.event.newMouseEvent(event_type, position)
			if event == nil or event == false then return nil, "newMouseEvent returned nil" end
			if options and options.source_state_id ~= nil then
				local result = event:setProperty(30, options.source_state_id)
				if result == nil or result == false then return nil, "property refused" end
			end
			event:setProperty(31, #fixture.constructed)
			return { event = event, active = true, attempted = false }
		end,
		post_mouse_event = function(owner)
			if type(owner) ~= "table" or owner.active ~= true then return false end
			owner.attempted = true
			local result = owner.event:post()
			if result == nil or result == false then return false end
			owner.active = false
			return true
		end,
		discard_mouse_event = function(owner)
			if type(owner) ~= "table" or owner.active ~= true or owner.attempted == true then
				return false
			end
			owner.active = false
			return true
		end,
		prepare_mouse_handoff = function(owners)
			local events = {}
			for index, owner in ipairs(owners) do
				if type(owner) ~= "table" or owner.active ~= true then return nil, "unavailable" end
				events[index] = owner.event
			end
			return { owners = owners, events = events }
		end,
		commit_mouse_handoff = function(handoff)
			for _, owner in ipairs(handoff.owners) do owner.active = false end
			return handoff.events
		end,
		defer_after_callback = function(label, callback)
			fixture.deferred[#fixture.deferred + 1] = { label = label, callback = callback }
		end,
	}
	package.loaded["modules.gestures.actions_click"] = nil
	_G.hs = hs_stub

	local ok, err = xpcall(function()
		local ClickActions = require("modules.gestures.actions_click")
		fixture.failure_mode = failure_mode
		body(ClickActions, fixture, types)
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(DEPENDENCIES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

local function assert_atomic_failure(failure_mode, expected_detail)
	with_fixture(failure_mode, function(ClickActions, fixture, types)
		-- Arm both buttons before enabling the injected mouseUp failure. This makes
		-- a partial release observable: one successful mouseUp would escape while
		-- the other hold remained live.
		fixture.failure_mode = nil
		ClickActions.toggle_left_click()
		ClickActions.toggle_right_click()
		fixture.failure_mode = failure_mode

		helpers.assert_eq(fixture.constructed, { types.leftMouseDown, types.rightMouseDown })
		helpers.assert_eq(fixture.posted, { types.leftMouseDown, types.rightMouseDown })
		helpers.assert_eq(#fixture.taps, 3)
		local key_watcher = fixture.taps[1]
		local left_drag_tap = fixture.taps[2]
		local right_drag_tap = fixture.taps[3]

		local ok, swallowed, returned_events = pcall(key_watcher.callback, {})
		helpers.assert_true(ok, "a native constructor failure must not escape the eventtap callback")
		helpers.assert_eq(swallowed, false)
		helpers.assert_nil(returned_events, "no partial mouseUp may be returned before every release exists")
		helpers.assert_eq(fixture.constructed, { types.leftMouseDown, types.rightMouseDown })
		helpers.assert_eq(fixture.posted, { types.leftMouseDown, types.rightMouseDown })
		helpers.assert_eq(key_watcher.stopped, 0, "the recovery watcher must remain armed")
		helpers.assert_eq(left_drag_tap.stopped, 0, "the left hold must remain recoverable")
		helpers.assert_eq(right_drag_tap.stopped, 0, "the right hold must remain recoverable")
		helpers.assert_eq(ClickActions.is_right_click_held(), true)

		-- File logging in the eventtap itself would add synchronous I/O to the hot
		-- path. The diagnostic must become visible only through deferred work.
		helpers.assert_eq(#fixture.errors, 0)
		helpers.assert_eq(#fixture.deferred, 1)
		helpers.assert_eq(fixture.deferred[1].label, "click-hold release diagnostic")
		fixture.deferred[1].callback()
		helpers.assert_eq(#fixture.errors, 1)
		helpers.assert_contains(fixture.errors[1], expected_detail)

		-- Once the native constructor recovers, both public toggles must take their
		-- release branches. A stale false state would instead create another down.
		fixture.failure_mode = nil
		ClickActions.toggle_left_click()
		ClickActions.toggle_right_click()
		helpers.assert_eq(fixture.constructed, {
			types.leftMouseDown,
			types.rightMouseDown,
			types.leftMouseUp,
			types.rightMouseUp,
		})
		helpers.assert_eq(fixture.posted, {
			types.leftMouseDown,
			types.rightMouseDown,
			types.leftMouseUp,
			types.rightMouseUp,
		})
		helpers.assert_eq(ClickActions.is_right_click_held(), false)
		helpers.assert_eq(key_watcher.stopped, 1)
	end)
end

helpers.describe("gestures click-hold mouseUp construction failure", function()
	helpers.it("keeps both holds atomic and observable when newMouseEvent throws", function()
		assert_atomic_failure("throw", "injected mouseUp constructor failure")
	end)

	helpers.it("keeps both holds atomic and observable when newMouseEvent returns nil", function()
		assert_atomic_failure("nil", "newMouseEvent returned nil")
	end)
end)
