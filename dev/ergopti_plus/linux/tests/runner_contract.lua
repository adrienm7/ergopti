--- tests/runner_contract.lua

--- ==============================================================================
--- MODULE: Linux Test Runner Integrity Contract
--- DESCRIPTION:
--- Validates discovery against an explicit module manifest and rejects runs that
--- execute no assertions. Kept independent from run.lua so the runner's own
--- failure decisions can be regression-tested without spawning a nested suite.
--- ==============================================================================

local M = {}

local function indexed_set(values, label)
	if type(values) ~= "table" then return nil, label .. " is not a table" end
	local set = {}
	for index, value in ipairs(values) do
		if type(value) ~= "string" or value == "" then
			return nil, string.format("%s entry %d is not a module name", label, index)
		end
		if set[value] then return nil, label .. " contains duplicate " .. value end
		set[value] = true
	end
	return set
end

--- Compares discovered modules with the checked manifest exactly.
--- @param discovered table|nil
--- @param expected table
--- @param discovery_error string|nil
--- @return boolean ok
--- @return string|nil error_message
function M.audit_manifest(discovered, expected, discovery_error)
	if discovery_error then return false, "test discovery failed: " .. tostring(discovery_error) end
	local discovered_set, discovered_error = indexed_set(discovered, "discovery")
	if not discovered_set then return false, discovered_error end
	local expected_set, expected_error = indexed_set(expected, "manifest")
	if not expected_set then return false, expected_error end
	if #expected == 0 then return false, "test manifest is empty" end

	for _, module_name in ipairs(expected) do
		if not discovered_set[module_name] then
			return false, "manifest module was not discovered: " .. module_name
		end
	end
	for _, module_name in ipairs(discovered) do
		if not expected_set[module_name] then
			return false, "discovered module is absent from manifest: " .. module_name
		end
	end
	return true
end

--- Loads every manifested module and retains each individual failure.
--- @param modules table
--- @param loader function
--- @return integer attempted
--- @return table errors Array of { module, error }.
function M.load_modules(modules, loader)
	local errors = {}
	for _, module_name in ipairs(modules) do
		local ok, load_error = pcall(loader, module_name)
		if not ok then
			errors[#errors + 1] = { module = module_name, error = tostring(load_error) }
		end
	end
	return #modules, errors
end

--- Rejects an assertion-free run, including an unmatched --only filter.
--- @param total_modules integer
--- @param passed integer
--- @param failed integer
--- @param only_filter string|nil
--- @return boolean ok
--- @return string|nil error_message
function M.audit_execution(total_modules, passed, failed, only_filter)
	if type(total_modules) ~= "number" or total_modules < 1 then
		return false, "no test module was loaded"
	end
	local executed = (tonumber(passed) or 0) + (tonumber(failed) or 0)
	if executed < 1 then
		if only_filter then
			return false, string.format("--only filter matched no test: %q", only_filter)
		end
		return false, "test modules loaded but no assertion executed"
	end
	return true
end

return M
