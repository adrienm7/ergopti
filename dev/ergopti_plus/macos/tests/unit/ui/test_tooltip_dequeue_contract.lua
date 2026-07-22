--- tests/unit/ui/test_tooltip_dequeue_contract.lua

--- ==============================================================================
--- MODULE: Tooltip Dequeue Contract Test (macOS)
--- DESCRIPTION:
--- Validates the Hammerspoon stacked-tooltip dequeue logic against the canonical
--- test vectors defined in _shared/tests/corpus/tooltip/dequeue_vectors.json.
--- Loads the shared JSON at require time so the vectors are always in sync
--- with the cross-driver corpus.
--- ==============================================================================

local helpers = require("tests.helpers")

local Dequeue = helpers.load_with_stubs("ui.tooltip.dequeue")

local DEC = 0.2
local FLOOR = 0.05
local MS_OPTS = {
	duration_field = "durationSec",
	expire_field = "expireMs",
	timeout_decrement_sec = DEC,
	timeout_floor_sec = FLOOR,
}

-- Load vectors from the shared JSON corpus — no more hardcoded VECTORS table.
local function load_corpus_vectors()
	local corpus_path = helpers.shared("tests/corpus/tooltip/dequeue_vectors.json")
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open dequeue corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result) end
	return result.vectors, nil
end

local VECTORS, corpus_err = load_corpus_vectors()
helpers.assert_true(VECTORS ~= nil, "dequeue corpus load: " .. tostring(corpus_err))
helpers.assert_true(#VECTORS >= 3, "dequeue corpus must have at least 3 vectors")

local function ids_of(rows)
	local out = {}
	for _, row in ipairs(rows) do
		table.insert(out, row.id)
	end
	return out
end

local function stamp_ms(rows, now_ms)
	local stamped = {}
	local max_remaining = 0
	for _, row in ipairs(rows) do
		local copy = {}
		for k, v in pairs(row) do copy[k] = v end
		local d = row.durationSec
		if type(d) == "number" and d > 0 then
			local eff = Dequeue.effective_duration_sec(d, MS_OPTS)
			copy.expireMs = now_ms + math.floor(eff * 1000 + 0.5)
			max_remaining = math.max(max_remaining, copy.expireMs - now_ms)
		else
			copy.expireMs = 0
		end
		table.insert(stamped, copy)
	end
	return stamped, max_remaining
end

local function prune_ms(rows, now_ms)
	local remaining = {}
	for _, row in ipairs(rows) do
		local exp = row.expireMs
		if not exp or exp == 0 or now_ms < exp then
			table.insert(remaining, row)
		end
	end
	return remaining
end

local function next_delay_ms(rows, now_ms)
	local earliest = nil
	for _, row in ipairs(rows) do
		local exp = row.expireMs
		if exp and exp > 0 and now_ms < exp then
			if not earliest or exp < earliest then earliest = exp end
		end
	end
	if not earliest then return 0 end
	return math.max(50, earliest - now_ms)
end

local function assert_same_ids(actual, expected, ctx)
	helpers.assert_eq(#actual, #expected, ctx .. " — row count")
	for i, id in ipairs(expected) do
		helpers.assert_eq(actual[i], id, ctx .. " — id[" .. i .. "]")
	end
end

-- Replay all corpus vectors.
for _, vec in ipairs(VECTORS) do
	local dequeue = Dequeue.should_use_dequeue_path(vec.rows, MS_OPTS)
	helpers.assert_eq(dequeue, vec.expectDequeue, vec.id .. " should_use_dequeue_path")

	if vec.steps then
		local stamped = nil
		for _, step in ipairs(vec.steps) do
			if step.action == "stamp" then
				stamped = select(1, stamp_ms(vec.rows, step.atMs))
				assert_same_ids(ids_of(stamped), step.expectIds, vec.id .. " stamp ids")
				for id, exp_ms in pairs(step.expectExpiries) do
					for _, row in ipairs(stamped) do
						if row.id == id then
							helpers.assert_eq(row.expireMs, exp_ms, vec.id .. " expiry " .. id)
						end
					end
				end
			elseif step.action == "prune" then
				local remaining = prune_ms(stamped, step.atMs)
				assert_same_ids(ids_of(remaining), step.expectIds, vec.id .. " prune @" .. step.atMs)
				if step.expectNextDelayMs then
					helpers.assert_eq(next_delay_ms(remaining, step.atMs), step.expectNextDelayMs,
						vec.id .. " next delay @" .. step.atMs)
				end
				stamped = remaining
			end
		end
	end
end

-- HS-specific expire_at path (seconds since epoch, not ms).
local hs_rows = {
	{ text = "a", duration = 1 },
	{ text = "b", duration = 2 },
}
helpers.assert_true(Dequeue.should_use_dequeue_path(hs_rows, {
	duration_field = "duration",
	expire_field = "expire_at",
	timeout_decrement_sec = DEC,
	timeout_floor_sec = FLOOR,
}), "HS field names activate dequeue")

local now = 1000.0
local stamped_hs = select(1, Dequeue.stamp_expiry_times(hs_rows, now, {
	duration_field = "duration",
	expire_field = "expire_at",
	timeout_decrement_sec = DEC,
	timeout_floor_sec = FLOOR,
}))
helpers.assert_eq(stamped_hs[1].expire_at, now + 0.8, "HS out1 expire_at")
helpers.assert_eq(stamped_hs[2].expire_at, now + 1.8, "HS out2 expire_at")

local remaining_hs = Dequeue.prune_expired(stamped_hs, now + 0.8, {
	expire_field = "expire_at",
})
helpers.assert_eq(#remaining_hs, 1, "HS prune keeps longer row")
helpers.assert_eq(remaining_hs[1].text, "b", "HS surviving row")

print("[PASS] test_tooltip_dequeue_contract")
