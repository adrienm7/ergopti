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


helpers.describe("adapters.file_system: final logical publication admission", function()
	local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
	for _, unchanged in ipairs({ false, true }) do
		local no_op = unchanged
		for _, result in ipairs({ "true", "false", "nil", "truthy", "throw" }) do
			local mode = result
			helpers.it("checks " .. mode .. " admission after the final source read, unchanged=" .. tostring(no_op), function()
				with_fixture(function(fixture)
					local path = os.tmpname()
					local file = assert(io.open(path, "wb")); assert(file:write("original")); assert(file:close())
					local adapter = fixture.make_adapter()
					local read, rename = adapter.read_with_status, os.rename
					local reads, admitted_after, admissions, replacements = 0, 0, 0, 0
					adapter.read_with_status = function(...)
						local content, status, detail = read(...)
						reads = reads + 1
						return content, status, detail
					end
					os.rename = function(...)
						replacements = replacements + 1
						return rename(...)
					end
					local called, written, detail = pcall(adapter.write_if_unchanged_admitted,
						path, no_op and "original" or "changed", { status = "ok", content = "original" }, nil,
						function()
							admissions, admitted_after = admissions + 1, reads
							if mode == "throw" then error("controlled logical refusal") end
							if mode == "true" then return true end
							if mode == "false" then return false end
							if mode == "truthy" then return {} end
						end)
					os.rename, adapter.read_with_status = rename, read
					local handle = assert(io.open(path, "rb"))
					local actual = assert(handle:read("*a")); assert(handle:close())
					os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
					helpers.assert_eq(called, true)
					helpers.assert_eq(written, mode == "true", tostring(detail))
					helpers.assert_eq(admissions, 1)
					helpers.assert_true(reads > 0)
					helpers.assert_eq(admitted_after, reads, "no logical/source reader follows final admission")
					helpers.assert_eq(replacements, mode == "true" and not no_op and 1 or 0)
					helpers.assert_eq(actual, mode == "true" and not no_op and "changed" or "original")
				end)
			end)
		end
	end
end)


helpers.describe("FileSystem admitted publication captures exact source before callbacks", function()
	local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
	for _, unchanged in ipairs({ false, true }) do
		local no_op = unchanged
		helpers.it("refuses a mutated caller precondition and keeps the genuine external image, unchanged=" .. tostring(no_op), function()
			with_fixture(function(fixture)
				local path = os.tmpname()
				local function put(content)
					local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
				end
				put("original")
				local adapter = fixture.make_adapter()
				local read, rename = adapter.read_with_status, os.rename
				local expected = { status = "ok", content = "original" }
				local observed, reads, replacements, admissions = false, 0, 0, 0
				adapter.read_with_status = function(...)
					reads = reads + 1
					if not observed then
						observed = true
						put("external-successor")
						expected.content = "external-successor"
					end
					return read(...)
				end
				os.rename = function(...) replacements = replacements + 1; return rename(...) end
				local called, written = pcall(adapter.write_if_unchanged_admitted,
					path, no_op and "original" or "candidate", expected, nil,
					function() admissions = admissions + 1; return true end)
				os.rename, adapter.read_with_status = rename, read
				local file = assert(io.open(path, "rb"))
				local actual = assert(file:read("*a")); assert(file:close())
				os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
				helpers.assert_eq(called, true)
				helpers.assert_eq(written, false)
				helpers.assert_eq(actual, "external-successor")
				helpers.assert_true(reads > 0)
				helpers.assert_eq(replacements, 0)
				helpers.assert_eq(admissions, 0, "source drift is rejected before logical admission")
			end)
		end)
	end
end)


helpers.describe("FileSystem admitted source requires raw plain classified scalars", function()
	local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
	helpers.it("rejects malformed and inherited source fields before any native reader or admission", function()
		with_fixture(function(fixture)
			local path = os.tmpname()
			local handle = assert(io.open(path, "wb")); assert(handle:write("owned")); assert(handle:close())
			local adapter = fixture.make_adapter()
			local effects, reads, admissions = 0, 0, 0
			local read = adapter.read_with_status
			adapter.read_with_status = function(...) reads = reads + 1; return read(...) end
			local inherited = setmetatable({}, { __index = function()
				effects = effects + 1; return "owned"
			end, __eq = function() effects = effects + 1; return true end })
			local shapes = { false, {}, { status = "ok", content = 1 }, { status = false, content = "owned" },
				{ status = "OK", content = "owned" }, { status = "absent", content = "owned" }, inherited,
				setmetatable({ status = "ok", content = "owned" }, { __eq = function() effects = effects + 1; return true end }) }
			for _, expected in ipairs(shapes) do
				local pub_called, written = pcall(adapter.write_if_unchanged_admitted,
					path, "candidate", expected, nil, function() admissions = admissions + 1; return true end)
				local remove_called, removed = pcall(adapter.remove_if_unchanged_admitted,
					path, expected, nil, function() admissions = admissions + 1; return true end)
				helpers.assert_eq(pub_called, true)
				helpers.assert_eq(written, false)
				helpers.assert_eq(remove_called, true)
				helpers.assert_eq(removed, false)
			end
			adapter.read_with_status = read
			local file = assert(io.open(path, "rb"))
			local actual = assert(file:read("*a")); assert(file:close())
			os.remove(path)
			helpers.assert_eq(actual, "owned")
			helpers.assert_eq(reads, 0)
			helpers.assert_eq(effects, 0)
			helpers.assert_eq(admissions, 0)
		end)
	end)
end)
