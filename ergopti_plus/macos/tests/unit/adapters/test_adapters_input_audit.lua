--- tests/unit/adapters/test_adapters_input_audit.lua

--- ==============================================================================
--- MODULE: adapters-input Audit Regression Tests
--- DESCRIPTION:
--- Regression coverage for two defects found in the adapters-input review:
---   - adapters-input-1: text_sender.send() throws (instead of log-and-return)
---     when text is nil/non-string because the auto-mode length check `#text`
---     runs outside any pcall.
---   - adapters-input-2: timer_scheduler tracks live timers in a weak-VALUE
---     table, so a fire-and-forget handle (not retained by the caller) can be
---     collected and then escape cancelAll(), leaking the underlying hs.timer.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================================
-- =====================================================
-- ======= 1/ text_sender nil-text safety ==============
-- =====================================================
-- =====================================================

helpers.describe("adapters-input-1: text_sender.send nil-text must not throw", function()
	local function load_sender_with_event_counter()
		package.loaded["tests.stubs.hs"] = nil
		local eventtap = require("tests.stubs.hs").eventtap
		local new_key_event = eventtap.event.newKeyEvent
		local created = 0
		eventtap.event.newKeyEvent = function(...)
			created = created + 1
			return new_key_event(...)
		end
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.event_provenance"] = nil
		local sender = helpers.load_with_stubs("adapters.text_sender", { eventtap = eventtap })
		return sender, function() return created end
	end

	-- Called DIRECTLY, not through pcall. "did not throw" was the whole assertion,
	-- and it is the weaker half: log_and_return means the call returns AND emits
	-- nothing. A guard that threw would fail here anyway, with its real stack
	-- instead of a boolean — a pcall converts the one useful artefact into `false`.
	--
	-- The strong half is the keystroke count. A malformed payload that still
	-- reached hs.eventtap would type garbage into whatever the user has focused.
	helpers.it("send(nil) in auto mode returns without emitting a keystroke", function()
		local TextSender, event_count = load_sender_with_event_counter()
		TextSender.send(nil)
		helpers.assert_eq(event_count(), 0,
			"a nil payload must emit nothing — reaching hs.eventtap would type into whatever "
				.. "window the user has focused")
	end)

	helpers.it("send(123) numeric payload returns without emitting a keystroke", function()
		local TextSender, event_count = load_sender_with_event_counter()
		TextSender.send(123)
		helpers.assert_eq(event_count(), 0, "a non-string payload must emit nothing either")
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ timer_scheduler cancelAll reach ==========
-- =====================================================
-- =====================================================

helpers.describe("adapters-input-2: timer_scheduler cancelAll must reach unretained timers", function()
	helpers.it("a fire-and-forget timer is still cancelled by cancelAll() after GC", function()
		local stopped = { count = 0 }
		-- Faithful native timer double: the scheduler now owns new/start/running
		-- transactionally, and Hammerspoon's start/stop methods return the timer
		local timer_stub = {
			new = function(_, _fn)
				local running = false
				local timer = {}
				function timer:start()
					running = true
					return self
				end
				function timer:running() return running end
				function timer:stop()
					stopped.count = stopped.count + 1
					running = false
					return self
				end
				return timer
			end,
			secondsSinceEpoch = function() return 0 end,
			absoluteTime = function() return 0 end,
			usleep = function(_) end,
		}
		local Scheduler = helpers.load_with_stubs("adapters.timer_scheduler", { timer = timer_stub })

		-- Schedule WITHOUT retaining the returned handle (fire-and-forget), the
		-- exact pattern used by api_mlx/api_ollama/api_remote (e.g. after(0, fn)).
		local committed = select(2, Scheduler.after(10, function() end))
		helpers.assert_eq(committed, true,
			"the fixture must prove it armed a real scheduler-owned timer before dropping it")

		-- Force a GC: with a weak-value registry the dropped handle is collected
		-- and its entry vanishes, so cancelAll() can no longer stop the timer.
		collectgarbage("collect")
		collectgarbage("collect")

		Scheduler.cancelAll()

		helpers.assert_eq(stopped.count, 1,
			"cancelAll() must stop the underlying hs.timer even when the handle was not retained")
		helpers.assert_eq(Scheduler.activeCount(), 0,
			"the strong registry must release the settled fire-and-forget timer")
	end)
end)
