--- tests/unit/infra/logger/test_account_name.lua

--- ==============================================================================
--- MODULE: Linux Account Name
--- DESCRIPTION:
--- The privacy redactor needs the name of the account the daemon runs as. A start
--- without $USER and $LOGNAME (`env -i`, a container entry point, a build sandbox)
--- used to refuse the daemon; the passwd entry now answers instead.
--- ==============================================================================

local helpers = require("tests.helpers")
local AccountName = helpers.load_module("infra.account_name")

local function env_of(values)
	return function(name) return values[name] end
end

helpers.describe("linux account name", function()
	helpers.it("prefers USER, then LOGNAME, over the passwd entry", function()
		local asked = 0
		local lookup = function() asked = asked + 1 return "passwd_name" end
		helpers.assert_eq(AccountName.resolve(env_of({ USER = "from_user", LOGNAME = "from_logname" }), lookup), "from_user")
		helpers.assert_eq(AccountName.resolve(env_of({ LOGNAME = "from_logname" }), lookup), "from_logname")
		helpers.assert_eq(AccountName.resolve(env_of({ USER = "", LOGNAME = "from_logname" }), lookup), "from_logname",
			"an empty variable is no answer")
		helpers.assert_eq(asked, 0, "the passwd entry is not read while the environment answers")
	end)

	helpers.it("asks the passwd entry when neither variable is set", function()
		helpers.assert_eq(AccountName.resolve(env_of({}), function() return "passwd_name" end), "passwd_name")
	end)

	helpers.it("has no answer when nothing knows the account", function()
		helpers.assert_nil(AccountName.resolve(env_of({}), function() return nil end))
	end)

	helpers.it("reads the real passwd entry of the running account on LuaJIT", function()
		if not pcall(require, "ffi") then return end
		local name = AccountName.resolve(env_of({}))
		helpers.assert_type(name, "string", "the effective user has a passwd entry here")
		helpers.assert_true(name ~= "", "and a name")
	end)
end)
