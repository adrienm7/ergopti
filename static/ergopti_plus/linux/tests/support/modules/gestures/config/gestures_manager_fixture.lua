--- tests/support/modules/gestures/config/gestures_manager_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_gestures_manager
--- DESCRIPTION:
--- Prelude shared by the test_gestures_manager_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local TomlCodec = require("toml_codec")

-- Actual native catalogue identity, not runtime assignment presence, owns
-- retirement. Every file fixture is retained until explicit caller cleanup.
local function binding_source_fixture(source, test)
	local path = os.tmpname()
	local function write(content)
		local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
	end
	local function read()
		local file = assert(io.open(path, "rb")); local content = file:read("*a"); assert(file:close()); return content
	end
	write(source)
	local manager = helpers.load_module("modules.gestures.manager")
	local okay, detail = xpcall(function() test(manager, path, read, write) end, debug.traceback)
	pcall(os.remove, path)
	if not okay then error(detail, 0) end
end

return {
	helpers = helpers,
	TomlCodec = TomlCodec,
	binding_source_fixture = binding_source_fixture,
}
