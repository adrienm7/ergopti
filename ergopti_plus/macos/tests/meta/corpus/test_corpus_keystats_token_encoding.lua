--- tests/meta/corpus/test_corpus_keystats_token_encoding.lua

--- ==============================================================================
--- MODULE: Keystats Token Encoding Corpus (macOS)
--- DESCRIPTION:
--- Runs the shared token encoding contract with the vectors decoded by the
--- shared decoder. The Linux suite runs the same one.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local handle = assert(io.open(helpers.shared("tests/corpus/keystats/token_encoding_vectors.json"), "rb"))
local vectors = assert(Json.decode(handle:read("*a")), "the token vectors must decode")
handle:close()

require("tests.lua.metrics.token_encoding_contract").register(helpers, { vectors = vectors })
