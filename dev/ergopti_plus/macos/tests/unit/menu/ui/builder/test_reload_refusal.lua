--- tests/unit/menu/ui/builder/test_reload_refusal.lua

--- ==============================================================================
--- MODULE: Menu Reload Refusal Notice (macOS)
--- DESCRIPTION:
--- A menu Reload refused by a running global action or by the termination
--- coordinator used to leave the old settings in place in silence, or after a
--- « Reloading… » notice. Windows (ReloadRefusedNotify) and Linux
--- (ui/reload_refusal.lua) tell the user with init.reload_refused_*. The real
--- menu `reload` action is compiled from menu/ui/init.lua and run over
--- recording ports (NUI-002).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Compiles the menu's reload action over the given reload answer.
--- @param accepted any What do_reload returns.
--- @return function reload, table notices
local function reload_action(accepted)
	local source = assert(helpers.read_module_source("menu.ui"))
	local body = source:match("\n\t\treload%s+= (function%(%)\n.-\n\t\tend),\n")
	helpers.assert_true(body ~= nil, "the menu reload action is found")
	local notices = {}
	local env = setmetatable({
		do_reload = function(source_name)
			helpers.assert_eq(source_name, "menu")
			return accepted
		end,
		notifications = { notify = function(title, body_text, kind)
			notices[#notices + 1] = { title = title, body = body_text, kind = kind }
			return true
		end },
		i18n = { get = function(key) return key end },
		Logger = { warn = function() end },
		LOG = "test",
	}, { __index = _G })
	local chunk = assert((loadstring or load)("return " .. body, "menu reload", "t", env))
	if setfenv then setfenv(chunk, env) end
	return chunk(), notices
end

helpers.describe("macOS menu Reload refusal (nui-002-reload-refused)", function()
	for _, refused in ipairs({ false, "nil" }) do
		helpers.it("tells a refused Reload (" .. tostring(refused) .. ")", function()
			local reload, notices = reload_action(refused == false and false or nil)
			helpers.assert_true(reload() ~= true)
			helpers.assert_eq(#notices, 1, "a refused Reload must not leave the old settings in silence")
			helpers.assert_eq(notices[1].title, "init.reload_refused_title")
			helpers.assert_eq(notices[1].body, "init.reload_refused_body")
			helpers.assert_eq(notices[1].kind, "error")
		end)
	end

	helpers.it("gives an accepted Reload no refusal notice", function()
		local reload, notices = reload_action(true)
		helpers.assert_eq(reload(), true)
		helpers.assert_eq(#notices, 0)
	end)
end)
