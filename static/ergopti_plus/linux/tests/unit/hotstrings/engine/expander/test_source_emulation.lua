--- tests/unit/hotstrings/engine/expander/test_source_emulation.lua

--- ==============================================================================
--- MODULE: Shared Layout Source Emulation
--- DESCRIPTION:
--- Replays the shared typing vectors of the layout source emulation (custom
--- modifiers, shortcuts, tap-holds) against the engine this driver and macOS
--- share; the web engine replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.source_emulation_contract").register(helpers, require("core.fs.engine.paths").shared)
