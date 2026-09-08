--- tests/unit/ui/test_tooltip_watcher_reuse.lua

--- ==============================================================================
--- MODULE: Tooltip Watcher Lifecycle Regression
--- DESCRIPTION:
--- Exercises real tooltip ownership while keeping native fixtures scoped per case.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")
local with_fixture = support.with_fixture
local CASES = support.CASES
local running_timers = support.running_timers
local hardware_key_event = support.hardware_key_event

helpers.describe("tooltip watcher reuse", function()
	helpers.it("(tooltip-watcher-reuse) LLM reset rejects an uncommitted tooltip", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])

			helpers.assert_eq(context.tooltip.reset_timer(), false,
				"reset_timer must not arm a deadline before any tooltip owns the UI")
			helpers.assert_eq(#running_timers(context.timers), 0,
				"an invisible tooltip must not leave an orphan idle timer")
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) LLM reset closes a visible tooltip with a disabled watcher", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local cancels = 0
			context.tooltip.set_cancel_callback(function() cancels = cancels + 1; return true end)
			helpers.assert_eq(CASES[1].render(context.tooltip), true)
			context.created[1].enabled = false

			helpers.assert_eq(context.tooltip.reset_timer(), false,
				"a deadline cannot be renewed without a complete active watcher set")
			helpers.assert_eq(cancels, 1,
				"loss of interaction ownership must run the full cancel contract")
			helpers.assert_true(not context.tooltip.is_visible())
			helpers.assert_true(not context.renderer.visible,
				"watcher loss must close physical pixels, not only logical state")
			for _, watcher in ipairs(context.created) do
				helpers.assert_true(not watcher:isEnabled(),
					"every remaining watcher must be passive after fail-close")
			end
			helpers.assert_eq(#running_timers(context.timers), 0)
		end)
	end)

	helpers.it("(tooltip-watcher-reuse) a replaced LLM idle callback cannot dismiss the live deadline", function()
		with_fixture(function(fixture)
			local context = fixture.load_tooltip(CASES[1])
			local cancels = 0
			context.tooltip.set_cancel_callback(function() cancels = cancels + 1; return true end)
			helpers.assert_eq(CASES[1].render(context.tooltip), true)
			local old_timer = running_timers(context.timers)[1]
			helpers.assert_not_nil(old_timer)

			helpers.assert_eq(context.tooltip.reset_timer(), true)
			local live_timers = running_timers(context.timers)
			helpers.assert_eq(#live_timers, 1)
			local live_timer = live_timers[1]
			helpers.assert_true(live_timer ~= old_timer,
				"reset_timer must replace the prior deadline")

			-- Quartz may already have queued the old callback when stop() wins the
			-- timer race. Invoke the callback directly to model that delivery.
			old_timer.fn()
			helpers.assert_eq(cancels, 0,
				"a detached deadline must not run the current tooltip's cancel contract")
			helpers.assert_true(context.tooltip.is_visible(),
				"the tooltip must remain visible under its replacement deadline")
			helpers.assert_true(live_timer.running,
				"the stale callback must not stop the replacement deadline")
			helpers.assert_eq(#running_timers(context.timers), 1)
		end)
	end)

	for _, spec in ipairs(CASES) do
		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " reuses a complete active set and resets only its idle timer", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				local first_render = spec.render(context.tooltip)
				helpers.assert_eq(first_render, true,
					"a complete initial watcher set must report render success")

				helpers.assert_eq(#context.created, spec.watcher_count,
					"the first render must create the complete dismissal-watcher set")
				local first_timer = running_timers(context.timers)[1]
				helpers.assert_not_nil(first_timer, "the first render must arm its idle timer")

				local second_render = spec.render(context.tooltip)
				helpers.assert_eq(second_render, true,
					"reusing a complete watcher set must report render success")

				helpers.assert_eq(#context.created, spec.watcher_count,
					"a repeated render must reuse active eventtaps instead of rebuilding them")
				for _, watcher in ipairs(context.created) do
					helpers.assert_eq(watcher.started, 1, "a reused watcher must not be restarted")
					helpers.assert_eq(watcher.stopped, 0, "a reused watcher must not be stopped")
					helpers.assert_true(watcher:isEnabled(), "every reused watcher must remain active")
				end
				helpers.assert_eq(first_timer.running, false,
					"the old idle deadline must be cancelled on a repeated render")
				local active_timers = running_timers(context.timers)
				helpers.assert_eq(#active_timers, 1, "exactly one reset idle timer must remain active")
				helpers.assert_true(active_timers[1] ~= first_timer,
					"the repeated render must arm a fresh idle deadline")
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " tears down a partial set and retries it on the next render", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec, { [2] = "creation_throw" })
				local failed_render = spec.render(context.tooltip)
				local partial_count = spec.watcher_count - 1
				helpers.assert_eq(#context.created, partial_count,
					"the injected failure must leave an observable incomplete set")
				helpers.assert_true(not context.tooltip.is_visible(),
					"an incomplete dismissal set must fail closed instead of leaving stale UI")
				helpers.assert_eq(failed_render, false,
					"an incomplete dismissal set must be reported to the caller")
				helpers.assert_true(context.renderer.hide_calls >= 1,
					"fail-close must hide the physical canvas, not only its logical flag")
				for _, watcher in ipairs(context.created) do
					helpers.assert_true(not watcher:isEnabled(),
						"every watcher from an incomplete set must be stopped immediately")
				end

				local retry_render = spec.render(context.tooltip)

				helpers.assert_eq(#context.created, partial_count + spec.watcher_count,
					"the next render must retry every watcher, not preserve a partial set")
				for index = 1, partial_count do
					helpers.assert_eq(context.created[index].stopped, 1,
						"every watcher from the incomplete set must be stopped before retry")
				end
				for index = partial_count + 1, #context.created do
					helpers.assert_true(context.created[index]:isEnabled(),
						"every watcher in the retried set must be active")
				end
				helpers.assert_true(context.tooltip.is_visible(),
					"a complete retry must make the tooltip usable again")
				helpers.assert_eq(retry_render, true,
					"a complete retry must report success")
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rejects taps that throw or remain disabled during activation", function()
			with_fixture(function(fixture)
				for _, fault in ipairs({ "start_disabled", "start_throw", "is_enabled_throw" }) do
					for _, fault_index in ipairs({ 1, spec.watcher_count }) do
						local context = fixture.load_tooltip(spec, { [fault_index] = fault })
						local cancel_calls = 0
						if spec.label == "LLM" then
							context.tooltip.set_cancel_callback(function()
								cancel_calls = cancel_calls + 1
								return true
							end)
						end
						local failed_render = spec.render(context.tooltip)

						helpers.assert_true(not context.tooltip.is_visible(),
							fault .. " must fail closed when dismissal ownership is incomplete")
						helpers.assert_eq(failed_render, false,
							fault .. " must report activation failure to the caller")
						helpers.assert_true(context.renderer.hide_calls >= 1,
							fault .. " must hide the physical canvas")
						for _, watcher in ipairs(context.created) do
							helpers.assert_eq(watcher.stopped, 1,
								fault .. " must attempt teardown for every created watcher")
							helpers.assert_true(not watcher:isEnabled(),
								fault .. " must leave no active partial watcher")
						end
						helpers.assert_eq(#running_timers(context.timers), 0,
							fault .. " must leave no idle deadline behind")
						if spec.label == "LLM" then
							helpers.assert_eq(cancel_calls, 1,
								fault .. " must cancel engine ownership exactly once")
						end

						local created_before_retry = #context.created
						local retry_render = spec.render(context.tooltip)
						helpers.assert_eq(#context.created, created_before_retry + spec.watcher_count,
							fault .. " must retry the complete watcher set on the next render")
						helpers.assert_true(context.tooltip.is_visible(),
							fault .. " recovery must restore a usable tooltip")
						helpers.assert_eq(retry_render, true,
							fault .. " recovery must report success")
					end
				end
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retains activation orphans until their stop can be verified", function()
			with_fixture(function(fixture)
				for _, fault in ipairs({ "start_throw_stop_throw", "is_enabled_throw_stop_throw" }) do
					for _, fault_index in ipairs({ 1, spec.watcher_count }) do
						local context = fixture.load_tooltip(spec, { [fault_index] = fault })
						local failed_render = spec.render(context.tooltip)
						local orphan = context.created[fault_index]

						helpers.assert_eq(failed_render, false,
							fault .. " must report the unrevoked activation failure")
						helpers.assert_true(orphan:isEnabled(),
							fault .. " must model an eventtap that remained active")
						helpers.assert_true(not context.tooltip.is_visible(),
							fault .. " must still fail the tooltip closed")
						helpers.assert_eq(#context.created, spec.watcher_count,
							fault .. " must finish owning only the attempted candidate set")
						if fault_index == spec.watcher_count then
							helpers.assert_eq(#running_timers(context.timers), 0,
								fault .. " fail-close must begin with no deferred dispatcher")
							local consumed = orphan.fn(hardware_key_event(48, {}, "\t"))
							helpers.assert_eq(consumed, false,
								fault .. " retained key tap must pass input while its session is closed")
							helpers.assert_eq(#running_timers(context.timers), 0,
								fault .. " retained key tap must not enqueue hidden-session work")
						end

						local blocked_retry = spec.render(context.tooltip)
						helpers.assert_eq(blocked_retry, false,
							fault .. " must keep retries fail-closed while cleanup is blocked")
						helpers.assert_eq(#context.created, spec.watcher_count,
							fault .. " must not create replacements beside the orphan")

						orphan.stop = function(self)
							self.stopped = self.stopped + 1
							self.enabled = false
							return self
						end
						local recovered_render = spec.render(context.tooltip)
						helpers.assert_eq(recovered_render, true,
							fault .. " must recover after the retained orphan can be stopped")
						helpers.assert_eq(#context.created, spec.watcher_count * 2,
							fault .. " must create exactly one complete replacement set")
						local enabled_count = 0
						for _, watcher in ipairs(context.created) do
							if watcher:isEnabled() then enabled_count = enabled_count + 1 end
						end
						helpers.assert_eq(enabled_count, spec.watcher_count,
							fault .. " recovery must leave exactly one active set")
					end
				end
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " never duplicates a watcher whose stop operation remains failed", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				spec.render(context.tooltip)
				local orphan = context.created[1]
				orphan.stop = function(self)
					self.stopped = self.stopped + 1
					error("simulated persistent eventtap stop failure")
				end
				context.created[2].enabled = false

				local failed_render = spec.render(context.tooltip)
				helpers.assert_eq(#context.created, spec.watcher_count,
					"a failed stop must abort replacement before creating new taps")
				helpers.assert_true(orphan:isEnabled(),
					"the harness must retain the still-active orphan after stop fails")
				helpers.assert_true(not context.tooltip.is_visible(),
					"an unrevoked watcher must force the tooltip closed")
				helpers.assert_eq(failed_render, false,
					"an unrevoked watcher must report failure")
				helpers.assert_true(context.renderer.hide_calls >= 1,
					"an unrevoked watcher must hide the physical canvas")

				local retry_render = spec.render(context.tooltip)
				helpers.assert_eq(#context.created, spec.watcher_count,
					"a later render must retry cleanup without duplicating the orphan")
				helpers.assert_eq(retry_render, false,
					"persistent cleanup failure must remain visible to callers")
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retries the full set after a transient stop failure is revoked", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				spec.render(context.tooltip)
				local orphan = context.created[1]
				local real_stop = orphan.stop
				local failed_once = false
				orphan.stop = function(self)
					if not failed_once then
						failed_once = true
						self.stopped = self.stopped + 1
						error("simulated one-shot eventtap stop failure")
					end
					return real_stop(self)
				end
				context.created[2].enabled = false

				local failed_render = spec.render(context.tooltip)
				helpers.assert_eq(#context.created, spec.watcher_count,
					"the render that observes a stop failure must not create replacements")
				helpers.assert_true(not orphan:isEnabled(),
					"fail-close cleanup may revoke a one-shot orphan before returning")
				helpers.assert_eq(failed_render, false,
					"the render that observed cleanup failure must still report failure")

				local retry_render = spec.render(context.tooltip)
				helpers.assert_eq(#context.created, spec.watcher_count * 2,
					"the next render must create exactly one complete replacement set")
				helpers.assert_true(context.tooltip.is_visible(),
					"successful cleanup and retry must restore the tooltip")
				helpers.assert_eq(retry_render, true,
					"successful cleanup and retry must report success")
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retains a watcher whose stopped status is ambiguous", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				spec.render(context.tooltip)
				local ambiguous = context.created[1]
				local real_is_enabled = ambiguous.isEnabled
				ambiguous.isEnabled = function() return nil end
				context.created[2].enabled = false

				local failed_render = spec.render(context.tooltip)
				helpers.assert_eq(failed_render, false,
					"nil isEnabled status must not be treated as verified cleanup")
				helpers.assert_eq(#context.created, spec.watcher_count,
					"ambiguous cleanup must not create replacement taps")
				ambiguous.isEnabled = real_is_enabled

				local recovered_render = spec.render(context.tooltip)
				helpers.assert_eq(recovered_render, true,
					"cleanup must recover once stopped state is exactly false")
				helpers.assert_eq(#context.created, spec.watcher_count * 2,
					"recovery must create exactly one complete replacement set")
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retains a failed idle deadline without duplicating watcher sets", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				spec.render(context.tooltip)
				local idle_timer = running_timers(context.timers)[1]
				helpers.assert_not_nil(idle_timer, "the initial render must own an idle deadline")
				idle_timer.stop = function()
					error("simulated persistent timer stop failure")
				end

				local failed_render = spec.render(context.tooltip)
				helpers.assert_eq(failed_render, false,
					"a timer that cannot be replaced safely must fail the render closed")
				helpers.assert_true(not context.tooltip.is_visible(),
					"timer ownership failure must close the tooltip")
				helpers.assert_eq(#context.created, spec.watcher_count,
					"timer failure must not create a duplicate watcher set")

				local blocked_retry = spec.render(context.tooltip)
				helpers.assert_eq(blocked_retry, false,
					"persistent timer cleanup failure must remain visible to callers")
				helpers.assert_eq(#context.created, spec.watcher_count,
					"persistent timer cleanup failure must not create replacements")

				idle_timer.stop = function(self)
					self.running = false
					return self
				end
				local recovered_render = spec.render(context.tooltip)
				helpers.assert_eq(recovered_render, true,
					"the tooltip must recover after the retained deadline can be stopped")
				helpers.assert_eq(#context.created, spec.watcher_count * 2,
					"timer recovery must create exactly one complete replacement set")
				helpers.assert_eq(#running_timers(context.timers), 1,
					"timer recovery must leave exactly one active idle deadline")
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rebuilds the whole set when one watcher becomes disabled", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				spec.render(context.tooltip)
				context.created[1].enabled = false

				spec.render(context.tooltip)

				helpers.assert_eq(#context.created, spec.watcher_count * 2,
					"a disabled member must invalidate the complete watcher set")
				for index = 1, spec.watcher_count do
					helpers.assert_eq(context.created[index].stopped, 1,
						"recovery must stop every member of the stale set")
				end
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " hide tears down every watcher and idle timer", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec)
				spec.render(context.tooltip)
				context.tooltip.hide()

				for _, watcher in ipairs(context.created) do
					helpers.assert_eq(watcher.stopped, 1, "hide must stop every dismissal watcher")
					helpers.assert_true(not watcher:isEnabled(), "hide must leave no watcher active")
				end
				helpers.assert_eq(#running_timers(context.timers), 0,
					"hide must leave no idle timer active")
			end)
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rejects a renderer failure swallowed before the commit callback", function()
			with_fixture(function(fixture)
				local context = fixture.load_tooltip(spec, { render_skip_callback = true })
				local cancel_calls = 0
				if spec.label == "LLM" then
					context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1; return true end)
				end

				local render_result = spec.render(context.tooltip)
				helpers.assert_eq(render_result, false,
					"missing commit callback must be reported as a failed render")
				helpers.assert_true(not context.tooltip.is_visible(),
					"missing commit callback must clear logical visibility")
				helpers.assert_true(not context.renderer.visible,
					"the swallowed renderer failure must leave no physical canvas")
				helpers.assert_eq(#context.created, 0,
					"missing commit callback must not create eventtaps")
				helpers.assert_eq(#running_timers(context.timers), 0,
					"missing commit callback must not arm timers")
				if spec.label == "LLM" then
					helpers.assert_eq(cancel_calls, 1,
						"swallowed LLM paint failure must release engine ownership")
				end
			end)
		end)
	end
end)
