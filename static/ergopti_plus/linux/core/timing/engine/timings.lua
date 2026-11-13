--- core/timing/engine/timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader (Linux)
--- DESCRIPTION:
--- Binds the shared timings reader (_shared/core/timing/engine/timings_core.lua) to this driver: its
--- logger, its shared-path resolver and the shared TOML parser. The registry,
--- `_shared/core/timing/data/constants.toml`, is the single authoritative source
--- for every tunable timing in the project (debounces, timeouts, poll
--- intervals, ...).
---
--- FEATURES & RATIONALE:
--- 1. The lookup rules (fail fast on a missing file, section or key; seconds
---    and count helpers) live in the shared module, not here.
--- 2. The path goes through `infra.paths`, never through the location of this
---    file: on an installed package the driver sits flat in /usr/lib/ergopti,
---    so counting path components looked for the file under /usr and the
---    daemon died on its first read.
---
--- USAGE:
---   local Timings = require("core.timing.engine.timings")
---   local SESSION_TIMEOUT_MS = Timings.ms("keystats", "session_timeout_ms")
--- ==============================================================================

local Logger = require("core.logger.engine.shim")
local Paths = require("core.fs.engine.paths")

-- A missing parser is a broken install: say so instead of a raw stack trace.
local ok_reader, Reader = pcall(require, "core.text.engine.toml_codec.reader")
if not ok_reader then
	error("[timings] core.text.engine.toml_codec.reader not available — is _shared/ in package.path?")
end

return require("core.timing.engine.timings_core").new({
	logger = Logger,
	log = "timings",
	loaded_level = "info",
	shared_path = Paths.shared,
	parse = Reader.parse,
})
