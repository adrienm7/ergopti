--- tools/test/managed_native_python_test.lua
--- Native candidate policy over injected metadata/header ports; no native execution.
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/tools/test/managed_native_python_test%.lua$"))
local repository = arg[1] or root
package.path = repository .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path
package.loaded["infra.logger"] = { error = function() end }
local Interpreter = assert(loadfile(repository .. "/static/ergopti_plus/macos/adapters/python_interpreter.lua"))()
local system = nil
Interpreter.resolve = function() return system end
package.loaded["adapters.python_interpreter"] = Interpreter
local catalogue = { schema_version = 1, downloads = {
	arm = { name = "cpython", os = "darwin", libc = "none", prerelease = "", arch = { family = "aarch64" }, major = 3, minor = 11, patch = 16 },
	intel = { name = "cpython", os = "darwin", libc = "none", prerelease = "", arch = { family = "x86_64" }, major = 3, minor = 11, patch = 16 },
} }
local Locator = {
	arm64 = "cpython-3.11.16-macos-aarch64-none/bin/python3.11",
	x86_64 = "cpython-3.11.16-macos-x86_64-none/bin/python3.11",
}
package.loaded["core.llm.managed_python_locator"] = Locator
package.loaded["modules.llm.bootstrap_retry_generated"] = { admission_seconds = 30 }
package.loaded["adapters.file_system"] = {
	read_with_status = function() error("GUI catalogue reads are forbidden") end,
	classify_no_follow = function() return {
		mode = "file", permissions = "rwxr-xr-x", dev = 1, ino = 2,
		size = 4096, modification = 1, change = 1,
	}, "ok" end,
}
local resolved, arch, close_result = nil, "arm64", true
_G.hs = { processInfo = { arch = arch }, fs = {
	pathToAbsolute = function(path) return resolved or path end,
} }
local header = string.char(0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1)
local real_open = io.open
io.open = function() error("GUI binary reads are forbidden") end
package.loaded["adapters.timer_scheduler"] = {
	now_ns = function() return 1000000000 end,
	after = function(_, callback) return { timer = {}, callback = callback }, true end,
	onSettled = function() return true end,
	cancel = function(timer) if close_result == true then timer.timer = nil; return true end; return false end,
}
package.loaded["adapters.shell_runner"] = { spawn = function(executable, args, done)
	assert(executable == "/usr/bin/od" and args[4] == "4096")
	local retired = false
	return {
		onSettled = function() return true end,
		isSettled = function() return retired end,
		start = function()
			local hex = {}; for index = 1, #header do hex[#hex + 1] = string.format("%02x", header:byte(index)) end
			done(0, table.concat(hex, " "), "")
			retired = close_result == true
			return true
		end,
		terminate = function() return true end,
	}
end }
package.loaded["adapters.task_lifecycle"] = {
	start = function(handle) return handle.start() end,
	terminate = function(handle) return handle.terminate() end,
}
local native_probe = {}
package.loaded["adapters.native_python_probe"] = native_probe
local Provider = assert(loadfile(root .. "/static/ergopti_plus/macos/modules/llm/managed_native_python.lua"))()
local resolve = Provider.resolve
function Provider.resolve()
	-- Each original vector receives an isolated real owner. A duplicate or
	-- malformed source projection is now refused before native task acquisition.
	Locator.duplicate = catalogue.downloads.duplicate and "unqualified" or nil
	Locator.arm64 = type(catalogue.downloads.arm.minor) == "number"
		and "cpython-3.11.16-macos-aarch64-none/bin/python3.11" or false
	local actual = assert(loadfile(root .. "/static/ergopti_plus/macos/adapters/native_python_probe.lua"))()
	native_probe.get, native_probe.cancel = actual.get, actual.cancel
	return resolve()
end
local checks = 0
local function check(value, expected) assert(value == expected); checks = checks + 1 end
local prefix = assert(os.getenv("HOME")):gsub("/+$", "") .. "/Library/Application Support/Ergopti/native-bootstrap/python/"
check(Provider.resolve(), prefix .. "cpython-3.11.16-macos-aarch64-none/bin/python3.11")
hs.processInfo.arch = "x86_64"
header = string.char(0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1)
check(Provider.resolve(), prefix .. "cpython-3.11.16-macos-x86_64-none/bin/python3.11")
header = string.char(0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1)
check(Provider.resolve(), nil)
resolved = "/foreign/python"
check(Provider.resolve(), nil)
resolved = nil; hs.processInfo.arch = "arm64"; close_result = nil
check(Provider.resolve(), nil)
close_result = true; catalogue.downloads.duplicate = catalogue.downloads.arm
check(Provider.resolve(), nil)
catalogue.downloads.duplicate = nil; catalogue.downloads.arm.minor = true
check(Provider.resolve(), nil)
system = "/actual/native/system/python"
check(Provider.resolve(), system)
io.open = real_open
print("Managed native Python injected policy controls passed: " .. checks)
