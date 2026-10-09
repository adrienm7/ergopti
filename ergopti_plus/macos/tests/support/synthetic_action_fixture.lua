--- tests/support/synthetic_action_fixture.lua

--- ==============================================================================
--- MODULE: Synthetic Action Test Fixture
--- DESCRIPTION:
--- Drives one action module through the production SyntheticInput deferred
--- broker and exposes the callback-returned Quartz events. The fixture observes
--- the real immutable provenance tags; mocking emit_key_stroke would stay green
--- if tagging, FIFO handoff, or the declared action effect regressed.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}


--- Loads a module against a fresh Hammerspoon stub and records broker triggers.
--- @param module_name string Module to load.
--- @return table fixture
function M.load(module_name)
	-- This fixture needs fresh production adapters for each scenario. Keep this
	-- eviction local: the generic load helper must preserve package.loaded stubs
	-- that a test intentionally installs before loading its subject.
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil
	package.loaded["tests.stubs.hs"] = nil
	local eventtap = require("tests.stubs.hs").eventtap
	local base_new_mouse = eventtap.event.newMouseEvent
	local posted_trigger = nil
	eventtap.event.newMouseEvent = function(event_type, position, modifiers)
		local event = base_new_mouse(event_type, position, modifiers)
		event.post = function(self)
			posted_trigger = self
			return self
		end
		return event
	end

	local subject = helpers.load_with_stubs(module_name, { eventtap = eventtap })
	local hs_table = _G.hs
	local synthetic = require("adapters.synthetic_input")
	local provenance = require("adapters.event_provenance")

	return {
		subject = subject,
		hs = hs_table,
		synthetic = synthetic,
		provenance = provenance,
		drain = function(consumer_id)
			local broker = hs_table.timer.__timers[#hs_table.timer.__timers]
			assert(broker and broker.running,
				"synthetic action did not schedule a deferred broker")
			broker:fire()
			assert(posted_trigger ~= nil,
				"synthetic action broker did not post its tagged trigger")

			local pump = nil
			for _, tap in ipairs(hs_table.eventtap.__taps) do
				if tap.types and tap.types[1] == hs_table.eventtap.event.types.otherMouseUp then
					pump = tap
					break
				end
			end
			assert(pump ~= nil, "synthetic action pump was not created")
			local consume, events = pump.fn(posted_trigger)
			assert(consume == true and type(events) == "table" and #events == 2,
				"synthetic action pump did not return one key pair")
			local down = provenance.classify(events[1], consumer_id or "test.action")
			local up = provenance.classify(events[2], consumer_id or "test.action")
			assert(down and up, "synthetic action pair has no exact provenance")
			hs_table.timer.__fire_all()
			return events, down, up
		end,
	}
end


return M
