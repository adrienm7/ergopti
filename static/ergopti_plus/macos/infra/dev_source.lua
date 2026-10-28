--- infra/dev_source.lua

--- ==============================================================================
--- MODULE: Developer Source Mode
--- DESCRIPTION:
--- Answers whether this runtime belongs to a developer ErgoptiPlus.app that runs
--- the Lua of a repository clone (ERGOPTI_DEV_SOURCE=1 bash
--- tools/build/build_macos_app.sh), and resolves the few things such a runtime
--- still reads from its own application bundle.
---
--- FEATURES & RATIONALE:
--- 1. Launcher authority: only the launcher of a developer build exports the
---    clone root (Identifiers.dev_source.environment), and it removes any
---    inherited value, so a packaged runtime never receives one.
--- 2. Exact match: the root must name the clone this very driver runs from. A
---    root naming another tree is an invalid state and raises; the instance
---    admission then treats the process as foreign instead of guessing.
--- 3. Bundle-only natives: LuaSocket is staged by the build into the payload
---    (tools/build/bundle-macos-luasocket.sh) and is never in a clone. A
---    developer runtime loads exactly that module from its own payload; every
---    other module comes from the clone, so a deleted source file cannot be
---    silently replaced by a stale bundled copy.
--- 4. Pure resolution: the environment reader, the driver folder and the bundle
---    path are parameters, so every branch is tested without Hammerspoon.
--- ==============================================================================

local Identifiers = require("identifiers")

local M = {}

--- Environment variable naming the clone root, set only by a developer launcher.
M.ENVIRONMENT = Identifiers.dev_source.environment
--- The driver folder inside a clone or a bundle's Resources.
M.DRIVER_SUBPATH = "/static/ergopti_plus/macos"

-- The embedded runtime lives at <app>/Contents/Frameworks/Hammerspoon.app.
local EMBEDDED_RUNTIME_SUFFIX = "/Contents/Frameworks/Hammerspoon.app"
local LAUNCHER_SUFFIX = "/Contents/MacOS/" .. Identifiers.app.name
local PAYLOAD_SUFFIX = "/Contents/Resources" .. M.DRIVER_SUBPATH

-- The only modules a developer runtime takes from its payload, by module name,
-- with the payload-relative file and, for a native module, its entry point.
local PAYLOAD_MODULES = {
	["socket"] = { file = "/socket.lua" },
	["socket.core"] = { file = "/socket/core.so", entry = "luaopen_socket_core" },
}

-- Cached root of this process; false once resolved as "not a developer runtime".
local _resolved = nil





-- ==================================
-- ==================================
-- ======= 1/ Mode Resolution =======
-- ==================================
-- ==================================

--- The driver folder this module was loaded from (infra/ is one level below).
--- @return string|nil
local function own_driver_dir()
	local source = ((debug.getinfo(1, "S") or {}).source or ""):gsub("^@", "")
	return source:match("^(.*)/infra/[^/]+$")
end

--- Resolves the clone root of a developer runtime.
--- @param getenv function Environment reader.
--- @param driver_dir string|nil Absolute folder of the running driver.
--- @return string|nil root Clone root, or nil for an ordinary runtime.
function M.resolve(getenv, driver_dir)
	local root = getenv(M.ENVIRONMENT)
	if root == nil or root == "" then return nil end
	if type(root) ~= "string" or root:sub(1, 1) ~= "/" or root:sub(-1) == "/" then
		error(M.ENVIRONMENT .. " is not a plain absolute clone path", 0)
	end
	if driver_dir ~= root .. M.DRIVER_SUBPATH then
		error(string.format("%s names the clone %s, but this driver runs from %s",
			M.ENVIRONMENT, root, tostring(driver_dir)), 0)
	end
	return root
end

--- Returns the clone root of this process, or nil when it is not a developer runtime.
--- Raises when the launcher's root does not name the running driver.
--- @return string|nil root
function M.root()
	if _resolved == nil then _resolved = M.resolve(os.getenv, own_driver_dir()) or false end
	return _resolved or nil
end

--- Reports whether this process is a developer runtime.
--- @return boolean
function M.is_active()
	return M.root() ~= nil
end





-- ====================================
-- ====================================
-- ======= 2/ Bundle Resolution =======
-- ====================================
-- ====================================

--- Derives the launcher application root from the embedded runtime's bundle.
--- @param runtime_bundle string|nil hs.processInfo.bundlePath of the runtime.
--- @return string|nil app Absolute launcher .app path.
local function application_root(runtime_bundle)
	if type(runtime_bundle) ~= "string" or runtime_bundle:sub(-#EMBEDDED_RUNTIME_SUFFIX) ~= EMBEDDED_RUNTIME_SUFFIX then
		return nil
	end
	local app = runtime_bundle:sub(1, #runtime_bundle - #EMBEDDED_RUNTIME_SUFFIX)
	return app:match("%.app$") and app or nil
end

--- The launcher executable that owns a developer runtime: the driver tree is in
--- a clone, so it cannot be derived from the Lua source path.
--- @param runtime_bundle string|nil hs.processInfo.bundlePath of the runtime.
--- @return string|nil path Absolute Contents/MacOS launcher path.
function M.launcher_executable(runtime_bundle)
	local app = application_root(runtime_bundle)
	return app and app .. LAUNCHER_SUFFIX or nil
end

--- The payload driver folder of the developer app.
--- @param runtime_bundle string|nil hs.processInfo.bundlePath of the runtime.
--- @return string|nil path Absolute Contents/Resources driver folder.
function M.payload_driver_dir(runtime_bundle)
	local app = application_root(runtime_bundle)
	return app and app .. PAYLOAD_SUFFIX or nil
end

--- Builds the package searcher that loads the payload-only modules of a
--- developer app, and nothing else.
--- @param payload_dir string|nil Result of M.payload_driver_dir().
--- @param load_file function loadfile-compatible loader.
--- @param load_lib function package.loadlib-compatible loader.
--- @return function searcher package.searchers entry.
function M.payload_searcher(payload_dir, load_file, load_lib)
	return function(name)
		local module = PAYLOAD_MODULES[name]
		if not module then return nil end
		if type(payload_dir) ~= "string" then
			return "\n\tno developer app payload holds " .. name .. " (runtime bundle not recognised)"
		end
		local path = payload_dir .. module.file
		local loader, reason
		if module.entry then loader, reason = load_lib(path, module.entry)
		else loader, reason = load_file(path) end
		if type(loader) == "function" then return loader, path end
		return string.format("\n\tdeveloper app payload %s: %s", path, tostring(reason))
	end
end

return M
