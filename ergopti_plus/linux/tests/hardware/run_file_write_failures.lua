--- tests/hardware/run_file_write_failures.lua
--- ==============================================================================
--- MODULE: Native Linux file-write receipts
--- DESCRIPTION:
--- Drives the production FileSystem adapter against /dev/full. Small writes fail
--- during buffered close; large writes fail during write itself. These are real
--- Linux ENOSPC receipts, without a filled disk or simulated io.open.
--- Regular-file controls retain successful write/append behavior.
--- ==============================================================================

local FileSystem = require("adapters.file_system")
local failures, checks = 0, 0
local temporary = assert(os.tmpname())

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then
		io.stdout:write("PASS " .. name .. "\n")
	else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, method in ipairs({ "write", "append" }) do
	for _, payload in ipairs({ "buffered", string.rep("x", 65536) }) do
		local buffered = #payload < 4096
		check(method .. (buffered and " buffered ENOSPC" or " immediate ENOSPC"), function()
			local file = assert(io.open("/dev/full", method == "write" and "w" or "a"))
			local written = file:write(payload)
			local closed = file:close()
			if buffered then
				assert(written and not closed, "fixture must fail when flushing buffered bytes")
			else
				assert(not written, "fixture must fail in the native write")
			end
			assert(FileSystem[method]("/dev/full", payload) == false,
				"production adapter reported success despite native ENOSPC")
		end)
	end
end

check("regular file write", function()
	assert(FileSystem.write(temporary, "first"), "regular write failed")
	assert(FileSystem.read(temporary) == "first", "regular bytes changed")
end)
check("regular file append", function()
	assert(FileSystem.append(temporary, " second"), "regular append failed")
	assert(FileSystem.read(temporary) == "first second", "appended bytes changed")
end)

assert(os.remove(temporary))
io.stdout:write(string.format("Native file writes: %d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
