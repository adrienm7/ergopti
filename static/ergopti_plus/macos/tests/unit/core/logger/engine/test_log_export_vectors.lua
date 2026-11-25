--- tests/unit/core/logger/engine/test_log_export_vectors.lua

--- ==============================================================================
--- MODULE: Log export replays the shared vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/logger/log_export_vectors.json, which the
--- Linux and Windows suites replay too, through core/logger/engine/log_export.lua
--- and the shared ZIP writer behind « Export the logs (zip) ».
---
--- ROOT CAUSE ENCODED:
--- Testers had to send dozens of log files by hand, and nothing kept their
--- typed text out of them. The one archive takes a fixed set of files and
--- copies each through the field report's privacy rules.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

require("tests.lua.core.log_export_contract")(helpers, json, helpers.shared(""))
