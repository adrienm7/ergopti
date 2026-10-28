--- tests/unit/modules/keystats/aggregation/test_app_category_store_corpus.lua

--- ==============================================================================
--- MODULE: App Category Store Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays the shared app category store vectors
--- (_shared/tests/corpus/metrics/app_category_store_vectors.json) through the
--- shared codec with Hammerspoon's JSON library. The Linux suite replays the
--- same vectors with its own.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Corpus = require("test.app_category_store_corpus")

Corpus.register(helpers, {
	path = helpers.shared("tests/corpus/metrics/app_category_store_vectors.json"),
	decode = json.decode,
	encode = json.encode,
	label = "app category store vectors (macOS)",
})
