--- _shared/lua/llm/ollama_install_policy.lua

--- ==============================================================================
--- MODULE: Canonical Ollama Installation Policy
--- DESCRIPTION:
--- Projects the canonical release catalogue and generated application-folder
--- owner into immutable per-release names. Native filesystem, UID, executable
--- admission, consent and process lifecycle remain driver-owned capabilities.
--- ==============================================================================

local M = {}
local ASSETS = {
	linux = { x86_64 = "linux-amd64", amd64 = "linux-amd64", aarch64 = "linux-arm64", arm64 = "linux-arm64" },
	macos = { x86_64 = "macos-universal", arm64 = "macos-universal" },
	windows = { x86_64 = "windows-amd64", amd64 = "windows-amd64", aarch64 = "windows-arm64", arm64 = "windows-arm64" },
}

--- Validates one literal path segment without interpreting user filename bytes.
--- @param value any
--- @return boolean
local function segment(value)
	return type(value) == "string" and value ~= "" and value ~= "." and value ~= ".."
		and not value:find("/", 1, true) and not value:find("\0", 1, true)
end

--- Rejects traversal and ambiguous POSIX roots; only trailing slashes normalize.
--- @param path any
--- @return string|nil canonical
function M.canonical_posix_path(path)
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("\0", 1, true)
		or path:find("//", 1, true) then return nil end
	local normalized = path == "/" and path or path:gsub("/+$", "")
	for component in normalized:gmatch("[^/]+") do
		if not segment(component) then return nil end
	end
	return normalized
end

--- Copies one authoritative platform asset before any external predicate runs.
--- @param catalogue table Decoded canonical ollama_release.json.
--- @param platform string
--- @param architecture string Actual native architecture, not an environment hint.
--- @return table|nil snapshot { key, version, name, sha256, bytes, url }.
--- @return string|nil reason
function M.asset(catalogue, platform, architecture)
	local supported = ASSETS[platform]
	local key = supported and supported[architecture]
	if not key then return nil, "ollama_architecture_unavailable" end
	if type(catalogue) ~= "table" or rawget(catalogue, "schema_version") ~= 1 then return nil, "ollama_release_unreadable" end
	local version, assets = rawget(catalogue, "version"), rawget(catalogue, "assets")
	local source = type(assets) == "table" and rawget(assets, key) or nil
	if type(version) ~= "string" or not version:match("^%d+%.%d+%.%d+$") or type(source) ~= "table" then
		return nil, "ollama_release_unreadable"
	end
	local name, digest, bytes = rawget(source, "filename"), rawget(source, "sha256"), rawget(source, "bytes")
	if not segment(name) or not name:match("^ollama%-[%w%-]+%.[%w%.]+$")
		or type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$")
		or type(bytes) ~= "number" or bytes <= 0 or bytes % 1 ~= 0 then return nil, "ollama_release_unreadable" end
	return { key = key, version = version, name = name, sha256 = digest, bytes = bytes,
		url = "https://github.com/ollama/ollama/releases/download/v" .. version .. "/" .. name }
end

--- Chooses only a valid explicit XDG root or an actual absolute HOME fallback.
--- This policy deliberately does not inherit config_paths.home's TMPDIR fallback.
--- @param environment table Snapshot of XDG_DATA_HOME and HOME.
--- @return string|nil directory
--- @return string|nil reason
function M.data_root(environment)
	if type(environment) ~= "table" then return nil, "user_directories_unreadable" end
	local xdg, home = rawget(environment, "XDG_DATA_HOME"), rawget(environment, "HOME")
	if xdg ~= nil and xdg ~= "" then
		local directory = M.canonical_posix_path(xdg)
		if not directory then return nil, "xdg_data_home_invalid" end
		return directory
	end
	local directory = M.canonical_posix_path(home)
	if not directory then return nil, "user_home_unavailable" end
	return directory:gsub("/+$", "") .. "/.local/share"
end

--- Projects a versioned POSIX install target without writing or aliasing it.
--- The final /ollama preserves the independently qualified archive-file ABI.
--- @param environment table
--- @param app_dirs table Generated app_dirs owner.
--- @param asset table Canonical asset snapshot.
--- @return table|nil plan
--- @return string|nil reason
function M.posix_plan(environment, app_dirs, asset)
	local root, reason = M.data_root(environment)
	if not root then return nil, reason end
	local app = type(app_dirs) == "table" and rawget(app_dirs, "folder_name") or nil
	if not segment(app) then return nil, "application_directory_unreadable" end
	if type(asset) ~= "table" or not segment(asset.key) or type(asset.version) ~= "string"
		or not asset.version:match("^%d+%.%d+%.%d+$") or type(asset.sha256) ~= "string"
		or #asset.sha256 ~= 64 or not asset.sha256:match("^[0-9a-f]+$") then return nil, "ollama_release_unreadable" end
	local application = root:gsub("/+$", "") .. "/" .. app
	local runtime = application .. "/runtimes/ollama"
	local release = runtime .. "/" .. asset.version .. "-" .. asset.key .. "-" .. asset.sha256
	local directory = release .. "/ollama"
	return { data_root = root, application = application, runtime = runtime, parent = release,
		directory = directory, executable = directory .. "/bin/ollama", libraries = directory .. "/lib/ollama" }
end

return M
