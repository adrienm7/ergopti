--- modules/llm/ollama_binary.lua

--- ==============================================================================
--- MODULE: Ollama Executable Resolver
--- DESCRIPTION:
--- Resolves the one Ollama executable used by every API, menu, and bootstrap
--- path. The app no longer bundles Ollama, so the resolver looks for an
--- source-bound optional install hint, then the official Ollama.app (system
--- then user Applications), Homebrew, the copy Ergopti downloads on demand
--- into its own Application Support folder, then PATH.
---
--- FEATURES & RATIONALE:
--- 1. Stock candidates use one filesystem attribute
---    read. Optional runtime metadata is a provisional hint; the native server
---    owner independently verifies its actual catalogue, bytes and signature.
--- 2. Optional metadata is received asynchronously; cheap attributes invalidate
---    its provisional cache. Source admission always runs again in Python.
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
M.SOURCE_NATIVE_MANAGED = "native_managed"





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

--- Returns the optional source-qualified runtime's native install directory.
--- @return string|nil directory Native owned location, not a trust statement.
function M.native_managed_install_dir()
	local home = home_directory()
	return home and home .. "/Library/Application Support/Ergopti/ollama-native-http" or nil
end

--- Receives only a provisional installed-receipt hint for the native runtime.
--- The real server owner repeats byte, catalogue, signature and image admission.
--- @return string|nil executable Candidate with matched current metadata.
--- @return table|nil budgets Existing retry owner values.
--- @return string|nil state Exact pending task state.
function M.native_candidate()
	local directory = M.native_managed_install_dir()
	if not directory then return nil end
	local source = debug.getinfo(1, "S").source:sub(2)
	local driver = source:match("^(.*)/modules/llm/ollama_binary%.lua$")
	if not driver then return nil end
	local hint, state = require("adapters.managed_ollama_hint").get(directory, driver)
	if not hint then return nil, nil, state end
	return is_executable_file(hint.candidate) and hint.candidate or nil, hint.budgets
end

--- Resolve stock candidates live, or receive an asynchronously invalidated hint.
--- @return string|nil executable_path
--- @return string|nil error_message
--- @return string|nil source One of the SOURCE_* identifiers.
function M.resolve()
	local native, _, state = M.native_candidate()
	if native then return native, nil, M.SOURCE_NATIVE_MANAGED end
	if state == "pending" then return nil, "managed runtime metadata is pending", nil end
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
