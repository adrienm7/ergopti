--- _shared/lua/test/keystats_aggregation_corpus.lua

--- Replays the cross-driver aggregation corpus
--- (`_shared/tests/corpus/keystats/aggregation_vectors.json`) through a Lua
--- driver's walker and checks every `expected` key of every vector against
--- the resulting batch and per-application contexts. The Windows suite replays
--- the same vectors through KLW_WalkTypingEntry.
---
--- Each expected key has exactly one reading below; a key nobody can read
--- fails the vector, so a new vector cannot pass by asserting nothing.
--- Registered by the macOS and Linux suites with their production walk entry.
local M = {}

--- Sums one numeric field over every row of a batch sub-table.
local function sum(rows, field)
	local total = 0
	for _, row in pairs(rows or {}) do total = total + (tonumber(row[field]) or 0) end
	return total
end

--- Counts the rows of a batch sub-table.
local function count(rows)
	local total = 0
	for _ in pairs(rows or {}) do total = total + 1 end
	return total
end

--- The largest value of one numeric field over the rows of a sub-table.
local function max(rows, field)
	local best = 0
	for _, row in pairs(rows or {}) do
		local value = tonumber(row[field]) or 0
		if value > best then best = value end
	end
	return best
end

--- Sorted tokens of an n-gram family whose item satisfies `keep`.
local function tokens(batch, family, keep)
	local out = {}
	for key, item in pairs(batch.ngram[family] or {}) do
		if keep(item) then out[#out + 1] = key:match("^[^\1]*\1[^\1]*\1(.*)$") end
	end
	table.sort(out)
	return out
end

--- The only value every row of a sub-table agrees on for one field.
local function single(rows, field)
	local value
	for _, row in pairs(rows or {}) do
		if value ~= nil and row[field] ~= value then return "<several>" end
		value = row[field]
	end
	return value
end

-- How each expected key is read. `r` is { batch, ctx } where ctx is the
-- context of the vector's last typing application.
M.READINGS = {
	app_day = function(r, want, helpers, id)
		for key, fields in pairs(want) do
			local row = r.batch.app_day[key]
			helpers.assert_true(row ~= nil, id .. ": app_day row " .. key:gsub("\1", " | ") .. " exists")
			for field, value in pairs(fields) do
				helpers.assert_eq(row[field] or 0, value, id .. ": app_day." .. field)
			end
		end
	end,
	app_day_chars = function(r) return sum(r.batch.app_day, "chars") end,
	app_day_hs_suggested = function(r) return sum(r.batch.app_day, "hs_suggested") end,
	app_time_count = function(r) return count(r.batch.app_time) end,
	app_time_ms_total = function(r) return sum(r.batch.app_time, "ms") end,
	burst_count_total = function(r) return sum(r.batch.bursts, "count_total") end,
	burst_open_chars = function(r) return r.ctx.current_burst and r.ctx.current_burst.char_count or 0 end,
	session_count_total = function(r) return sum(r.batch.sessions, "count_total") end,
	session_open_chars = function(r) return r.ctx.current_session and r.ctx.current_session.char_count or 0 end,
	chars_class_letter = function(r) return sum(r.batch.chars_class, "letter") end,
	chars_class_space = function(r) return sum(r.batch.chars_class, "space") end,
	chars_class_punct = function(r) return sum(r.batch.chars_class, "punct") end,
	chars_class_first_typed_min = function(r) return single(r.batch.chars_class, "first_typed_min") end,
	chars_class_last_typed_min = function(r) return single(r.batch.chars_class, "last_typed_min") end,
	ergo_focus_count = function(r) return sum(r.batch.ergo, "focus_to_first_key_count") end,
	ergo_focus_sum_ms = function(r) return sum(r.batch.ergo, "focus_to_first_key_sum_ms") end,
	ergo_same_finger_max = function(r) return max(r.batch.ergo, "same_finger_streak_max") end,
	ergo_same_hand_max = function(r) return max(r.batch.ergo, "same_hand_streak_max") end,
	errors_bs_total = function(r) return sum(r.batch.errors, "bs_total") end,
	errors_cascade_count = function(r) return sum(r.batch.errors, "cascade_count") end,
	hourly_c = function(r) return sum(r.batch.hourly, "c") end,
	hourly_e = function(r) return sum(r.batch.hourly, "e") end,
	hourly_es = function(r) return sum(r.batch.hourly, "es") end,
	kc_hold_count = function(r) return sum(r.batch.kc_hold, "count") end,
	kc_hold_sum_ms = function(r) return sum(r.batch.kc_hold, "sum_ms") end,
	kc_hold_max_ms = function(r) return max(r.batch.kc_hold, "max_ms") end,
	layouts_count_total = function(r) return sum(r.batch.layouts, "count") end,
	last_cur_word = function(r) return r.ctx.cur_word end,
	last_hist_len = function(r) return #(r.ctx.hist or {}) end,
	last_p1 = function(r) return r.ctx.p1 end,
	last_prev_word = function(r) return r.ctx.prev_word end,
	ngram_chars_count = function(r) return count(r.batch.ngram.ngram_chars) end,
	ngram_bigrams_count = function(r) return count(r.batch.ngram.ngram_bigrams) end,
	ngram_trigrams_count = function(r) return count(r.batch.ngram.ngram_trigrams) end,
	ngram_words = function(r) return tokens(r.batch, "ngram_words", function(item) return item.c > 0 end) end,
	ngram_chars_delay_count = function(r) return sum(r.batch.ngram.ngram_chars, "cd") end,
	ngram_chars_total_delay_ms = function(r) return sum(r.batch.ngram.ngram_chars, "td") end,
	ngram_zero_delay_tokens = function(r)
		return tokens(r.batch, "ngram_chars", function(item) return item.c > 0 and item.cd == 0 end)
	end,
	ngram_chars_error_tokens = function(r)
		return tokens(r.batch, "ngram_chars", function(item) return item.e > 0 end)
	end,
	switches_to_count = function(r) return count(r.batch.switches_to) end,
	system_day_wifi_changes = function(r) return sum(r.batch.system_day, "wifi_changes") end,
	titles_count = function(r) return count(r.batch.titles) end,
	titles_ms_total = function(r) return sum(r.batch.titles, "ms") end,
	trigger_buckets_hs_count = function(r) return sum(r.batch.app_buckets, "hs_in_c") end,
}

--- Loads the corpus.
--- @param read_file function Given a path, returns its content or nil.
--- @param decode function JSON decoder.
--- @param path string Absolute corpus path.
--- @return table corpus
function M.load(read_file, decode, path)
	local content = assert(read_file(path), "aggregation corpus unreadable: " .. tostring(path))
	local corpus = decode(content)
	assert(type(corpus) == "table" and type(corpus.vectors) == "table" and #corpus.vectors > 0,
		"aggregation corpus has no vectors")
	return corpus
end

--- The application of a vector's last typing event, whose context the
--- `last_*` and `*_open_*` keys read.
--- @param vector table
--- @return string|nil
function M.last_typing_app(vector)
	local app
	for _, event in ipairs(vector.events) do
		if event.type == "typing" then app = event.app end
	end
	return app
end

--- Registers one case per vector on a driver's helpers.
--- @param helpers table The driver's test helpers.
--- @param env table {
---   corpus = table (from M.load),
---   label = string (suite title),
---   replay = function(vector) -> batch, ctx_of(app) -> table|nil,
---   skip = table|nil { [vector_id] = reason } for vectors whose event kind the
---          driver records elsewhere; every entry must name a real vector. }
function M.register(helpers, env)
	local skip = env.skip or {}
	local ids = {}
	for _, vector in ipairs(env.corpus.vectors) do ids[vector.id] = true end
	helpers.describe(env.label, function()
		helpers.it("every skipped vector exists and states its reason", function()
			for id, reason in pairs(skip) do
				helpers.assert_true(ids[id] == true, "skip names an unknown vector: " .. tostring(id))
				helpers.assert_true(type(reason) == "string" and #reason > 20, id .. " needs a stated reason")
			end
		end)
		for _, vector in ipairs(env.corpus.vectors) do
			if not skip[vector.id] then
				helpers.it(vector.id .. ": " .. tostring(vector.description), function()
					local batch, ctx_of = env.replay(vector)
					local app = M.last_typing_app(vector)
					local reading = { batch = batch, ctx = (app and ctx_of(app)) or {} }
					for key, want in pairs(vector.expected) do
						local read = M.READINGS[key]
						helpers.assert_true(read ~= nil, vector.id .. ": no reading for expected key " .. key)
						local got = read(reading, want, helpers, vector.id)
						if got ~= nil or type(want) ~= "table" then
							helpers.assert_eq(got, want, vector.id .. ": " .. key)
						end
					end
				end)
			end
		end
	end)
end

return M
