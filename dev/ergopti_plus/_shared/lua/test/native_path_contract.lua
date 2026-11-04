--- _shared/lua/test/native_path_contract.lua

--- ==============================================================================
--- MODULE: Native Path Text Contract
--- DESCRIPTION:
--- Pins the host separator rule of the shared path owner on a modelled POSIX
--- host, where a backslash is filename data, and on a modelled Windows host,
--- where it separates components (posix-backslash-separator-owner).
--- ==============================================================================

local M = {}

local POSIX_CONFIG = "/\n;\n?\n!\n-\n"
local WINDOWS_CONFIG = "\\\n;\n?\n!\n-\n"

--- Runs body with package.config modelling one host, restoring it afterwards.
--- @param config string Modelled package.config.
--- @param body function Receives the owner.
local function on_host(config, body)
	local saved = package.config
	package.config = config
	local ok, failure = xpcall(body, debug.traceback, require("native_path"))
	package.config = saved
	if not ok then error(failure, 0) end
end

--- Registers the owner's vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	helpers.describe("native path: a backslash is filename data on POSIX (posix-backslash-separator-owner)", function()
		helpers.it("posix-backslash-separator-owner: splits only at slashes", function()
			on_host(POSIX_CONFIG, function(Path)
				helpers.assert_eq(Path.separators(), "/")
				helpers.assert_eq(Path.dirname("/Users/a/back\\slash/file.toml"), "/Users/a/back\\slash")
				helpers.assert_eq(Path.dirname("/Users/a/back\\slash"), "/Users/a")
				helpers.assert_eq(Path.basename("/Users/a/back\\slash"), "back\\slash")
				helpers.assert_eq(Path.directory_prefix("/Users/a/b\\c"), "/Users/a/")
				helpers.assert_eq(Path.components("/Users/b\\c/d"), { "Users", "b\\c", "d" })
				helpers.assert_eq(Path.has_separator("Ergo\\L.keylayout"), false)
				helpers.assert_eq(Path.has_separator("a/b"), true)
			end)
		end)
		helpers.it("posix-backslash-separator-owner: trailing separators are slashes only", function()
			on_host(POSIX_CONFIG, function(Path)
				helpers.assert_eq(Path.without_trailing_separators("/a/b//"), "/a/b")
				helpers.assert_eq(Path.without_trailing_separators("/a/b\\"), "/a/b\\")
				helpers.assert_eq(Path.has_trailing_separator("/a/b\\"), false)
				helpers.assert_eq(Path.with_trailing_separator("/a/b\\"), "/a/b\\/")
				helpers.assert_eq(Path.with_trailing_separator("/a/b/"), "/a/b/")
			end)
		end)
		helpers.it("posix-backslash-separator-owner: only a slash roots a POSIX path", function()
			on_host(POSIX_CONFIG, function(Path)
				helpers.assert_eq(Path.is_rooted("/a"), true)
				helpers.assert_eq(Path.is_rooted("\\a"), false)
				helpers.assert_eq(Path.is_absolute("C:/a"), false)
				helpers.assert_eq(Path.is_absolute("relative/a"), false)
			end)
		end)
		helpers.it("posix-backslash-separator-owner: edge cases have no component", function()
			on_host(POSIX_CONFIG, function(Path)
				helpers.assert_nil(Path.dirname("file.toml"))
				helpers.assert_nil(Path.basename(""))
				helpers.assert_nil(Path.basename("/a/"))
				helpers.assert_nil(Path.directory_prefix("file.toml"))
				helpers.assert_eq(Path.components("/"), {})
			end)
		end)
		helpers.it("posix-backslash-separator-owner: a Windows host separates at both", function()
			on_host(WINDOWS_CONFIG, function(Path)
				helpers.assert_eq(Path.separators(), "/\\")
				helpers.assert_eq(Path.dirname("C:\\Users\\a\\file.toml"), "C:\\Users\\a")
				helpers.assert_eq(Path.basename("C:/Users\\a"), "a")
				helpers.assert_eq(Path.without_trailing_separators("C:\\a\\/"), "C:\\a")
				helpers.assert_eq(Path.has_separator("a\\b"), true)
				helpers.assert_eq(Path.is_absolute("C:\\a"), true)
				helpers.assert_eq(Path.is_absolute("C:/a"), true)
			end)
		end)
	end)
end

return M
