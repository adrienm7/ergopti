--- tests/unit/modules/keystats/core/test_app_category_store_corpus.lua

--- ==============================================================================
--- MODULE: App Category Store Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays the shared app category store vectors
--- (_shared/tests/corpus/metrics/app_category_store_vectors.json) through the
--- shared codec with the Linux JSON library. The macOS suite replays the same
--- vectors with Hammerspoon's.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Corpus = require("test.app_category_store_corpus")

Corpus.register(helpers, {
	path = helpers.driver_root() .. "/../_shared/tests/corpus/metrics/app_category_store_vectors.json",
	decode = Json.decode,
	encode = Json.encode,
	label = "app category store vectors (Linux)",
})
