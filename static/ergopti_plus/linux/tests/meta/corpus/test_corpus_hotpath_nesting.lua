--- tests/meta/corpus/test_corpus_hotpath_nesting.lua

--- ==============================================================================
--- MODULE: Hot-path Nesting Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json
--- through the shared nesting tracker that infra/perf_counters.lua drives. The
--- macOS suite replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

local corpus_path = helpers.driver_root() .. "/../_shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json"
local handle = assert(io.open(corpus_path, "r"), "cannot open corpus at " .. corpus_path)
local text = handle:read("*a")
handle:close()

require("test.hotpath_nesting_replay").register(helpers, { driver = "linux", corpus = text })
