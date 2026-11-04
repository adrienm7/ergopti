--- tests/unit/ui/metrics/test_metrics_instant_open.lua

--- ==============================================================================
--- MODULE: Metrics Instant Open
--- DESCRIPTION:
--- Opening the typing dashboard used to wait about ten seconds: 0.4 s after
--- the window appeared, the whole all-time projection ran synchronously on
--- the Hammerspoon main thread, which also held back the cached paint and
--- WebKit's own presentation. The window must now paint the persisted snapshot
--- (labelled with its date) before any aggregation, then replace it in place
--- with the paced projection.
---
--- FEATURES & RATIONALE:
--- 1. The snapshot is painted before any SQLite statement runs.
--- 2. The paced refresh replaces it with a newer revision marked fresh.
--- 3. A corrupt or legacy snapshot is deleted and never painted.
--- 4. The dashboard Reset deletes the snapshot and its partial file.
--- 5. Neither show(), the bootstrap, nor the request poller reads SQLite.
--- ==============================================================================

local helpers = require("tests.helpers")
local Publication = require("tests.support.ui.metrics.typing.publication")
local with_delivery = require("tests.support.typing_delivery_fixture")
local FakeSqlite = require("tests.support.fake_ngram_sqlite")

local PAYLOAD = '{"manifest":{"2026-09-01":{"Code":{"chars":42}}},"app_icons":{},"initial_data":null,"kc_layout":{}}'
local GENERATED_AT = 1790000000
local SNAPSHOT = "ERGOPTI_TYPING_METRICS_SNAPSHOT 2 " .. GENERATED_AT .. " " .. #PAYLOAD .. "\n" .. PAYLOAD

--- Runs a dashboard scenario over a fake store whose statements are counted.
local function with_store(callback)
	with_delivery(function(dashboard, context, timers, errors, successes, evaluations, filesystem)
		local sqlite = FakeSqlite.new({
			ngram_chars = { { date = "2026-09-01", app = "Code", token = "a", c = 3, td = 300, e = 0, esrc_json = "{}" } },
		})
		-- The dashboard captured these hs.fs and hs.json doubles when it loaded
		package.loaded["hs.fs"].attributes = function() return { mode = "file" } end
		local dashboard_json = package.loaded["hs.json"]
		local reader = helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite })
		package.loaded["modules.keystats.sqlite_reader"] = reader
		package.loaded["modules.keystats.log_manager"].get_sqlite_path = function() return "/fake/db.sqlite" end
		package.loaded["modules.keystats.log_manager"].get_db_rev = function() return 1 end
		local function statements()
			local total = 0
			for _, count in pairs(sqlite.statements) do total = total + count end
			return total
		end
		callback({
			dashboard = dashboard, context = context, timers = timers, errors = errors,
			successes = successes, evaluations = evaluations, filesystem = filesystem,
			statements = statements, json = dashboard_json,
		})
	end)
end

helpers.describe("metrics-instant-open: dashboard", function()
	helpers.it("renders the cached snapshot before any aggregation, then replaces it", function()
		with_store(function(t)
			local saved = nil
			io.open = function(path, access)
				helpers.assert_eq(access, "w")
				local file = {}
				file.write = function(self, header, payload) saved = { path = path, header = header, payload = payload }; return self end
				file.close = function() return true end
				return file
			end
			t.filesystem.read_with_status = function() return SNAPSHOT, "ok" end
			t.timers[1]()
			helpers.assert_eq(t.evaluations[1].code, "typeof window.publishTypingMetricsData")
			t.evaluations[1].done("function", nil)
			local painted = t.evaluations[2].code
			local _, painted_metadata, painted_payload = Publication.decode(painted)
			helpers.assert_eq(painted_payload, PAYLOAD, "the snapshot payload is painted verbatim")
			helpers.assert_eq(painted_metadata.manifest_revision, 0)
			helpers.assert_eq(painted_metadata.freshness.state, "stale")
			helpers.assert_eq(painted_metadata.freshness.generated_at, GENERATED_AT * 1000,
				"the painted snapshot is labelled with its age")
			helpers.assert_eq(t.statements(), 0, "no aggregation has run when the snapshot is painted")

			t.context.settle_jobs()
			helpers.assert_true(t.statements() > 0, "the paced refresh reads the store")
			helpers.assert_eq(t.evaluations[3].code, "typeof window.publishTypingMetricsData")
			t.evaluations[3].done("function", nil)
			local fresh = t.evaluations[4].code
			local _, fresh_metadata, fresh_payload = Publication.decode(fresh)
			helpers.assert_eq(fresh_metadata.manifest_revision, 1,
				"the refresh outranks the snapshot revision, so the page replaces it in place")
			helpers.assert_eq(fresh_metadata.freshness.state, "fresh")
			helpers.assert_true(saved ~= nil and saved.path:sub(-8) == ".partial", "the refresh becomes the next snapshot")
			helpers.assert_eq(fresh_payload, saved.payload, "the saved snapshot is what was published")
			helpers.assert_eq(#t.errors, 0, table.concat(t.errors, " | "))
		end)
	end)

	for _, corrupt in ipairs({
		'{"manifest":"{}","app_icons":"{}","initial_data":"null","kc_layout":"{}"}',
		"ERGOPTI_TYPING_METRICS_SNAPSHOT 2 " .. GENERATED_AT .. " 9999\n" .. PAYLOAD,
		"ERGOPTI_TYPING_METRICS_SNAPSHOT 1 " .. GENERATED_AT .. " " .. #PAYLOAD .. "\n" .. PAYLOAD,
		"ERGOPTI_TYPING_METRICS_SNAPSHOT 2 " .. GENERATED_AT .. " 5\n<svg>",
	}) do
		helpers.it("ignores and deletes a corrupt or old-format cache: " .. corrupt:sub(1, 36), function()
			with_store(function(t)
				local previous_remove, removed = os.remove, {}
				local ok, err = xpcall(function()
					os.remove = function(path) removed[#removed + 1] = path; return true end
					t.filesystem.read_with_status = function() return corrupt, "ok" end
					t.timers[1]()
					helpers.assert_eq(removed[1], require("ui.metrics_typing.snapshot").PATH)
					helpers.assert_eq(t.evaluations[1].code, "typeof window.setTypingMetricsFreshness",
						"an invalid snapshot is never painted; the loading notice is shown instead")
					t.evaluations[1].done("function", nil)
					helpers.assert_eq(t.evaluations[2].code, 'window.setTypingMetricsFreshness({"state":"loading"},0);')
					for _, evaluation in ipairs(t.evaluations) do
						helpers.assert_nil(evaluation.code:find("publishTypingMetricsData(", 1, true))
					end
				end, debug.traceback)
				os.remove = previous_remove
				if not ok then error(err, 0) end
			end)
		end)
	end

	helpers.it("clearing the dashboard data deletes the snapshot and its partial file", function()
		with_store(function(t)
			local previous_remove, removed = os.remove, {}
			local ok, err = xpcall(function()
				os.remove = function(path) removed[#removed + 1] = path; return true end
				t.json.decode = function() return { action = "clear_cache", reset_id = 1 } end
				t.context.poll()
				t.evaluations[1].done("request", nil)
				t.evaluations[2].done(true, nil)
				local path = require("ui.metrics_typing.snapshot").PATH
				helpers.assert_eq(table.concat(removed, "|"), path .. "|" .. path .. ".partial")
				helpers.assert_eq(t.evaluations[3].code, "window.complete_cache_reset(1,true);")
			end, debug.traceback)
			os.remove = previous_remove
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("never aggregates synchronously on the open path or in the request poller", function()
		with_store(function(t)
			helpers.assert_eq(t.statements(), 0, "show() reads nothing")
			t.timers[1]()
			helpers.assert_eq(t.statements(), 0, "the bootstrap reads only the snapshot file")
			t.json.decode = function()
				return { start_date = "2026-09-01", end_date = "2026-09-30", apps = { "Code" }, request_id = 7 }
			end
			t.context.poll()
			local mailbox = #t.evaluations
			t.evaluations[mailbox].done("request", nil)
			t.evaluations[#t.evaluations].done(true, nil)
			helpers.assert_eq(t.statements(), 0, "a range request is queued, not projected in the callback")
			t.context.settle_jobs()
			helpers.assert_true(t.statements() > 0)
			local answered = false
			for _, evaluation in ipairs(t.evaluations) do
				if evaluation.code:find("window.receive_range_data(", 1, true)
					and evaluation.code:find(",7)", 1, true) then answered = true end
			end
			helpers.assert_true(answered, "the queued range request is answered with its request id")
		end)
	end)
end)

helpers.describe("Typing publication decoder protocol vectors", function()
	helpers.it("preserves escaped bytes and prototype keys (typing-publication-protocol)", function()
		local code = [=[window.publishTypingMetricsData(JSON.parse("{\"manifest\":{\"__proto__\":{\"title\":\"quote \\\" slash \\\\ punctuation ), and Unicode é € 😀\"}},\"initial_data\":null}"),{"manifest_revision":7,"freshness":{"state":"fresh"}});]=]
		local expected = [=[{"manifest":{"__proto__":{"title":"quote \" slash \\ punctuation ), and Unicode é € 😀"}},"initial_data":null}]=]
		local payload, metadata, encoded_payload = Publication.decode(code)
		helpers.assert_eq(encoded_payload, expected, "decoding must retain the exact inner JSON bytes")
		helpers.assert_eq(payload.manifest.__proto__.title, [=[quote " slash \ punctuation ), and Unicode é € 😀]=])
		helpers.assert_eq(metadata, { manifest_revision = 7, freshness = { state = "fresh" } })
	end)

	local refusals = {
		{
			name = "an unquoted payload",
			code = 'window.publishTypingMetricsData(JSON.parse(42),{});',
			receipt = "requires a quoted JSON payload",
		},
		{
			name = "unterminated quoting",
			code = [=[window.publishTypingMetricsData(JSON.parse("unterminated),{});]=],
			receipt = "requires complete JSON.parse arguments",
		},
		{
			name = "an escaped terminal quote",
			code = [=[window.publishTypingMetricsData(JSON.parse("unterminated\"),{});]=],
			receipt = "requires complete JSON.parse arguments",
		},
		{
			name = "a missing argument delimiter",
			code = [=[window.publishTypingMetricsData(JSON.parse("{}"){});]=],
			receipt = "requires complete JSON.parse arguments",
		},
		{
			name = "obsolete object-literal transport",
			code = 'window.publishTypingMetricsData({"manifest":{}},{});',
			receipt = "requires the JSON.parse boundary",
		},
	}
	for _, vector in ipairs(refusals) do
		helpers.it("refuses " .. vector.name .. " (typing-publication-protocol)", function()
			local ok, err = pcall(Publication.decode, vector.code)
			helpers.assert_eq(ok, false, "malformed transport must never produce a publication")
			helpers.assert_not_nil(tostring(err):find(vector.receipt, 1, true),
				"the refusal must identify the broken publication boundary")
		end)
	end
end)
