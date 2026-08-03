--- tests/unit/meta/test_corpus_logger_behaviour.lua

--- ==============================================================================
--- MODULE: Logger Behaviour Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/logger/behaviour_vectors.json against the macOS
--- driver logger. The sibling corpus (_shared/modules/logger/test_vectors.json)
--- pins the LINE FORMAT; this one pins the parts that decide whether a line
--- exists at all — severity filtering and the ring buffer.
---
--- WHY IT EXISTS: this driver used levels 1/2/3/4 while the spec, the AutoHotkey
--- driver and the shared Lua core all used 10/20/30/40. Nothing compared them, so
--- a level NUMBER meant two different things depending on who read it, and
--- re-pointing this driver at the shared core would have silently changed what
--- every threshold filtered. This corpus is what makes that adoption checkable.
---
--- COVERAGE:
--- 1. Corpus integrity — every section is present and non-empty, so a truncated
---    file cannot make the whole consumer pass over nothing.
--- 2. Numbering — the driver's LEVELS match spec § 4.
--- 3. Filtering — for each threshold, exactly the listed variants are emitted and
---    exactly the listed ones are dropped, measured through the test sink rather
---    than by reading the level back.
--- 4. Lifecycle pairs — trace/done and start/success can never be split.
--- 5. Ring buffer — capacity, order, the two boundary cases either side of
---    capacity, and clear-after-wrap.
--- ==============================================================================

local helpers = require("tests.helpers")
local json    = require("json")
local Logger  = require("infra.logger")




-- ==============================================
-- ==============================================
-- ======= 1/ Corpus Loading ====================
-- ==============================================
-- ==============================================

local CORPUS_PATH = helpers.shared("tests/corpus/logger/behaviour_vectors.json")

--- Reads and decodes the shared behaviour corpus.
--- Fails loudly: a corpus that cannot be read must not let the suite report
--- success on zero vectors.
--- @return table
local function read_corpus()
	local fh = io.open(CORPUS_PATH, "r")
	assert(fh, "logger behaviour corpus not found at " .. CORPUS_PATH)
	local raw = fh:read("*a")
	fh:close()
	local decoded = json.decode(raw)
	assert(type(decoded) == "table", "logger behaviour corpus did not decode into a table")
	return decoded
end

local CORPUS = read_corpus()

-- The variant name in the corpus → the driver function that emits it. Kept
-- explicit rather than derived so a renamed variant fails here, loudly, instead
-- of quietly testing seven of eight.
local EMITTERS = {
	debug   = function(...) Logger.debug(...) end,
	trace   = function(...) Logger.trace(...) end,
	done    = function(...) Logger.done(...) end,
	info    = function(...) Logger.info(...) end,
	start   = function(...) Logger.start(...) end,
	success = function(...) Logger.success(...) end,
	warn    = function(...) Logger.warn(...) end,
	error   = function(...) Logger.error(...) end,
}

-- Every probe message must be unique. The logger suppresses a line identical to
-- the previous one inside a short window, so reusing one string would make the
-- SECOND case that emits a given variant read as "dropped" — a false failure
-- that looks exactly like a broken threshold.
local _probe_seq = 0

--- Emits one variant with the sink installed and reports whether it got through.
--- @param variant string
--- @return boolean emitted
local function emits(variant)
	_probe_seq = _probe_seq + 1
	local seen = false
	Logger.set_sink(function() seen = true end)
	EMITTERS[variant]("corpus", "Ligne de test %d.", _probe_seq)
	Logger.set_sink(nil)
	return seen
end




-- ==============================================
-- ==============================================
-- ======= 2/ Corpus Integrity ==================
-- ==============================================
-- ==============================================

helpers.describe("Logger behaviour corpus: integrity", function()
	helpers.it("holds every section, none of them empty", function()
		helpers.assert_eq(type(CORPUS.numbering), "table", "the corpus must declare the spec numbering")
		helpers.assert_eq(type(CORPUS.aliases), "table", "the corpus must declare the accepted aliases")
		helpers.assert_true(#CORPUS.filtering > 0, "the filtering section is empty — every case below would pass vacuously")
		helpers.assert_true(#CORPUS.lifecycle_pairs > 0, "the lifecycle-pair section is empty")
		helpers.assert_eq(type(CORPUS.ring_buffer), "table", "the corpus must declare the ring-buffer contract")
		helpers.assert_true(#CORPUS.ring_buffer.cases > 0, "the ring-buffer section is empty")
	end)

	helpers.it("names all eight variants, and this driver emits every one of them", function()
		local named = {}
		for _, case in ipairs(CORPUS.filtering) do
			for _, v in ipairs(case.emitted) do named[v] = true end
			for _, v in ipairs(case.dropped) do named[v] = true end
		end
		local count = 0
		for variant in pairs(named) do
			helpers.assert_eq(type(EMITTERS[variant]), "function",
				"the corpus names the variant '" .. variant .. "', which this driver does not emit")
			count = count + 1
		end
		helpers.assert_eq(count, 8, "the corpus must exercise all eight variants")
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 3/ Numbering & Aliases ===============
-- ==============================================
-- ==============================================

helpers.describe("Logger behaviour corpus: numbering", function()
	-- The corpus names variants; this driver's public table names thresholds. The
	-- two meet at the four threshold names, which is the whole numbering surface.
	local THRESHOLD_OF = { debug = "DEBUG", info = "INFO", warn = "WARNING", error = "ERROR" }

	helpers.it("LEVELS match spec § 4", function()
		for variant, expected in pairs(CORPUS.numbering) do
			local threshold = THRESHOLD_OF[variant]
			if threshold then
				helpers.assert_eq(Logger.LEVELS[threshold], expected,
					"Logger.LEVELS." .. threshold .. " must be the spec's " .. tostring(expected) ..
					" — a level number that means something different here than in the AutoHotkey " ..
					"driver is a threshold nobody can reason about")
			end
		end
	end)

	helpers.it("every alias resolves to its spec level", function()
		local saved = Logger.current_level
		for alias, expected in pairs(CORPUS.aliases) do
			if type(expected) == "number" then
				Logger.set_level(alias)
				helpers.assert_eq(Logger.current_level, expected,
					"set_level('" .. alias .. "') must resolve to " .. tostring(expected))
				-- The macOS menu persists "WARNING" while the AHK ini writes
				-- "warning"; both must land on the same threshold.
				Logger.set_level(alias:upper())
				helpers.assert_eq(Logger.current_level, expected,
					"set_level('" .. alias:upper() .. "') must resolve to the same level as '" .. alias .. "'")
			end
		end
		Logger.set_level(saved)
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 4/ Severity Filtering ================
-- ==============================================
-- ==============================================

helpers.describe("Logger behaviour corpus: filtering", function()
	for _, case in ipairs(CORPUS.filtering) do
		helpers.it(case.id, function()
			local saved = Logger.current_level
			Logger.set_level(case.min_level)

			for _, variant in ipairs(case.emitted) do
				helpers.assert_eq(emits(variant), true,
					"at threshold '" .. case.min_level .. "', " .. variant .. " must be emitted")
			end
			for _, variant in ipairs(case.dropped) do
				helpers.assert_eq(emits(variant), false,
					"at threshold '" .. case.min_level .. "', " .. variant .. " must be dropped")
			end

			Logger.set_level(saved)
		end)
	end

	for _, pair in ipairs(CORPUS.lifecycle_pairs) do
		helpers.it(pair.id, function()
			local saved = Logger.current_level
			for _, threshold in ipairs({ "debug", "info", "warning", "error" }) do
				Logger.set_level(threshold)
				helpers.assert_eq(emits(pair.a), emits(pair.b),
					"at threshold '" .. threshold .. "', " .. pair.a .. " and " .. pair.b ..
					" must be emitted or dropped together — half a lifecycle pair in the log reads " ..
					"as a silent failure that never happened")
			end
			Logger.set_level(saved)
		end)
	end
end)




-- ==============================================
-- ==============================================
-- ======= 5/ Ring Buffer =======================
-- ==============================================
-- ==============================================

helpers.describe("Logger behaviour corpus: ring buffer", function()
	-- Each case gets its own salt so no two cases ever emit the same text. The
	-- logger suppresses a line identical to the previous one inside a short
	-- window and pushes a "N identical lines suppressed" summary in its place —
	-- so a repeated first line would put the summary at snapshot[1] and the case
	-- would fail reading a real behaviour as a broken buffer.
	local _run = 0

	--- Emits n distinctly-numbered lines at a threshold that lets them all through.
	--- @param n number
	--- @return number salt The salt used, needed to read the indices back.
	local function emit_numbered(n)
		_run = _run + 1
		local saved = Logger.current_level
		Logger.set_level("DEBUG")
		Logger.ring_buffer_clear()
		for i = 1, n do
			Logger.info("corpus", "run %d ligne %d", _run, i)
		end
		Logger.set_level(saved)
		return _run
	end

	--- Extracts the emission index a snapshot entry carries.
	--- @param line string
	--- @return number|nil
	local function index_of(line)
		local n = tostring(line):match("ligne (%d+)")
		return n and tonumber(n) or nil
	end

	for _, case in ipairs(CORPUS.ring_buffer.cases) do
		helpers.it(case.id, function()
			emit_numbered(case.emit)
			if case.clear then Logger.ring_buffer_clear() end

			local snapshot = Logger.ring_buffer_snapshot()
			helpers.assert_eq(#snapshot, case.expect_size,
				case.id .. ": the buffer must hold " .. tostring(case.expect_size) .. " entry(ies)")

			if case.expect_first then
				helpers.assert_eq(index_of(snapshot[1]), case.expect_first,
					case.id .. ": the oldest surviving entry must be line " .. tostring(case.expect_first))
				helpers.assert_eq(index_of(snapshot[#snapshot]), case.expect_last,
					case.id .. ": the newest entry must be line " .. tostring(case.expect_last))

				-- Chronological order is asserted across the WHOLE snapshot, not
				-- just its ends: a circular buffer returned as its raw array has
				-- the right first and last entries only by accident, and reads as
				-- two shuffled halves in between.
				local previous = nil
				for _, line in ipairs(snapshot) do
					local idx = index_of(line)
					helpers.assert_true(idx ~= nil, case.id .. ": every entry must carry its emission index")
					if previous then
						helpers.assert_eq(idx, previous + 1,
							case.id .. ": the snapshot must read oldest-first with no gaps")
					end
					previous = idx
				end
			end

			Logger.ring_buffer_clear()
		end)
	end

	helpers.it("capacity matches the corpus", function()
		-- Derived rather than read from a constant: a capacity field that drifted
		-- from the real array would agree with itself and with nothing else.
		local saved = Logger.current_level
		Logger.set_level("DEBUG")
		Logger.ring_buffer_clear()
		for i = 1, CORPUS.ring_buffer.capacity + 25 do
			Logger.info("corpus", "capacite ligne %d", i)
		end
		helpers.assert_eq(#Logger.ring_buffer_snapshot(), CORPUS.ring_buffer.capacity,
			"the buffer must cap at the corpus capacity")
		Logger.ring_buffer_clear()
		Logger.set_level(saved)
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 6/ Driver Default ====================
-- ==============================================
-- ==============================================

helpers.describe("Logger behaviour corpus: this driver's default", function()
	helpers.it("the module default matches the row the corpus records for it", function()
		-- A starting threshold is a policy, not a behaviour of the filter, so the
		-- corpus records one row per driver and each asserts its own. Changing it
		-- is then a deliberate edit to the shared file, not a surprise in a log
		-- that suddenly went quiet.
		local recorded = CORPUS.driver_defaults.macos_module_default
		helpers.assert_eq(type(recorded), "string", "the corpus must record this driver's default")

		local fresh = helpers.load_with_stubs("infra.logger")
		helpers.assert_eq(fresh.current_level, fresh.LEVELS[recorded:upper()],
			"the module's starting level must be the corpus's '" .. recorded .. "'")
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 7/ Deduplication =====================
-- ==============================================
-- ==============================================

helpers.describe("Logger behaviour corpus: dedup", function()
	-- The clock is driven by the test, not by the wall: a window measured in
	-- seconds cannot be exercised by a suite that runs in milliseconds, and
	-- sleeping for it would add five seconds per case to every CI run.
	local fake_now = 0

	--- Runs one dedup case and reports what reached the sink.
	--- @param messages table Array of message bodies to emit, in order.
	--- @param variant string|nil Variant to emit them with (default "info").
	--- @return table lines Every line the sink received.
	local function run(messages, variant)
		local lines = {}
		local saved_clock = Logger.clock_fn
		local saved_level = Logger.current_level
		Logger.clock_fn = function() return fake_now end
		Logger.reset_dedup()
		Logger.ring_buffer_clear()
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line, v) lines[#lines + 1] = { line = line, variant = v } end)
		for _, body in ipairs(messages) do
			EMITTERS[variant or "info"]("corpus", body)
		end
		Logger.set_sink(nil)
		Logger.clock_fn = saved_clock
		Logger.set_level(saved_level)
		return lines
	end

	--- True when a line is a suppression summary rather than a real message.
	local function is_summary(line)
		return tostring(line):find("identical", 1, true) ~= nil
	end

	for _, vector in ipairs(CORPUS.dedup.cases) do
		helpers.it(vector.id, function()
			local lines = run(vector.emit, vector.variant)

			if vector.expect_delivered then
				helpers.assert_eq(#lines, vector.expect_delivered,
					vector.id .. ": " .. tostring(vector.expect_delivered) .. " line(s) must reach the sink")
			end

			if vector.expect_suppressed then
				helpers.assert_eq(Logger.dedup_suppressed_count(), vector.expect_suppressed,
					vector.id .. ": " .. tostring(vector.expect_suppressed) ..
					" line(s) must have been suppressed — asserting the absence alone would pass " ..
					"against a logger that dropped them for any other reason")
			end

			if vector.expect_summary then
				local summaries = 0
				for _, entry in ipairs(lines) do
					if is_summary(entry.line) then
						summaries = summaries + 1
						helpers.assert_true(tostring(entry.line):find(tostring(vector.expect_summary_count), 1, true) ~= nil,
							vector.id .. ": the summary must carry the suppressed count, got " .. tostring(entry.line))
					end
				end
				helpers.assert_eq(summaries, 1, vector.id .. ": closing a streak must emit exactly one summary")
			end

			if vector.expect_summary_variant then
				-- Seed a streak at the variant under test, then close it and read
				-- the summary's variant back.
				run({ "graine", "graine" }, vector.expect_summary_variant)
				local closing = {}
				Logger.set_sink(function(line, v) closing[#closing + 1] = { line = line, variant = v } end)
				Logger.set_level("DEBUG")
				EMITTERS[vector.expect_summary_variant]("corpus", "fermeture")
				Logger.set_sink(nil)

				local found = nil
				for _, entry in ipairs(closing) do
					if is_summary(entry.line) then found = entry end
				end
				helpers.assert_true(found ~= nil, vector.id .. ": closing the streak must emit a summary")
				helpers.assert_true(tostring(found.line):find(vector.expect_summary_variant:upper(), 1, true) ~= nil,
					vector.id .. ": the summary must carry the suppressed variant's label, or a swallowed " ..
					"error storm never reaches the errors-only log — got " .. tostring(found.line))
			end

			if vector.expect_ring_entries then
				helpers.assert_eq(#Logger.ring_buffer_snapshot(), vector.expect_ring_entries,
					vector.id .. ": the ring feeds crash reports — a thousand copies of one line would " ..
					"push out everything that explains it")
			end

			Logger.reset_dedup()
			Logger.ring_buffer_clear()
		end)
	end

	helpers.it("a streak that outlives the window re-surfaces", function()
		-- De-BOUNCED, not permanently silenced. Without this the first occurrence
		-- of a recurring line would be the only one ever logged, all session.
		local lines = {}
		local saved_clock = Logger.clock_fn
		local saved_level = Logger.current_level
		Logger.clock_fn = function() return fake_now end
		Logger.reset_dedup()
		Logger.ring_buffer_clear()
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = line end)

		Logger.info("corpus", "recurrente")
		Logger.info("corpus", "recurrente")
		fake_now = fake_now + CORPUS.dedup.window_seconds + 1
		Logger.info("corpus", "recurrente")

		Logger.set_sink(nil)
		Logger.clock_fn = saved_clock
		Logger.set_level(saved_level)

		local real = 0
		for _, line in ipairs(lines) do
			if not is_summary(line) then real = real + 1 end
		end
		helpers.assert_eq(real, 2, "the line must re-surface once the window has passed")
		Logger.reset_dedup()
		Logger.ring_buffer_clear()
	end)
end)
