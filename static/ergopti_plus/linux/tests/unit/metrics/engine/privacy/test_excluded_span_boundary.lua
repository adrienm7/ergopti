--- tests/unit/metrics/engine/privacy/test_excluded_span_boundary.lua

--- ==============================================================================
--- MODULE: Linux Metrics Excluded Span Boundary
--- DESCRIPTION:
--- An exclusion (collection pause, private window, secure field, password
--- suppression, metrics switched off) hides the keys typed during it. The keys
--- either side of it were not consecutive, so no word, bigram, inter-key delay
--- or typing time may bridge the excluded span, whether the characters before
--- it are still pending or were committed by an earlier flush (audit LM-001).
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local PreferencesFixture = require("tests.support.metrics_preferences_fixture")
local Monotonic = require("core.logger.engine.monotonic")

local ENTER = {
	pause = function(k) k.suspend_collection() end,
	private = function(k) k.set_private_window(true) end,
	secure = function(k) k.set_secure_field(true) end,
	suppressed = function(k) k.suppress() end,
	disabled = function(k) helpers.assert_true(k.set_enabled(false)) end,
}
local LEAVE = {
	pause = function(k) k.resume_collection() end,
	private = function(k) k.set_private_window(false) end,
	secure = function(k) k.set_secure_field(false) end,
	suppressed = function(k) k.unsuppress() end,
	disabled = function(k) helpers.assert_true(k.set_enabled(true)) end,
}

--- Finds one walked n-gram row of the fake writer.
--- @param writer table Fake SQLite writer.
--- @param table_name string N-gram family.
--- @param token string N-gram token.
--- @return table|nil row
local function ngram(writer, table_name, token)
	for _, entry in ipairs(writer.ngrams) do
		if entry.table_name == table_name and entry.ngrams[token] then return entry.ngrams[token] end
	end
	return nil
end

helpers.describe("Linux metrics excluded span boundary", function()
	for _, mode in ipairs({ "same_snapshot", "across_commit" }) do
		for _, boundary in ipairs({ "pause", "private", "secure", "suppressed", "disabled" }) do
			helpers.it("(lm-001) " .. boundary .. " " .. mode .. " is not bridged by sequences or timing", function()
				local previous_now = Monotonic.now_ms
				local previous_writer = package.loaded["metrics.engine.journal.sqlite_writer"]
				local previous_keystats = package.loaded["metrics.engine.keystats"]
				local observed = 1000
				Monotonic.now_ms = function() return observed end
				local ok, err = pcall(PreferencesFixture.with, function()
					local writer = Fakes.sqlite_writer()
					package.loaded["metrics.engine.journal.sqlite_writer"] = writer
					package.loaded["metrics.engine.keystats"] = nil
					local k = require("metrics.engine.keystats")
					k.init({ sqlite_path = "/tmp/ergopti-lm-001.sqlite" })
					helpers.assert_true(k.set_enabled(true))
					k.on_keydown("a", 1000, "test-app")
					if mode == "across_commit" then helpers.assert_true(k.flush()) end
					ENTER[boundary](k)
					k.on_keydown("X", 1100, "test-app")
					LEAVE[boundary](k)
					observed = 1300
					k.on_keydown("b", 1200, "test-app")
					k.on_keydown(" ", 1300, "test-app")
					helpers.assert_true(k.flush())
					helpers.assert_nil(ngram(writer, "ngram_bigrams", "ab"), "no bigram spans the excluded key")
					helpers.assert_nil(ngram(writer, "ngram_words", "ab"), "no word spans the excluded key")
					helpers.assert_true(ngram(writer, "ngram_words", "b") ~= nil, "the word after the span is its own")
					helpers.assert_eq(k.get_app_stats()["test-app"].typing_time_ms, 100,
						"only the b-to-space interval is typing time")
					for _, entry in ipairs(writer.typing) do
						helpers.assert_true(not tostring(entry.row.text):find("X", 1, true), "the excluded key is absent")
					end
				end)
				Monotonic.now_ms = previous_now
				package.loaded["metrics.engine.journal.sqlite_writer"] = previous_writer
				package.loaded["metrics.engine.keystats"] = previous_keystats
				if not ok then error(err, 0) end
			end)
		end
	end
end)
