--- tests/meta/corpus/test_corpus_hotpath_nesting.lua

--- ==============================================================================
--- MODULE: Hot-path Nesting Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json
--- through the shared nesting tracker that metrics/engine/perf/hotpath_profiler.lua drives.
--- The Linux suite replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

local corpus_path = helpers.shared("tests/corpus/diagnostics/hotpath_nesting_vectors.json")
local handle = assert(io.open(corpus_path, "r"), "cannot open corpus at " .. corpus_path)
local text = handle:read("*a")
handle:close()

require("tests.lua.core.hotpath_nesting_replay").register(helpers, { driver = "macos", corpus = text })
