--- tests/support/modules/updater/check/updater_manager_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_updater_manager
--- DESCRIPTION:
--- Prelude shared by the test_updater_manager_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

local Installer = helpers.load_module("modules.updater.installer")

local Fs = helpers.load_module("adapters.file_system")

--- Authors native evidence for controlled responses independently of request options.
--- Each literal endpoint names one fixture representation, including bodyless 304s.
local function etag_response(result, endpoint, validator, conditional)
	result.etag_receipt = { format = "curl-etag-final-v1", effective_url = endpoint,
		validator = validator, associated = true, conditional_sent = conditional == true,
		sent_validator = conditional == true and validator or nil }
	return result
end

local Json = require("json")

--- Runs a body against a fresh manager bound to a temporary config.toml.
local function with_config(initial, body)
	local path = os.tmpname()
	pcall(os.remove, path)
	if initial then
		local handle = assert(io.open(path, "w"))
		handle:write(initial)
		handle:close()
	end
	local previous = package.loaded["modules.updater.manager"]
	package.loaded["modules.updater.manager"] = nil
	local fresh = require("modules.updater.manager")
	local ok, err = pcall(function()
		fresh.init({ config_path = path })
		fresh.stop_background_checks()
		body(fresh, path)
	end)
	fresh.stop_background_checks()
	package.loaded["modules.updater.manager"] = previous
	pcall(os.remove, path)
	if not ok then error(err, 0) end
end

local function read_config(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local decoded = require("toml_codec").decode(handle:read("*a"))
	handle:close()
	return decoded
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_ok(command)
	return Installer._status_ok(os.execute(command))
end

local function write_file(path, content)
	local handle = assert(io.open(path, "w"))
	handle:write(content)
	handle:close()
end

local function read_file(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

return {
	helpers = helpers,
	Fakes = Fakes,
	Installer = Installer,
	Fs = Fs,
	etag_response = etag_response,
	Json = Json,
	with_config = with_config,
	read_config = read_config,
	shell_quote = shell_quote,
	command_ok = command_ok,
	write_file = write_file,
	read_file = read_file,
}
