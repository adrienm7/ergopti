--- tests/unit/adapters/file_system/test_atomic_source_contract.lua

--- ==============================================================================
--- MODULE: FileSystem Atomic Source Contract Regression
--- DESCRIPTION:
--- Preserves the filesystem transaction contract at its owning boundary.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("adapters.file_system: write() source uses temp+rename (F-MED-16)", function()
	local function read_source()
		-- Selected by a declaration unique to adapters/file_system.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.expand_path")
		helpers.assert_true(src ~= nil, "adapters/file_system.lua source must be locatable")
		return src
	end

	helpers.it("write() reserves a private adjacent staging path before publication", function()
		local src = read_source()
		local fn_start = src:find("local function write_atomic", 1, true)
		helpers.assert_true(fn_start ~= nil, "the shared atomic writer must exist")
		local fn_end = src:find("\nfunction M.append", fn_start, true)
		local body = src:sub(fn_start, fn_end)
		local public_write = src:match("function M%.write%(path, content%)(.-)end") or ""

		helpers.assert_true(public_write:find("write_atomic(path, content, nil)", 1, true) ~= nil,
			"the canonical two-argument port must delegate to the reviewed atomic writer")
		helpers.assert_true(body:find("reserve_staging_area(resolved_path)", 1, true) ~= nil,
			"write() must exclusively reserve its staging pathname before opening it (F-MED-16)")
		helpers.assert_true(body:find("os.rename(", 1, true) ~= nil,
			"write() must publish the staged content via os.rename (F-MED-16)")
	end)

	helpers.it("write() delegates final-link resolution to the symlink-aware resolver", function()
		local src = read_source()
		local fn_start = src:find("local function write_atomic", 1, true)
		local fn_end   = src:find("\nfunction M.append", fn_start, true)
		local body = src:sub(fn_start, fn_end)
		local resolver_start = src:find("local function resolve_write_path(path)", 1, true)
		local resolver_end = src:find("local function revalidate_write_path", resolver_start, true)
		local resolver = src:sub(resolver_start, resolver_end)

		helpers.assert_true(body:find("resolve_write_path(path)", 1, true) ~= nil,
			"write() must invoke the shared resolver before it creates or renames the staging file")
		helpers.assert_true(resolver:find("inspect_path(prefix, component_parent, component)", 1, true) ~= nil,
			"the resolver must classify every component, including the final pathname")
		helpers.assert_nil(resolver:find("inspect_path(current)", 1, true),
			"a duplicate full-path probe must not reject a destination whose parent is meant to be created")
	end)
end)
