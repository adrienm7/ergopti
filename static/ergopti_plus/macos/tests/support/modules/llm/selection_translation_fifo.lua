--- tests/support/modules/llm/selection_translation_fifo.lua

--- ==============================================================================
--- MODULE: Selection Translation Quartz FIFO Fixture
--- DESCRIPTION:
--- Composes the real translation, destination tracker, Text and SyntheticInput
--- modules. Only native Quartz delivery is delayed; returned key payloads update
--- the modeled document at the exact window focused at that handoff.
--- ==============================================================================

local Fixture = require("tests.support.modules.llm.selection_translation_fixture")
local Quartz = require("tests.support.synthetic_input_fixture")
local M = {}

--- Builds a real FIFO pipeline with separately controlled timers and delivery.
--- @return table world
function M.build(configure, options)
	local world = Fixture.build_world("Hello", "fr", options)
	local classification_timers = hs.timer.__timers
	local quartz = Quartz.make({ deliver_trigger = false })
	for key, value in pairs(quartz.hs_overrides) do
		if key == "application" then
			for name, method in pairs(value) do hs.application[name] = method end
		else
			hs[key] = value
		end
	end
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.storage"] = nil
	if configure then configure(world, quartz) end
	world.synthetic = require("adapters.synthetic_input")
	world.quartz = quartz
	world.native_destination.utils.prewarm_ignored_win_watchers({}, {})
	assert(world.native_destination.utils.capture_text_destination(), "native tracker must retain its classified receipt")
	local delivered = 0
	local direct_pending = nil

	local function apply_key(event)
		if not event.isDown then return end
		local modifiers = table.concat(event.modifiers or {}, "+")
		if modifiers == "cmd" and event.key == "c" then
			if world.selection ~= "" then hs.pasteboard.setContents(world.selection) end
		elseif modifiers == "cmd" and event.key == "v" then
			world.pasted = world.clipboard
			world.document[#world.document + 1] = world.clipboard
			world.paste_focus = world.focus
			world.selection = ""
		elseif modifiers == "shift" and event.key == "right" then
			world.selection = world.pasted
		end
	end
	-- Guarded clipboard pairs post outside the HID collector. Observe their
	-- actual native event.post calls rather than fabricating a CG trigger.
	local prior_observer = quartz.key_observer
	quartz.key_observer = function(event, app)
		if prior_observer then prior_observer(event, app) end
		apply_key(event)
	end
	local function direct_timer()
		for _, timer in ipairs(quartz.timers) do
			if not timer.stopped and timer.delay == world.synthetic.PERIODIC_OWNER_TICK_SEC then return timer end
		end
	end
	function world.deliver()
		if direct_pending then
			local timer = direct_pending
			direct_pending = nil
			if timer.stopped then return end
			for index, retained in ipairs(quartz.timers) do
				if retained == timer then table.remove(quartz.timers, index); break end
			end
			world.elapse(timer.delay)
			timer.callback()
			if timer.recurring and not timer.stopped then quartz.timers[#quartz.timers + 1] = timer end
			return
		end
		delivered = delivered + 1
		local trigger = assert(quartz.triggers[delivered], "expected a posted native broker trigger")
		local reads = world.native_destination.reads
		quartz.deliver_posted_trigger(trigger)
		assert(world.native_destination.reads == reads, "broker delivery must never probe AX")
		local delivery = quartz.pump_deliveries[#quartz.pump_deliveries]
		for _, event in ipairs(delivery.events or {}) do apply_key(event) end
	end
	function world.elapse(delay)
		quartz.options.absolute_time = quartz.timer.absoluteTime() + math.ceil(delay * 1e9)
		quartz.options.epoch = quartz.timer.secondsSinceEpoch() + delay
	end
	function world.fire(delay)
		world.elapse(delay)
		quartz.fire_timer_matching(delay)
	end
	function world.tick_classification()
		for _, timer in ipairs(classification_timers) do
			if timer.running and timer.fired == 0 and timer.delay == 5 then timer:fire(); return end
		end
		error("the real destination TTL timer was not retained")
	end
	function world.complete_handoff()
		for _ = 1, 20 do
			local delay
			for _, timer in ipairs(quartz.timers) do
				if not timer.stopped and timer.delay == 0 then delay = 0; break end
			end
			if delay == nil and direct_timer() then delay = world.synthetic.PERIODIC_OWNER_TICK_SEC end
			if delay == nil then return end
			world.fire(delay)
		end
		error("native handoff completion did not settle")
	end
	function world.advance(delay)
		for _, timer in ipairs(quartz.timers) do
			if not timer.stopped and math.abs(timer.delay - delay) < 0.000001 then
				world.fire(delay)
				return
			end
		end
		world.elapse(delay)
	end
	function world.post_next()
		local previous = #quartz.triggers
		for _ = 1, 20 do
			local timer = direct_timer()
			if timer then direct_pending = timer; return end
			world.fire(0)
			if #quartz.triggers > previous then return end
		end
		error("the queued payload never posted its broker trigger")
	end
	function world.flush()
		for _ = 1, 100 do
			if direct_pending or delivered < #quartz.triggers then
				world.deliver()
			else
				local next_delay
				for _, timer in ipairs(quartz.timers) do
					if not timer.stopped and timer.delay < 1.5
						and (next_delay == nil or timer.delay < next_delay) then next_delay = timer.delay end
				end
				if next_delay == nil then return end
				world.fire(next_delay)
			end
		end
		error("the real translation FIFO did not settle")
	end
	return world
end

--- Runs a complete native FIFO scenario with exact module and hs restoration.
--- @param scenario function Receives the native FIFO world.
function M.with_world(scenario, configure, options)
	return require("tests.support.modules.llm.selection_translation_scope").run(function()
		return scenario(M.build(configure, options))
	end)
end

return M
