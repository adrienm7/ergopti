--- tests/meta/corpus/test_corpus_keystats_correction_erased.lua

--- ==============================================================================
--- MODULE: Keystats Erased and Synthetic N-gram Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/keystats/correction_erased_vectors.json through
--- the macOS aggregator (walk_typing): erased n-grams and the source of
--- synthetic corrections. The AHK replayer is written on the PC.
--- ==============================================================================

local helpers = require("tests.helpers")

local fh = assert(io.open(helpers.shared("tests/corpus/keystats/correction_erased_vectors.json"), "r"))
local data = require("hs").json.decode(fh:read("*a"))
fh:close()

--- Loads a fresh aggregator with the stubs the aggregation corpus uses.
--- @return table agg
local function fresh_aggregator()
	for _, name in ipairs({ "modules.keystats.aggregator", "modules.keystats.aggregator.core",
		"modules.keystats.aggregator.events", "modules.keystats.aggregator.sql",
		"modules.keystats.aggregator.state" }) do
		package.loaded[name] = nil
	end
	package.loaded["modules.keystats.sqlite_writer"] = { get_db = function() return nil end, init = function() end }
	package.loaded["modules.keystats.export"] = { get_native_app_category = function() return "Development" end, init = function() end }
	package.loaded["infra.timings"] = {
		ms = function(_section, key)
			if key == "think_pause_ms" then return 2000 end
			if key == "max_keystroke_delay_ms" then return 5000 end
			if key == "burst_gap_ms" then return 1000 end
			if key == "session_gap_ms" then return 300000 end
			if key == "auto_repeat_max_delay_ms" then return 50 end
			if key == "hold_threshold_ms" then return 200 end
			return 1000
		end,
		sec = function() return 1.0 end,
	}
	local agg = helpers.load_with_stubs("modules.keystats.aggregator")
	local S = require("modules.keystats.aggregator.state")
	S.initialized, S.agg_batch, S.ngram_ctx, S.device_id = false, nil, nil, nil
	agg.init({ device_id = "corpus-test-uuid" })
	return agg
end

require("test.keystats_correction_erased_contract")(helpers, data, function(vec)
	local agg = fresh_aggregator()
	for index, flush in ipairs(vec.flushes) do
		local events = {}
		for _, ev in ipairs(flush) do events[#events + 1] = { ev.char, ev.delay, ev.meta or {} } end
		agg.walk_typing({ app = data.app, timestamp = data.timestamps[index], events = events })
	end
	local ngram = require("modules.keystats.aggregator.state").agg_batch.ngram
	return ngram
end, 6)
