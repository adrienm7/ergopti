--- infra/timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader (Linux)
--- DESCRIPTION:
--- Binds the shared timings reader (_shared/lua/timings.lua) to this driver: its
--- logger, its shared-path resolver and the shared TOML parser. The registry,
--- `_shared/modules/timings/constants.toml`, is the single authoritative source
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
---   local Timings = require("infra.timings")
---   local SESSION_TIMEOUT_MS = Timings.ms("keystats", "session_timeout_ms")
--- ==============================================================================

local Logger = require("logger.shim")
local Paths = require("infra.paths")

-- A missing parser is a broken install: say so instead of a raw stack trace.
local ok_reader, Reader = pcall(require, "toml_codec.reader")
if not ok_reader then
	error("[timings] toml_codec.reader not available — is _shared/lua/ in package.path?")
end

return require("timings").new({
	logger = Logger,
	log = "timings",
	loaded_level = "info",
	shared_path = Paths.shared,
	parse = Reader.parse,
})
