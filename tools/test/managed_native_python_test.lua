--- tools/test/managed_native_python_test.lua
--- Native candidate policy over injected metadata/header ports; no native execution.
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/tools/test/managed_native_python_test%.lua$"))
package.path = root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path
local Json = require("json")
package.loaded["infra.logger"] = { error = function() end }
local repository = arg[1] or root
local Interpreter = assert(loadfile(repository .. "/static/ergopti_plus/macos/adapters/python_interpreter.lua"))()
local system = nil
Interpreter.resolve = function() return system end
package.loaded["adapters.python_interpreter"] = Interpreter
local catalogue = { schema_version = 1, downloads = {
	arm = { name = "cpython", os = "darwin", libc = "none", prerelease = "", arch = { family = "aarch64" }, major = 3, minor = 11, patch = 16 },
	intel = { name = "cpython", os = "darwin", libc = "none", prerelease = "", arch = { family = "x86_64" }, major = 3, minor = 11, patch = 16 },
} }
package.loaded["adapters.file_system"] = { read_with_status = function() return Json.encode(catalogue), "ok" end }
local resolved, arch, close_result = nil, "arm64", true
_G.hs = { processInfo = { arch = arch }, fs = {
	pathToAbsolute = function(path) return resolved or path end,
	attributes = function() return { mode = "file", permissions = "rwxr-xr-x" } end,
} }
local header = string.char(0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1)
local real_open = io.open
io.open = function(_, mode)
	assert(mode == "rb")
	return { read = function(_, maximum) assert(maximum == 4096); return header end,
		close = function() return close_result end }
end
local Provider = assert(loadfile(root .. "/static/ergopti_plus/macos/modules/llm/managed_native_python.lua"))()
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
