--- _shared/lua/test/tap_hold_decision_contract.lua

--- ==============================================================================
--- MODULE: Tap-Hold Decision Corpus Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/tap_hold/decision_vectors.json through one
--- driver's real tap-hold engine and compares the keystrokes applications
--- receive with the corpus. The driver owns the replay (its engine, its key
--- codes, its action vocabulary); this contract owns the corpus checks, the
--- stroke spelling and the divergence ratchet, so the drivers cannot drift in
--- how they read one vector.
---
--- A vector may list a driver under `divergences`: that driver is held to
--- what it does instead, with the reason given, so the difference stays
--- visible in both suites and a fix on either side turns a test red until the
--- corpus is updated.
--- ==============================================================================

local M = {}

-- The drivers a divergence may name.
local DRIVERS = { windows = true, macos = true, linux = true }

-- The vector count, pinned so a truncated corpus fails instead of shrinking
-- the contract.
M.VECTOR_COUNT = 23




-- =====================================
-- =====================================
-- ======= 1/ Stroke spelling ==========
-- =====================================
-- =====================================

--- Spells one keystroke as the corpus does: the modifiers in the hold-picker
--- order, then the key, joined with "+".
--- @param stroke table { key = string, mods = { [modifier] = true } }.
--- @param order table The `[tap_hold.hold_picker]` modifiers, in order.
--- @return string
local function spell(stroke, order)
	local known, parts = {}, {}
	for _, modifier in ipairs(order) do
		known[modifier] = true
		if stroke.mods[modifier] then parts[#parts + 1] = modifier end
	end
	for modifier in pairs(stroke.mods) do
		assert(known[modifier], "stroke modifier '" .. tostring(modifier) .. "' is not a hold-picker modifier")
	end
	parts[#parts + 1] = stroke.key
	return table.concat(parts, "+")
end

--- Spells every keystroke of one replay.
--- @param strokes table Array of strokes.
--- @param order table Hold-picker modifier order.
--- @return table spelled
local function spell_all(strokes, order)
	local out = {}
	for index, stroke in ipairs(strokes) do out[index] = spell(stroke, order) end
	return out
end

--- Joins a list for a failure message.
--- @param list table|nil
--- @return string
local function joined(list)
	return "[" .. table.concat(list or {}, ", ") .. "]"
end




-- =====================================
-- =====================================
-- ======= 2/ Corpus checks ============
-- =====================================
-- =====================================

--- Validates the shape of one vector before any driver replays it.
--- @param helpers table Driver test helpers.
--- @param vector table One corpus vector.
local function check_shape(helpers, vector)
	helpers.assert_true(type(vector.id) == "string" and vector.id ~= "", "a vector has no id")
	helpers.assert_true(type(vector.bindings) == "table" and next(vector.bindings) ~= nil,
		vector.id .. ": no bindings")
	for key, binding in pairs(vector.bindings) do
		helpers.assert_true(type(binding.threshold_ms) == "number" and binding.threshold_ms > 0,
			vector.id .. ": binding '" .. key .. "' has no threshold")
		helpers.assert_true(type(binding.hold) == "string" and binding.hold ~= "",
			vector.id .. ": binding '" .. key .. "' has no hold")
	end
	helpers.assert_true(type(vector.events) == "table" and #vector.events > 0, vector.id .. ": no events")
	local last = -math.huge
	for index, event in ipairs(vector.events) do
		helpers.assert_true(event[1] == "down" or event[1] == "up",
			vector.id .. ": event " .. index .. " is neither down nor up")
		helpers.assert_true(type(event[2]) == "string", vector.id .. ": event " .. index .. " names no key")
		helpers.assert_true(type(event[3]) == "number" and event[3] >= last,
			vector.id .. ": event " .. index .. " goes back in time")
		last = event[3]
	end
	helpers.assert_true(type(vector.expected) == "table" and type(vector.expected.strokes) == "table",
		vector.id .. ": no expected strokes")
	for driver, divergence in pairs(vector.divergences or {}) do
		helpers.assert_true(DRIVERS[driver] == true, vector.id .. ": unknown driver '" .. tostring(driver) .. "'")
		helpers.assert_true(type(divergence.reason) == "string" and divergence.reason ~= "",
			vector.id .. ": the " .. driver .. " divergence gives no reason")
		helpers.assert_true(type(divergence.strokes) == "table",
			vector.id .. ": the " .. driver .. " divergence lists no strokes")
		local same = joined(divergence.strokes) == joined(vector.expected.strokes)
			and joined(divergence.hold_presses) == joined(vector.expected.hold_presses)
		helpers.assert_true(not same,
			vector.id .. ": the " .. driver .. " divergence is the expectation itself; remove it")
	end
end




-- =====================================
-- =====================================
-- ======= 3/ Replay ===================
-- =====================================
-- =====================================

--- Registers one test per vector for one driver.
--- @param helpers table Driver test helpers (describe, it, assert_eq, assert_true).
--- @param driver string "macos" or "linux": the key of its divergences.
--- @param corpus table The decoded decision corpus.
--- @param picker table The decoded `[tap_hold.hold_picker]` table.
--- @param replay function replay(vector) -> { strokes = { stroke }, hold_presses = { string } }.
function M.run(helpers, driver, corpus, picker, replay)
	assert(DRIVERS[driver], "unknown driver '" .. tostring(driver) .. "'")
	assert(type(replay) == "function", "a replay function is required")
	local order = assert(type(picker) == "table" and picker.modifiers, "the hold picker lists no modifiers")
	helpers.describe("tap-hold decision corpus (" .. driver .. ")", function()
		helpers.it("holds the pinned number of vectors", function()
			helpers.assert_eq(#corpus.vectors, M.VECTOR_COUNT,
				"decision_vectors.json changed size: update M.VECTOR_COUNT with the corpus")
		end)
		local seen = {}
		for _, vector in ipairs(corpus.vectors) do
			local divergence = vector.divergences and vector.divergences[driver] or nil
			local label = "(tap-hold-decision) " .. tostring(vector.id)
				.. (divergence and (" diverges: " .. divergence.reason) or "")
			helpers.it(label, function()
				helpers.assert_true(not seen[vector.id], tostring(vector.id) .. " is listed twice")
				seen[vector.id] = true
				check_shape(helpers, vector)
				local expected = divergence or vector.expected
				local got = replay(vector)
				local strokes = spell_all(got.strokes, order)
				helpers.assert_eq(strokes, expected.strokes,
					vector.id .. ": the keystrokes " .. joined(strokes) .. " are not " .. joined(expected.strokes))
				if expected.hold_presses ~= nil then
					helpers.assert_eq(got.hold_presses, expected.hold_presses,
						vector.id .. ": the hold put down " .. joined(got.hold_presses)
							.. ", not " .. joined(expected.hold_presses))
				end
			end)
		end
	end)
end

return M
