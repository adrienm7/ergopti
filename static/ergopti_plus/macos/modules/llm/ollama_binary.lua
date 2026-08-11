--- modules/llm/ollama_binary.lua

--- ==============================================================================
--- MODULE: Ollama Executable Resolver
--- DESCRIPTION:
--- Resolves the one Ollama executable used by every API, menu, and bootstrap
--- path. A launcher-owned bundle path is authoritative and fails closed when
--- invalid; standalone Hammerspoon sessions fall back to executable files in
--- the standard Homebrew locations and then PATH.
--- ==============================================================================

local M = {}

local hs = hs

local BUNDLED_BIN_ENV = "ERGOPTI_OLLAMA_BIN"
local SYSTEM_CANDIDATES = {
	"/opt/homebrew/bin/ollama",
	"/usr/local/bin/ollama",
}

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

--- Resolves Ollama without a cache so removal/replacement is observed promptly.
--- @return string|nil executable_path
--- @return string|nil error_message
--- @return boolean managed_override_present
function M.resolve()
	local env_ok, bundled = pcall(os.getenv, BUNDLED_BIN_ENV)
	if not env_ok then
		return nil, "could not read " .. BUNDLED_BIN_ENV, true
	end
	if bundled ~= nil and bundled ~= "" then
		if is_executable_file(bundled) then return bundled, nil, true end
		return nil, BUNDLED_BIN_ENV .. " is not an executable absolute file", true
	end

	local seen = {}
	local function accept(path)
		if seen[path] then return nil end
		seen[path] = true
		if is_executable_file(path) then return path end
		return nil
	end

	for _, candidate in ipairs(SYSTEM_CANDIDATES) do
		local resolved = accept(candidate)
		if resolved then return resolved, nil, false end
	end

	local path_ok, raw_path = pcall(os.getenv, "PATH")
	if path_ok and type(raw_path) == "string" then
		for directory in raw_path:gmatch("[^:]+") do
			if directory:sub(1, 1) == "/" then
				local resolved = accept(directory:gsub("/+$", "") .. "/ollama")
				if resolved then return resolved, nil, false end
			end
		end
	end

	return nil, "no executable Ollama binary was found", false
end

return M
