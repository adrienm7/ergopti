--- tests/unit/infra/test_stub_scope.lua

--- ==============================================================================
--- MODULE: Native Stub Scope Regression
--- DESCRIPTION:
--- Preserves exact cache predecessors across loader sweeps and nested scopes.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYS = { "hs", "hs.timer", "tests.stubs.hs", "infra.i18n",
	"ui.menu.scope_fixture", "modules.keymap.registry_scope_fixture" }

helpers.describe("native stub scope", function()
	for _, throws in ipairs({ false, true }) do
		helpers.it("(stub-scope) restores first predecessors after " .. (throws and "throw" or "success"), function()
			helpers.with_fresh_modules(KEYS, function()
				local original_hs = rawget(_G, "hs")
				local values = { false, {}, false, {}, {}, {} }
				for index, key in ipairs(KEYS) do package.loaded[key] = values[index] end
				local reached = 0
				local ok, result = pcall(helpers.with_stub_scope, {}, function()
					for _ = 1, 2 do
						local native = helpers.load_with_stubs("hs")
						helpers.assert_true(native == _G.hs)
						helpers.assert_true(package.loaded["hs.timer"] == native.timer)
						helpers.assert_nil(package.loaded[KEYS[5]])
						helpers.assert_nil(package.loaded[KEYS[6]])
						reached = reached + 1
					end
					if throws then error("scope callback injected failure", 0) end
					return "scope callback completed"
				end)
				helpers.assert_eq(ok, not throws)
				helpers.assert_eq(reached, 2)
				helpers.assert_true(tostring(result):find("scope callback", 1, true) ~= nil)
				helpers.assert_true(rawequal(rawget(_G, "hs"), original_hs))
				for index, key in ipairs(KEYS) do
					helpers.assert_true(rawequal(package.loaded[key], values[index]), key)
				end
			end)
		end)
	end

	helpers.it("(stub-scope) restores a nested scope before the outer loader continues", function()
		helpers.with_fresh_modules(KEYS, function()
			local original_hs = rawget(_G, "hs")
			local result = table.pack(helpers.with_stub_scope({}, function()
				local outer = helpers.load_with_stubs("hs")
				local outer_i18n = package.loaded["infra.i18n"]
				local ok, reason = pcall(helpers.with_stub_scope, { "infra.i18n" }, function()
					local inner = helpers.load_with_stubs("hs")
					helpers.assert_true(inner ~= outer)
					error("nested scope failure", 0)
				end)
				helpers.assert_eq(ok, false)
				helpers.assert_true(reason:find("nested scope failure", 1, true) ~= nil)
				helpers.assert_true(_G.hs == outer)
				helpers.assert_true(package.loaded["hs"] == outer)
				helpers.assert_true(package.loaded["infra.i18n"] == outer_i18n)
				helpers.assert_true(helpers.load_with_stubs("hs") ~= outer)
				return nil, false, "tail"
			end))
			helpers.assert_eq(result.n, 3)
			helpers.assert_nil(result[1])
			helpers.assert_eq(result[2], false)
			helpers.assert_eq(result[3], "tail")
			helpers.assert_true(rawequal(_G.hs, original_hs))
			for _, key in ipairs(KEYS) do helpers.assert_nil(package.loaded[key], key) end
		end)
	end)
end)
