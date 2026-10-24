--- tests/unit/ui/healthcheck/test_healthcheck_device_probe.lua

--- ==============================================================================
--- MODULE: Diagnostics Device Write Probe (Linux)
--- DESCRIPTION:
--- The diagnostics permission row asks whether the daemon may write the uinput
--- device. It used to open the node with io.open(path, "ab"), which carries
--- O_CREAT: with the uinput module absent, a root daemon created a regular file
--- at /dev/uinput, reported the permission as granted, and the writer then took
--- that file for the device. The probe must answer without creating anything.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv = require("luv")

--- Runs body with a private directory, removed afterwards.
--- @param body function body(directory)
local function with_directory(body)
	local directory = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti_device_probe_XXXXXX"))
	local ok, err = pcall(body, directory)
	for name in function(handle) return uv.fs_scandir_next(handle) end, assert(uv.fs_scandir(directory)) do
		uv.fs_unlink(directory .. "/" .. name)
	end
	uv.fs_rmdir(directory)
	if not ok then error(err, 0) end
end

helpers.describe("diagnostics device write probe", function()
	helpers.it("answers missing for an absent device and creates nothing", function()
		local Bridge = helpers.load_module("ui.healthcheck.bridge")
		with_directory(function(directory)
			local path = directory .. "/uinput"
			helpers.assert_eq(Bridge._device_writable_for_test(path), "missing")
			helpers.assert_nil(uv.fs_lstat(path), "probing a device never creates its node")
		end)
	end)

	helpers.it("answers granted for a node this user may write, and leaves it as it was", function()
		local Bridge = helpers.load_module("ui.healthcheck.bridge")
		with_directory(function(directory)
			local path = directory .. "/uinput"
			local fd = assert(uv.fs_open(path, "w", 384))
			assert(uv.fs_close(fd))
			helpers.assert_eq(Bridge._device_writable_for_test(path), "granted")
			helpers.assert_eq(assert(uv.fs_stat(path)).size, 0, "the probe writes nothing")
		end)
	end)
end)
