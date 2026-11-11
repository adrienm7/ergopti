--- tests/unit/infra/test_user_private_group.lua

--- ==============================================================================
--- MODULE: User Private Group Rule
--- DESCRIPTION:
--- The managed Ollama installer admits a group-writable ancestor only in the
--- user's private group (umask 0002 on Debian, Ubuntu, Fedora). These cases
--- pin the rule: the user's name and primary gid, no other member listed or
--- primary; anything else is a shared group. One case reads the real account
--- databases for the running account's own primary group.
--- ==============================================================================

local helpers = require("tests.helpers")
local Group = helpers.load_module("infra.user_private_group")

local ME = { name = "alice", uid = 1000, gid = 1000 }
local ACCOUNTS = { { name = "root", uid = 0, gid = 0 }, ME, { name = "bob", uid = 1001, gid = 1001 } }

helpers.describe("user private group (umask-0002-private-group)", function()
	helpers.it("admits the group named like the user that holds only the user", function()
		helpers.assert_true(Group.is_private(ME, { name = "alice", gid = 1000, members = {} }, ACCOUNTS))
		helpers.assert_true(Group.is_private(ME, { name = "alice", gid = 1000, members = { "alice" } }, ACCOUNTS))
	end)
	helpers.it("refuses a group with another listed member", function()
		helpers.assert_eq(Group.is_private(ME, { name = "alice", gid = 1000, members = { "alice", "bob" } }, ACCOUNTS), false)
	end)
	helpers.it("refuses a group another account has as its primary group", function()
		local shared = { ME, { name = "carol", uid = 1002, gid = 1000 } }
		helpers.assert_eq(Group.is_private(ME, { name = "alice", gid = 1000, members = {} }, shared), false)
	end)
	helpers.it("refuses a group whose name or gid is not the user's", function()
		helpers.assert_eq(Group.is_private(ME, { name = "users", gid = 100, members = {} }, ACCOUNTS), false)
		helpers.assert_eq(Group.is_private(ME, { name = "alice", gid = 1005, members = {} }, ACCOUNTS), false)
		helpers.assert_eq(Group.is_private(ME, { name = "staff", gid = 1000, members = {} }, ACCOUNTS), false)
	end)
	helpers.it("refuses malformed facts", function()
		helpers.assert_eq(Group.is_private(nil, { name = "alice", gid = 1000, members = {} }, ACCOUNTS), false)
		helpers.assert_eq(Group.is_private(ME, { name = "alice", gid = 1000 }, ACCOUNTS), false)
		helpers.assert_eq(Group.is_current_user_private(-1), false)
		helpers.assert_eq(Group.is_current_user_private("1000"), false)
	end)
	helpers.it("reads the real account databases without raising", function()
		local gid = require("luv").getgid()
		helpers.assert_eq(type(Group.is_current_user_private(gid)), "boolean")
		-- No account has a private group whose id no group holds.
		helpers.assert_eq(Group.is_current_user_private(2147483646), false)
	end)
end)
