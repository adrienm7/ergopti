--- tests/hardware/run_keystats_layout_capture.lua
--- ==============================================================================
--- MODULE: Native Physical Family Capture Contract
--- DESCRIPTION:
--- Uses the supported real Hook provider, collector and SQLite receipts. Buffered
--- input keeps its physical family through a later publication, not a host XKB swap.
--- ==============================================================================

local root, receipt = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv, Json = require("luv"), require("json")
local Fixture = require("tests.support.keystats_native_fixture")
local Preferences = require("tests.support.metrics_preferences_fixture")
local Clock = require("infra.monotonic")
local Timings = require("infra.timings")
local Calendar = require("modules.keystats.calendar")
local Hook = require("adapters.keyboard_hook")
local Reader = require("modules.hotstrings.input_reader")
local helpers = require("tests.helpers")
local known = Reader.get_layouts()
assert(known.qwerty and known.azerty, "the actual physical family registry must support both controls")
local previous_layout = Hook.get_layout()
local previous_capture = Calendar.capture
local local_day = os.date("*t")
local noon = os.time({ year = local_day.year, month = local_day.month, day = local_day.day, hour = 12 }) * 1000
local origin = math.floor(Clock.now_ms())
-- Fix only the observation wall offset to local noon, so a CI midnight cannot
-- split this layout fixture. Native monotonic/deadline/process clocks stay real.
Calendar.capture = function()
	local mono = math.floor(Clock.now_ms())
	local wall = noon + mono - origin
	return { mono_ms = mono, wall_ms = wall, date = os.date("%Y-%m-%d", math.floor(wall / 1000)),
		ts = os.date("!%Y-%m-%d %H:%M:%S", math.floor(wall / 1000)) }
end
local directory = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/layout-context-XXXXXX"))
local databases, observations, violations, checks = {}, {}, 0, 0

--- Checks a native invariant independently of whether attribution is still broken.
local function equal(actual, expected)
	checks = checks + 1
	helpers.assert_eq(actual, expected)
end

--- Observes exact native retirement under the normal SQLite deadline.
local function await(predicate, pump)
	local deadline = uv.hrtime() + Timings.ms("keystats", "sqlite_operation_timeout_ms") * 1000000
	while not predicate() and uv.hrtime() < deadline do uv.run("nowait"); pump(); uv.sleep(1) end
	assert(predicate(), "the real native SQLite owner must retire")
end

--- Gives a scenario private storage, while keeping the actual metadata provider.
local function scenario(name, body)
	Preferences.with(function()
		Fixture.with(function(k)
			local database = directory .. "/" .. name .. ".sqlite"
			databases[#databases + 1] = database
			k.init({ sqlite_path = database })
			require("tests.support.metrics_consent_fixture").enable(k)
			local writer = require("modules.keystats.sqlite_writer")
			local function rows(sql) return assert(writer.query_rows(sql)) end
			body(k, writer, rows)
		end)
	end)
end

--- Records the observed contract, permitting all original-red cases to execute.
local function attribution(name, actual, expected, ergo, expected_ergo, raw, expected_raw)
	local matches = #actual == #expected
	for index, value in ipairs(expected) do if actual[index] ~= value then matches = false end end
	if expected_ergo and ergo[1] ~= expected_ergo then matches = false end
	if raw then
		if #raw ~= #expected_raw then matches = false end
		for index, value in ipairs(expected_raw) do if raw[index] ~= value then matches = false end end
	end
	if not matches then violations = violations + 1 end
	observations[#observations + 1] = { case = name, actual = actual, expected = expected,
		ergo = ergo, expected_ergo = expected_ergo, raw_layouts = raw, expected_raw_layouts = expected_raw, attribution_correct = matches }
end

local ok, failure = xpcall(function()
	for _, case in ipairs({
		{ name = "same-family", before = "a", after = "b", expected = { "qwerty|1" } },
		{ name = "buffered-family-switch", before = "a", after = "b", switch = "azerty", expected = { "azerty|1", "qwerty|1" } },
		{ name = "explicit-prefix-flush", before = "a", after = "b", switch = "azerty", flush_prefix = true,
			expected = { "azerty|1", "qwerty|1" } },
		{ name = "switch-without-new-input", before = "a", switch = "azerty", expected = { "qwerty|1" } },
		{ name = "ergo-buffered-prefix", before = "mn", switch = "azerty", expected = { "qwerty|1" }, ergo = "2|2" },
		{ name = "ergo-cross-family", before = "m", after = "n", switch = "azerty",
			expected = { "azerty|1", "qwerty|1" }, ergo = "2|2" },
		{ name = "ergo-reverse-family", initial = "azerty", before = "m", after = "n", switch = "qwerty",
			expected = { "azerty|1", "qwerty|1" }, ergo = "1|2" },
	}) do
		scenario(case.name, function(k, writer, rows)
			assert(Hook.set_layout(case.initial or "qwerty"))
			local start, starts = writer.start_flush, 0
			writer.start_flush = function(...) starts = starts + 1; return start(...) end
			local passed, detail = xpcall(function()
				local at, codes = math.floor(Clock.now_ms()), {}
				local keycodes = { a = 30, b = 48, m = 50, n = 49 }
				local function input(text)
					for char in text:gmatch(".") do
						-- Main's actual input producer floors its monotonic stamp before
						-- on_keydown; avoid injecting fractional INTEGER-column data.
						k.record_physical_key("layout-probe", keycodes[char], at + #codes)
						k.on_keydown(char, at + #codes, "layout-probe", keycodes[char])
						codes[#codes + 1] = keycodes[char]
					end
				end
				input(case.before)
				if case.flush_prefix then Fixture.flush(k) end
				if case.switch then assert(Hook.set_layout(case.switch)) end
				if case.after then input(case.after) end
				equal(starts, case.flush_prefix and 1 or 0)
				Fixture.flush(k)
				await(function() return k.stop() end, function() k.pump_flush() end)
				local layout_rows = rows("SELECT layout,count FROM agg_app_day_layouts WHERE app='layout-probe' ORDER BY layout;")
				local ergo = rows("SELECT same_finger_streak_max,same_hand_streak_max FROM agg_app_day_ergo WHERE app='layout-probe';")
				local events = rows("SELECT events_json FROM events_typing WHERE app='layout-probe' ORDER BY id;")
				local text, actual_codes = {}, {}
				for _, value in ipairs(events) do
					for _, event in ipairs(Json.decode(value)) do
						text[#text + 1], actual_codes[#actual_codes + 1] = event[1], event[3].sk
						equal(event[3].s, nil)
					end
				end
				equal(table.concat(text), case.before .. (case.after or ""))
				equal(actual_codes, codes)
				equal(rows("SELECT SUM(c) FROM ngram_scancodes WHERE app='layout-probe';"), { tostring(#codes) })
				equal(rows("SELECT chars FROM agg_app_day WHERE app='layout-probe';"), { tostring(#codes) })
				if case.ergo then
					equal(rows("SELECT token,c FROM ngram_bigrams WHERE app='layout-probe';"), { "mn|1" })
					equal(rows("SELECT token,c FROM ngram_chars WHERE app='layout-probe' ORDER BY token;"), { "m|1", "n|1" })
					equal(rows("SELECT count_total,longest_chars FROM agg_app_day_session WHERE app='layout-probe';"), { "1|2" })
					equal(rows("SELECT count_total,max_chars FROM agg_app_day_burst WHERE app='layout-probe';"), { "1|2" })
				end
				equal(rows("SELECT kind,count(*) FROM events_session GROUP BY kind ORDER BY kind;"), { "session_end|1", "session_start|1" })
				local initial = case.initial or "qwerty"
				local expected_raw
				if case.after and (case.switch or case.flush_prefix) then
					expected_raw = { initial .. "|" .. case.before, (case.switch or initial) .. "|" .. case.after }
				else expected_raw = { initial .. "|" .. case.before .. (case.after or "") } end
				attribution(case.name, layout_rows, case.expected, ergo, case.ergo,
					rows("SELECT layout,text FROM events_typing ORDER BY id;"), expected_raw)
			end, debug.traceback)
			writer.start_flush = start
			assert(passed, detail)
		end)
	end

	scenario("synthetic-family-switch", function(k, _, rows)
		assert(Hook.set_layout("qwerty"))
		k.on_keydown("a", math.floor(Clock.now_ms()), "layout-probe", 30)
		assert(Hook.set_layout("azerty"))
		k.record_hotstring("layout-probe", "x", "mn", math.floor(Clock.now_ms()), "static", 0, false)
		Fixture.flush(k)
		equal(rows("SELECT group_concat(text,'') FROM (SELECT text FROM events_typing ORDER BY id);"), { "a" })
		equal(rows("SELECT token,c,json_extract(esrc_json,'$.hotstring') FROM ngram_chars WHERE token IN ('m','n') ORDER BY token;"),
			{ "m|1|1", "n|1|1" })
		local raw = rows("SELECT events_json FROM events_typing ORDER BY id;")
		local manual, synthetic = 0, 0
		for _, value in ipairs(raw) do
			for _, event in ipairs(Json.decode(value)) do
				if event[3].s then synthetic = synthetic + 1; equal(event[3].sk, nil)
				else manual = manual + 1; equal(event[3].sk, 30) end
			end
		end
		equal(manual, 1); equal(synthetic, 2)
		attribution("synthetic-family-switch", rows("SELECT layout,count FROM agg_app_day_layouts ORDER BY layout;"),
			{ "azerty|1", "qwerty|1" }, {}, nil,
			rows("SELECT layout,text FROM events_typing ORDER BY id;"), { "qwerty|a", "azerty|" })
	end)

	scenario("refused-switch-prefix", function(k, writer, rows)
		assert(Hook.set_layout("qwerty"))
		k.on_keydown("a", math.floor(Clock.now_ms()), "layout-probe", 30)
		local start = writer.start_flush
		writer.start_flush = function()
			assert(Hook.set_layout("azerty"))
			k.on_keydown("b", math.floor(Clock.now_ms()), "layout-probe", 48)
			return nil
		end
		local called, saved = pcall(k.flush)
		writer.start_flush = start
		assert(called and saved == false and not k.has_flush_debt())
		Fixture.flush(k)
		equal(rows("SELECT group_concat(text,'') FROM (SELECT text FROM events_typing ORDER BY id);"), { "ab" })
		attribution("refused-switch-prefix", rows("SELECT layout,count FROM agg_app_day_layouts ORDER BY layout;"),
			{ "azerty|1", "qwerty|1" }, {}, nil,
			rows("SELECT layout,text FROM events_typing ORDER BY id;"), { "qwerty|a", "azerty|b" })
	end)

	scenario("owned-prefix-switch", function(k, writer, rows)
		assert(Hook.set_layout("qwerty"))
		k.on_keydown("a", math.floor(Clock.now_ms()), "layout-probe", 30)
		local start, native, released = writer.start_flush, nil, false
		writer.start_flush = function(...)
			native = assert(start(...))
			local proxy = { result = native.result }
			function proxy:pump() local done = native:pump(); self.result = native.result; return released and done end
			function proxy:is_settled() return released and native:is_settled() end
			function proxy:is_read_safe() return released and native:is_read_safe() end
			function proxy:is_retryable() return native:is_retryable() end
			function proxy:phase() return native:phase() end
			function proxy:cancel() return native:cancel() end
			return proxy
		end
		local passed, detail = xpcall(function()
			equal(k.flush(), false)
			await(function() return native:is_settled() end, function() k.pump_flush() end)
			assert(native.result.committed and k.has_flush_debt())
			assert(Hook.set_layout("azerty"))
			k.on_keydown("b", math.floor(Clock.now_ms()), "layout-probe", 48)
			released = true
			k.pump_flush()
			writer.start_flush = start
			Fixture.flush(k)
			equal(rows("SELECT group_concat(text,'') FROM (SELECT text FROM events_typing ORDER BY id);"), { "ab" })
			attribution("owned-prefix-switch", rows("SELECT layout,count FROM agg_app_day_layouts ORDER BY layout;"),
				{ "azerty|1", "qwerty|1" }, {}, nil,
			rows("SELECT layout,text FROM events_typing ORDER BY id;"), { "qwerty|a", "azerty|b" })
		end, debug.traceback)
		released, writer.start_flush = true, start
		assert(passed, detail)
	end)
end, debug.traceback)
Calendar.capture = previous_capture
assert(Hook.set_layout(previous_layout))
local output = assert(io.open(receipt, "wb"))
assert(output:write(Json.encode({ observations = observations, violations = violations, checks = checks,
	execution_completed = ok, error = ok and nil or failure }), "\n")); assert(output:close())
for _, database in ipairs(databases) do os.remove(database); os.remove(database .. "-wal"); os.remove(database .. "-shm") end
local retired, cleanup_failure = uv.fs_rmdir(directory)
if not ok then error(failure, 0) end
assert(retired, cleanup_failure)
assert(#observations == 10, "all actual physical provider scenarios must execute")
print("native layout capture: scenarios=" .. #observations .. " violations=" .. violations .. " checks=" .. checks)
if violations > 0 then os.exit(1) end
