--- _shared/lua/test/menu_platform_lookup.lua

--- ==============================================================================
--- MODULE: Native-Visible Declared Menu Identity Contract
--- DESCRIPTION:
--- Hidden siblings never own native captions, readiness, status or held delivery.
--- ==============================================================================

local M = {}

--- Registers actual renderer/file lookup controls for one native Lua platform.
--- @param helpers table Registered native assertion owner.
--- @param platform string Native driver token, "hs" or "linux".
function M.register(helpers, platform)
	assert(platform == "hs" or platform == "linux", "lookup contract needs a native Lua platform")
	local foreign = platform == "hs" and "linux" or "hs"
	local function scenario(body)
		local path = assert(os.tmpname())
		local document = string.format([[{
	"probe": [
		{"type":"command","id":"owned","i18n":"button.cancel","platforms":["%s"],
		 "disabled_when":["foreign_ready"],"checked_when":["foreign_checked"],
		 "status_rows":{"unavailable":[{"type":"label","i18n":"button.cancel"}]}},
		{"type":"command","id":"owned","i18n":"button.ok","platforms":["%s"],
		 "disabled_when":["native_ready"],"checked_when":["native_checked"],
		 "status_rows":{"unavailable":[{"type":"label","i18n":"button.ok"}]}}
	]
}]], foreign, platform)
		local handle
		local ok, detail = pcall(function()
			handle = assert(io.open(path, "wb"))
			assert(handle:write(document))
			assert(handle:close()); handle = nil
			local translator = require("infra.i18n")
			local renderer = assert(require("menu.renderer").new({ platform = platform,
				manifest_path = function() return path end, json_decode = require("json").decode,
				i18n = translator, logger = helpers.make_logger_stub(),
			}))
			local calls = { native = 0, foreign = 0, actions = 0 }
			local getters = {
				native_ready = function() calls.native = calls.native + 1; return true end,
				native_checked = function() calls.native = calls.native + 1; return true end,
				foreign_ready = function() calls.foreign = calls.foreign + 1; return false end,
				foreign_checked = function() calls.foreign = calls.foreign + 1; return false end,
			}
			local commands = { owned = function(...) calls.actions = calls.actions + 1; return ... end }
			body(renderer, renderer.get_array("probe"), commands, getters, calls, translator)
		end)
		if handle then pcall(handle.close, handle) end
		local removed, reason = os.remove(path)
		assert(removed, "owned lookup fixture removal failed: " .. tostring(reason))
		if not ok then error(detail, 0) end
	end

	helpers.describe("native-visible menu identity: " .. platform, function()
		for _, ordering in ipairs({ "hidden-first", "native-first" }) do
			helpers.it("retains caption readiness checked state and exact action acknowledgment: " .. ordering, function()
				scenario(function(renderer, rows, commands, getters, calls, translator)
					if ordering == "native-first" then rows[1], rows[2] = rows[2], rows[1] end
					local row = renderer.command_row("probe", "owned", commands, getters)
					helpers.assert_true(type(row) == "table")
					helpers.assert_eq(row.label, translator.get("button.ok"))
					helpers.assert_true(row.disabled ~= true)
					helpers.assert_eq(renderer.resolve_checked_when("probe", "owned", getters), true)
					helpers.assert_eq(calls.foreign, 0, "hidden getters never decide a native command")
					helpers.assert_eq(row.action("native-ack"), "native-ack")
					helpers.assert_eq(calls.actions, 1)
					helpers.assert_eq(calls.foreign, 0)
				end)
			end)
		end
		helpers.it("rejects duplicate visible identities before any readiness or native action", function()
			scenario(function(renderer, rows, commands, getters, calls)
				rows[1].platforms = { platform }
				helpers.assert_eq(renderer.command_row("probe", "owned", commands, getters), nil)
				helpers.assert_eq(renderer.resolve_disabled_when("probe", "owned", getters), true)
				helpers.assert_eq(renderer.resolve_checked_when("probe", "owned", getters), false)
				helpers.assert_eq(calls, { native = 0, foreign = 0, actions = 0 })
			end)
		end)
		helpers.it("ignores multiple hidden identities when exactly one native identity is visible", function()
			scenario(function(renderer, rows, commands, getters, calls, translator)
				rows[#rows + 1] = rows[1]
				local row = renderer.command_row("probe", "owned", commands, getters)
				helpers.assert_eq(row.label, translator.get("button.ok"))
				helpers.assert_true(row.disabled ~= true)
				helpers.assert_eq(calls.foreign, 0)
			end)
		end)
		helpers.it("withdrawn visible declaration blocks its held action while retaining the hidden sibling", function()
			scenario(function(renderer, rows, commands, getters, calls)
				rows[1], rows[2] = rows[2], rows[1]
				local row = assert(renderer.command_row("probe", "owned", commands, getters))
				helpers.assert_true(row.disabled ~= true, "the real visible predecessor is admitted before withdrawal")
				rows[1].platforms = { foreign }
				helpers.assert_eq(row.action("not-accepted"), false)
				helpers.assert_eq(renderer.command_row("probe", "owned", commands, getters), nil)
				helpers.assert_eq(calls.actions, 0)
				helpers.assert_eq(calls.foreign, 0)
				rows[1].platforms = { platform }
				helpers.assert_eq(row.action("repaired"), "repaired")
				helpers.assert_eq(calls.actions, 1)
			end)
		end)
		helpers.it("new visible ambiguity blocks a previously admitted retained action", function()
			scenario(function(renderer, rows, commands, getters, calls)
				rows[1], rows[2] = rows[2], rows[1]
				local row = assert(renderer.command_row("probe", "owned", commands, getters))
				helpers.assert_true(row.disabled ~= true, "the real visible predecessor is admitted before ambiguity")
				rows[2].platforms = { platform }
				helpers.assert_eq(row.action("not-accepted"), false)
				helpers.assert_eq(calls.actions, 0)
				helpers.assert_eq(calls.foreign, 0)
			end)
		end)
		helpers.it("checkbox provider reads the visible caption and visible predicates", function()
			scenario(function(renderer, rows, commands, getters, calls, translator)
				rows[1].type, rows[2].type = "check", "check"
				local row = renderer.check_row("probe", "owned", commands, getters)
				helpers.assert_eq(row.label, translator.get("button.ok"))
				helpers.assert_eq(row.checked, true)
				helpers.assert_true(row.disabled ~= true)
				helpers.assert_eq(calls.foreign, 0)
				rows[1].platforms = { platform }
				helpers.assert_eq(renderer.check_row("probe", "owned", commands, getters), nil)
				helpers.assert_eq(row.action("not-accepted"), false)
				helpers.assert_eq(calls.actions, 0)
			end)
		end)
		helpers.it("inert status comes from the native owner and rejects ambiguity or withdrawal", function()
			scenario(function(renderer, rows, _, _, calls, translator)
				local status = renderer.status_rows("probe", "owned", "unavailable")
				helpers.assert_eq(status[1].label, translator.get("button.ok"))
				helpers.assert_eq(status[1].disabled, true)
				helpers.assert_eq(status[1].action, nil)
				rows[1].platforms = { platform }
				helpers.assert_eq(renderer.status_rows("probe", "owned", "unavailable"), nil)
				rows[1].platforms, rows[2].platforms = { foreign }, { foreign }
				helpers.assert_eq(renderer.status_rows("probe", "owned", "unavailable"), nil)
				helpers.assert_eq(calls, { native = 0, foreign = 0, actions = 0 })
			end)
		end)
		helpers.it("single global inert status stays shared without granting native command ownership", function()
			scenario(function(renderer, rows, commands, getters, calls, translator)
				rows[2] = nil
				local status = renderer.status_rows("probe", "owned", "unavailable")
				helpers.assert_eq(status[1].label, translator.get("button.cancel"))
				helpers.assert_eq(status[1].disabled, true)
				helpers.assert_eq(status[1].action, nil)
				helpers.assert_eq(renderer.command_row("probe", "owned", commands, getters), nil)
				helpers.assert_eq(calls, { native = 0, foreign = 0, actions = 0 })
			end)
		end)
	end)
end

return M
