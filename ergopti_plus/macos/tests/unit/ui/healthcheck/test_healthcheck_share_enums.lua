--- tests/unit/ui/healthcheck/test_healthcheck_share_enums.lua

--- ==============================================================================
--- MODULE: Shared report enums cover the macOS values (macOS)
--- DESCRIPTION:
--- The shared report projects every enum field outside its schema list to the
--- field's default. A field report of 2026-10-29 read "Backend: unknown" with a
--- remote provider active and "Remapping engine: unknown" with a running lease:
--- the schema knew neither the "api" backend nor the lease controller's
--- "active" phase. These tests derive the values from the driver source, so a
--- new backend or lease phase cannot be shared as unknown again.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Reads one file whole.
--- @param path string
--- @return string
local function read_file(path)
	local fh = assert(io.open(path, "rb"), "cannot open " .. path)
	local body = fh:read("*a")
	fh:close()
	return body
end

--- Finds the enum descriptor of one field anywhere in the schema.
--- @param node any
--- @param field string
--- @return table|nil
local function find_enum(node, field)
	if type(node) ~= "table" then return nil end
	local candidate = node[field]
	if type(candidate) == "table" and candidate.kind == "enum" then return candidate end
	for _, child in pairs(node) do
		local found = find_enum(child, field)
		if found then return found end
	end
	return nil
end

--- Turns an enum descriptor's values into a set.
--- @param descriptor table
--- @return table
local function value_set(descriptor)
	local set = {}
	for _, value in ipairs(descriptor.values) do set[value] = true end
	return set
end

--- Collects every phase literal the lease controller can publish: set_phase()
--- arguments and the right-hand side of any *phase assignment.
--- @param source string
--- @return table phases Set of phase names.
local function lease_phases(source)
	local phases = {}
	for line in source:gmatch("[^\n]+") do
		local literal = line:match('set_phase%(%s*[%w_%.]+%s*,%s*"([%w_]+)"')
		if literal then phases[literal] = true end
		local rhs = line:match("phase%s*=%s*([^=].*)$")
		if rhs then
			local first = rhs:match('^%s*"([%w_]+)"')
			if first then phases[first] = true end
			for value in rhs:gmatch('%f[%w]and%s+"([%w_]+)"') do phases[value] = true end
			for value in rhs:gmatch('%f[%w]or%s+"([%w_]+)"') do phases[value] = true end
		end
	end
	return phases
end

helpers.describe("healthcheck: shared report enums", function()
	local schema = Json.decode(read_file(helpers.shared("modules/diagnostics/schema.json")))

	helpers.it("accepts every lease phase the controller publishes", function()
		local descriptor = find_enum(schema, "remap_phase")
		helpers.assert_not_nil(descriptor, "the schema declares remap_phase as an enum")
		local accepted = value_set(descriptor)
		local source = helpers.read_driver_source('local LOG = "karabiner.lease"')
		local phases = lease_phases(source)
		for _, known in ipairs({ "active", "paused", "fencing", "recovering", "uninitialized" }) do
			helpers.assert_true(phases[known] == true, "the source scan finds the phase " .. known)
		end
		for phase in pairs(phases) do
			helpers.assert_true(accepted[phase] == true,
				"the shared report must accept the lease phase " .. phase)
		end
	end)

	helpers.it("accepts every backend identifier of the detector", function()
		local descriptor = find_enum(schema, "ai_backend")
		helpers.assert_not_nil(descriptor, "the schema declares ai_backend as an enum")
		local accepted = value_set(descriptor)
		local source = helpers.read_driver_source('local LOG = "backend_detector"')
		local count = 0
		for backend in source:gmatch('M%.BACKEND_[%w_]+%s*=%s*"([%w_]+)"') do
			count = count + 1
			helpers.assert_true(accepted[backend] == true,
				"the shared report must accept the backend " .. backend)
		end
		helpers.assert_eq(count, 3, "the detector declares the mlx, ollama and api backends")
	end)
end)
