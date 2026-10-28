--- tests/unit/modules/keystats/log_manager/test_metrics_gitignore_initialization.lua

--- Public JSONL-only initialization on a physical filesystem and isolated Git repository.
local Helpers = require("tests.helpers")
local Fixture = require("tests.support.keystats.metrics_ignore_fixture")
local Lfs = require("lfs")
Helpers.describe("metrics Git exclusion initialization", function()
	Helpers.it("ignores the local journal in an otherwise clean Git repository (metrics-gitignore-public-init)", function()
		Fixture.run(function(f)
			Helpers.assert_eq(f.init(), true)
			Helpers.assert_eq(Lfs.attributes(f.today, "mode"), "file")
			Helpers.assert_eq(f.git("check-ignore", "--no-index", "metrics/by_device/device/today.log"), 0)
			Helpers.assert_eq(f.git("check-ignore", "--no-index", "metrics/by_device/device/data.sql"), 1)
		end)
	end)
	Helpers.it("preserves an explicit user choice to track the journal (metrics-gitignore-custom-preserved)", function()
		Fixture.run(function(f)
			local body = "# User choice\n!today.log\n*.sql\n"
			f.write(f.ignore, body)
			Helpers.assert_eq(f.init(), true)
			Helpers.assert_eq(f.files.read(f.ignore), body)
			Helpers.assert_eq(f.git("check-ignore", "--no-index", "metrics/by_device/device/data.sql"), 0)
			Helpers.assert_eq(f.git("check-ignore", "--no-index", "metrics/by_device/device/today.log"), 1)
		end)
	end)
	for _, kind in ipairs({ "empty", "directory", "symlink", "dangling" }) do
		Helpers.it("preserves existing " .. kind .. " entries without reading them (metrics-gitignore-preserve-" .. kind .. ")", function()
			Fixture.run(function(f)
				local target = f.root .. "/user-ignore"
				if kind == "empty" then f.write(f.ignore, "")
				elseif kind == "directory" then assert(Lfs.mkdir(f.ignore))
				else
					if kind == "symlink" then f.write(target, "user-owned bytes\n") end
					assert(Lfs.link(target, f.ignore, true))
				end
				local before = assert(Lfs.symlinkattributes(f.ignore))
				local read, creates = f.files.read_with_status, 0
				f.files.read_with_status = function(path, ...)
					assert(path ~= f.ignore, "existing user ignore must not be read")
					return read(path, ...)
				end
				local create = f.files.create_if_absent
				f.files.create_if_absent = function(path, ...)
					if path == f.ignore then creates = creates + 1 end
					return create(path, ...)
				end
				Helpers.assert_eq(f.init(), true)
				local after = assert(Lfs.symlinkattributes(f.ignore))
				Helpers.assert_eq(after.ino, before.ino)
				Helpers.assert_eq(after.mode, before.mode)
				Helpers.assert_eq(creates, 0)
				if kind == "symlink" then Helpers.assert_eq(f.files.read(target), "user-owned bytes\n") end
			end)
		end)
	end
	Helpers.it("preserves a create-only race winner (metrics-gitignore-racing-winner)", function()
		Fixture.run(function(f)
			local create = f.files.create_if_absent
			f.files.create_if_absent = function(path, body)
				if path == f.ignore then f.write(path, "# Concurrent choice\n") end
				return create(path, body)
			end
			Helpers.assert_eq(f.init(), true)
			Helpers.assert_eq(f.files.read(f.ignore), "# Concurrent choice\n")
		end)
	end)
	Helpers.it("reports a real publication IO error and retries before admission (metrics-gitignore-io-refusal)", function()
		Fixture.run(function(f)
			local link = hs.fs.link
			local refused = false
			hs.fs.link = function(source, destination, ...)
				if destination == f.ignore and not refused then
					refused = true
					-- A real POSIX hardlink refusal, with the native error receipt retained.
					return Lfs.link(source, f.root .. "/missing-parent/.gitignore")
				end
				return link(source, destination, ...)
			end
			Helpers.assert_eq(f.init(), false)
			Helpers.assert_eq(refused, true)
			Helpers.assert_eq(Lfs.symlinkattributes(f.today), nil)
			Helpers.assert_eq(#f.errors > 0, true)
			Helpers.assert_eq(f.init(), true)
			Helpers.assert_eq(f.git("check-ignore", "--no-index", "metrics/by_device/device/today.log"), 0)
		end)
	end)
	for _, receipt in ipairs({ "cleanup", "lock", "throw", "inconsistent" }) do
		Helpers.it("retains the exact owner after " .. receipt .. " refusal (metrics-gitignore-receipt-" .. receipt .. ")", function()
			Fixture.run(function(f)
				local create, calls = f.files.create_if_absent, 0
				f.files.create_if_absent = function(path, body)
					if path ~= f.ignore then return create(path, body) end
					calls = calls + 1
					if calls == 1 then
						local made, status = create(path, body)
						Helpers.assert_eq(made, true); Helpers.assert_eq(status, "created")
						if receipt == "throw" then error("publication boundary raised") end
						if receipt == "lock" then return false, "error", "lock cleanup pending" end
						if receipt == "inconsistent" then return true, "exists" end
						return true, "created", "staging cleanup pending"
					end
					if calls == 2 then return false, "error", "cleanup still pending" end
					return create(path, body)
				end
				Helpers.assert_eq(f.init(), false)
				Helpers.assert_eq(Lfs.symlinkattributes(f.today), nil)
				Helpers.assert_eq(f.init(), false)
				Helpers.assert_eq(calls, 2)
				Helpers.assert_eq(Lfs.symlinkattributes(f.today), nil)
				Helpers.assert_eq(f.init(), true)
				Helpers.assert_eq(calls, 3)
			end)
		end)
	end
	Helpers.it("settles actual staging cleanup before admitting a changed metrics root (metrics-gitignore-cleanup-owner)", function()
		Fixture.run(function(f)
			local refuse = true
			local rmdir = hs.fs.rmdir
			assert(Lfs.mkdir(f.root .. "/nonempty")); f.write(f.root .. "/nonempty/retained", "owned")
			local staging_path
			hs.fs.rmdir = function(path)
				if path:sub(1, #f.ignore + 5) == f.ignore .. ".tmp." then
					staging_path = path
					if refuse then return Lfs.rmdir(f.root .. "/nonempty") end
				end
				return rmdir(path)
			end
			Helpers.assert_eq(f.init(), false)
			Helpers.assert_eq(Lfs.attributes(f.ignore, "mode"), "file")
			local owned_inode = assert(Lfs.symlinkattributes(staging_path)).ino
			local second = f.root .. "/metrics-new"
			assert(Lfs.mkdir(second)); assert(Lfs.mkdir(second .. "/by_device")); assert(Lfs.mkdir(second .. "/by_device/device"))
			f.write(second .. "/by_device/device/device.json", assert(f.files.read(f.metrics .. "/by_device/device/device.json")))
			Helpers.assert_eq(f.init(second), false)
			Helpers.assert_eq(Lfs.symlinkattributes(staging_path).ino, owned_inode)
			Helpers.assert_eq(Lfs.symlinkattributes(second .. "/.gitignore"), nil)
			refuse = false
			Helpers.assert_eq(f.init(second), true)
			Helpers.assert_eq(Lfs.symlinkattributes(staging_path), nil)
			Helpers.assert_eq(Lfs.attributes(second .. "/.gitignore", "mode"), "file")
			Helpers.assert_eq(f.files.read(f.ignore), f.files.read(second .. "/.gitignore"))
		end)
	end)
	Helpers.it("fails visibly when ignore entry inspection is inconclusive (metrics-gitignore-inspection-refusal)", function()
		Fixture.run(function(f)
			local status = f.files.path_status
			f.files.path_status = function(path)
				if path == f.ignore then return "error", "native inspection refused" end
				return status(path)
			end
			Helpers.assert_eq(f.init(), false)
			Helpers.assert_eq(Lfs.symlinkattributes(f.today), nil)
			Helpers.assert_eq(f.errors[#f.errors]:find("native inspection refused", 1, true) ~= nil, true)
			f.files.path_status = status
			Helpers.assert_eq(f.init(), true)
		end)
	end)
end)
