--- tests/unit/modules/gestures/test_actions_click_acquisition_transaction.lua

--- ==============================================================================
--- MODULE: Click-Hold Acquisition Transaction Regression
--- DESCRIPTION:
--- Drives the real click-hold module through every native eventtap acquisition
--- boundary. A mouseDown and held-state bit may appear only after both required
--- taps are constructed, started, and proven enabled. Failed rollback handles
--- remain exact and retryable, stale callbacks stay inert, and a refused
--- deferred mouseUp passes the physical event through to release the button.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEPENDENCIES = {
	"infra.logger",
	"infra.timings",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"modules.gestures.actions_click",
}

--- Runs one isolated actions_click instance against a configurable native stub.
--- @param config table Failure injection configuration.
--- @param body function Test body receiving module, fixture, and event types.
local function with_fixture(config, body)
	local saved = {}
	for _, name in ipairs(DEPENDENCIES) do saved[name] = package.loaded[name] end
	local saved_hs = _G.hs

	local fixture = {
		config = config,
		construct_attempts = 0,
		taps = {},
		mouse_events = {},
		post_attempts = {},
		posted = {},
		deferred = {},
		defer_calls = 0,
		now = 100,
	}
	config.construct = config.construct or {}
	config.start = config.start or {}
	config.enabled = config.enabled or {}
	config.stop_failures = config.stop_failures or {}
	config.stop_throws = config.stop_throws or {}
	config.stop_stays_enabled = config.stop_stays_enabled or {}
	config.post = config.post or {}
	config.mouse_construct = config.mouse_construct or {}
	if config.defer_result == nil then config.defer_result = true end

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

	--- Applies one injected return/throw mode.
	--- @param mode string|nil Failure mode.
	--- @param tap table Native tap under test.
	--- @return table|boolean|nil result Native-shaped result.
	local function apply_start_mode(mode, tap)
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		if mode == "throw" then error("injected start failure") end
		if mode == "activate_false" then tap.enabled = true; return false end
		if mode == "activate_throw" then
			tap.enabled = true
			error("injected activate-then-throw failure")
		end
		tap.enabled = true
		return tap
	end

	local hs_stub = {
		mouse = {
			absolutePosition = function() return { x = 120, y = 80 } end,
		},
		timer = {
			secondsSinceEpoch = function() return fixture.now end,
		},
		eventtap = {
			new = function(watched_types, callback)
				fixture.construct_attempts = fixture.construct_attempts + 1
				local index = fixture.construct_attempts
				local construct_mode = config.construct[index]
				if construct_mode == "nil" then return nil end
				if construct_mode == "false" then return false end
				if construct_mode == "throw" then error("injected constructor failure") end

				local tap = {
					index = index,
					types = watched_types,
					callback = callback,
					start_attempts = 0,
					stop_attempts = 0,
					enabled = false,
				}
				function tap:start()
					self.start_attempts = self.start_attempts + 1
					return apply_start_mode(config.start[self.index], self)
				end
				function tap:isEnabled()
					local mode = config.enabled[self.index]
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					if mode == "throw" then error("injected isEnabled failure") end
					return self.enabled
				end
				function tap:stop()
					self.stop_attempts = self.stop_attempts + 1
					local throwing = config.stop_throws[self.index] or 0
					if throwing > 0 then
						config.stop_throws[self.index] = throwing - 1
						error("injected stop failure")
					end
					local remaining = config.stop_failures[self.index] or 0
					if remaining > 0 then
						config.stop_failures[self.index] = remaining - 1
						return false
					end
					local stays_enabled = config.stop_stays_enabled[self.index] or 0
					if stays_enabled > 0 then
						config.stop_stays_enabled[self.index] = stays_enabled - 1
					else
						self.enabled = false
					end
					return self
				end
				fixture.taps[#fixture.taps + 1] = tap
				return tap
			end,
				event = {
				types = types,
				properties = { eventSourceStateID = 30 },
				newMouseEvent = function(event_type, position)
					local construct_mode = config.mouse_construct[event_type]
					if construct_mode == "nil" then return nil end
					if construct_mode == "false" then return false end
					if construct_mode == "throw" then error("injected mouse-event constructor failure") end
					local event = { event_type = event_type, position = position }
					fixture.mouse_events[#fixture.mouse_events + 1] = event
					function event:setProperty()
						if config.property == "nil" then return nil end
						if config.property == "false" then return false end
						if config.property == "throw" then error("injected property failure") end
						return self
					end
					function event:post()
						fixture.post_attempts[#fixture.post_attempts + 1] = self.event_type
						local mode = config.post[self.event_type]
						if mode == "false" then config.post[self.event_type] = nil; return false end
						if mode == "nil" then config.post[self.event_type] = nil; return nil end
						if mode == "throw" then config.post[self.event_type] = nil; error("injected post failure") end
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
		error = function() end,
	}
	package.loaded["infra.timings"] = { sec = function() return 0.25 end }
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function()
			return nil, "foreign", { events = {} }
		end,
	}
	package.loaded["adapters.synthetic_input"] = {
		defer_after_callback = function(label, callback)
			fixture.defer_calls = fixture.defer_calls + 1
			if config.defer_result == "throw" then error("injected defer failure") end
			if config.defer_result ~= true then return false end
			fixture.deferred[#fixture.deferred + 1] = {
				label = label,
				callback = callback,
			}
			return true
		end,
	}
	package.loaded["modules.gestures.actions_click"] = nil
	_G.hs = hs_stub

	local ok, err = xpcall(function()
		local ClickActions = require("modules.gestures.actions_click")
		body(ClickActions, fixture, types)
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(DEPENDENCIES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Asserts that a failed acquisition produced no visible click ownership.
--- @param ClickActions table Fresh click actions module.
--- @param fixture table Native fixture state.
local function assert_no_hold_published(ClickActions, fixture)
	helpers.assert_eq(#fixture.posted, 0, "acquisition failure must post zero mouseDown events")
	helpers.assert_eq(ClickActions.is_right_click_held(), false,
		"acquisition failure must publish no right-held state")
	helpers.assert_eq(ClickActions.is_left_click_held(), false,
		"acquisition failure must publish no left-held state")
end

--- Invokes every rejected tap callback and proves it remains inert.
--- @param fixture table Native fixture state.
--- @param types table Native event types.
--- @param taps table|nil Optional exact rejected handles.
local function assert_rejected_callbacks_are_inert(fixture, types, taps)
	local posts_before = #fixture.posted
	local defers_before = fixture.defer_calls
	for _, tap in ipairs(taps or fixture.taps) do
		local event = {
			getType = function() return types.mouseMoved end,
			location = function() return { x = 130, y = 90 } end,
		}
		local ok, post_count_or_err = pcall(function()
			tap.callback(event)
			return #fixture.posted
		end)
		helpers.assert_true(ok, "a stale native callback must be contained")
		helpers.assert_eq(post_count_or_err, posts_before,
			"each stale callback must remain inert at its delivery boundary")
	end
	helpers.assert_eq(#fixture.posted, posts_before,
		"a rejected callback must never post a drag or click")
	helpers.assert_eq(fixture.defer_calls, defers_before,
		"a rejected callback must never schedule a state transition")
end

helpers.describe("click-hold acquisition transaction", function()
	helpers.it("rejects mouseDown construction and property failures before tap acquisition (click-hold-acquisition-transaction)", function()
		for _, mode in ipairs({ "nil", "false", "throw" }) do
			with_fixture({ mouse_construct = { [4] = mode } }, function(ClickActions, fixture)
				local committed = ClickActions.toggle_right_click()
				assert_no_hold_published(ClickActions, fixture)
				helpers.assert_eq(committed, false)
				helpers.assert_eq(#fixture.taps, 0,
					"a missing mouseDown event must allocate no native tap")
			end)
			with_fixture({ property = mode }, function(ClickActions, fixture)
				local committed = ClickActions.toggle_right_click()
				assert_no_hold_published(ClickActions, fixture)
				helpers.assert_eq(committed, false)
				helpers.assert_eq(#fixture.taps, 0,
					"an untaggable mouseDown event must allocate no native tap")
			end)
		end
	end)

	helpers.it("rejects nil, false, and throwing constructors before mouseDown (click-hold-acquisition-transaction)", function()
		for _, mode in ipairs({ "nil", "false", "throw" }) do
			for _, position in ipairs({ 1, 2 }) do
				with_fixture({ construct = { [position] = mode } }, function(ClickActions, fixture, types)
					local committed = ClickActions.toggle_left_click()
					assert_no_hold_published(ClickActions, fixture)
					helpers.assert_eq(committed, false)
					if position == 2 then
						helpers.assert_eq(fixture.taps[1].stop_attempts, 1,
							"the exact first candidate must roll back when its sibling construction fails")
					end
					assert_rejected_callbacks_are_inert(fixture, types)
				end)
			end
		end
	end)

	helpers.it("rejects every start boundary including activate-then-throw (click-hold-acquisition-transaction)", function()
		for _, mode in ipairs({ "nil", "false", "throw", "activate_false", "activate_throw" }) do
			for _, position in ipairs({ 1, 2 }) do
				with_fixture({ start = { [position] = mode } }, function(ClickActions, fixture, types)
					local committed = ClickActions.toggle_left_click()
					assert_no_hold_published(ClickActions, fixture)
					helpers.assert_eq(committed, false)
					helpers.assert_eq(#fixture.taps, 2,
						"both taps must exist before native activation begins")
					helpers.assert_eq(fixture.taps[1].stop_attempts, 1,
						"the exact key watcher candidate must roll back")
					helpers.assert_eq(fixture.taps[2].stop_attempts, 1,
						"the exact drag candidate must roll back even if start was never reached")
					assert_rejected_callbacks_are_inert(fixture, types)
				end)
			end
		end
	end)

	helpers.it("requires isEnabled commitment from both taps (click-hold-acquisition-transaction)", function()
		for _, mode in ipairs({ "nil", "false", "throw" }) do
			for _, position in ipairs({ 1, 2 }) do
				with_fixture({ enabled = { [position] = mode } }, function(ClickActions, fixture, types)
					local committed = ClickActions.toggle_right_click()
					assert_no_hold_published(ClickActions, fixture)
					helpers.assert_eq(committed, false)
					helpers.assert_eq(fixture.taps[1].stop_attempts, 1)
					helpers.assert_eq(fixture.taps[2].stop_attempts, 1)
					assert_rejected_callbacks_are_inert(fixture, types)
				end)
			end
		end
	end)

	helpers.it("retains refused rollback and retries that exact handle before a successor (click-hold-acquisition-transaction)", function()
		with_fixture({
			start = { [2] = "activate_throw" },
			stop_failures = { [2] = 2 },
		}, function(ClickActions, fixture, types)
			helpers.assert_eq(ClickActions.toggle_left_click(), false)
			assert_no_hold_published(ClickActions, fixture)
			helpers.assert_eq(fixture.taps[2].stop_attempts, 1)
			local old_tap_count = #fixture.taps

			helpers.assert_eq(ClickActions.toggle_left_click(), false,
				"a successor must be refused while exact rollback debt still refuses stop")
			helpers.assert_eq(#fixture.taps, old_tap_count,
				"cleanup debt must block construction of a sibling successor")
			helpers.assert_eq(fixture.taps[2].stop_attempts, 2)
			assert_no_hold_published(ClickActions, fixture)

			helpers.assert_eq(ClickActions.toggle_left_click(), true,
				"acquisition may resume only after exact cleanup succeeds")
			helpers.assert_eq(fixture.taps[2].stop_attempts, 3,
				"the retained exact handle, not a reconstructed surrogate, must be retried")
			helpers.assert_eq(fixture.posted, { types.leftMouseDown })
			helpers.assert_eq(ClickActions.is_left_click_held(), true)
			assert_rejected_callbacks_are_inert(fixture, types,
				{ fixture.taps[1], fixture.taps[2] })
			helpers.assert_eq(ClickActions.force_cleanup(), true)
		end)
	end)

	helpers.it("retains throwing rollback debt and retries the exact activated handle (click-hold-acquisition-transaction)", function()
		with_fixture({
			start = { [2] = "activate_throw" },
			stop_throws = { [2] = 1 },
		}, function(ClickActions, fixture, types)
			local committed = ClickActions.toggle_right_click()
			assert_no_hold_published(ClickActions, fixture)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(fixture.taps[2].stop_attempts, 1)

			helpers.assert_eq(ClickActions.toggle_right_click(), true,
				"the exact activated handle must be retried before a successor commits")
			helpers.assert_eq(fixture.taps[2].stop_attempts, 2)
			helpers.assert_eq(fixture.posted, { types.rightMouseDown })
			helpers.assert_eq(ClickActions.force_cleanup(), true)
		end)
	end)

	helpers.it("retains a truthy stop whose tap remains enabled (click-hold-acquisition-transaction)", function()
		with_fixture({
			start = { [2] = "activate_throw" },
			stop_stays_enabled = { [2] = 1 },
		}, function(ClickActions, fixture, types)
			local committed = ClickActions.toggle_left_click()
			assert_no_hold_published(ClickActions, fixture)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(fixture.taps[2].stop_attempts, 1)
			helpers.assert_eq(fixture.taps[2].enabled, true,
				"a truthy stop result alone must not erase the still-enabled handle")

			helpers.assert_eq(ClickActions.toggle_left_click(), true,
				"the exact still-enabled handle must be stopped before successor acquisition")
			helpers.assert_eq(fixture.taps[2].stop_attempts, 2)
			helpers.assert_eq(fixture.taps[2].enabled, false)
			helpers.assert_eq(fixture.posted, { types.leftMouseDown })
			helpers.assert_eq(ClickActions.force_cleanup(), true)
		end)
	end)

	helpers.it("passes physical mouseUp through after fencing state in the callback (click-hold-acquisition-transaction)", function()
		with_fixture({}, function(ClickActions, fixture, types)
			helpers.assert_eq(ClickActions.toggle_left_click(), true)
			local key_watcher = fixture.taps[1]
			local drag_tap = fixture.taps[2]
			fixture.now = fixture.now + 1
			local swallowed = drag_tap.callback({
				getType = function() return types.leftMouseUp end,
				location = function() return { x = 130, y = 90 } end,
			})

			helpers.assert_eq(swallowed, false,
				"the exact physical mouseUp must always reach Quartz")
			helpers.assert_eq(ClickActions.is_left_click_held(), false,
				"held state must be fenced before the eventtap callback returns")
			helpers.assert_eq(fixture.posted, { types.leftMouseDown },
				"physical release must not depend on a later synthetic mouseUp")
			helpers.assert_eq(drag_tap.stop_attempts, 1)
			helpers.assert_eq(key_watcher.stop_attempts, 1)
			helpers.assert_eq(#fixture.deferred, 1,
				"only an optional post-callback diagnostic may be deferred")

			local posts_before = #fixture.posted
			fixture.deferred[1].callback()
			helpers.assert_eq(#fixture.posted, posts_before,
				"the deferred diagnostic must own no release or state transition")
		end)
	end)

	helpers.it("passes physical mouseUp through even when diagnostic deferral throws (click-hold-acquisition-transaction)", function()
		with_fixture({ defer_result = "throw" }, function(ClickActions, fixture, types)
			helpers.assert_eq(ClickActions.toggle_right_click(), true)
			local drag_tap = fixture.taps[2]
			fixture.now = fixture.now + 1
			local callback_ok, swallowed = pcall(drag_tap.callback, {
				getType = function() return types.rightMouseUp end,
				location = function() return { x = 130, y = 90 } end,
			})
			helpers.assert_true(callback_ok, "diagnostic scheduling must not escape the eventtap")
			helpers.assert_eq(swallowed, false)
			helpers.assert_eq(ClickActions.is_right_click_held(), false)
			helpers.assert_eq(fixture.posted, { types.rightMouseDown })
		end)
	end)

	helpers.it("force cleanup releases once and retries exact stop debt (click-hold-acquisition-transaction)", function()
		with_fixture({}, function(ClickActions, fixture, types)
			helpers.assert_eq(ClickActions.toggle_left_click(), true)
			local drag_tap = fixture.taps[2]
			fixture.config.stop_failures[drag_tap.index] = 2

			helpers.assert_eq(ClickActions.force_cleanup(), false,
				"cleanup reports retained native debt instead of pretending success")
			helpers.assert_eq(ClickActions.is_left_click_held(), false,
				"mouseUp commitment clears button ownership even when tap stop refuses")
			helpers.assert_eq(fixture.posted, { types.leftMouseDown, types.leftMouseUp })
			helpers.assert_eq(drag_tap.stop_attempts, 2,
				"force cleanup retries the exact refused native handle")

			helpers.assert_eq(ClickActions.force_cleanup(), true)
			helpers.assert_eq(drag_tap.stop_attempts, 3)
			helpers.assert_eq(fixture.posted, { types.leftMouseDown, types.leftMouseUp },
				"retrying native tap cleanup must never duplicate mouseUp")
		end)
	end)

	helpers.it("retains held state until a refused mouseUp post can be retried (click-hold-acquisition-transaction)", function()
		with_fixture({ post = { [1] = "false" } }, function(ClickActions, fixture, types)
			helpers.assert_eq(ClickActions.toggle_left_click(), true)
			helpers.assert_eq(ClickActions.force_cleanup(), false)
			helpers.assert_eq(ClickActions.is_left_click_held(), true,
				"a refused mouseUp must retain explicit release ownership")
			helpers.assert_eq(fixture.posted, { types.leftMouseDown })

			helpers.assert_eq(ClickActions.force_cleanup(), true)
			helpers.assert_eq(ClickActions.is_left_click_held(), false)
			helpers.assert_eq(fixture.posted, { types.leftMouseDown, types.leftMouseUp })
		end)
	end)
end)
