--- tests/unit/modules/keystats/aggregation/test_aggregate_walker_correction_erased.lua

--- ==============================================================================
--- MODULE: Aggregate Walker — erased and synthetic n-gram corpus (Linux)
--- DESCRIPTION:
--- Replays the shared erased/synthetic n-gram vectors through the Linux walker,
--- one carried context per vector. The AHK replayer is written on the PC.
--- ==============================================================================

package.loaded["tests.support.modules.keystats.aggregation.aggregate_walker_fixture"] = nil
local Fixture = require("tests.support.modules.keystats.aggregation.aggregate_walker_fixture")

local file = assert(io.open(assert(require("infra.paths").shared(
	"tests/corpus/keystats/correction_erased_vectors.json")), "rb"))
local data = require("json").decode(assert(file:read("*a")))
assert(file:close())

require("test.keystats_correction_erased_contract")(Fixture.helpers, data, function(vec)
	local batch, ctx = nil, {}
	for _, flush in ipairs(vec.flushes) do
		local events = {}
		for _, ev in ipairs(flush) do
			events[#events + 1] = { ev.char, ev.delay, ev.meta or { s = 0 } }
		end
		batch = Fixture.Walker.walk(events, data.date, data.app, batch, Fixture.qwerty_clock(nil), ctx)
	end
	return batch.ngram
end, 6)
