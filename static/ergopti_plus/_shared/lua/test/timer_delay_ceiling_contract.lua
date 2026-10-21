--- _shared/lua/test/timer_delay_ceiling_contract.lua

--- ==============================================================================
--- MODULE: Timer Delay Ceiling Contract
--- DESCRIPTION:
--- Replays the shared delay-ceiling corpus against the finite-number policy and
--- every native timer or sleep boundary a driver declares. A refused delay must
--- never reach the native backend and must leave an explicit error behind.
--- ==============================================================================

local NumberPolicy = require("number_policy")
local M = {}

local CORPUS = "tests/corpus/timer/delay_ceiling_vectors.json"
local SPECIAL = { inf = math.huge, ["-inf"] = -math.huge }

--- Decodes the values JSON cannot spell.
--- @param value number|string Corpus value.
--- @return number
local function decode(value)
	if value == "nan" then return 0 / 0 end
	if type(value) == "string" then return assert(SPECIAL[value], "unknown corpus value " .. value) end
	return value
end

--- Reads the corpus once through the driver's own shared-root resolver.
--- @param shared_path function Driver resolver for a path under _shared/.
--- @return table corpus
local function load_corpus(shared_path)
	local file = assert(io.open(shared_path(CORPUS), "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	local corpus = assert(require("json").decode(text))
	assert(#corpus.millisecond_vectors >= 8 and #corpus.second_vectors >= 6, "delay ceiling corpus lost its vectors")
	return corpus
end

--- Registers the policy vectors and the driver's declared boundaries.
--- Each boundary is { name, unit = "milliseconds"|"seconds", replay, lower }:
--- replay(value) returns reached (the native backend received the delay) and
--- explained (a refusal was logged, raised or returned); lower(value) is the
--- boundary's own lower bound, true when omitted. Only a ceiling refusal must
--- be explained: a lower bound may clamp or skip silently by its own contract.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
--- @param boundaries table Array of boundary declarations.
function M.register(helpers, shared_path, boundaries)
	local corpus = load_corpus(shared_path)
	helpers.describe("timer-delay-ceiling: shared policy", function()
		helpers.it("timer-delay-ceiling: one named ceiling of 2^53 ms", function()
			helpers.assert_eq(NumberPolicy.MAX_TIMER_DELAY_MS, 2 ^ 53)
		end)
		for _, vector in ipairs(corpus.millisecond_vectors) do
			local row = vector
			helpers.it("timer-delay-ceiling: policy " .. row.id, function()
				helpers.assert_eq(NumberPolicy.within_timer_ceiling(decode(row.milliseconds)), row.admitted)
			end)
		end
		for _, vector in ipairs(corpus.second_vectors) do
			local row = vector
			helpers.it("timer-delay-ceiling: seconds conversion " .. row.id, function()
				local milliseconds = NumberPolicy.timer_delay_ms(decode(row.seconds))
				helpers.assert_eq(milliseconds ~= nil, row.admitted)
				if milliseconds ~= nil then helpers.assert_true(milliseconds >= 0) end
			end)
		end
	end)
	assert(type(boundaries) == "table" and #boundaries > 0, "a driver must declare its timer boundaries")
	helpers.describe("timer-delay-ceiling: native boundaries", function()
		for _, declared in ipairs(boundaries) do
			local boundary = declared
			local vectors = boundary.unit == "seconds" and corpus.second_vectors or corpus.millisecond_vectors
			assert(boundary.unit == "seconds" or boundary.unit == "milliseconds", boundary.name .. " needs a unit")
			for _, vector in ipairs(vectors) do
				local row = vector
				helpers.it("timer-delay-ceiling: " .. boundary.name .. " " .. row.id, function()
					local value = decode(row[boundary.unit])
					local expected = row.admitted and (boundary.lower == nil or boundary.lower(value))
					local reached, explained = boundary.replay(value)
					helpers.assert_eq(reached == true, expected,
						boundary.name .. (expected and " must arm an admitted delay" or " must refuse before the native backend"))
					if not row.admitted then
						helpers.assert_true(explained == true, boundary.name .. " must refuse with an explicit error")
					end
				end)
			end
		end
	end)
end

return M
