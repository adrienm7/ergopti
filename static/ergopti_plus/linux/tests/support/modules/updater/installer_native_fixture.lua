--- tests/support/modules/updater/installer_native_fixture.lua

--- ==============================================================================
--- MODULE: Native Installer Namespace Fixture
--- DESCRIPTION:
--- Models only the already-validated archive collaborator with native file
--- copies, while all transaction moves, ownership recording, smoke and cleanup
--- remain production operations. The separate installed updater native chain
--- qualifies genuine tar/HTTP/FD handling; distro unit images do not ship tar.
--- ==============================================================================

local M = {}
local Native = require("luv")
local Shell = require("adapters.shell_runner")
local Helpers = require("tests.helpers")
local PREFIX = "ergopti-install-publication-"

--- Writes complete fixture bytes with an acknowledged close.
--- @param path string
--- @param content string
function M.write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	assert(file:close())
end

--- Reads complete fixture bytes, or nil for an absent source.
--- @param path string
--- @return string|nil
function M.read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

--- Allocates an exclusive native temporary directory.
--- @return string
function M.scratch()
	return assert(Native.fs_mkdtemp(Native.os_tmpdir() .. "/" .. PREFIX .. "XXXXXX"))
end

--- Retires only the fixture namespace supplied by scratch().
--- @param root string
function M.remove(root)
	assert(type(root) == "string" and root:match("([^/]+)$"):sub(1, #PREFIX) == PREFIX, "fixture namespace required")
	assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
end

--- Creates an actual standalone root and an explicitly modeled archive port.
--- @param installer table Production installer whose unmodified operations are retained.
--- @return table fixture Native paths, archive collaborator and exact install context.
function M.create(installer)
	local root = M.scratch()
	local prefix, payload = root .. "/prefix", root .. "/payload"
	local installed = prefix .. "/lib/ergopti"
	for _, path in ipairs({ installed .. "/linux/install", installed .. "/_shared/lua",
		installed .. "/_shared/data/locales", installed .. "/bin", prefix .. "/bin",
		payload .. "/linux/infra", payload .. "/_shared/data/locales", payload .. "/_shared/lua", payload .. "/bin" }) do
		assert(Shell.run("mkdir -p -- " .. Shell.quote(path)))
	end
	assert(Native.fs_copyfile(Helpers.driver_root() .. "/install/ownership.sh", installed .. "/linux/install/ownership.sh"))
	M.write(installed .. "/old.marker", "original installation\n")
	M.write(installed .. "/linux/ergopti_hotstrings.lua", "-- Previous driver fixture.\n")
	M.write(installed .. "/_shared/data/locales/en.json", "{}\n")
	M.write(installed .. "/_shared/lua/init.lua", "-- Previous shared fixture.\n")
	M.write(installed .. "/bin/ergopti-hotstrings", "#!/bin/sh\nexit 0\n")
	assert(Native.fs_chmod(installed .. "/bin/ergopti-hotstrings", 493))
	local wrapper = prefix .. "/bin/ergopti-hotstrings"
	M.write(wrapper, "#!/bin/sh\nexec " .. Shell.quote(installed .. "/bin/ergopti-hotstrings") .. " \"$@\"\n")
	assert(Native.fs_chmod(wrapper, 493))
	M.write(payload .. "/linux/ergopti_hotstrings.lua", "-- Selected driver fixture.\n")
	M.write(payload .. "/linux/infra/version.lua", "return {}\n")
	M.write(payload .. "/linux/new.marker", "selected installation\n")
	M.write(payload .. "/_shared/data/locales/en.json", "{}\n")
	M.write(payload .. "/_shared/lua/init.lua", "-- Selected shared fixture.\n")
	M.write(payload .. "/_shared/build_stamp.txt", "commit=" .. string.rep("a", 40) .. "\nversion=1.2.3\n")
	M.write(payload .. "/bin/ergopti-hotstrings", "#!/bin/sh\nexit 0\n")
	assert(Native.fs_chmod(payload .. "/bin/ergopti-hotstrings", 493))
	M.write(payload .. "/install.sh", "#!/bin/sh\nexit 0\n")
	local archive = root .. "/validated-archive.fixture"
	local archive_receipt = "validated archive collaborator\n"
	M.write(archive, archive_receipt)
	local ops = {}
	for name, operation in pairs(installer.DEFAULT_OPS) do ops[name] = operation end
	ops.validate_archive = function(path)
		if path ~= archive or M.read(path) ~= archive_receipt then return false, "fixture archive admission refused" end
		return true
	end
	ops.extract = function(path, work_dir)
		if path ~= archive or M.read(path) ~= archive_receipt then return false end
		for _, relative in ipairs({ "linux", "linux/infra", "_shared", "_shared/data", "_shared/data/locales", "_shared/lua", "bin" }) do
			if Native.fs_mkdir(work_dir .. "/" .. relative, 448) ~= true then return false end
		end
		for _, relative in ipairs({ "linux/ergopti_hotstrings.lua", "linux/infra/version.lua", "linux/new.marker",
			"_shared/data/locales/en.json", "_shared/lua/init.lua", "_shared/build_stamp.txt", "bin/ergopti-hotstrings", "install.sh" }) do
			if Native.fs_copyfile(payload .. "/" .. relative, work_dir .. "/" .. relative) ~= true then return false end
		end
		return true
	end
	return { root = root, installed = installed, archive = archive, ops = ops,
		context = { kind = "standalone", install_root = installed, parent = prefix .. "/lib", wrapper = wrapper } }
end

return M
