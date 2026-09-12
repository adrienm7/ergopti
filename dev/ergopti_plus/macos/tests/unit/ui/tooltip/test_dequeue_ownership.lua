--- tests/unit/ui/tooltip/test_dequeue_ownership.lua

--- ==============================================================================
--- MODULE: Tooltip Dequeue Ownership Regression
--- DESCRIPTION:
--- Exercises real tooltip ownership while keeping native fixtures scoped per case.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")
local with_fixture = support.with_fixture
local CASES = support.CASES
local running_timers = support.running_timers
local hardware_key_event = support.hardware_key_event
local drain_deferred_actions = support.drain_deferred_actions

local DEQUEUE_RETRY_TIMER_FAILURES = {
	{
		label = "false",
		install = function() hs.timer.doAfter = function() return false end end,
	},
	{
		label = "nil",
		install = function() hs.timer.doAfter = function() return nil end end,
	},
	{
		label = "throw",
		install = function()
			hs.timer.doAfter = function() error("simulated dequeue retry timer failure") end
		end,
	},
}

helpers.describe("tooltip watcher reuse preserves dequeue ownership", function()
	helpers.it("(tooltip-watcher-first-deadline) mounts watchers for an absolute first render", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			local previous_clock = hs.timer.secondsSinceEpoch
			hs.timer.secondsSinceEpoch = function() return 100 end
			local ok, err = xpcall(function()
				helpers.assert_eq(context.tooltip.show_stacked({
					{ text = "absolute deadline", duration = 1, expire_at = 101 },
					{ text = "longer row", duration = 2, expire_at = 102 },
				}, true), true)
				helpers.assert_eq(#context.created, CASES[2].watcher_count,
					"deadline metadata cannot impersonate an already-mounted UI session")
				for _, watcher in ipairs(context.created) do
					helpers.assert_true(watcher:isEnabled(),
						"every dismissal watcher must be live before visibility commits")
				end
			end, debug.traceback)
			hs.timer.secondsSinceEpoch = previous_clock
			context.tooltip.hide_forced()
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("(tooltip-action-lease) revokes the exact winner before re-arbitration", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			local previous_clock = hs.timer.secondsSinceEpoch
			local now = 100
			local expiry_calls = 0
			local visible_inside_expiry = nil
			local lease = {}
			hs.timer.secondsSinceEpoch = function() return now end

			local ok, err = xpcall(function()
				helpers.assert_eq(context.tooltip.show_stacked({
					{
						text = "timed literal winner",
						duration = 0.01,
						expire_at = 100.01,
						lease_token = lease,
						on_expire = function()
							expiry_calls = expiry_calls + 1
							visible_inside_expiry = context.tooltip.is_visible()
						end,
					},
					{ text = "stale dimmed fallback", duration = 0, dimmed = true },
				}, true), true)
				helpers.assert_true(context.tooltip.has_visible_lease(lease),
					"the exact winner row, not merely its canvas, must own the action lease")

				local timers = running_timers(context.timers)
				helpers.assert_eq(#timers, 1,
					"the finite winner must own exactly one dequeue deadline")
				now = 100.02
				timers[1].running = false
				timers[1].fn()

				helpers.assert_eq(expiry_calls, 1,
					"winner expiry must delegate one fresh arbitration to its owner")
				helpers.assert_eq(visible_inside_expiry, false,
					"stale pixels and their lease must be revoked before owner code runs")
				helpers.assert_true(not context.tooltip.has_visible_lease(lease))
				helpers.assert_true(not context.tooltip.is_visible())
				helpers.assert_eq(context.renderer.stacked_render_calls, 1,
					"the dequeue must not promote a stale dimmed fallback on its own")

				local persistent_lease = {}
				context.config.settings.timeout_sec = 0
				local running_before_persistent = {}
				for _, timer in ipairs(running_timers(context.timers)) do
					running_before_persistent[timer] = true
				end
				helpers.assert_eq(context.tooltip.show_stacked({
					{ text = "provider snapshot", duration = 0, lease_token = persistent_lease },
				}, true), true)
				helpers.assert_true(context.tooltip.has_visible_lease(persistent_lease),
					"an infinite provider row needs an exact lease even without dequeue state")
				local new_running_timers = 0
				for _, timer in ipairs(running_timers(context.timers)) do
					if not running_before_persistent[timer] then
						new_running_timers = new_running_timers + 1
					end
				end
				helpers.assert_eq(new_running_timers, 0,
					"the infinite lease must not fabricate a dequeue deadline")
				helpers.assert_eq(context.tooltip.hide_forced(), true)
				helpers.assert_true(not context.tooltip.has_visible_lease(persistent_lease),
					"authoritative hide must revoke an infinite provider lease")
			end, debug.traceback)

			hs.timer.secondsSinceEpoch = previous_clock
			context.tooltip.hide_forced()
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("(tooltip-action-lease-hide-retry) retains the winner until native hide commits", function()
		with_fixture(function(fixture)
			local faults = { hide_stacked_result = false }
			local context = fixture.load_tooltip(CASES[2], faults)
			local previous_clock = hs.timer.secondsSinceEpoch
			local now = 100
			local expiry_calls = 0
			local lease = {}
			hs.timer.secondsSinceEpoch = function() return now end

			local ok, err = xpcall(function()
				helpers.assert_eq(context.tooltip.show_stacked({
					{
						text = "timed literal winner",
						duration = 0.01,
						expire_at = 100.01,
						lease_token = lease,
						on_expire = function() expiry_calls = expiry_calls + 1 end,
					},
					{ text = "stale dimmed fallback", duration = 0, dimmed = true },
				}, true), true)

				local first_deadline = running_timers(context.timers)[1]
				helpers.assert_not_nil(first_deadline,
					"the positive control must own the winner deadline")
				now = 100.02
				first_deadline.running = false
				first_deadline.fn()

				helpers.assert_eq(expiry_calls, 0,
					"re-arbitration must wait until native pixels are actually revoked")
				helpers.assert_true(context.tooltip.is_visible(),
					"a refused stacked hide must preserve truthful visible state")
				helpers.assert_true(context.renderer.stacked_visible,
					"the native failure double must leave the old pixels on screen")
				helpers.assert_true(context.tooltip.has_visible_lease(lease),
					"the action lease must remain bound to pixels that are still visible")

				local retries = running_timers(context.timers)
				helpers.assert_eq(#retries, 1,
					"failed native cleanup must retain one asynchronous retry owner")
				helpers.assert_true(retries[1] ~= first_deadline,
					"the delivered deadline must not impersonate the cleanup retry")
				helpers.assert_true(retries[1].delay > 0,
					"persistent native failures must not create a zero-delay retry loop")

				faults.hide_stacked_result = true
				retries[1].running = false
				retries[1].fn()
				helpers.assert_eq(expiry_calls, 1,
					"successful retry must delegate exactly one fresh arbitration")
				helpers.assert_true(not context.tooltip.is_visible())
				helpers.assert_true(not context.tooltip.has_visible_lease(lease))
			end, debug.traceback)

			hs.timer.secondsSinceEpoch = previous_clock
			faults.hide_stacked_result = true
			context.tooltip.hide_forced()
			if not ok then error(err, 0) end
		end)
	end)

	for _, timer_fault in ipairs(DEQUEUE_RETRY_TIMER_FAILURES) do
		helpers.it("(tooltip-action-lease-hide-retry-arm-" .. timer_fault.label
			.. ") preserves a physical cleanup owner", function()
			with_fixture(function(fixture)
				local faults = { hide_stacked_result = false }
				local context = fixture.load_tooltip(CASES[2], faults)
				local previous_clock = hs.timer.secondsSinceEpoch
				local previous_do_after = hs.timer.doAfter
				local now = 100
				local expiry_calls = 0
				local lease = {}
				hs.timer.secondsSinceEpoch = function() return now end

				local ok, err = xpcall(function()
					helpers.assert_eq(context.tooltip.show_stacked({
						{
							text = "timed literal winner",
							duration = 0.01,
							expire_at = 100.01,
							lease_token = lease,
							on_expire = function() expiry_calls = expiry_calls + 1 end,
						},
						{ text = "stale dimmed fallback", duration = 0, dimmed = true },
					}, true), true)

					local first_deadline = running_timers(context.timers)[1]
					helpers.assert_not_nil(first_deadline,
						"the positive control must own the winner deadline")
					timer_fault.install()
					now = 100.02
					first_deadline.running = false
					first_deadline.fn()

					helpers.assert_eq(expiry_calls, 0,
						"timer failure must not re-arbitrate while stale pixels remain")
					helpers.assert_true(context.tooltip.is_visible(),
						"the failed native hide must retain truthful visible state")
					helpers.assert_true(context.tooltip.has_visible_lease(lease),
						"the exact action lease must remain coupled to visible pixels")
					helpers.assert_eq(#running_timers(context.timers), 0,
						"an invalid retry result must not masquerade as a live timer")
					helpers.assert_eq(#context.created, 4,
						"timer failure must mount a fresh physical cleanup watcher set")
					for index = 1, 2 do
						helpers.assert_true(not context.created[index]:isEnabled(),
							"the expired watcher generation must remain stopped")
					end
					for index = 3, 4 do
						helpers.assert_true(context.created[index]:isEnabled(),
							"the fallback watcher generation must remain active")
					end

					-- Recover the native surface before exercising the fallback callback.
					-- The interaction still crosses the retained post-eventtap dispatcher.
					faults.hide_stacked_result = true
					hs.timer.doAfter = previous_do_after
					local consumed = context.created[3].fn(hardware_key_event(0, {}, ""))
					helpers.assert_eq(consumed, false,
						"physical cleanup must never consume the user's event")
					helpers.assert_true(context.tooltip.is_visible(),
						"the eventtap callback must defer native cleanup until after return")
					helpers.assert_true(context.renderer.stacked_visible,
						"the eventtap callback must not perform synchronous canvas work")
					drain_deferred_actions(context.timers)

					helpers.assert_true(not context.tooltip.is_visible(),
						"the fallback interaction must revoke the stale native surface")
					helpers.assert_true(not context.renderer.stacked_visible)
					helpers.assert_true(not context.tooltip.has_visible_lease(lease),
						"physical cleanup must revoke the exact stale action lease")
					helpers.assert_eq(expiry_calls, 0,
						"fallback dismissal must not replay the expired owner callback")
				end, debug.traceback)

				hs.timer.secondsSinceEpoch = previous_clock
				hs.timer.doAfter = previous_do_after
				faults.hide_stacked_result = true
				context.tooltip.hide_forced()
				if not ok then error(err, 0) end
			end)
		end)
	end

	helpers.it("(tooltip-watcher-reuse) owns and revokes a zero-delay dequeue timer", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			local clock_reads = 0
			local previous_clock = hs.timer.secondsSinceEpoch
			hs.timer.secondsSinceEpoch = function()
				clock_reads = clock_reads + 1
				return clock_reads == 1 and 100 or 200
			end

			local shown = context.tooltip.show_stacked({
				{ text = "expired first", duration = 1 },
				{ text = "expired second", duration = 2 },
			}, true)
			hs.timer.secondsSinceEpoch = previous_clock

			helpers.assert_eq(shown, true)
			local timers = running_timers(context.timers)
			helpers.assert_eq(#timers, 1,
				"the immediate dequeue callback must remain explicitly owned until delivery")
			helpers.assert_eq(timers[1].delay, 0)
			helpers.assert_eq(context.tooltip.hide_forced(), true)
			helpers.assert_true(not timers[1].running,
				"authoritative hide must revoke an owned zero-delay callback")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) retains an ambiguously armed dequeue timer until its callback arrives", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			local real_do_after = hs.timer.doAfter
			local do_after_calls = 0
			local ambiguous_timer
			hs.timer.doAfter = function(delay, callback)
				do_after_calls = do_after_calls + 1
				if do_after_calls > 1 then return real_do_after(delay, callback) end
				ambiguous_timer = {
					delay = delay,
					fn = callback,
					running = function() error("simulated ambiguous timer status") end,
					stop = function() error("simulated persistent timer stop failure") end,
				}
				return ambiguous_timer
			end

			local rows = {
				{ text = "short", duration = 1 },
				{ text = "long", duration = 2 },
			}
			helpers.assert_eq(context.tooltip.show_stacked(rows, true), false,
				"unverifiable ownership must fail the first render closed")
			helpers.assert_eq(context.tooltip.show_stacked(rows, true), false,
				"the retained timer must block a duplicate replacement")
			helpers.assert_eq(do_after_calls, 1,
				"cleanup ambiguity must retain the exact handle instead of scheduling beside it")

			ambiguous_timer.fn()
			helpers.assert_eq(context.tooltip.show_stacked(rows, true), true,
				"delivery of the retained exact callback must release ownership for recovery")
			helpers.assert_eq(do_after_calls, 2)
			hs.timer.doAfter = real_do_after
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) guarded hotstring hide leaves an active dequeue set intact", function()
		with_fixture(function(fixture)
			local spec = CASES[2]
			local context = fixture.load_tooltip(spec)
			helpers.assert_eq(context.tooltip.show_stacked({
				{ text = "short", duration = 1 },
				{ text = "long", duration = 2 },
			}, true), true, "the dequeue fixture must become visibly active")

			helpers.assert_eq(#context.created, spec.watcher_count,
				"the initial dequeue render must mount one complete dismissal set")
			helpers.assert_eq(context.tooltip.hide(), false,
				"a guarded hide must not report that a visible dequeue surface was hidden")
			helpers.assert_eq(context.tooltip.is_visible(), true,
				"the active dequeue surface must remain logically visible")
			helpers.assert_eq(context.renderer.stacked_visible, true,
				"the active dequeue canvas must remain natively visible")
			for _, watcher in ipairs(context.created) do
				helpers.assert_true(watcher:isEnabled(),
					"guarded hide must not tear down watchers owned by an active dequeue cycle")
			end

			context.tooltip.hide_forced()
			for _, watcher in ipairs(context.created) do
				helpers.assert_true(not watcher:isEnabled(),
					"authoritative hide must still tear down dequeue-owned watchers")
			end
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) dequeue timer stop failure blocks replacement atomically", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			local rows = {
				{ text = "short", duration = 1 },
				{ text = "long", duration = 2 },
			}
			helpers.assert_eq(context.tooltip.show_stacked(rows, true), true)
			local dequeue_timer = running_timers(context.timers)[1]
			helpers.assert_not_nil(dequeue_timer)
			dequeue_timer.stop = function()
				error("simulated persistent dequeue timer stop failure")
			end
			local renders_before = context.renderer.stacked_render_calls

			helpers.assert_eq(context.tooltip.show_stacked(rows, true), false,
				"an unrevoked dequeue timer must abort the replacement render")
			helpers.assert_eq(context.renderer.stacked_render_calls, renders_before,
				"replacement pixels must not paint while the old deadline is live")
			helpers.assert_eq(#running_timers(context.timers), 1,
				"failed stop must retain one owned timer, never create a second")
			helpers.assert_true(not context.tooltip.is_visible(),
				"dequeue ownership failure must fail the tooltip closed")
			helpers.assert_eq(context.tooltip.show_stacked(rows, true), false,
				"persistent cleanup failure must block later retries")
			helpers.assert_eq(#running_timers(context.timers), 1,
				"blocked retries must not multiply dequeue timers")

			dequeue_timer.stop = function(self)
				self.running = false
				return self
			end
			helpers.assert_eq(context.tooltip.show_stacked(rows, true), true,
				"a later render must recover after verified timer cleanup")
			helpers.assert_eq(#running_timers(context.timers), 1,
				"recovery must leave exactly one dequeue deadline")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) stale dequeue callback cannot mutate a replacement stack", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			local rows_a = {
				{ text = "A short", duration = 1 },
				{ text = "A long", duration = 2 },
			}
			local rows_b = {
				{ text = "B short", duration = 3 },
				{ text = "B long", duration = 4 },
			}
			helpers.assert_eq(context.tooltip.show_stacked(rows_a, true), true)
			local stale_timer = running_timers(context.timers)[1]
			helpers.assert_eq(context.tooltip.show_stacked(rows_b, true), true)
			local renders_before = context.renderer.stacked_render_calls

			stale_timer.fn()
			helpers.assert_eq(context.renderer.stacked_render_calls, renders_before,
				"a callback detached from ownership must not repaint current rows")
			helpers.assert_eq(#running_timers(context.timers), 1,
				"a stale callback must not arm an extra dequeue deadline")
			helpers.assert_true(context.tooltip.is_visible(),
				"the replacement stack must remain visible after stale callback delivery")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) dequeue rebuild requires a committed stacked repaint", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[2])
			helpers.assert_eq(context.tooltip.show_stacked({
				{ text = "short", duration = 1 },
				{ text = "long", duration = 2 },
			}, true), true)
			context.renderer.render_stacked = function() end
			local now = hs.timer.secondsSinceEpoch()

			local rebuild_result = context.tooltip.show_stacked({
				{ text = "short", duration = 1, expire_at = now + 1 },
				{ text = "long", duration = 2, expire_at = now + 2 },
			}, true)
			helpers.assert_eq(rebuild_result, false,
				"a swallowed stacked-render failure must not report a committed rebuild")
			helpers.assert_true(not context.tooltip.is_visible(),
				"a failed dequeue repaint must fail the tooltip closed")
			for _, watcher in ipairs(context.created) do
				helpers.assert_true(not watcher:isEnabled(),
					"a failed dequeue repaint must revoke the reused watcher set")
			end
			helpers.assert_eq(#running_timers(context.timers), 0,
				"a failed dequeue repaint must revoke the dequeue deadline")
		end)
	end)
end)
