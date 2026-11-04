--- tests/unit/infra/text_and_paths/paths/test_find_upward_posix_backslash.lua

--- ==============================================================================
--- MODULE: Upward path walk keeps POSIX backslash bytes
--- DESCRIPTION:
--- On macOS a backslash is an ordinary filename byte, but the bootstrap resolver
--- climbed with [/\\] as separators. Above a directory such as "back\slash" it
--- stepped into "back" instead of the real parent, so a foreign folder named
--- "back" holding _shared could become the shared root, and every level spent
--- on the bogus parent was lost (paths-posix-backslash-2026-10-21). Backslash
--- now separates only when the host itself is Windows, as in the shared
--- hotstring file helpers and the Linux bootstrap.
--- ==============================================================================

local helpers = require("tests.helpers")

local POSIX_CONFIG = "/\n;\n?\n!\n-\n"

--- Runs a fresh resolver on a modelled POSIX host.
--- @param existing table Set of absolute paths that exist.
--- @param scenario function Receives Paths and the probed paths.
local function on_posix(existing, scenario)
	local saved_config, saved_hs = package.config, rawget(_G, "hs")
	local ok, failure = xpcall(function()
		helpers.with_fresh_modules({ "infra.paths", "infra.logger" }, function()
			package.config = POSIX_CONFIG
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local probed = {}
			_G.hs = { fs = { attributes = function(path)
				probed[#probed + 1] = path
				if existing[path] then return { mode = "directory" } end
				return nil, "No such file or directory"
			end } }
			scenario(require("infra.paths"), probed)
		end)
	end, debug.traceback)
	package.config, _G.hs = saved_config, saved_hs
	if not ok then error(failure, 0) end
end


helpers.describe("Paths.find_upward treats backslash as data on POSIX (paths-posix-backslash-2026-10-21)", function()
	helpers.it("climbs from a backslash directory to its real parent", function()
		on_posix({ ["/Users/a/back/_shared"] = true, ["/Users/a/_shared"] = true }, function(Paths, probed)
			helpers.assert_eq(Paths.find_upward("/Users/a/back\\slash/macos", "_shared"), "/Users/a/_shared")
			for _, path in ipairs(probed) do
				helpers.assert_true(path ~= "/Users/a/back/_shared", "a bogus parent was probed: " .. path)
			end
		end)
	end)

	helpers.it("finds a target inside a directory whose name contains a backslash", function()
		on_posix({ ["/Users/a/back\\slash/_shared"] = true }, function(Paths)
			helpers.assert_eq(Paths.find_upward("/Users/a/back\\slash/macos/", "_shared"),
				"/Users/a/back\\slash/_shared")
		end)
	end)
end)
