--- tests/support/metrics_preferences_fixture.lua

--- ==============================================================================
--- MODULE: Isolated Metrics Preferences Fixture
--- DESCRIPTION:
--- Replaces the canonical preference port for one functional test and restores
--- the exact methods afterward, including when a test throws. Physical TOML
--- persistence is exercised separately by the real-file preference contract.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")

--- Builds a sparse, in-memory canonical preference port.
--- @param options table|nil Initial values and refused-write switch.
--- @return table preferences
function M.new(options)
	options = options or {}
	local values = {}
	for key, value in pairs(options.initial or {}) do values[key] = value end
	local port = { values = values }
	function port.admit() return true end
	function port.snapshot()
		local snapshot = {}
		for _, entry in ipairs(Manifest.features()) do
			if entry.path:match("^metrics%.[^.]+$") and entry.type == "boolean" then
				local value = values[entry.path]
				assert(value == nil or type(value) == "boolean", "invalid metrics fixture value")
				if value == nil then value = Manifest.default_for(entry.path) end
				snapshot[entry.path] = value
			end
		end
		return snapshot
	end
	function port.get(key) return values[key] end
	function port.has(key) return values[key] ~= nil end
	function port.keys()
		local keys = {}
		for key in pairs(values) do keys[#keys + 1] = key end
		return keys
	end
	function port.set(key, value)
		if options.writes_fail then return false end
		assert(type(value) == "boolean", "metrics fixture requires a boolean")
		assert(port.snapshot()[key] ~= nil, "unknown metrics fixture key")
		if value == Manifest.default_for(key) then values[key] = nil else values[key] = value end
		return true
	end
	return port
end

--- Runs a body with isolated methods even for an already loaded collector.
--- @param body function Functional test body.
--- @param options table|nil Initial values and refused-write switch.
function M.with(body, options)
	local preferences = require("infra.metrics_preferences")
	local old_snapshot, old_get, old_set = preferences.snapshot, preferences.get, preferences.set
	local fake = M.new(options)
	preferences.snapshot = fake.snapshot
	preferences.get = function(key) return fake.snapshot()[key] end
	preferences.set = fake.set
	local ok, err = pcall(body, fake)
	preferences.snapshot, preferences.get, preferences.set = old_snapshot, old_get, old_set
	if not ok then error(err, 0) end
end

--- Registers one functional test that cannot read or write user preferences.
--- @param name string Test description.
--- @param body function Functional test body.
function M.it(name, body)
	require("tests.helpers").it(name, function() M.with(body) end)
end

return M
