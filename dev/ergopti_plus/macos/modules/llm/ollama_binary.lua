--- modules/llm/ollama_binary.lua

--- ==============================================================================
--- MODULE: Ollama Executable Resolver
--- DESCRIPTION:
--- Resolves the one Ollama executable used by every API, menu, and bootstrap
--- path. The app no longer bundles Ollama, so the resolver looks for an
--- existing installation in a fixed order: the official Ollama.app (system
--- then user Applications), Homebrew, the copy Ergopti downloads on demand
--- into its own Application Support folder, then PATH.
---
--- FEATURES & RATIONALE:
--- 1. Stat-only probes: every candidate is checked with one filesystem
---    attribute read, never with a subprocess, so building the AI menu or
---    selecting a backend cannot stall the main run loop.
--- 2. No cache: a removal or a fresh install is observed on the next call.
--- 3. Single owner: the on-demand installer receives its target folder from
---    managed_install_dir(), so the download lands exactly where this resolver
---    looks for it.
--- 4. No configured override: the configuration has no Ollama path setting,
---    so the resolver starts with the official application bundle.
--- ==============================================================================

local M = {}

local hs = hs

local EXECUTABLE_NAME = "ollama"

-- The official Ollama.app keeps its CLI beside the runtime libraries in
-- Contents/Resources (ollama/ollama scripts/build_darwin.sh).
local APP_BUNDLE_CLI = "Ollama.app/Contents/Resources/" .. EXECUTABLE_NAME

local HOMEBREW_CANDIDATES = {
	"/opt/homebrew/bin/" .. EXECUTABLE_NAME,
	"/usr/local/bin/" .. EXECUTABLE_NAME,
}

-- Relative to HOME. Shares the Application Support folder of the MLX runtime
-- (ensure-mlx-deps.sh) so every downloaded AI runtime lives in one place.
local MANAGED_RELATIVE_DIR = "Library/Application Support/Ergopti/ollama"

-- Official download page offered when the user prefers a manual install.
M.DOWNLOAD_PAGE_URL = "https://ollama.com/download"

M.SOURCE_APP = "app"
M.SOURCE_USER_APP = "user_app"
M.SOURCE_HOMEBREW = "homebrew"
M.SOURCE_MANAGED = "managed"
M.SOURCE_PATH = "path"





-- ==========================================
-- ==========================================
-- ======= 1/ Filesystem Probes ==============
-- ==========================================
-- ==========================================

--- Checks the file shape without launching a shell or trusting existence alone.
--- @param path string Candidate executable path.
--- @return boolean executable
local function is_executable_file(path)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then return false end
	if not hs or type(hs.fs) ~= "table" or type(hs.fs.attributes) ~= "function" then return false end
	local ok, attributes = pcall(hs.fs.attributes, path)
	return ok and type(attributes) == "table"
		and attributes.mode == "file"
		and type(attributes.permissions) == "string"
		and attributes.permissions:find("x", 1, true) ~= nil
end

--- Reads HOME as an absolute path.
--- @return string|nil home
local function home_directory()
	local ok, home = pcall(os.getenv, "HOME")
	if not ok or type(home) ~= "string" or home:sub(1, 1) ~= "/" then return nil end
	return (home:gsub("/+$", ""))
end




-- =========================================
-- =========================================
-- ======= 2/ Candidate Order ==============
-- =========================================
-- =========================================

--- Returns the folder the on-demand installer publishes Ollama into.
--- @return string|nil directory Absolute folder, or nil without a usable HOME.
function M.managed_install_dir()
	local home = home_directory()
	if not home then return nil end
	return home .. "/" .. MANAGED_RELATIVE_DIR
end

--- Returns the executable the on-demand installer publishes.
--- @return string|nil path
function M.managed_executable_path()
	local directory = M.managed_install_dir()
	if not directory then return nil end
	return directory .. "/" .. EXECUTABLE_NAME
end

--- Lists every candidate in resolution order, without probing any of them.
--- @return table candidates Array of { path = string, source = string }.
function M.candidates()
	local list = {}
	local function add(path, source)
		if type(path) == "string" and path ~= "" then
			list[#list + 1] = { path = path, source = source }
		end
	end
	local home = home_directory()
	add("/Applications/" .. APP_BUNDLE_CLI, M.SOURCE_APP)
	if home then add(home .. "/Applications/" .. APP_BUNDLE_CLI, M.SOURCE_USER_APP) end
	for _, candidate in ipairs(HOMEBREW_CANDIDATES) do add(candidate, M.SOURCE_HOMEBREW) end
	add(M.managed_executable_path(), M.SOURCE_MANAGED)
	local path_ok, raw_path = pcall(os.getenv, "PATH")
	if path_ok and type(raw_path) == "string" then
		for directory in raw_path:gmatch("[^:]+") do
			if directory:sub(1, 1) == "/" then
				add(directory:gsub("/+$", "") .. "/" .. EXECUTABLE_NAME, M.SOURCE_PATH)
			end
		end
	end
	return list
end




-- ===================================
-- ===================================
-- ======= 3/ Resolution =============
-- ===================================
-- ===================================

--- Resolves Ollama without a cache so removal/replacement is observed promptly.
--- @return string|nil executable_path
--- @return string|nil error_message
--- @return string|nil source One of the SOURCE_* identifiers.
function M.resolve()
	local seen = {}
	for _, candidate in ipairs(M.candidates()) do
		if not seen[candidate.path] then
			seen[candidate.path] = true
			if is_executable_file(candidate.path) then
				return candidate.path, nil, candidate.source
			end
		end
	end
	return nil, "no executable Ollama binary was found", nil
end

return M
