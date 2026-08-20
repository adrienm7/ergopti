--- tests/unit/modules/keymap/test_synthetic_arm_guard.lua

--- ==============================================================================
--- MODULE: Synthetic Transaction Boundary Regression Tests
--- DESCRIPTION:
--- Verifies the real SyntheticInput producer contract: every key phase carries
--- immutable transaction metadata, consecutive producers remain distinct even
--- with identical payloads, cancelled records still decode fail-closed, and
--- malformed producer declarations fail fast before output exists.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads a fresh production adapter and its Quartz property contract.
--- @return table synthetic
--- @return table hs_stub
local function load_adapter()
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil
	local synthetic = helpers.load_with_stubs("adapters.synthetic_input")
	return synthetic, require("hs")
end


--- Builds one callback-return replacement.
--- @param synthetic table
--- @param owner string
--- @param text string
--- @return table events
local function build_replacement(synthetic, owner, text)
	local tx = synthetic.begin(owner, "replacement")
	local batch = synthetic.begin_callback(tx)
	helpers.assert_true(synthetic.keyStrokes(batch, text))
	local consume, events = synthetic.finish_callback(batch, true)
	helpers.assert_true(consume)
	helpers.assert_true(synthetic.seal(tx))
	return events
end


helpers.describe("SyntheticInput producer boundaries", function()
	helpers.it("attaches one immutable generation and ordered phases to a batch", function()
		local synthetic, hs_stub = load_adapter()
		local events = build_replacement(synthetic, "test.atomic", "AB")
		helpers.assert_eq(#events, 4)
		local property = hs_stub.eventtap.event.properties.eventSourceUserData
		local records = {}
		for index, event in ipairs(events) do
			records[index] = synthetic.lookup_tag(event:getProperty(property))
			helpers.assert_true(records[index] and records[index].owned)
			helpers.assert_eq(records[index].owner, "test.atomic")
			helpers.assert_eq(records[index].effect, "replacement")
		end
		helpers.assert_eq(records[1].generation, records[4].generation)
		helpers.assert_eq(records[1].ordinal, 1)
		helpers.assert_eq(records[1].phase, "down")
		helpers.assert_eq(records[2].phase, "up")
		helpers.assert_eq(records[3].ordinal, 2)
	end)

	helpers.it("keeps immediate identical producers in distinct generations", function()
		local synthetic, hs_stub = load_adapter()
		local first = build_replacement(synthetic, "test.first", "A")
		local second = build_replacement(synthetic, "test.second", "A")
		local property = hs_stub.eventtap.event.properties.eventSourceUserData
		local first_record = synthetic.lookup_tag(first[1]:getProperty(property))
		local second_record = synthetic.lookup_tag(second[1]:getProperty(property))
		helpers.assert_true(first_record.generation ~= second_record.generation)
		helpers.assert_true(first_record.tag ~= second_record.tag)
		helpers.assert_eq(first_record.owner, "test.first")
		helpers.assert_eq(second_record.owner, "test.second")
	end)

	helpers.it("keeps a cancelled tag fail-closed after enrichment is discarded", function()
		local synthetic, hs_stub = load_adapter()
		local tx = synthetic.begin("test.cancel", "replacement")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "x")
		local property = hs_stub.eventtap.event.properties.eventSourceUserData
		local tag = batch.events[1]:getProperty(property)
		helpers.assert_true(synthetic.lookup_tag(tag).enriched)
		helpers.assert_true(synthetic.cancel(tx))
		local stale = synthetic.lookup_tag(tag)
		helpers.assert_true(stale and stale.owned,
			"an Ergopti namespace tag must never become physical after rollback")
		helpers.assert_true(stale.stale)
		helpers.assert_eq(stale.enriched, false)
	end)

	helpers.it("fails fast for malformed producer declarations", function()
		local synthetic = load_adapter()
		helpers.assert_throws(function() synthetic.begin("", "replacement") end)
		helpers.assert_throws(function() synthetic.begin("test.invalid", "unknown") end)
		helpers.assert_eq(synthetic.stats().active_transactions, 0,
			"invalid declarations must not leak a partial transaction")
	end)
end)
