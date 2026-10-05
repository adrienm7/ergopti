--- tests/fixtures/native_event_loop_sleep_receipts.lua
--- ==============================================================================
--- MODULE: Native Event Loop Wait Completion Receipts
--- DESCRIPTION:
--- Executes genuine system waits and private executable exit-7 refusals. Stock
--- Lua has no FFI naturally; LuaJIT's no-FFI path and the cdef-refusal path use
--- explicit dependency seams. Commands, elapsed time and argv bytes are real.
--- No infinite wait, process signal or physical input is exercised.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = assert(source:match("^(.*)/tests/fixtures/native_event_loop_sleep_receipts%.lua$"))
package.path = driver_root .. "/?.lua;" .. driver_root .. "/?/init.lua;"
	.. driver_root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local ffi_ok = pcall(require, "ffi")
local root = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-native-nap-XXXXXX"))
local executable, capture = root .. "/sleep", root .. "/argv"
local previous_path, previous_capture = uv.os_getenv("PATH"), uv.os_getenv("ERGOPTI_TEST_NAP_ARGV")
assert(type(previous_path) == "string", "native fixture requires the existing command path")
assert(uv.fs_stat("/bin/sleep"), "native system sleep must exist")
local checks, failures = 0, 0

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes))
	assert(file:close())
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function restore_environment()
	assert(uv.os_setenv("PATH", previous_path))
	if previous_capture == nil then assert(uv.os_unsetenv("ERGOPTI_TEST_NAP_ARGV"))
	else assert(uv.os_setenv("ERGOPTI_TEST_NAP_ARGV", previous_capture)) end
end

local function controlled_executable(refused)
	write(capture, "")
	write(executable, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$ERGOPTI_TEST_NAP_ARGV\"\n"
		.. (refused and "exit 7\n" or "exec /bin/sleep \"$@\"\n"))
	assert(uv.fs_chmod(executable, 493)) -- 0755; only this private executable.
	assert(uv.os_setenv("PATH", root .. ":" .. previous_path))
	assert(uv.os_setenv("ERGOPTI_TEST_NAP_ARGV", capture))
end

local function load_loop(branch)
	local loaded, preload = package.loaded.ffi, package.preload.ffi
	package.loaded["adapters.event_loop"] = nil
	if branch == "no-FFI" and ffi_ok then
		package.loaded.ffi = nil
		package.preload.ffi = function() error("explicit test selects command fallback") end
	elseif branch == "cdef refusal" then
		package.loaded.ffi = { cdef = function() error("controlled native declaration refusal") end }
	end
	local ok, loop = pcall(require, "adapters.event_loop")
	package.loaded.ffi, package.preload.ffi = loaded, preload
	if not ok then error(loop, 0) end
	return loop
end

local function completed_wait(loop)
	local start = uv.hrtime()
	assert(loop.sleep_ms(25) == true, "healthy native wait must report completion")
	local elapsed = (uv.hrtime() - start) / 1e6
	assert(elapsed >= 25, "native wait reported completion before its requested duration")
	print(string.format("RECEIPT completed wait: %.3f ms", elapsed))
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	restore_environment()
	local handles = 0
	uv.walk(function() handles = handles + 1 end)
	assert(handles == 0 and not uv.loop_alive(), "synchronous wait retained native handles")
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("natural runtime backend completes a real wait", function()
	completed_wait(load_loop("natural"))
end)

check("natural runtime refuses typed and negative waits without executing private command", function()
	controlled_executable(true)
	local loop = load_loop("natural")
	assert(loop.sleep_ms(-1) == false and loop.sleep_ms("25") == false and loop.sleep_ms(nil) == false)
	assert(read(capture) == "", "refused typed waits executed a command")
end)

for _, branch in ipairs({ "no-FFI", "cdef refusal" }) do
	local qualification = branch == "no-FFI" and (ffi_ok and "explicit dependency seam" or "actual stock no-FFI")
		or "explicit cdef seam"
	check(branch .. " completes system command wait (" .. qualification .. ")", function()
		completed_wait(load_loop(branch))
	end)
	check(branch .. " honors actual controlled executable exit7 (" .. qualification .. ")", function()
		controlled_executable(true)
		assert(load_loop(branch).sleep_ms(20) == false, "actual native exit7 reported successful completion")
		assert(read(capture) == "0.020\n", "native child argv did not preserve requested wait")
	end)
	check(branch .. " completes healthy command following refusal (" .. qualification .. ")", function()
		controlled_executable(true)
		local loop = load_loop(branch)
		assert(loop.sleep_ms(20) == false, "controlled refusal reported completion")
		assert(read(capture) == "0.020\n")
		-- Preserve the selected path, but now execute the genuine system wait.
		write(executable, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$ERGOPTI_TEST_NAP_ARGV\"\nexec /bin/sleep \"$@\"\n")
		completed_wait(loop)
		assert(read(capture) == "0.020\n0.025\n", "refusal/recovery argv or invocation count changed")
	end)
end

restore_environment()
assert(uv.fs_unlink(executable))
assert(uv.fs_unlink(capture))
assert(uv.fs_rmdir(root))
assert(checks == 8, "native wait receipt fixture lost a case")
print(string.format("Native event loop wait receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
