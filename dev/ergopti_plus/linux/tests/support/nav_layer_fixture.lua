--- tests/support/nav_layer_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Recommended Navigation Fixture
--- DESCRIPTION:
--- Tests of recommended navigation import the shared preset explicitly. The
--- production engine never substitutes that preset for an absent user file.
--- ==============================================================================

local M = {}
local Layers = require("keymap.layers")
local Toml = require("toml_codec")
local Files = require("keymap.layer_editor")
local shared = require("tests.helpers").driver_root() .. "/../_shared"

--- Resolves and compiles the recommended keyboard layer for an engine fixture.
--- @return table layer Native evdev chord bindings.
function M.recommended()
	local ctx = Layers.load_context({ shared_root = shared, json_decode = require("json").decode,
		toml_decode = Toml.decode, read_file = Files.read_shipped })
	local preset = Layers.load(Files.read_shipped(shared .. "/keymap/layers.recommended.toml"), "linux", ctx, Toml.decode)
	assert(preset.ok, "the recommended navigation fixture must load without errors")
	return require("platform.remap.nav_layer").compile(preset.layers.nav, ctx.registry)
end

--- Imports the shared preset into an isolated manager configuration folder.
--- @param dir string The folder owned by the calling test.
function M.write(dir)
	local file = assert(io.open(dir .. "/layers.toml", "wb"))
	file:write(Files.read_shipped(shared .. "/keymap/layers.recommended.toml"))
	file:close()
end

return M
