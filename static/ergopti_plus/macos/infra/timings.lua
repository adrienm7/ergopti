--- infra/timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader (Hammerspoon)
--- DESCRIPTION:
--- Binds the shared timings reader (_shared/lua/timings.lua) to this driver: its
--- logger, its shared-path resolver and its TOML parser. The registry,
--- `_shared/modules/timings/constants.toml`, is the single authoritative source
--- for every tunable timing in the project (debounces, timeouts, poll
--- intervals, ...), so the per-module literals can be deleted and the drivers
--- stay in sync.
---
--- FEATURES & RATIONALE:
--- 1. The lookup rules (fail fast on a missing file, section or key; seconds
---    and count helpers) live in the shared module, not here.
--- 2. The path comes from `Paths.shared`, so it resolves identically under
---    Hammerspoon and the headless test runner regardless of the working
---    directory.
---
--- USAGE:
---   local Timings = require("infra.timings")
---   local CHAIN_FALLBACK_SEC = Timings.sec("llm", "chain_fallback_ms")
---   local IDLE_CHECK_SEC = Timings.sec("keystats", "idle_check_interval_ms")
--- ==============================================================================

local Logger = require("infra.logger")
local Paths = require("infra.paths")
local TomlReader = require("infra.toml.reader")

return require("timings").new({
	logger = Logger,
	log = "timings",
	loaded_level = "done",
	shared_path = Paths.shared,
	parse = TomlReader.parse,
})
