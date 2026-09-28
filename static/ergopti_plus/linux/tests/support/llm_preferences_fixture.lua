--- tests/support/llm_preferences_fixture.lua

--- Isolates functional AI controls from the user's canonical configuration.
local M = {}
local Manifest = require("infra.manifest_reader")
local Fakes = require("tests.fakes")

--- Builds a sparse preference port; physical persistence has separate file tests.
--- @param options table|nil Initial values and refused-write switch.
--- @return table preferences
function M.new(options)
	local port = Fakes.storage(options)
	local write, remove = port.set, port.delete
	function port.set(path, value)
		local operation = Manifest.sparse_operation(path, value)
		if operation.delete then return remove(path) end
		return write(path, value)
	end
	return port
end

--- Temporarily replaces methods even for consumers holding the real module.
--- @param body function Functional test body.
--- @param options table|nil Initial values and refused-write switch.
function M.with(body, options)
	local preferences = require("infra.llm_preferences")
	local old_get, old_set, old_delete = preferences.get, preferences.set, preferences.delete
	local fake = M.new(options)
	preferences.get, preferences.set, preferences.delete = fake.get, fake.set, fake.delete
	local ok, err = pcall(body, fake)
	preferences.get, preferences.set, preferences.delete = old_get, old_set, old_delete
	if not ok then error(err, 0) end
end

--- Registers a test with isolated AI persistence.
--- @param name string Test description.
--- @param body function Functional test body.
function M.it(name, body)
	require("tests.helpers").it(name, function() M.with(body) end)
end

return M
