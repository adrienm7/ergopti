--- tests/fixtures/native_storage_recovery_fifo_race.lua
--- Replaces the inspected recovery candidate with a real FIFO before admission.
local root = assert(arg[1])
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local driver = assert(source:match("^(.*)/tests/fixtures/native_storage_recovery_fifo_race%.lua$"))
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. driver .. "/../_shared/?.lua;"
	.. driver .. "/../_shared/?/init.lua;" .. package.path
local path = root .. "/" .. require("core.fs.engine.app_dirs").linux.folder_name .. "/storage.json"
local backup = path .. ".corrupt"
local function write(target, bytes)
	local file = assert(io.open(target, "wb")); assert(file:write(bytes)); assert(file:close())
end
write(path, "{broken")
write(backup, "older")
local getenv = os.getenv
os.getenv = function(name) if name == "XDG_CONFIG_HOME" then return root end; return getenv(name) end
local Shell = require("core.process.adapters.shell_runner")
local run, inspected, swapped = Shell.exec_checked, false, false
Shell.exec_checked = function(command)
	local ok, output, detail = run(command)
	if not inspected and command:find("if test %-L") then
		inspected = true
		assert(ok and output == "ordinary")
		assert(os.remove(backup))
		assert(Shell.run("mkfifo " .. Shell.quote(backup)))
		swapped = true
	end
	return ok, output, detail
end
local storage = require("core.fs.adapters.storage")
assert(storage.get("missing", "fallback") == "fallback")
local status = storage.recovery_status()
assert(swapped and status and status.preserved == true and status.path == backup .. ".1")
local file = assert(io.open(status.path, "rb"))
assert(file:read("*a") == "{broken")
assert(file:close())
