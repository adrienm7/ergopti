--- diagnostics/adapters/setup_check_ports.lua

--- ==============================================================================
--- MODULE: Session Setup Check Ports (Linux)
--- DESCRIPTION:
--- The native side of the field run's « setup » check
--- (diagnostics/engine/field_check/setup_check.lua): access checks through
--- libuv, the /dev/input listing, the two commands through the daemon's own
--- asynchronous runner (never a blocking shell on the keyboard loop) and the
--- compositor focus source's state. Each command is bound to half its field
--- run step's deadline (diagnostics/data/field_run_steps.json), so the two
--- together never outlast the step.
--- ==============================================================================

local M = {}

--- The bound of one command: half the deadline of the step running the check.
--- @param check string The check's id in the field run declaration.
--- @return number milliseconds
local function command_timeout_ms(check)
	local FieldRun = require("diagnostics.engine.field_run.field_run")
	local Paths = require("core.fs.engine.paths")
	local declaration = FieldRun.read_declaration(Paths.driver_root() .. "/diagnostics/data/field_run_steps.json")
	for _, step in ipairs(declaration.steps) do
		if step.check == check then return step.deadline_seconds * 1000 / 2 end
	end
	error("no field run step runs the " .. check .. " check")
end

--- Builds the ports.
--- @param check string The check's id in the field run declaration.
--- @return table ports
function M.new(check)
	local uv = require("luv")
	local Shell = require("core.process.adapters.shell_runner")
	local timeout_ms = command_timeout_ms(check)
	return {
		access = function(path, mode)
			local ok, _, code = uv.fs_access(path, mode)
			return ok == true, code
		end,
		list_dir = function(dir)
			local handle = uv.fs_scandir(dir)
			if not handle then return nil end
			local names = {}
			while true do
				local name = uv.fs_scandir_next(handle)
				if not name then break end
				names[#names + 1] = name
			end
			return names
		end,
		run = function(argv, done)
			if not Shell.has_command(argv[1], true) then return nil, "not_found" end
			local args = {}
			for index = 2, #argv do args[#args + 1] = argv[index] end
			return Shell.run_async(argv[1], args, { timeout_ms = timeout_ms }, function(result)
				if result.timed_out then done(nil, "timeout")
				elseif type(result.code) == "number" then done(result.code)
				else done(nil, "error") end
			end)
		end,
		focus_status = function()
			return require("platform.focus.window_info").compositor_focus_status()
		end,
	}
end

return M
