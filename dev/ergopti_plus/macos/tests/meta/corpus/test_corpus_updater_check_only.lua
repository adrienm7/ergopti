--- tests/meta/corpus/test_corpus_updater_check_only.lua

--- ==============================================================================
--- MODULE: Updater Check-Only Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/updater/check_only_vectors.json: the public
--- releases Atom feed, read as a release list by updater.release_sources and
--- classified by updater.check_result. The Linux updater falls back on exactly
--- this path when api.github.com gives no list (macOS reads the same feed in its
--- own check and hands the install to Sparkle): an available release is flagged
--- check-only because the feed names no asset and no digest. Both suites replay
--- the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("hs").json

local corpus_dir = helpers.shared("tests/corpus/updater/")
local channels_path = helpers.shared("modules/updater/channels.json")

local function read(path)
	local handle = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

local corpus = Json.decode(read(corpus_dir .. "check_only_vectors.json"))

helpers.describe("updater check-only corpus: the public feed answer on macOS", function()
	helpers.it("corpus is readable and has cases", function()
		helpers.assert_true(type(corpus) == "table" and type(corpus.cases) == "table" and #corpus.cases > 0,
			"the corpus must hold cases")
	end)

	for _, case in ipairs(corpus.cases) do
		helpers.it("check-only vector " .. case.id, function()
			local ReleaseSources = require("updater.release_sources")
			local CheckResult = require("updater.check_result")
			local registry = assert(require("updater.channels").load(Json.decode(read(channels_path))))
			local list, reason = ReleaseSources.feed_release_list(read(corpus_dir .. corpus.feed), corpus.owner, corpus.repo)
			helpers.assert_true(list ~= nil, "the feed must give a list: " .. tostring(reason))
			local result = CheckResult.classify(list, {
				registry = registry, channel = case.channel, current = case.current,
				installed = case.installed, check_only = true,
			})
			helpers.assert_eq(result.state, case.state)
			helpers.assert_eq(result.latest, case.latest)
			helpers.assert_eq(result.check_only == true, case.check_only,
				"only an available release read from the feed is check-only")
		end)
	end
end)
