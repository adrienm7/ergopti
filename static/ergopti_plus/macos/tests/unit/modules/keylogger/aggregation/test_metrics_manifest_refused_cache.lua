--- tests/unit/modules/keylogger/aggregation/test_metrics_manifest_refused_cache.lua

--- ==============================================================================
--- MODULE: Metrics Manifest Refused Read Cache Regression
--- DESCRIPTION:
--- Compose the real SQLite reader and incremental projection around a transient
--- row-query refusal. A successful fingerprint must not certify the incomplete
--- manifest that another statement produced, including during midnight extension.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNERS = {
	"modules.keylogger.sqlite_reader", "ui.metrics_typing.projection", "infra.paced_json",
	"infra.logger", "hs.sqlite3", "hs.json", "json",
}
local PAST, TODAY, TOMORROW = "2026-10-17", "2026-10-18", "2026-10-19"

local function iterator(rows)
	local index = 0
	return function() index = index + 1; return rows[index] end
end

--- Model just the two stored app days; fingerprint reads remain successful
--- while the errors projection can independently refuse its row statement.
local function fixture()
	local state = { refuse = false, reads = {}, errors = {}, closes = 0 }
	local stored = {
		{ date = PAST, app = "Editor", chars = 7, bs_total = 3 },
		{ date = TODAY, app = "Editor", chars = 2, bs_total = 1 },
	}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...)
		state.errors[#state.errors + 1] = string.format(message, ...)
	end
	package.loaded["infra.logger"] = logger
	local sqlite = { OK = 0 }
	function sqlite.open()
		local db = {}
		function db:exec() return sqlite.OK end
		function db:close() state.closes = state.closes + 1; return sqlite.OK end
		function db:nrows(sql)
			local source = sql:match("FROM ([%w_]+)")
			local lo, hi = sql:match("date >= '([%d%-]+)'"), sql:match("date <= '([%d%-]+)'")
			if sql:find("COUNT(*) AS n", 1, true) then
				-- Independently stable DB contents: a row-read failure is not a write.
				local total = { n = 0, s2 = 0 }
				if source == "agg_app_day" or source == "agg_app_day_errors" then
					for _, row in ipairs(stored) do
						if not hi or row.date <= hi then
							total.n = total.n + 1
							total.s2 = total.s2 + (source == "agg_app_day" and row.chars or row.bs_total)
						end
					end
				end
				return iterator({ total })
			end
			if sql:find("SELECT (SELECT MIN(date)", 1, true) then
				return iterator(source == "agg_app_day" and { { lo = PAST, hi = TODAY } } or {})
			end
			if source ~= "agg_app_day" and source ~= "agg_app_day_errors" then return iterator({}) end
			if source == "agg_app_day_errors" and state.refuse then error("controlled SQLITE_BUSY row refusal") end
			local rows = {}
			for _, row in ipairs(stored) do
				if (not lo or row.date >= lo) and (not hi or row.date <= hi) then
					rows[#rows + 1] = row
				end
			end
			return iterator(rows)
		end
		return db
	end
	local reader = helpers.load_with_stubs("modules.keylogger.sqlite_reader", { sqlite3 = sqlite })
	local original_read = reader.read_manifest
	reader.read_manifest = function(path, first, last, pacer)
		local manifest, complete = original_read(path, first, last, pacer)
		state.reads[#state.reads + 1] = { first = first, complete = complete }
		return manifest, complete
	end
	local projection = require("ui.metrics_typing.projection")
	function state.project(today)
		return projection.session(reader, "/fixture/db.sqlite", today, { pause = function() end }).manifest()
	end
	return state
end

helpers.describe("metrics-manifest-refused-cache", function()
	helpers.it("retries past errors after an incomplete cold projection with unchanged fingerprint", function()
		helpers.with_stub_scope(OWNERS, function()
			local state = fixture()
			state.refuse = true
			local partial = state.project(TODAY)
			helpers.assert_eq(partial[PAST].Editor.chars, 7, "accepted counters remain visible")
			helpers.assert_eq(partial[PAST].Editor.bs_total, 0)
			helpers.assert_eq(state.reads[1].complete, false)
			helpers.assert_true(#state.errors > 0, "the real reader must report the SQL refusal")
			state.refuse = false
			local recovered, encoded = state.project(TODAY)
			helpers.assert_eq(recovered[PAST].Editor.bs_total, 3,
				"a stable fingerprint must not freeze the refused historical table")
			helpers.assert_eq(state.reads[2].first, nil, "an incomplete manifest cannot authorize incremental reuse")
			helpers.assert_true(encoded:find('"bs_total":3', 1, true) ~= nil)
		end)
	end)

	helpers.it("retries a refused day that became historical during midnight extension", function()
		helpers.with_stub_scope(OWNERS, function()
			local state = fixture()
			helpers.assert_eq(state.project(TODAY)[PAST].Editor.bs_total, 3)
			state.refuse = true
			local partial = state.project(TOMORROW)
			helpers.assert_eq(state.reads[2].first, TODAY, "the healthy prior cache may extend by one day")
			helpers.assert_eq(state.reads[2].complete, false)
			helpers.assert_eq(partial[TODAY].Editor.bs_total, 0)
			state.refuse = false
			local recovered = state.project(TOMORROW)
			helpers.assert_eq(recovered[TODAY].Editor.bs_total, 1,
				"the refused extension must not become a certified historical day")
			helpers.assert_eq(recovered[PAST].Editor.bs_total, 3)
			helpers.assert_eq(state.reads[3].first, nil)
		end)
	end)

	helpers.it("keeps incremental reuse for an acknowledged complete projection", function()
		helpers.with_stub_scope(OWNERS, function()
			local state = fixture()
			local first, first_json = state.project(TODAY)
			local second, second_json = state.project(TODAY)
			helpers.assert_eq(state.reads[1].complete, true)
			helpers.assert_eq(state.reads[2].first, TODAY)
			helpers.assert_eq(second, first)
			helpers.assert_eq(second_json, first_json)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
end)
