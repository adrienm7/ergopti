--- tests/unit/modules/keystats/log_manager/test_ledger_bootstrap_policy.lua

--- Public initialization preserves existing ledgers and exact publication debt.
local Helpers = require("tests.helpers")
local Fixture = require("tests.support.keystats.metrics_ignore_fixture")
local Lfs = require("lfs")

local function ledger_path(fixture)
	return fixture.metrics .. "/by_device/device/data.sql"
end

Helpers.describe("canonical ledger initialization policy", function()
	Helpers.it("preserves an existing ledger without reading or replacing it (ledger-bootstrap-existing)", function()
		Fixture.run(function(f)
			local path = ledger_path(f)
			local body = "-- Existing complete ledger\nPRAGMA foreign_keys = OFF;\n"
			f.write(path, body)
			local before = assert(Lfs.symlinkattributes(path))
			local create, read = f.files.create_if_absent, f.files.read_with_status
			f.files.create_if_absent = function(destination, ...)
				assert(destination ~= path, "an existing ledger must not be republished")
				return create(destination, ...)
			end
			f.files.read_with_status = function(source, ...)
				assert(source ~= path, "bootstrap must leave existing ledger recovery to its owner")
				return read(source, ...)
			end
			Helpers.assert_eq(f.init(), true)
			Helpers.assert_eq(Lfs.symlinkattributes(path).ino, before.ino)
			f.files.read_with_status = read
			Helpers.assert_eq(f.files.read(path), body)
		end)
	end)
	Helpers.it("preserves a concurrent complete header (ledger-bootstrap-racing-winner)", function()
		Fixture.run(function(f)
			local path, winner, calls = ledger_path(f), "-- Concurrent ledger\nPRAGMA foreign_keys = OFF;\n", 0
			local create = f.files.create_if_absent
			f.files.create_if_absent = function(destination, body)
				if destination == path then calls = calls + 1; f.write(path, winner) end
				return create(destination, body)
			end
			Helpers.assert_eq(f.init(), true)
			Helpers.assert_eq(calls, 1)
			Helpers.assert_eq(f.files.read(path), winner)
		end)
	end)
	Helpers.it("rejects a native publication refusal before writer admission (ledger-bootstrap-link-refusal)", function()
		Fixture.run(function(f)
			local path, link, refused = ledger_path(f), hs.fs.link, false
			hs.fs.link = function(source, destination, ...)
				if destination == path and not refused then
					refused = true
					return Lfs.link(source, f.root .. "/missing-parent/data.sql")
				end
				return link(source, destination, ...)
			end
			Helpers.assert_eq(f.init(), false)
			Helpers.assert_eq(refused, true)
			Helpers.assert_eq(f.cache_path, nil)
			Helpers.assert_eq(Lfs.symlinkattributes(path), nil)
			Helpers.assert_eq(Lfs.symlinkattributes(f.today), nil)
			Helpers.assert_eq(f.errors[#f.errors]:find("canonical ledger", 1, true) ~= nil, true)
			Helpers.assert_eq(f.init(), true)
			Helpers.assert_eq(f.files.read(path):sub(-#"PRAGMA foreign_keys = OFF;\n"), "PRAGMA foreign_keys = OFF;\n")
		end)
	end)
	Helpers.it("settles the old header owner before a new root Git exclusion (ledger-bootstrap-cross-root-debt)", function()
		Fixture.run(function(f)
			local path, rmdir, refuse, staging = ledger_path(f), hs.fs.rmdir, true, nil
			assert(Lfs.mkdir(f.root .. "/nonempty")); f.write(f.root .. "/nonempty/retained", "owned")
			hs.fs.rmdir = function(directory)
				if directory:sub(1, #path + 5) == path .. ".tmp." then
					staging = directory
					if refuse then return Lfs.rmdir(f.root .. "/nonempty") end
				end
				return rmdir(directory)
			end
			Helpers.assert_eq(f.init(), false)
			Helpers.assert_eq(f.cache_path, nil)
			local stage_inode = assert(Lfs.symlinkattributes(staging)).ino
			local header_inode = assert(Lfs.symlinkattributes(path)).ino
			local second = f.root .. "/metrics-new"
			assert(Lfs.mkdir(second)); assert(Lfs.mkdir(second .. "/by_device")); assert(Lfs.mkdir(second .. "/by_device/device"))
			f.write(second .. "/by_device/device/device.json", assert(f.files.read(f.metrics .. "/by_device/device/device.json")))
			Helpers.assert_eq(f.init(second), false)
			Helpers.assert_eq(Lfs.symlinkattributes(staging).ino, stage_inode)
			Helpers.assert_eq(Lfs.symlinkattributes(second .. "/.gitignore"), nil)
			refuse = false
			Helpers.assert_eq(f.init(second), true)
			Helpers.assert_eq(Lfs.symlinkattributes(staging), nil)
			Helpers.assert_eq(Lfs.symlinkattributes(path).ino, header_inode)
			Helpers.assert_eq(f.files.read(path), f.files.read(second .. "/by_device/device/data.sql"))
		end)
	end)
	Helpers.it("refuses inconclusive ledger metadata before admission (ledger-bootstrap-inspection-refusal)", function()
		Fixture.run(function(f)
			local path, status = ledger_path(f), f.files.path_status
			f.files.path_status = function(destination)
				if destination == path then return "error", "native metadata refused" end
				return status(destination)
			end
			Helpers.assert_eq(f.init(), false)
			Helpers.assert_eq(f.cache_path, nil)
			Helpers.assert_eq(Lfs.symlinkattributes(f.today), nil)
			Helpers.assert_eq(f.errors[#f.errors]:find("canonical ledger", 1, true) ~= nil, true)
			f.files.path_status = status
			Helpers.assert_eq(f.init(), true)
		end)
	end)
end)
