--- tests/unit/diagnostics/engine/reports/test_readable_report_contract.lua

--- ==============================================================================
--- MODULE: Readable Diagnostics Report Contract (macOS)
--- DESCRIPTION:
--- Replays the shared report vectors: the same readable English report as the
--- page and the Windows driver, and a large configuration cut on the bug link
--- only in its changed settings.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.diagnostics.report_contract")(helpers, require("core.text.engine.json"), helpers.shared(""))
