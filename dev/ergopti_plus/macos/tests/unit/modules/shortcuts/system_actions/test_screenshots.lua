--- tests/unit/modules/shortcuts/system_actions/test_screenshots.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local with_fixture = fixture.with_fixture
local as_physical = fixture.as_physical
local make_sys_screenshot_spies = fixture.make_sys_screenshot_spies
local run_screenshot_deferred = fixture.run_screenshot_deferred
local spawn_of = fixture.spawn_of
local argv_of = fixture.argv_of

helpers.describe("shortcuts.actions.system: bind_instant_screenshot defers exec (shortcuts-actions-1 regression)", function()

	helpers.it("invoking the eventtap callback does NOT call hs.execute inline", function()
		with_fixture(function()
			local _sys, spy = make_sys_screenshot_spies()
			_sys.bind_instant_screenshot()

			helpers.assert_true(spy.captured_cb ~= nil, "bind_instant_screenshot must register an eventtap callback")

			-- Simulate the @ key with no modifiers
			local fake_event = as_physical({
				getKeyCode = function() return 10 end,
				getFlags   = function() return {} end,
			})
			spy.captured_cb(fake_event)

			helpers.assert_eq(#spy.exec_calls, 0,
				"hs.execute must NOT be called inline in the eventtap callback (would block CGEventTap thread)")
		end)
	end)

	helpers.it("invoking the eventtap callback launches the capture work as a subprocess", function()
		with_fixture(function()
			local _sys, spy = make_sys_screenshot_spies()
			_sys.bind_instant_screenshot()

			local fake_event = as_physical({
				getKeyCode = function() return 10 end,
				getFlags   = function() return {} end,
			})
			spy.captured_cb(fake_event)
			helpers.assert_eq(#spy.tasks, 0,
				"frontmost-window lookup and subprocess creation must not run on the eventtap")
			run_screenshot_deferred(spy)

			-- This is the half of the invariant the "no inline hs.execute" case cannot
			-- carry: silently doing NOTHING also calls no blocking API.
			helpers.assert_true(#spy.tasks >= 1,
				"the capture work must actually be launched, off the tap callback — a fix that "
				.. "merely stops calling hs.execute inline and drops the screenshot would pass "
				.. "the inline assertion above")
			local first = spy.tasks[1]
			helpers.assert_true(first.path:sub(1, 1) == "/",
				"the binary must be an absolute path: the Hammerspoon process does not inherit "
				.. "the login shell's PATH, so a bare name is not reliably resolvable")
			helpers.assert_true(first.started,
				"an hs.task that is created but never started is a subprocess that never runs, "
				.. "and start() is where a refused launch is reported")
		end)
	end)

	helpers.it("the capture runs only after the directory has been created", function()
		with_fixture(function()
			local _sys, spy = make_sys_screenshot_spies()
			_sys.bind_instant_screenshot()

			local fake_event = as_physical({
				getKeyCode = function() return 10 end,
				getFlags   = function() return {} end,
			})
			spy.captured_cb(fake_event)
			run_screenshot_deferred(spy)

			local mkdir = spawn_of(spy, "mkdir")
			helpers.assert_true(mkdir ~= nil, "the screenshots directory must still be created")
			helpers.assert_true(argv_of(mkdir):find("-p", 1, true) ~= nil,
				"mkdir needs -p: the parent Pictures/screenshots path may not exist either")

			-- The ordering assertion the old mechanism could not express. Both calls used
			-- to be issued back to back inside one deferred block, so nothing verified
			-- that the directory existed before screencapture tried to write into it.
			helpers.assert_nil(spawn_of(spy, "screencapture"),
				"the capture must NOT be launched before mkdir reports completion — a capture "
				.. "into a missing directory writes no file, and the old code notified success "
				.. "regardless")

			mkdir.on_done(0, "", "")

			local capture = spawn_of(spy, "screencapture")
			helpers.assert_true(capture ~= nil,
				"once the directory exists the capture must be launched")
			local argv = argv_of(capture)
			helpers.assert_true(argv:find("-l", 1, true) ~= nil,
				"the capture must still target the recorded window id with -l")
			helpers.assert_true(argv:find("42", 1, true) ~= nil,
				"and that id must be the one read from the frontmost window, not a placeholder")
			helpers.assert_eq(#spy.exec_calls, 0,
				"and none of this may go through the blocking shell at any point")
		end)
	end)
end)


helpers.describe("shortcuts.actions.system: bind_instant_screenshot guards nil window ID (shortcuts-actions-2 regression)", function()

	helpers.it("does NOT run screencapture when window id is nil", function()
		with_fixture(function()
			local nil_id_window = {
				frontmostWindow = function()
					return { id = function() return nil end }
				end,
			}
			local _sys, spy = make_sys_screenshot_spies(nil_id_window)
			_sys.bind_instant_screenshot()

			local fake_event = as_physical({
				getKeyCode = function() return 10 end,
				getFlags   = function() return {} end,
			})
			helpers.assert_true(spy.captured_cb ~= nil, "eventtap must have been registered")
			-- The callback must not raise even when id() returns nil
			-- Called directly: the regression is a raise, so a raise must fail this case
			-- with its own error rather than with a boolean.
			spy.captured_cb(fake_event)

			-- Run the retained post-eventtap FIFO; the nil-id guard lives inside it.
			run_screenshot_deferred(spy)
			-- The nil-id guard must bail out before scheduling screencapture
			local found_screencapture = false
			for _, cmd in ipairs(spy.exec_calls) do
				if cmd:find("screencapture", 1, true) then found_screencapture = true end
			end
			helpers.assert_true(not found_screencapture,
				"screencapture must NOT be called when window id is nil")
		end)
	end)

	helpers.it("a nil window id launches no subprocess at all", function()
		with_fixture(function()
			-- Replaces a source grep for the old shell command string. Asserting the
			-- ORDER of two substrings in the file could only ever prove the guard is
			-- written above the call; this proves it actually stops it, and it keeps
			-- holding through any rewrite of the capture mechanism.
			local _sys, spy = make_sys_screenshot_spies({
				frontmostWindow = function() return { id = function() return nil end } end,
			})
			_sys.bind_instant_screenshot()

			spy.captured_cb(as_physical({
				getKeyCode = function() return 10 end,
				getFlags   = function() return {} end,
			}))
			run_screenshot_deferred(spy)

			helpers.assert_eq(#spy.tasks, 0,
				"a borderless or system window returns nil from :id(), and screencapture -l "
				.. "needs a valid CGWindowID — concatenating nil into the argv would raise "
				.. "inside the callback, where the throw is invisible")
			helpers.assert_eq(#spy.exec_calls, 0, "and nothing may reach the blocking shell either")
		end)
	end)

end)
