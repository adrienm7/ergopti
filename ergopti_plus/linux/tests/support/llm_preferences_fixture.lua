--- tests/support/llm_preferences_fixture.lua

--- Isolates functional AI controls from the user's canonical configuration.
local M = {}
local Manifest = require("infra.manifest_reader")
local Fakes = require("tests.fakes")

--- Builds a sparse preference port; physical persistence has separate file tests.
--- @param options table|nil Initial values and refused-write switch.
--- @return table preferences
function M.new(options)
	options = options or {}
	local port = Fakes.storage(options)
	local write, remove = port.set, port.delete
	local revision = 0
	function port.generation() return revision end
	function port.admit() return true end
	function port.get_many(paths)
		local values = {}
		for _, path in ipairs(paths) do
			local value = port.get(path)
			if value == nil then value = Manifest.default_for(path) end
			values[path] = value
		end
		return values, { status = "ok", content = tostring(revision) }
	end
	function port.set(path, value)
		local operation = Manifest.sparse_operation(path, value)
		local committed
		if operation.delete then committed = remove(path) else committed = write(path, value) end
		if committed == true then revision = revision + 1 end
		return committed
	end
	function port.delete(path)
		local committed = remove(path)
		if committed == true then revision = revision + 1 end
		return committed
	end
	function port.set_many(values, expected_source, admission)
		if options.writes_fail then return false end
		if expected_source and expected_source.content ~= tostring(revision) then return false end
		local next_values = {}
		for key, value in pairs(port.values) do next_values[key] = value end
		for path, value in pairs(values) do
			local operation = Manifest.sparse_operation(path, value)
			if operation.delete then next_values[path] = nil else next_values[path] = value end
		end
		if admission ~= nil then
			if type(admission) ~= "function" then return false end
			local ok, allowed = pcall(admission)
			if not ok or allowed ~= true then return false end
		end
		port.values = next_values
		revision = revision + 1
		return true
	end
	return port
end

--- Temporarily replaces methods even for consumers holding the real module.
--- @param body function Functional test body.
--- @param options table|nil Initial values and refused-write switch.
function M.with(body, options)
	local preferences = require("infra.llm_preferences")
	local old_get, old_set, old_delete = preferences.get, preferences.set, preferences.delete
	local old_many = preferences.set_many
	local old_get_many = preferences.get_many
	local old_generation, old_admit = preferences.generation, preferences.admit
	local fake = M.new(options)
	preferences.get, preferences.set, preferences.delete = fake.get, fake.set, fake.delete
	preferences.set_many = fake.set_many
	preferences.get_many = fake.get_many
	preferences.generation, preferences.admit = fake.generation, fake.admit
	local ok, err = pcall(body, fake)
	preferences.get, preferences.set, preferences.delete = old_get, old_set, old_delete
	preferences.set_many = old_many
	preferences.get_many = old_get_many
	preferences.generation, preferences.admit = old_generation, old_admit
	if not ok then error(err, 0) end
end

--- Registers a test with isolated AI persistence.
--- @param name string Test description.
--- @param body function Functional test body.
function M.it(name, body)
	require("tests.helpers").it(name, function() M.with(body) end)
end

return M
