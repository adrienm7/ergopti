--- tests/e2e/boot/native_input_sources.lua

--- ==============================================================================
--- MODULE: Native Input-Source Selection Model
--- DESCRIPTION:
--- Models the launcher's typed selection roles against one retained inventory.
--- Only native API edges are replaced: the installed driver's resolver, task
--- ownership, menu actions and completion handling remain production code.
--- This is a headless contract model, not native Carbon qualification.
--- ==============================================================================

local M = {}

--- Matches the native argv boundary for an input-source identifier or name.
--- @param value any Native argument candidate.
--- @return boolean valid
local function valid_identifier(value)
	return type(value) == "string" and value ~= "" and #value <= 1024 and not value:find("\0", 1, true)
end

--- Resolves a selection in one inventory, preserving native stdout and exit status.
--- @param args table Native argv without the executable.
--- @param sources table Ordered { key, source_id, localised } inventory records.
--- @param environment table Environment assigned to this task.
--- @param launcher_environment table Identity exported by the running launcher.
--- @param selection_status number|nil Carbon acceptance status, zero by default.
--- @return table answer Native { code, stdout } result.
--- @return table|nil observation Model evidence, never injected into native stdout.
function M.answer(args, sources, environment, launcher_environment, selection_status)
	local by_name = args[1] == "--select-input-source-by-name"
	if (not by_name and args[1] ~= "--select-input-source") or #args ~= (by_name and 3 or 2)
		or not valid_identifier(args[2]) or (by_name and not valid_identifier(args[3])) then
		return { code = 64 }
	end
	local observation = { role = args[1], environment = true }
	-- Lua proves helper identity before spawn; the CLI does not refuse its env.
	-- Observe propagation without inventing a native environment requirement.
	for _, key in ipairs({ "ERGOPTI_LAUNCHER_EXECUTABLE", "ERGOPTI_LAUNCHER_DEVICE", "ERGOPTI_LAUNCHER_INODE" }) do
		if environment[key] ~= launcher_environment[key] then observation.environment = false end
	end
	local matches, exact_matches = {}, {}
	for _, source in ipairs(sources) do
		if by_name and source.source_id == args[3] then exact_matches[#exact_matches + 1] = source.key end
		local candidate = by_name and source.localised or source.source_id
		if candidate == args[2] then matches[#matches + 1] = source.key end
	end
	if #exact_matches > 0 then matches = exact_matches end
	if #matches > 1 then
		-- The cause is model evidence; the real worker writes nothing on exit 70.
		observation.result = "ambiguous"
		return { code = 70 }, observation
	end
	if #matches == 0 then
		observation.result = "MISS"
		return { code = 0, stdout = "MISS\n" }, observation
	end
	local status = selection_status or 0
	observation.result = tostring(status)
	if status == 0 then observation.selected = matches[1] end
	return { code = 0, stdout = tostring(status) .. "\n" }, observation
end

return M
