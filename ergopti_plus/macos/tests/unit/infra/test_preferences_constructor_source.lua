--- tests/unit/infra/test_preferences_constructor_source.lua

--- ==============================================================================
--- MODULE: Preferences Constructor Loader Coordinates
--- DESCRIPTION:
--- Genuine absolute, driver-cwd and mixed normal loaders retain strict source
--- admission; copied factories and missing native cwd refuse before invocation.
--- ==============================================================================
local helpers = require("tests.helpers")
local text_utils = require("infra.text_utils")
local lfs = require("lfs")
local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local driver = assert(source:match("^(.*)/tests/unit/infra/test_preferences_constructor_source%.lua$"))

-- Each child has genuine isolated module caches and a private configuration root.
-- Relative requires run from the documented driver cwd; mixed requires retain a
-- genuine absolute ConfigMigrate/Writer before Preferences uses relative names.
local child = [=[
local driver, inherited, mode, scratch = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
local shared = assert(driver:match("^(.*)/macos$")) .. "/_shared/lua"
local absolute = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;"
package.path = absolute .. inherited
_G.hs = require("tests.stubs.hs")
require("tests.helpers").load_with_stubs("infra.logger")
local expected = mode == "absolute" or mode == "relative" or mode == "mixed"
local called = 0
if mode ~= "absolute" and mode ~= "relative" then
	local owner = require("config_migrate")
	require("toml_codec.writer")
	if mode == "copied-factory" then
		local actual = assert(debug.getinfo(owner.writer_admission_factory, "S").source:match("^@(.*)$"))
		local input = assert(io.open(actual, "rb"))
		local bytes = assert(input:read("*a")); assert(input:close())
		local output = assert(io.open(scratch .. "/copied-owner.lua", "wb"))
		assert(output:write(bytes)); assert(output:close())
		local copied = assert(loadfile(scratch .. "/copied-owner.lua"))()
		owner.writer_admission_factory = copied.writer_admission_factory
	elseif mode == "replaced-factory" then
		owner.writer_admission_factory = function() called = called + 1; error("replacement must not execute") end
	elseif mode == "failed-directory" then
		_G.hs.fs = { currentDir = function() error("controlled native directory failure") end }
	end
end
if mode ~= "absolute" then
	package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. inherited
end
local ok, result = pcall(require, "infra.preferences")
assert(ok == expected, "normal-loader admission " .. mode .. ": " .. tostring(result))
if ok then
	assert(type(result) == "table", "genuine Preferences constructor must return its owner")
else
	assert(tostring(result):find("preference schema owner is not canonical", 1, true), tostring(result))
end
assert(called == 0, "a foreign replacement must refuse before invocation")
print("PREFERENCES_SOURCE " .. mode .. " admitted=" .. tostring(ok) .. " replacement_calls=" .. called)
]=]

local function remove_owned(path)
	for entry in lfs.dir(path) do
		if entry ~= "." and entry ~= ".." then
			local item = path .. "/" .. entry
			if lfs.symlinkattributes(item, "mode") == "directory" then remove_owned(item)
			else assert(os.remove(item)) end
		end
	end
	assert(lfs.rmdir(path))
end

local function check_source(mode)
	local scratch = os.tmpname()
	os.remove(scratch)
	assert(lfs.mkdir(scratch))
	local ok, reason = pcall(function()
		local path = scratch .. "/probe.lua"
		local output = assert(io.open(path, "wb"))
		assert(output:write(child)); assert(output:close())
		local quote = text_utils.shell_quote
		local command = "cd " .. quote(driver) .. " && env HOME=" .. quote(scratch)
			.. " XDG_CONFIG_HOME=" .. quote(scratch .. "/config")
			.. " XDG_DATA_HOME=" .. quote(scratch .. "/data")
			.. " XDG_STATE_HOME=" .. quote(scratch .. "/state")
			.. " TMPDIR=" .. quote(scratch) .. " " .. quote(os.getenv("LUA") or "lua")
			.. " " .. quote(path) .. " " .. quote(driver) .. " " .. quote(package.path)
			.. " " .. quote(mode) .. " " .. quote(scratch) .. " 2>&1"
			.. "; probe_status=$?; printf '\\nPREFERENCES_CHILD_EXIT=%s\\n' \"$probe_status\"; exit \"$probe_status\""
		local pipe = assert(io.popen(command, "r"))
		local read, result = pcall(pipe.read, pipe, "*a")
		local closed, _, status = pipe:close()
		assert(read, result)
		helpers.assert_eq(closed and 0 or status, 0, result)
		helpers.assert_true(result:find("PREFERENCES_CHILD_EXIT=0", 1, true) ~= nil, result)
		local admitted = mode == "absolute" or mode == "relative" or mode == "mixed"
		helpers.assert_true(result:find("PREFERENCES_SOURCE " .. mode .. " admitted=" .. tostring(admitted)
			.. " replacement_calls=0", 1, true) ~= nil, result)
	end)
	local cleaned, cleanup_reason = pcall(remove_owned, scratch)
	if not ok then error(reason, 0) end
	assert(cleaned, cleanup_reason)
end

helpers.describe("Preferences normal-loader source coordinates", function()
	for _, mode in ipairs({ "absolute", "relative", "mixed", "copied-factory", "replaced-factory", "failed-directory" }) do
		helpers.it("(preferences-constructor-source) " .. mode, function() check_source(mode) end)
	end
end)
