--- platform/remap/lease_helper.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Native Helper Resolution
--- DESCRIPTION:
--- Resolves the already-shipped ErgoptiPlus launcher executable that also owns
--- the headless Karabiner lease mode. Only the exact executable derived from the
--- application bundle containing this driver may cross the spawn boundary.
---
--- FEATURES & RATIONALE:
--- 1. Bundle-Bound Override: the launcher export is accepted only when it is the
---    same regular file as the helper derived independently from this bundled
---    Lua tree, proved by file identity rather than by spelling (MLC-005).
--- 2. Bundle Derivation: direct launches of the embedded Hammerspoon still find
---    Contents/MacOS/ErgoptiPlus from the bundled Lua source path. A developer
---    app runs a clone, so its helper is derived from the runtime's own bundle.
--- 3. Alias Rejection: symlinks, renamed wrappers, developer build artifacts and
---    stock Karabiner executables are never treated as process identity.
--- 4. Fail Closed: no shell watchdog fallback is selected when the native helper
---    is absent; the generation lease remains zero and rules stay inert.
--- ==============================================================================

local M = {}

local hs = hs
local NativePath = require("core.fs.engine.native_path")
local DevSource = require("infra.dev_source")
local HELPER_ENV = "ERGOPTI_LAUNCHER_EXECUTABLE"
local HELPER_DEVICE_ENV = "ERGOPTI_LAUNCHER_DEVICE"
local HELPER_INODE_ENV = "ERGOPTI_LAUNCHER_INODE"
local BUNDLE_CONFIG_SUFFIX = "/Contents/Resources/static/ergopti_plus/macos"
local HELPER_BASENAME = "ErgoptiPlus"
local MAX_EXACT_FLOAT_INTEGER = 9007199254740991

local function source_driver_root()
	local source = ((debug.getinfo(1, "S") or {}).source or ""):gsub("^@", "")
	local remap = NativePath.dirname(source)
	local platform = remap and NativePath.basename(remap) == "remap" and NativePath.dirname(remap) or nil
	if not platform or NativePath.basename(platform) ~= "platform" then return nil end
	return NativePath.dirname(platform)
end

local function basename(path)
	if type(path) ~= "string" then return nil end
	return NativePath.basename(NativePath.without_trailing_separators(path))
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

--- Reads one path's own file identity without following a final symlink.
--- @param path string
--- @return string|nil device, string|nil inode Nil unless a regular file.
local function regular_file_identity(path)
	local ok, attributes = pcall(hs.fs.symlinkAttributes, path)
	if not ok or type(attributes) ~= "table" or attributes.mode ~= "file" then return nil end
	return identity_component(attributes.dev), identity_component(attributes.ino)
end

--- Proves that the launcher's exported path and the bundle-derived path name
--- the same regular executable, the one the running launcher exported the file
--- identity of. The proof is the file identity, not the spelling: Hammerspoon
--- loads init.lua under a resolved path (/private/var for a translocated app, the
--- target of a symlinked Applications folder) and an accented folder may reach
--- each side in another Unicode form, while Foundation exports the launcher's
--- own spelling (MLC-005). A symlink at the helper itself, a renamed wrapper, a
--- replaced file and a path resolving to another program are still refused.
--- @param override string Path the running launcher exported.
--- @param bundled string Helper path derived from this driver's bundle.
--- @param expected_device string Device exported by the running launcher.
--- @param expected_inode string Inode exported by the running launcher.
--- @return boolean valid
local function is_helper_executable(override, bundled, expected_device, expected_inode)
	if type(override) ~= "string" or override == "" or type(bundled) ~= "string" or bundled == "" then
		return false
	end
	if basename(override) ~= HELPER_BASENAME or basename(bundled) ~= HELPER_BASENAME then return false end
	if not hs or type(hs.fs) ~= "table"
		or type(hs.fs.attributes) ~= "function"
		or type(hs.fs.symlinkAttributes) ~= "function"
		or type(hs.fs.pathToAbsolute) ~= "function" then
		return false
	end
	for _, path in ipairs({ override, bundled }) do
		local device, inode = regular_file_identity(path)
		if device ~= expected_device or inode ~= expected_inode then return false end
	end
	local ok, attributes = pcall(hs.fs.attributes, bundled)
	if not ok or type(attributes) ~= "table" or attributes.mode ~= "file"
		or type(attributes.permissions) ~= "string"
		or attributes.permissions:find("x", 1, true) == nil
		or identity_component(attributes.dev) ~= expected_device
		or identity_component(attributes.ino) ~= expected_inode then
		return false
	end
	-- Whatever folders lead to it, the file must sit in an application bundle's
	-- executable folder under the helper's name.
	local resolved_ok, resolved = pcall(hs.fs.pathToAbsolute, bundled)
	return resolved_ok and type(resolved) == "string"
		and resolved:match("%.app/Contents/MacOS/" .. HELPER_BASENAME .. "$") ~= nil
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
--- @return table|nil environment Exact identity to copy into this helper process.
function M.resolve(driver_root_override)
	local bundled
	-- A developer app runs a clone (infra/dev_source.lua): its helper is derived
	-- from the native runtime bundle instead, then proved exactly as below.
	local dev_ok, dev_root = pcall(DevSource.root)
	if not dev_ok then return nil, "developer source root refused: " .. tostring(dev_root) end
	if dev_root and not driver_root_override then
		bundled = DevSource.launcher_executable(hs and hs.processInfo and hs.processInfo.bundlePath)
		if not bundled then
			return nil, "developer runtime is not inside an ErgoptiPlus application bundle"
		end
	else
		bundled = bundle_candidate(driver_root_override or source_driver_root())
	end
	if not bundled then
		return nil, "native helper requires a bundled ErgoptiPlus driver tree"
	end

	local override = os.getenv(HELPER_ENV)
	local expected_device = os.getenv(HELPER_DEVICE_ENV)
	local expected_inode = os.getenv(HELPER_INODE_ENV)
	if type(override) ~= "string" or override == "" then
		return nil, "running launcher did not export its exact helper path"
	end
	if not is_canonical_identity_text(expected_device)
		or not is_canonical_identity_text(expected_inode) then
		return nil, "running launcher did not export a canonical helper file identity"
	end
	if is_helper_executable(override, bundled, expected_device, expected_inode) then
		-- The launcher's own spelling: it is the path it exported to this child.
		return override, nil, {
			[HELPER_ENV] = override,
			[HELPER_DEVICE_ENV] = expected_device,
			[HELPER_INODE_ENV] = expected_inode,
		}
	end

	return nil, "ERGOPTI_LAUNCHER_EXECUTABLE is not the bundle-owned helper the running launcher identified"
end

return M
