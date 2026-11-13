--- tests/unit/modules/diagnostics/test_crash_report_contract.lua

--- ==============================================================================
--- MODULE: Crash Report Contract (macOS)
--- DESCRIPTION:
--- Replays the shared crash report vectors: the same document, file names and
--- retention cap as Linux (parity audit D6, R31).
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.diagnostics.crash_report_contract")(helpers, require("core.text.engine.json"), helpers.shared(""))
