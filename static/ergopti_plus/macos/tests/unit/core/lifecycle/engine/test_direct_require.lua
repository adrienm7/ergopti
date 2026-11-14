--- tests/unit/core/lifecycle/engine/test_direct_require.lua

--- ==============================================================================
--- MODULE: Regression — the runtime's wrapped require never runs after boot
--- DESCRIPTION:
--- Hammerspoon 1.1.1 wraps `require`: every call lists and sorts package.loaded
--- for its crash reporter. One lazy `require` per script-chord row turned the
--- Shortcuts submenu from 47 ms into 1 s of main thread (field reports of
--- 2026-11-01 and 2026-11-02), and the unit runner's plain `require` cannot show
--- it: the wrapper is modelled here with what it does on each call.
--- ==============================================================================

local helpers = require("tests.helpers")
local DirectRequire = require("core.lifecycle.engine.direct_require")

--- A global table holding the wrapper Hammerspoon installs.
--- @return table env
--- @return table world { walks } The number of package.loaded listings made.
local function hammerspoon_env()
	local world = { walks = 0 }
	local original = function(name) return "module:" .. name, "loader data" end
	local env = { rawrequire = original }
	env.require = function(name)
		local result = env.rawrequire(name)
		world.walks = world.walks + 1
		return result
	end
	return env, world
end

helpers.describe("direct require", function()
	helpers.it("(direct-require) calls the original with no walk of the loaded modules", function()
		local env, world = hammerspoon_env()
		helpers.assert_eq(DirectRequire.install(env), true)
		for _ = 1, 3360 do helpers.assert_eq(env.require("direct_require_probe"), "module:direct_require_probe") end
		helpers.assert_eq(world.walks, 0, "the wrapper must not run once per row")
		helpers.assert_true(rawequal(env.require, env.rawrequire), "the global is the original itself")
	end)

	helpers.it("reports a runtime without the original and leaves its require working", function()
		local wrapped = function() return "wrapped" end
		local env = { require = wrapped }
		helpers.assert_eq(DirectRequire.install(env), false)
		helpers.assert_true(rawequal(env.require, wrapped))
	end)

	helpers.it("runs before the first module init.lua loads and says when it could not", function()
		-- The boot unit is found by the install call it owns, not by its path.
		local source = assert(helpers.read_driver_unit('require("core.lifecycle.engine.direct_require").install(_G)'))
		local install = source:find('require("core.lifecycle.engine.direct_require").install(_G)', 1, true)
		helpers.assert_true(install ~= nil, "init.lua must install the direct require")
		helpers.assert_true(install < source:find('require("infra.logger")', 1, true),
			"the logger's own load tree is the largest user of the wrapper")
		helpers.assert_true(source:find("if not direct_require_installed then", 1, true) ~= nil,
			"a refused install must reach the log")
	end)
end)
