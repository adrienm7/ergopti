--- menu/engine/manifest_reader.lua

--- ==============================================================================
--- MODULE: Features Manifest Reader (Linux)
--- DESCRIPTION:
--- Binds the shared manifest reader (_shared/menu/engine/manifest_reader_core.lua) to this
--- driver: its logger and the generated manifest next to it. This is the Linux
--- counterpart of `macos/menu/engine/manifest_reader.lua` and
--- `windows/menu/engine/manifest_reader.ahk`.
---
--- WHY THIS MODULE EXISTS:
--- Linux was the only driver with no features manifest at all, so the Linux
--- keystats had nowhere to read the cross-driver privacy toggles from. That is
--- why it ran unconditionally, with no off switch and no private-browsing
--- filter, while the other two drivers read all four flags from the shared
--- manifest.
---
--- FEATURES & RATIONALE:
--- 1. cwd-independent load: the manifest is located relative to THIS file via
---    `debug.getinfo`, so it resolves identically under the daemon and the
---    headless test runner regardless of the working directory or
---    `package.path`.
--- 2. No platform default depends on this machine, so the shared reader runs
---    without resolution hooks.
--- ==============================================================================

local Logger = require("core.logger.engine.shim")
local NativePath = require("core.fs.engine.native_path")

-- linux/menu/engine/manifest_reader.lua -> linux -> _generated/features_manifest.lua.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local infra_dir = NativePath.dirname(source) or source
local driver_dir = NativePath.dirname(infra_dir) or infra_dir

return require("menu.engine.manifest_reader_core").new({
	logger = Logger,
	log = "menu.engine.manifest_reader",
	manifest_path = driver_dir .. "/_generated/features_manifest.lua",
})
