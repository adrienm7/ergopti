-- tests/support/ui/menu/menu_llm/system_probe_stub.lua

--- Answers the model system check's memory and disk probes at once. The check
--- runs `sysctl` and `df` as tasks (a blocking hs.execute held the main thread,
--- issue #101), so fixtures that exercise it replace adapters.shell_runner.
local M = {}

--- Installs the stub as adapters.shell_runner; the caller's module list must
--- include that name so the previous module is restored afterwards.
--- @param ram_gb integer Installed memory the sysctl probe reports.
--- @param free_gb integer Free disk gigabytes the df probe reports.
function M.install(ram_gb, free_gb)
	package.loaded["adapters.shell_runner"] = {
		run = function(executable, _, on_done)
			if executable:find("sysctl", 1, true) then
				on_done(true, tostring(ram_gb * 1024 * 1024 * 1024))
			else
				on_done(true, "Filesystem 512-blocks Used Available Capacity Mounted\n"
					.. "/dev/disk3s1 976 300 " .. tostring(free_gb) .. " 75% /\n")
			end
			return true, { terminate = function() return true end }
		end,
	}
end

return M
