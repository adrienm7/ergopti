--- tests/unit/diagnostics/engine/reports/test_redact_work.lua

--- ==============================================================================
--- MODULE: Redaction Work Contract (macOS)
--- DESCRIPTION:
--- Replays the shared redaction work contract: the logger redacts every line, so
--- an unmatched line costs one fold and no rebuild, as on Linux.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.diagnostics.redact_work")(helpers, require("core.text.engine.json"), helpers.shared(""))
