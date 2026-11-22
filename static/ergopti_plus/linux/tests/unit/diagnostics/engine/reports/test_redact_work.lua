--- tests/unit/diagnostics/engine/reports/test_redact_work.lua

--- ==============================================================================
--- MODULE: Redaction Work Contract (Linux)
--- DESCRIPTION:
--- Replays the shared redaction work contract: the logger sink redacts every
--- line, so an unmatched line costs one fold and no rebuild, as on macOS.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.diagnostics.redact_work")(helpers, require("core.text.engine.json"), helpers.driver_root() .. "/../_shared")
