--- platform/remap/lease_helper.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Native Helper Resolution
--- DESCRIPTION:
--- Resolves the already-shipped ErgoptiPlus launcher executable that also owns
--- the headless Karabiner lease mode. Only the exact executable derived from the
--- application bundle containing this driver may cross the spawn boundary.
---
--- FEATURES & RATIONALE:
--- 1. Bundle-Bound Override: the launcher export is accepted only when it equals
---    the exact helper path derived independently from this bundled Lua tree.
--- 2. Bundle Derivation: direct launches of the embedded Hammerspoon still find
---    Contents/MacOS/ErgoptiPlus from the bundled Lua source path.
--- 3. Alias Rejection: symlinks, renamed wrappers, developer build artifacts and
---    stock Karabiner executables are never treated as process identity.
--- 4. Fail Closed: no shell watchdog fallback is selected when the native helper
---    is absent; the generation lease remains zero and rules stay inert.
--- ==============================================================================

local M = {}

local hs = hs
local HELPER_ENV = "ERGOPTI_LAUNCHER_EXECUTABLE"
local HELPER_DEVICE_ENV = "ERGOPTI_LAUNCHER_DEVICE"
local HELPER_INODE_ENV = "ERGOPTI_LAUNCHER_INODE"
local BUNDLE_CONFIG_SUFFIX = "/Contents/Resources/static/ergopti_plus/macos"
local HELPER_BASENAME = "ErgoptiPlus"
local MAX_EXACT_FLOAT_INTEGER = 9007199254740991

local function source_driver_root()
	local source = ((debug.getinfo(1, "S") or {}).source or ""):gsub("^@", "")
	return source:match("^(.*)[/\\]platform[/\\]remap[/\\][^/\\]+$")
end

local function basename(path)
	if type(path) ~= "string" then return nil end
	local trimmed = path:gsub("[/\\]+$", "")
	return trimmed:match("([^/\\]+)$")
end

--- Canonicalizes one non-negative integer filesystem identity component.
--- @param value any hs.fs `dev` or `ino` value.
--- @return string|nil canonical Decimal representation.
local function identity_component(value)
	if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then return nil end
	-- Lua 5.4 preserves lfs inode values as 64-bit integers. Formatting them as
	-- floats would silently round values above 2^53 and reject the real launcher.
	if type(math.type) == "function" and math.type(value) == "integer" then
		return tostring(value)
	end
	if value > MAX_EXACT_FLOAT_INTEGER then return nil end
	return string.format("%.0f", value)
end

--- Validates one canonical decimal component exported by the running launcher.
--- @param value any Environment value.
--- @return boolean valid
local function is_canonical_identity_text(value)
	return type(value) == "string"
		and (value == "0" or value:match("^[1-9]%d*$") ~= nil)
end

--- Proves that a candidate is the exact regular executable derived from the
--- containing application bundle, not a same-named alias or wrapper. Basename is
--- only a shape check; equality with the independently derived bundle path is the
--- authority that prevents a renamed stock Karabiner process from being spawned.
--- @param path string Candidate helper path.
--- @param expected_path string Exact bundle-derived helper path.
--- @param expected_device string Device exported by the running launcher.
--- @param expected_inode string Inode exported by the running launcher.
--- @return boolean valid
local function is_helper_executable(path, expected_path, expected_device, expected_inode)
	if type(path) ~= "string" or path == "" then return false end
	if type(expected_path) ~= "string" or path ~= expected_path then return false end
	if basename(path) ~= HELPER_BASENAME then return false end
	if not hs or type(hs.fs) ~= "table"
		or type(hs.fs.attributes) ~= "function"
		or type(hs.fs.symlinkAttributes) ~= "function"
		or type(hs.fs.pathToAbsolute) ~= "function" then
		return false
	end
	local lstat_ok, link_attributes = pcall(hs.fs.symlinkAttributes, path)
	if not lstat_ok or type(link_attributes) ~= "table"
		or link_attributes.mode ~= "file"
		or identity_component(link_attributes.dev) ~= expected_device
		or identity_component(link_attributes.ino) ~= expected_inode then
		return false
	end
	local ok, attributes = pcall(hs.fs.attributes, path)
	if not ok or type(attributes) ~= "table" or attributes.mode ~= "file"
		or type(attributes.permissions) ~= "string"
		or attributes.permissions:find("x", 1, true) == nil
		or identity_component(attributes.dev) ~= expected_device
		or identity_component(attributes.ino) ~= expected_inode then
		return false
	end
	local resolved_ok, resolved = pcall(hs.fs.pathToAbsolute, path)
	return resolved_ok and resolved == expected_path
end

local function bundle_candidate(driver_root)
	if type(driver_root) ~= "string" then return nil end
	if driver_root:sub(-#BUNDLE_CONFIG_SUFFIX) ~= BUNDLE_CONFIG_SUFFIX then return nil end
	local bundle_root = driver_root:sub(1, #driver_root - #BUNDLE_CONFIG_SUFFIX)
	if not bundle_root:match("%.app$") then return nil end
	return bundle_root .. "/Contents/MacOS/ErgoptiPlus"
end

--- Resolves one executable helper path without starting a process.
--- @param driver_root_override string|nil Test-only explicit source root; normal
---   callers omit it and use this module's own immutable source location.
--- @return string|nil path Existing native helper executable.
--- @return string|nil error_message Stable failure detail.
function M.resolve(driver_root_override)
	local driver_root = driver_root_override or source_driver_root()
	local bundled = bundle_candidate(driver_root)
	if not bundled then
		return nil, "native helper requires a bundled ErgoptiPlus driver tree"
	end

	local override = os.getenv(HELPER_ENV)
	local expected_device = os.getenv(HELPER_DEVICE_ENV)
	local expected_inode = os.getenv(HELPER_INODE_ENV)
	if type(override) ~= "string" or override == "" then
		return nil, "running launcher did not export its exact helper path"
	end
	if override ~= bundled then
		return nil, "ERGOPTI_LAUNCHER_EXECUTABLE differs from the bundle-owned helper"
	end
	if not is_canonical_identity_text(expected_device)
		or not is_canonical_identity_text(expected_inode) then
		return nil, "running launcher did not export a canonical helper file identity"
	end
	if is_helper_executable(bundled, bundled, expected_device, expected_inode) then return bundled end

	return nil, "bundle-owned ErgoptiPlus helper no longer matches the running launcher"
end

return M
