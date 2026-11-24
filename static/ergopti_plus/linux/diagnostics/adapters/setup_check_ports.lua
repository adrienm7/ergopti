--- diagnostics/adapters/setup_check_ports.lua

--- ==============================================================================
--- MODULE: Session Setup Check Ports (Linux)
--- DESCRIPTION:
--- The native side of the field run's « setup » check
--- (diagnostics/engine/field_check/setup_check.lua): access checks through
--- libuv, the /dev/input listing, the two commands through the daemon's own
--- asynchronous runner (never a blocking shell on the keyboard loop) and the
--- compositor focus source's state.
--- ==============================================================================

local M = {}

--- Builds the ports.
--- @return table ports
function M.new()
	local uv = require("luv")
	local Shell = require("core.process.adapters.shell_runner")
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
		run = function(argv, timeout_ms, done)
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
