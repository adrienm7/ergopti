--- tests/unit/ui/test_tooltip_watcher_reuse.lua

--- ==============================================================================
--- MODULE: Tooltip Watcher Reuse Regression Tests
--- DESCRIPTION:
--- Exercises the real LLM and hotstring tooltip modules against observable
--- eventtap and timer doubles. Repeated streaming or preview renders must reset
--- only the idle deadline instead of rebuilding every dismissal tap, while an
--- incomplete or disabled set must be discarded and rebuilt as one unit.
--- ==============================================================================

local helpers = require("tests.helpers")

local IDLE_TIMEOUT_SEC = 10

local CASES = {
	{
		label = "LLM",
		module_name = "ui.tooltip.tooltip_llm",
		watcher_count = 3,
		render = function(tooltip)
			return tooltip.show_predictions({ "prediction" }, 1, true)
		end,
	},
	{
		label = "hotstring",
		module_name = "ui.tooltip.tooltip_hotstring",
		watcher_count = 2,
		render = function(tooltip)
			return tooltip.show("expansion", false, true)
		end,
	},
}

--- Loads one real tooltip module with observable renderer and eventtap ports.
--- @param spec table Tooltip case descriptor.
--- @param faults table|nil Fault kind keyed by eventtap creation index.
--- @return table Test context.
local function load_tooltip(spec, faults)
	local Config = helpers.load_with_stubs("ui.tooltip.config")
	Config.settings.timeout_sec = IDLE_TIMEOUT_SEC
	Config.settings.llm_timeout_sec = IDLE_TIMEOUT_SEC
	-- These adapters retain hs.timer/eventtap objects in module locals. Reload
	-- them with the fresh hs stub so deferred-action assertions cannot inspect a
	-- different timer table and pass without ever draining the real queue.
	package.loaded["adapters.event_provenance"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_tap_guard"] = nil

	local renderer
	renderer = {
		hide_calls = 0,
		render_calls = 0,
		stacked_render_calls = 0,
		visible = false,
		stacked_visible = false,
		canvas = {
			minimumTextSize = function() return { w = 100, h = 20 } end,
		},
		render = function(_content, _state, on_shown)
			if faults and faults.render_throw then error("simulated renderer failure") end
			renderer.render_calls = renderer.render_calls + 1
			renderer.visible = true
			if faults and faults.render_skip_callback then
				renderer.hide()
				return
			end
			if type(on_shown) == "function" then on_shown() end
		end,
		render_stacked = function(_rows, _state, on_shown)
			renderer.stacked_render_calls = renderer.stacked_render_calls + 1
			renderer.stacked_visible = true
			if type(on_shown) == "function" then on_shown() end
		end,
		hide = function()
			renderer.hide_calls = renderer.hide_calls + 1
			renderer.visible = false
		end,
		hide_stacked = function() renderer.stacked_visible = false end,
	}
	package.loaded["ui.tooltip.renderer"] = renderer

	local created = {}
	local creation_calls = 0
	local real_new = hs.eventtap.new
	hs.eventtap.new = function(types, callback)
		creation_calls = creation_calls + 1
		local fault = faults and faults[creation_calls] or nil
		if fault == "creation_throw" then
			error("simulated eventtap creation failure")
		end
		local watcher = real_new(types, callback)
		if fault == "start_disabled" then
			watcher.start = function(self)
				self.started = self.started + 1
				self.enabled = false
				return self
			end
		elseif fault == "start_throw" or fault == "start_throw_stop_throw" then
			watcher.start = function(self)
				self.started = self.started + 1
				self.enabled = true
				error("simulated eventtap start failure")
			end
		elseif fault == "is_enabled_throw" or fault == "is_enabled_throw_stop_throw" then
			local real_is_enabled = watcher.isEnabled
			local failed_once = false
			watcher.isEnabled = function(self)
				if not failed_once then
					failed_once = true
					error("simulated eventtap status failure")
				end
				return real_is_enabled(self)
			end
		end
		if fault == "start_throw_stop_throw" or fault == "is_enabled_throw_stop_throw" then
			watcher.stop = function(self)
				self.stopped = self.stopped + 1
				error("simulated persistent eventtap stop failure")
			end
		end
		created[#created + 1] = watcher
		return watcher
	end

	package.loaded[spec.module_name] = nil
	local tooltip = require(spec.module_name)

	return {
		created = created,
		renderer = renderer,
		timers = hs.timer.__timers,
		tooltip = tooltip,
	}
end

--- Returns the currently running timers from a test context.
--- @param timers table Timer objects.
--- @return table Running timers.
local function running_timers(timers)
	local result = {}
	for _, timer in ipairs(timers) do
		if timer.running then result[#result + 1] = timer end
	end
	return result
end

--- Builds a physical key event with only the fields tooltip watchers read.
--- @param keycode number Quartz keycode.
--- @param flags table|nil Modifier flags.
--- @param characters string|nil Produced characters.
--- @return table Event double.
local function hardware_key_event(keycode, flags, characters)
	local event = {}
	function event:getProperty() return 0 end
	function event:getKeyCode() return keycode end
	function event:getFlags() return flags or {} end
	function event:getCharacters() return characters or "" end
	return event
end

--- Fires every pending zero-delay dispatcher without expiring idle timers.
--- @param timers table Timer objects.
local function drain_deferred_actions(timers)
	for _ = 1, 10 do
		local fired = false
		for _, timer in ipairs(timers) do
			if timer.running and timer.delay == 0 then
				timer:fire()
				fired = true
			end
		end
		if not fired then return end
	end
	error("deferred action queue did not become idle")
end





-- ====================================
-- ====================================
-- ======= 1/ Watcher Lifecycle =======
-- ====================================
-- ====================================

helpers.describe("tooltip watcher reuse", function()
	helpers.it("(tooltip-watcher-reuse) LLM reset rejects an uncommitted tooltip", function()
		local context = load_tooltip(CASES[1])

		helpers.assert_eq(context.tooltip.reset_timer(), false,
			"reset_timer must not arm a deadline before any tooltip owns the UI")
		helpers.assert_eq(#running_timers(context.timers), 0,
			"an invisible tooltip must not leave an orphan idle timer")
	end)

	helpers.it("(tooltip-watcher-reuse) LLM reset closes a visible tooltip with a disabled watcher", function()
		local context = load_tooltip(CASES[1])
		local cancels = 0
		context.tooltip.set_cancel_callback(function() cancels = cancels + 1 end)
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

	helpers.it("(tooltip-watcher-reuse) a replaced LLM idle callback cannot dismiss the live deadline", function()
		local context = load_tooltip(CASES[1])
		local cancels = 0
		context.tooltip.set_cancel_callback(function() cancels = cancels + 1 end)
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

	for _, spec in ipairs(CASES) do
		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " reuses a complete active set and resets only its idle timer", function()
			local context = load_tooltip(spec)
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " tears down a partial set and retries it on the next render", function()
			local context = load_tooltip(spec, { [2] = "creation_throw" })
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rejects taps that throw or remain disabled during activation", function()
			for _, fault in ipairs({ "start_disabled", "start_throw", "is_enabled_throw" }) do
				for _, fault_index in ipairs({ 1, spec.watcher_count }) do
					local context = load_tooltip(spec, { [fault_index] = fault })
					local cancel_calls = 0
					if spec.label == "LLM" then
						context.tooltip.set_cancel_callback(function()
							cancel_calls = cancel_calls + 1
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retains activation orphans until their stop can be verified", function()
			for _, fault in ipairs({ "start_throw_stop_throw", "is_enabled_throw_stop_throw" }) do
				for _, fault_index in ipairs({ 1, spec.watcher_count }) do
					local context = load_tooltip(spec, { [fault_index] = fault })
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " never duplicates a watcher whose stop operation remains failed", function()
			local context = load_tooltip(spec)
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retries the full set after a transient stop failure is revoked", function()
			local context = load_tooltip(spec)
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retains a watcher whose stopped status is ambiguous", function()
			local context = load_tooltip(spec)
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " retains a failed idle deadline without duplicating watcher sets", function()
			local context = load_tooltip(spec)
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rebuilds the whole set when one watcher becomes disabled", function()
			local context = load_tooltip(spec)
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

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " hide tears down every watcher and idle timer", function()
			local context = load_tooltip(spec)
			spec.render(context.tooltip)
			context.tooltip.hide()

			for _, watcher in ipairs(context.created) do
				helpers.assert_eq(watcher.stopped, 1, "hide must stop every dismissal watcher")
				helpers.assert_true(not watcher:isEnabled(), "hide must leave no watcher active")
			end
			helpers.assert_eq(#running_timers(context.timers), 0,
				"hide must leave no idle timer active")
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rejects a renderer failure swallowed before the commit callback", function()
			local context = load_tooltip(spec, { render_skip_callback = true })
			local cancel_calls = 0
			if spec.label == "LLM" then
				context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1 end)
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
	end
end)

helpers.describe("tooltip rendering is committed atomically", function()
	for _, spec in ipairs(CASES) do
		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " closes logical and physical state when rendering throws", function()
			local context = load_tooltip(spec, { render_throw = true })
			local cancel_calls = 0
			if spec.label == "LLM" then
				context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1 end)
			end

			local render_result = spec.render(context.tooltip)
			helpers.assert_eq(render_result, false,
				"a renderer exception must be reported to the caller")
			helpers.assert_true(not context.tooltip.is_visible(),
				"a renderer exception must clear logical visibility")
			helpers.assert_true(context.renderer.hide_calls >= 1,
				"a renderer exception must hide the physical canvas")
			helpers.assert_eq(#context.created, 0,
				"a renderer exception before commit must not create eventtaps")
			helpers.assert_eq(#running_timers(context.timers), 0,
				"a renderer exception before commit must not arm an idle timer")
			if spec.label == "LLM" then
				helpers.assert_eq(cancel_calls, 1,
					"an LLM renderer exception must release engine ownership exactly once")
			end
		end)

		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " fail-closes an unexpected watcher callback crash", function()
			local context = load_tooltip(spec)
			local cancel_calls = 0
			if spec.label == "LLM" then
				context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1 end)
			end
			local saved_event_types = hs.eventtap.event.types
			hs.eventtap.event.types = nil
			local call_ok, render_result = pcall(spec.render, context.tooltip)
			hs.eventtap.event.types = saved_event_types

			helpers.assert_true(call_ok,
				"watcher setup exceptions must not escape the renderer boundary")
			helpers.assert_eq(render_result, false,
				"watcher setup exceptions must be reported to the caller")
			helpers.assert_true(not context.tooltip.is_visible(),
				"watcher setup exceptions must clear logical visibility")
			helpers.assert_true(context.renderer.hide_calls >= 1,
				"watcher setup exceptions must hide the physical canvas")
			helpers.assert_eq(#running_timers(context.timers), 0,
				"watcher setup exceptions must revoke the already-armed idle deadline")
			if spec.label == "LLM" then
				helpers.assert_eq(cancel_calls, 1,
					"watcher setup exceptions must cancel LLM ownership exactly once")
			end
		end)
	end

	helpers.it("(tooltip-watcher-reuse) a failed LLM refresh cannot expose new state behind old pixels", function()
		local context = load_tooltip(CASES[1])
		local cancel_calls = 0
		context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1 end)
		helpers.assert_eq(context.tooltip.show_predictions({ "old" }, 1, true), true)
		context.renderer.render = function() error("simulated streaming repaint failure") end

		local refresh_result = context.tooltip.show_predictions({ "unseen new text" }, 1, true)
		helpers.assert_eq(refresh_result, false,
			"a failed streaming repaint must report failure")
		helpers.assert_true(not context.tooltip.is_visible(),
			"old pixels must not remain actionable after a failed refresh")
		helpers.assert_eq(cancel_calls, 1,
			"a failed refresh must release prediction-engine ownership")
		for _, watcher in ipairs(context.created) do
			helpers.assert_true(not watcher:isEnabled(),
				"a failed refresh must tear down the prior dismissal set")
		end
		helpers.assert_eq(#running_timers(context.timers), 0,
			"a failed refresh must cancel the prior idle deadline")
	end)

	helpers.it("(tooltip-watcher-reuse) failed LLM navigation cannot diverge selection from pixels", function()
		local context = load_tooltip(CASES[1])
		local cancel_calls = 0
		context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1 end)
		helpers.assert_eq(context.tooltip.show_predictions({ "first", "second" }, 1, true), true)
		context.renderer.render = function() error("simulated navigation repaint failure") end

		local navigate_result = context.tooltip.navigate(1)
		helpers.assert_eq(navigate_result, false,
			"a failed navigation repaint must report failure")
		helpers.assert_true(not context.tooltip.is_visible(),
			"a failed navigation repaint must close the stale selection UI")
		helpers.assert_eq(context.tooltip.get_current_index(), 1,
			"fail-close must reset the unseen logical selection")
		helpers.assert_eq(cancel_calls, 1,
			"failed navigation must release engine ownership exactly once")
	end)

	helpers.it("(tooltip-watcher-reuse) loading paint reports disabled, empty, and renderer failures", function()
		local context = load_tooltip(CASES[2])
		helpers.assert_eq(context.tooltip.show_loading("loading", false), false,
			"a disabled loading indicator must not report a successful paint")
		helpers.assert_eq(context.tooltip.show_loading("", true), false,
			"an empty loading indicator must not report a successful paint")
		context.renderer.render = function() error("simulated loading repaint failure") end
		helpers.assert_eq(context.tooltip.show_loading("loading", true), false,
			"a loading renderer exception must be reported")
		helpers.assert_true(not context.tooltip.is_visible(),
			"a failed loading paint must clear logical visibility")
		helpers.assert_true(context.renderer.hide_calls >= 1,
			"a failed loading paint must hide the physical canvas")

		local swallowed = load_tooltip(CASES[2], { render_skip_callback = true })
		helpers.assert_eq(swallowed.tooltip.show_loading("loading", true), false,
			"a loading renderer that swallows failure must still report no commit")
		helpers.assert_true(not swallowed.tooltip.is_visible(),
			"swallowed loading failure must clear logical visibility")
	end)

	helpers.it("(tooltip-watcher-reuse) stale LLM acceptance cannot target a streaming repaint", function()
		local context = load_tooltip(CASES[1])
		local accepts = 0
		local synthetic = require("adapters.synthetic_input")
		context.tooltip.set_accept_callback(function() accepts = accepts + 1 end)
		helpers.assert_eq(context.tooltip.show_predictions({ "visible A" }, 1, true), true)
		local key_watcher = context.created[CASES[1].watcher_count]
		helpers.assert_eq(key_watcher.fn(hardware_key_event(48, {}, "\t")), true,
			"positive control: visible A must own the physical Tab")
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1,
			"the A acceptance must really be queued before B repaints")

		helpers.assert_eq(context.tooltip.show_predictions({ "visible B" }, 1, true), true,
			"the streaming repaint must commit before the old deferred action drains")
		drain_deferred_actions(context.timers)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
			"the stale A action must be drained rather than left unexecuted")
		helpers.assert_eq(accepts, 0,
			"a Tab classified against A must not accept the B prediction pool")
		helpers.assert_true(context.tooltip.is_visible(),
			"discarding stale A work must leave visible B intact")
	end)

	helpers.it("(tooltip-watcher-reuse) stale hotstring dismissal cannot hide a replacement", function()
		local context = load_tooltip(CASES[2])
		local synthetic = require("adapters.synthetic_input")
		helpers.assert_eq(context.tooltip.show("visible A", false, true), true)
		local key_watcher = context.created[CASES[2].watcher_count]
		helpers.assert_eq(key_watcher.fn(hardware_key_event(0, {}, "a")), false,
			"hotstring dismissal observes but never consumes the physical key")
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1,
			"the A dismissal must really be queued before B replaces it")

		helpers.assert_eq(context.tooltip.show("visible B", false, true), true,
			"the replacement must commit before the old deferred dismissal drains")
		drain_deferred_actions(context.timers)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
			"the stale A dismissal must be drained rather than left unexecuted")
		helpers.assert_true(context.tooltip.is_visible(),
			"a dismissal classified against A must not hide visible B")
	end)

	helpers.it("(tooltip-watcher-reuse) same-generation deferred acceptance still executes", function()
		local context = load_tooltip(CASES[1])
		local accepts = 0
		local synthetic = require("adapters.synthetic_input")
		context.tooltip.set_accept_callback(function() accepts = accepts + 1 end)
		helpers.assert_eq(context.tooltip.show_predictions({ "visible" }, 1, true), true)
		local key_watcher = context.created[CASES[1].watcher_count]
		helpers.assert_eq(key_watcher.fn(hardware_key_event(48, {}, "\t")), true)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1)

		drain_deferred_actions(context.timers)
		helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
			"the positive-control dispatcher must actually drain")
		helpers.assert_eq(accepts, 1,
			"generation fencing must not discard current-render acceptance")
	end)

	for _, spec in ipairs(CASES) do
		helpers.it("(tooltip-watcher-reuse) " .. spec.label
			.. " rejects an old CG callback delivered during a new watcher epoch", function()
			local context = load_tooltip(spec)
			local synthetic = require("adapters.synthetic_input")
			helpers.assert_eq(spec.render(context.tooltip), true)
			local old_key_callback = context.created[spec.watcher_count].fn
			if spec.label == "LLM" then
				helpers.assert_eq(context.tooltip.hide(), true)
			else
				helpers.assert_eq(context.tooltip.hide_forced(), true)
			end
			helpers.assert_eq(spec.render(context.tooltip), true)
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0)

			local consumed = old_key_callback(hardware_key_event(48, {}, "\t"))
			helpers.assert_eq(consumed, false,
				"a callback owned by A must pass input after B mounts new taps")
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
				"an old CG callback must not enqueue work under B's live generation")
			helpers.assert_true(context.tooltip.is_visible(),
				"old callback delivery must leave B visible")
		end)
	end
end)

helpers.describe("tooltip watcher reuse preserves dequeue ownership", function()
	helpers.it("(tooltip-watcher-reuse) owns and revokes a zero-delay dequeue timer", function()
		local context = load_tooltip(CASES[2])
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

	helpers.it("(tooltip-watcher-reuse) retains an ambiguously armed dequeue timer until its callback arrives", function()
		local context = load_tooltip(CASES[2])
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

	helpers.it("(tooltip-watcher-reuse) guarded hotstring hide leaves an active dequeue set intact", function()
		local spec = CASES[2]
		local context = load_tooltip(spec)
		context.tooltip.show_stacked({
			{ text = "short", duration = 1 },
			{ text = "long", duration = 2 },
		}, true)

		helpers.assert_eq(#context.created, spec.watcher_count,
			"the initial dequeue render must mount one complete dismissal set")
		context.tooltip.hide()
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

	helpers.it("(tooltip-watcher-reuse) dequeue timer stop failure blocks replacement atomically", function()
		local context = load_tooltip(CASES[2])
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

	helpers.it("(tooltip-watcher-reuse) stale dequeue callback cannot mutate a replacement stack", function()
		local context = load_tooltip(CASES[2])
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

	helpers.it("(tooltip-watcher-reuse) dequeue rebuild requires a committed stacked repaint", function()
		local context = load_tooltip(CASES[2])
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

helpers.describe("tooltip facade propagates watcher ownership", function()
	helpers.it("(tooltip-watcher-reuse) facade reports low-level mount failures and suppresses show callbacks", function()
		local saved_llm = package.loaded["ui.tooltip.tooltip_llm"]
		local saved_hotstring = package.loaded["ui.tooltip.tooltip_hotstring"]
		local saved_facade = package.loaded["ui.tooltip.init"]
		local results = { hotstring = false, stacked = false, loading = false, llm = false }
		local cleanup = { llm = true, hotstring = true, llm_calls = 0, hotstring_calls = 0 }

		package.loaded["ui.tooltip.tooltip_llm"] = {
			hide = function()
				cleanup.llm_calls = cleanup.llm_calls + 1
				return cleanup.llm
			end,
			hide_silent = function()
				cleanup.llm_calls = cleanup.llm_calls + 1
				return cleanup.llm
			end,
			show_predictions = function() return results.llm end,
		}
		package.loaded["ui.tooltip.tooltip_hotstring"] = {
			dismiss_silent = function() return true end,
			hide = function()
				cleanup.hotstring_calls = cleanup.hotstring_calls + 1
				return cleanup.hotstring
			end,
			hide_forced = function()
				cleanup.hotstring_calls = cleanup.hotstring_calls + 1
				return cleanup.hotstring
			end,
			show = function() return results.hotstring end,
			show_stacked = function() return results.stacked end,
			show_loading = function() return results.loading end,
		}
		package.loaded["ui.tooltip.init"] = nil
		local facade = require("ui.tooltip.init")
		local show_calls = 0
		facade.set_on_show_callback(function() show_calls = show_calls + 1 end)

		helpers.assert_eq(facade.show("preview", false, true), false,
			"the facade must propagate a hotstring watcher failure")
		helpers.assert_eq(facade.show_stacked({ { text = "preview" } }, true), false,
			"the facade must propagate a stacked watcher failure")
		helpers.assert_eq(facade.show_loading("loading", true), false,
			"the facade must propagate a loading paint failure")
		helpers.assert_eq(facade.show_predictions({ "prediction" }, 1, true), false,
			"the facade must propagate an LLM watcher failure")
		helpers.assert_eq(show_calls, 0,
			"failed low-level renders must not emit a successful show notification")

		results.hotstring = true
		results.stacked = true
		results.loading = true
		results.llm = true
		helpers.assert_eq(facade.show("preview", false, true), true,
			"the facade must preserve hotstring render success")
		helpers.assert_eq(facade.show_stacked({ { text = "preview" } }, true), true,
			"the facade must preserve stacked render success")
		helpers.assert_eq(facade.show_loading("loading", true), true,
			"the facade must preserve loading paint success")
		helpers.assert_eq(facade.show_predictions({ "prediction" }, 1, true), true,
			"the facade must preserve LLM render success")
		helpers.assert_eq(show_calls, 4,
			"only successful low-level renders may emit show notifications")

		helpers.assert_eq(facade.hide(), true,
			"facade hide must report verified cleanup from both owners")
		cleanup.llm = false
		local llm_calls_before = cleanup.llm_calls
		local hotstring_calls_before = cleanup.hotstring_calls
		helpers.assert_eq(facade.hide_forced(), false,
			"facade cleanup must propagate either owner's revocation failure")
		helpers.assert_eq(cleanup.llm_calls, llm_calls_before + 1)
		helpers.assert_eq(cleanup.hotstring_calls, hotstring_calls_before + 1,
			"cleanup must still reach hotstring ownership after an LLM failure")
		helpers.assert_eq(facade.hide_forced_silent(), false,
			"the hot-path cleanup variant must preserve the same ownership contract")

		package.loaded["ui.tooltip.tooltip_llm"] = saved_llm
		package.loaded["ui.tooltip.tooltip_hotstring"] = saved_hotstring
		package.loaded["ui.tooltip.init"] = saved_facade
	end)
end)

helpers.describe("tooltip facade serializes cross-owner transitions", function()
	helpers.it("(tooltip-watcher-reuse) failed LLM successor hides prior shared-canvas pixels", function()
		local context = load_tooltip(CASES[2])
		package.loaded["ui.tooltip.tooltip_llm"] = nil
		require("ui.tooltip.tooltip_llm")
		package.loaded["ui.tooltip.init"] = nil
		local facade = require("ui.tooltip.init")

		helpers.assert_eq(facade.show("old hotstring", false, true), true)
		helpers.assert_true(context.renderer.visible,
			"positive control: old hotstring pixels must be on the shared canvas")
		helpers.assert_eq(facade.show_predictions({ "disabled" }, 1, false), false)
		helpers.assert_true(not context.renderer.visible,
			"a disabled or failed LLM successor must hide the old shared canvas")
	end)

	helpers.it("(tooltip-watcher-reuse) hotstring orphan blocks LLM mount until verified cleanup", function()
		local context = load_tooltip(CASES[2])
		package.loaded["ui.tooltip.tooltip_llm"] = nil
		local llm = require("ui.tooltip.tooltip_llm")
		package.loaded["ui.tooltip.init"] = nil
		local facade = require("ui.tooltip.init")

		helpers.assert_eq(facade.show("hot", false, true), true)
		local orphan = context.created[CASES[2].watcher_count]
		orphan.stop = function(self)
			self.stopped = self.stopped + 1
			error("simulated hotstring transition stop failure")
		end
		helpers.assert_eq(facade.show_predictions({ "llm" }, 1, true), false,
			"LLM mount must abort while hotstring watcher cleanup is unverified")
		helpers.assert_eq(#context.created, CASES[2].watcher_count,
			"failed hotstring cleanup must prevent every LLM eventtap creation")
		helpers.assert_true(not context.renderer.visible,
			"an aborted LLM transition must not leave stale hotstring pixels")
		helpers.assert_eq(orphan.fn({}), false,
			"the retained hotstring key tap must be passive while transition is blocked")
		helpers.assert_true(not llm.is_visible(),
			"the LLM must not claim visibility after a blocked transition")

		orphan.stop = function(self) self.enabled = false; return self end
		helpers.assert_eq(facade.show_predictions({ "llm" }, 1, true), true,
			"LLM mount must recover after hotstring cleanup succeeds")
		helpers.assert_eq(#context.created,
			CASES[2].watcher_count + CASES[1].watcher_count,
			"recovery must create exactly one LLM watcher set")
	end)

	helpers.it("(tooltip-watcher-reuse) LLM orphan blocks hotstring mount until verified cleanup", function()
		local context = load_tooltip(CASES[1])
		package.loaded["ui.tooltip.tooltip_hotstring"] = nil
		local hotstring = require("ui.tooltip.tooltip_hotstring")
		package.loaded["ui.tooltip.init"] = nil
		local facade = require("ui.tooltip.init")

		helpers.assert_eq(facade.show_predictions({ "llm" }, 1, true), true)
		local orphan = context.created[CASES[1].watcher_count]
		orphan.stop = function(self)
			self.stopped = self.stopped + 1
			error("simulated LLM transition stop failure")
		end
		helpers.assert_eq(facade.show("hot", false, true), false,
			"hotstring mount must abort while LLM watcher cleanup is unverified")
		helpers.assert_eq(#context.created, CASES[1].watcher_count,
			"failed LLM cleanup must prevent every hotstring eventtap creation")
		helpers.assert_eq(orphan.fn({}), false,
			"the retained LLM key tap must pass input while transition is blocked")
		helpers.assert_true(not hotstring.is_visible(),
			"the hotstring tooltip must not claim visibility after a blocked transition")

		orphan.stop = function(self) self.enabled = false; return self end
		helpers.assert_eq(facade.show("hot", false, true), true,
			"hotstring mount must recover after LLM cleanup succeeds")
		helpers.assert_eq(#context.created,
			CASES[1].watcher_count + CASES[2].watcher_count,
			"recovery must create exactly one hotstring watcher set")
	end)
end)
