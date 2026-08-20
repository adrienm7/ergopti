--- tests/unit/modules/keylogger/test_synth_queue_drain.lua

--- ==============================================================================
--- MODULE: Keylogger Synthetic Provenance Regression Tests
--- DESCRIPTION:
--- Exercises EventProvenance against tags allocated by the real SyntheticInput
--- adapter. Ownership is immutable user-data membership; process information is
--- diagnostic only, consumer dedupe is independent, and a failed native read
--- cannot consume another consumer's claim.
--- ==============================================================================

local helpers = require("tests.helpers")

local CURRENT_PID = 7001
local FOREIGN_PID = 8002


--- Loads fresh production provenance and transaction adapters.
--- @return table fixture
local function load_fixture()
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil
	local provenance = helpers.load_with_stubs("adapters.event_provenance", {
		processInfo = { processID = CURRENT_PID },
	})
	return {
		provenance = provenance,
		synthetic = require("adapters.synthetic_input"),
		hs = require("hs"),
	}
end


--- Allocates one real tagged keyDown/keyUp pair.
--- @param fixture table
--- @return table down_event
local function tagged_event(fixture)
	local tx = fixture.synthetic.begin("test.keylogger", "replacement")
	local batch = fixture.synthetic.begin_callback(tx)
	fixture.synthetic.keyStroke(batch, { "cmd" }, "v")
	local _, events = fixture.synthetic.finish_callback(batch, true)
	fixture.synthetic.seal(tx)
	return events[1]
end


--- Overrides only the optional PID diagnostic on an adapter event.
--- @param fixture table
--- @param event table
--- @param pid integer
local function set_diagnostic_pid(fixture, event, pid)
	local property = fixture.hs.eventtap.event.properties.eventSourceUnixProcessID
	local original = event.getProperty
	event.getProperty = function(self, requested)
		if requested == property then return pid end
		return original(self, requested)
	end
end


helpers.describe("event provenance: explicit tags are the only ownership authority", function()
	helpers.it("classifies a real adapter tag and deduplicates per consumer", function()
		local fixture = load_fixture()
		local event = tagged_event(fixture)
		local keylogger, status = fixture.provenance.classify(event, "keylogger")
		helpers.assert_true(keylogger and keylogger.owned)
		helpers.assert_eq(keylogger.owner, "test.keylogger")
		helpers.assert_eq(status, fixture.provenance.STATUS_OWNED)
		helpers.assert_eq(keylogger.duplicate, false)

		local again = fixture.provenance.classify(event, "keylogger")
		helpers.assert_true(again.duplicate)
		local keymap = fixture.provenance.classify(event, "keymap")
		helpers.assert_eq(keymap.duplicate, false,
			"keymap and keylogger must own independent dedupe slots")
	end)

	helpers.it("keeps an untagged same-process event physical", function()
		local fixture = load_fixture()
		local properties = fixture.hs.eventtap.event.properties
		local pid_reads = 0
		local event = {
			getProperty = function(_self, property)
				if property == properties.eventSourceUserData then return 0 end
				pid_reads = pid_reads + 1
				return CURRENT_PID
			end,
		}
		local metadata, status = fixture.provenance.classify(event, "keylogger")
		helpers.assert_nil(metadata)
		helpers.assert_eq(status, fixture.provenance.STATUS_FOREIGN)
		helpers.assert_eq(pid_reads, 0,
			"missing tag membership must stop classification before diagnostics")
	end)

	helpers.it("keeps a tagged event owned when PID diagnostics disagree", function()
		local fixture = load_fixture()
		local event = tagged_event(fixture)
		set_diagnostic_pid(fixture, event, FOREIGN_PID)
		local metadata, status = fixture.provenance.classify(event, "keylogger")
		helpers.assert_true(metadata and metadata.owned)
		helpers.assert_eq(status, fixture.provenance.STATUS_OWNED)
		helpers.assert_eq(metadata.pid_matches, false)
	end)

	helpers.it("contains a native getter failure without consuming the live tag", function()
		local fixture = load_fixture()
		local event = tagged_event(fixture)
		local unreadable = { getProperty = function() error("Quartz read failed") end }
		local ok, metadata, status = pcall(
			fixture.provenance.classify, unreadable, "keylogger")
		helpers.assert_true(ok, "native property failures must stay inside the adapter")
		helpers.assert_nil(metadata)
		helpers.assert_eq(status, fixture.provenance.STATUS_UNREADABLE)
		local claimed = fixture.provenance.classify(event, "keylogger")
		helpers.assert_true(claimed and not claimed.duplicate,
			"the failed read must not consume any live tag claim")
	end)

	helpers.it("fails fast on invalid fenced-consumer IDs before touching Quartz", function()
		local fixture = load_fixture()
		local reads = 0
		local event = {
			getProperty = function()
				reads = reads + 1
				return 0
			end,
		}
		for _, invalid in ipairs({ false, 1, {}, "" }) do
			helpers.assert_throws(function()
				fixture.provenance.classify_with_fence(event, invalid)
			end)
		end
		helpers.assert_throws(function()
			fixture.provenance.classify_with_fence(event, nil)
		end)
		helpers.assert_eq(reads, 0,
			"programmer-contract failures must precede native reads and fence claims")
	end)

	helpers.it("fails fast when Quartz user-data tags are unavailable", function()
		package.loaded["tests.stubs.hs"] = nil
		local base = require("tests.stubs.hs")
		local eventtap = {}
		for key, value in pairs(base.eventtap) do eventtap[key] = value end
		eventtap.event = {}
		for key, value in pairs(base.eventtap.event) do eventtap.event[key] = value end
		eventtap.event.properties = {}
		for key, value in pairs(base.eventtap.event.properties) do
			if key ~= "eventSourceUserData" then
				eventtap.event.properties[key] = value
			end
		end
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.event_provenance"] = nil
		local ok, err = pcall(helpers.load_with_stubs,
			"adapters.event_provenance", { eventtap = eventtap })
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("eventSourceUserData", 1, true) ~= nil,
			"the fail-fast error must identify the missing immutable-tag contract")
	end)
end)
