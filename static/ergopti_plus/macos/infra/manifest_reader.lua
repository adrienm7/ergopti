--- infra/manifest_reader.lua

--- ==============================================================================
--- MODULE: Features Manifest Reader (Hammerspoon)
--- DESCRIPTION:
--- Binds the shared manifest reader (_shared/lua/manifest_reader.lua) to this
--- driver: its logger, the generated manifest next to it, and the resolution of
--- the one default that depends on this machine, the model backend. This is the
--- macOS counterpart of the AHK `infra/manifest_reader.ahk`: both read the
--- manifest at `_shared/modules/features/manifest.toml`, so the cross-driver
--- feature defaults are a genuine single source.
---
--- FEATURES & RATIONALE:
--- 1. cwd-independent load: the manifest is located relative to THIS file via
---    `debug.getinfo`, so it resolves identically under Hammerspoon and the
---    headless test runner regardless of the working directory or
---    `package.path`.
--- 2. Metadata and unrelated preferences must not perform native hardware
---    probes. Every value projection that includes the backend still resolves
---    the same owner, once.
--- ==============================================================================

local Logger = require("infra.logger")
local NativePath = require("native_path")

-- The backend default is hardware-derived: resolved on the first read that includes it.
local BACKEND_PATH = "llm.models.selected"
local platform_resolved = false

--- Resolves the platform backend into its manifest entry before a read that
--- includes it.
--- @param reader table The shared reader.
--- @param path string|nil The path about to be read; nil is every value.
local function resolve_platform(reader, path)
	if platform_resolved then return end
	if path ~= nil and path ~= BACKEND_PATH and BACKEND_PATH:sub(1, #path + 1) ~= path .. "." then return end
	local backend = require("modules.llm.backend_detector").auto_default()
	local entry = assert(reader.find_declared_entry_by_path(BACKEND_PATH), "platform backend declaration missing")
	entry.default, entry.recommended = backend, backend
	platform_resolved = true
end

--- Resolves the platform backend for every prefix a scope (and its includes) owns.
--- @param reader table The shared reader.
--- @param scope string Scope identifier.
--- @param direct_only boolean|nil True to skip the included scopes.
local function resolve_scope(reader, scope, direct_only)
	local declaration = reader.scope_declaration(scope)
	for _, prefix in ipairs(declaration.prefixes or {}) do resolve_platform(reader, prefix) end
	if not direct_only then
		for _, child in ipairs(declaration.includes or {}) do resolve_scope(reader, child) end
	end
end

-- macos/infra/manifest_reader.lua -> macos -> _generated/features_manifest.lua.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local infra_dir = NativePath.dirname(source) or source
local driver_dir = NativePath.dirname(infra_dir) or infra_dir

return require("manifest_reader").new({
	logger = Logger,
	log = "manifest_reader",
	manifest_path = driver_dir .. "/_generated/features_manifest.lua",
	resolve_path = resolve_platform,
	resolve_scope = resolve_scope,
})
