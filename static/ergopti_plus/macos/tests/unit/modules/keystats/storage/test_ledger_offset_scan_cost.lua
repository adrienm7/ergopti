--- tests/unit/modules/keystats/storage/test_ledger_offset_scan_cost.lua

--- ==============================================================================
--- MODULE: Regression — the legacy ledger offset scan stays cheap
--- DESCRIPTION:
--- The 2026-10-30 field report held the main thread 17 s in one keystats ingest
--- tick: the unjournaled-ledger admission read the whole local data.sql (heap
--- 52 -> 342 MB) and found its last complete COMMIT with a byte-by-byte Lua
--- loop. The scan now jumps between the bytes that change its lexical state.
--- These cases pin the old boundary semantics against a copy of the byte loop
--- and bound the scan cost per byte.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.i18n"] = { get = function(k) return k end, t = function(k) return k end }
local Export = helpers.load_with_stubs("modules.keystats.export")

--- The byte-by-byte scan the shipped code used, kept as the semantic oracle.
local function reference_offset(chunk)
	local last_commit, i, n = 0, 1, #chunk
	local in_string, in_comment = false, false
	while i <= n do
		local ch = chunk:sub(i, i)
		if in_comment then
			if ch == "\n" then in_comment = false end
		elseif in_string then
			if ch == "'" then
				if chunk:sub(i + 1, i + 1) == "'" then i = i + 1 else in_string = false end
			end
		elseif ch == "-" and chunk:sub(i + 1, i + 1) == "-" then
			in_comment = true
			i = i + 1
		elseif ch == "'" then
			in_string = true
		elseif ch == "\n" and chunk:sub(i + 1, i + 8) == "COMMIT;\n" then
			last_commit = i + 8
			i = i + 8
		end
		i = i + 1
	end
	return last_commit
end

local TOKENS = {
	"\n", "COMMIT;\n", "\nCOMMIT;\n", "'", "''", "-", "--", "-- note\n", "BEGIN TRANSACTION;",
	"INSERT INTO events VALUES (1, 'a');", "x", " ", "\nCOMMIT;", "COMMIT", "/*", "*/",
}

--- Key events of one typing row, shaped like the producer's events_json.
local EVENTS_JSON = (function()
	local events = {}
	for k = 1, 24 do
		events[k] = string.format('{"c":"%s","t":%d,"h":%d,"kc":%d}', string.char(96 + k), 1000 + k * 87, 60 + k, k)
	end
	return "[" .. table.concat(events, ",") .. "]"
end)()

--- One producer batch: a typing row with quoted text, escapes, a typed COMMIT
--- line and its events_json payload, after an ingest comment.
local function batch(id)
	return string.format("\n-- ingest offset %d\nBEGIN TRANSACTION;\nINSERT OR IGNORE INTO events_typing VALUES "
		.. "('mac', %d, '2026-10-30T10:10:43', '2026-10-30', 'TextEdit', 'dev''s notes', NULL, 'AXTextArea', "
		.. "'ergopti', NULL, 0, 0, 3, 1, 240, 512, 80, 40, 72, 'typed -- not a comment\nCOMMIT;\nstill text', "
		.. "NULL, '%s');\nCOMMIT;\n", id, id, EVENTS_JSON)
end

helpers.describe("keystats: legacy ledger offset scan cost", function()
	helpers.it("matches the byte-by-byte scan on random lexical soups", function()
		math.randomseed(20261030)
		for case = 1, 3000 do
			local parts = {}
			for p = 1, math.random(0, 24) do parts[p] = TOKENS[math.random(#TOKENS)] end
			local chunk = table.concat(parts)
			local expected = reference_offset(chunk)
			local got = Export._last_complete_batch_offset(chunk)
			if got ~= expected then
				error(string.format("case %d: offset %d, expected %d for %q", case, got, expected, chunk), 0)
			end
		end
	end)

	helpers.it("matches the byte-by-byte scan on producer batches with a torn tail", function()
		local parts = {}
		for id = 1, 200 do parts[#parts + 1] = batch(id) end
		local whole = table.concat(parts)
		helpers.assert_eq(Export._last_complete_batch_offset(whole), #whole)
		for cut = #whole - 400, #whole do
			local torn = whole:sub(1, cut)
			helpers.assert_eq(Export._last_complete_batch_offset(torn), reference_offset(torn),
				"torn ledger cut at byte " .. cut)
		end
	end)

	helpers.it("scans a large ledger far faster than one Lua step per byte", function()
		local parts = {}
		for id = 1, 8000 do parts[#parts + 1] = batch(id) end
		local ledger = table.concat(parts)
		local cpu = os.clock()
		local fast = Export._last_complete_batch_offset(ledger)
		local fast_ms = (os.clock() - cpu) * 1000
		cpu = os.clock()
		local slow = reference_offset(ledger)
		local slow_ms = (os.clock() - cpu) * 1000
		helpers.assert_eq(fast, slow)
		helpers.assert_eq(fast, #ledger)
		-- Relative budget: both scans run on this machine, so the ratio holds on
		-- a loaded CI runner where an absolute millisecond ceiling would not.
		helpers.assert_true(fast_ms * 4 < slow_ms, string.format(
			"the native-find scan must stay well under the byte loop (%.1f ms vs %.1f ms for %d bytes)",
			fast_ms, slow_ms, #ledger))
	end)
end)
