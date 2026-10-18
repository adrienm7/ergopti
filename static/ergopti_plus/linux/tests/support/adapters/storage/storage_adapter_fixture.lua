--- tests/support/adapters/storage/storage_adapter_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_storage_adapter
--- DESCRIPTION:
--- Prelude shared by the test_storage_adapter_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a throwaway XDG config root under the system temp directory and
--- ensures its ergopti_plus/ subdirectory exists so the storage adapter can
--- write there instead of the developer's real config.
--- @return string Absolute path to inject as XDG_CONFIG_HOME.
local function make_temp_config_root()
	local base = os.tmpname()
	os.remove(base)
	base = base:gsub("\\", "/"):gsub("/+$", "")
	if package.config:sub(1, 1) == "\\" then
		os.execute(string.format('mkdir "%s" 2>nul', (base .. "/ergopti_plus"):gsub("/", "\\")))
	else
		os.execute(string.format('mkdir -p "%s"', base .. "/ergopti_plus"))
	end
	return base
end

--- Runs actual native files under an isolated XDG root and restores the fixture.
--- @param source string|nil Independent initial JSON bytes.
--- @param callback function
local function storage_cohort_fixture(source, callback)
	local root = make_temp_config_root()
	local path = root .. "/ergopti_plus/storage.json"
	local function write(name, bytes) local file = assert(io.open(name, "wb")); assert(file:write(bytes)); assert(file:close()) end
	local function read(name)
		local file = io.open(name, "rb"); if not file then return nil end
		local bytes = assert(file:read("*a")); assert(file:close()); return bytes
	end
	if source ~= nil then write(path, source) end
	local getenv, previous = os.getenv, package.loaded["adapters.storage"]
	os.getenv = function(name) if name == "XDG_CONFIG_HOME" then return root end; return getenv(name) end
	local okay, detail = xpcall(function()
		callback(helpers.load_module("adapters.storage"), require("adapters.file_system"), path, root .. "/snapshot", write, read)
	end, debug.traceback)
	os.getenv, package.loaded["adapters.storage"] = getenv, previous
	local Shell = require("adapters.shell_runner"); assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
	if not okay then error(detail, 0) end
end

-- These controls retain actual native Reader/Writer/FileSystem publication. The
-- wrapper changes only its terminal receipt after an independently observed file
-- effect; assertions run outside protected native callbacks.
local function ordinary_debt_fixture(mode, callback)
	storage_cohort_fixture('{"a":false,"future":0.1,"huge":9007199254740993}', function(storage, files, path, backup, write, read)
		local native = files.write_if_unchanged
		local state = { writes = 0, cleanups = 0, mode = mode, effect = true, native_effect = true }
		files.write_if_unchanged = function(name, content, expected)
			if name ~= path then return native(name, content, expected) end
			state.writes = state.writes + 1
			if state.native_effect then
				local result, detail = native(name, content, expected)
				if result ~= true then return result, detail end
			end
			if state.mode == "normal" then return true end
			if state.mode == "no_receipt" then return false, "unacknowledged native effect" end
			return false, "retained native cleanup", function()
				state.cleanups = state.cleanups + 1
				if state.observe then state.observe() end
				if state.mode == "raise" then error("native cleanup raised") end
				if state.mode == "refuse" then return false, "cleanup refused" end
				return true, nil, state.effect
			end
		end
		local okay, detail = xpcall(function() callback(storage, files, path, backup, write, read, state) end, debug.traceback)
		files.write_if_unchanged = native
		if not okay then error(detail, 0) end
	end)
end

return {
	helpers = helpers,
	make_temp_config_root = make_temp_config_root,
	storage_cohort_fixture = storage_cohort_fixture,
	ordinary_debt_fixture = ordinary_debt_fixture,
}
