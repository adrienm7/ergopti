--- modules/llm/ollama_binary.lua

--- ==============================================================================
--- MODULE: Ollama Executable Resolver
--- DESCRIPTION:
--- Resolves the one Ollama executable used by every API, menu, and bootstrap
--- path: Ergopti's own pinned runtime (owned-runtimes row "Ollama", decision
--- PIN). A user's own Ollama (the app, Homebrew, PATH) is not looked for: it
--- is never selected, started, stopped or modified.
---
--- FEATURES & RATIONALE:
--- 1. Optional runtime metadata is a provisional hint received asynchronously;
---    the native server owner independently verifies its actual catalogue,
---    bytes and signature, and source admission always runs again in Python.
--- 2. No configured override: the configuration has no Ollama path setting.
--- ==============================================================================

local M = {}

local hs = hs

-- The one source the resolver names.
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





-- ===================================
-- ===================================
-- ======= 2/ Resolution =============
-- ===================================
-- ===================================

--- Returns the optional source-qualified runtime's native install directory.
--- @return string|nil directory Native owned location, not a trust statement.
function M.native_managed_install_dir()
	local home = home_directory()
	return home and home .. "/" .. require("core.fs.engine.app_dirs").macos.support_relative .. "/ollama-native-http" or nil
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

--- Resolves the one Ollama Ergopti uses: its own pinned runtime. A user's own
--- Ollama is never looked for, selected, started, stopped or modified, even
--- when it is installed and running (maintainer decision, issue #104).
--- @return string|nil executable_path
--- @return string|nil error_message
--- @return string|nil source SOURCE_NATIVE_MANAGED, or nil.
function M.resolve()
	local native, _, state = M.native_candidate()
	if native then return native, nil, M.SOURCE_NATIVE_MANAGED end
	if state == "pending" then return nil, "managed runtime metadata is pending", nil end
	return nil, "Ergopti's own Ollama runtime is not installed", nil
end

--- Returns the Ollama version Ergopti pins for its own runtime, from the one
--- source the native installer verifies (managed_ollama_runtime.json).
--- @return string version
function M.pinned_version()
	local source = debug.getinfo(1, "S").source:sub(2)
	local driver = assert(source:match("^(.*)/modules/llm/ollama_binary%.lua$"), "driver root unavailable")
	local text, status = require("core.fs.adapters.file_system").read_with_status(
		driver .. "/../_shared/ai/data/managed_ollama_runtime.json")
	assert(status == "ok" and type(text) == "string", "managed Ollama runtime contract is unreadable")
	local decoded = require("core.text.engine.json").decode(text)
	assert(type(decoded) == "table" and type(decoded.version) == "string"
		and decoded.version:match("^%d+%.%d+%.%d+$"), "managed Ollama runtime contract names no version")
	return decoded.version
end

return M
