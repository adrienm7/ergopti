--- tests/unit/ui/menu/menu_llm/download/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: MLX Download Fixture Isolation
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture

helpers.describe("MLX download fixture isolation", function()
	helpers.it("(mlx-fixture-scope) restores the native alias after callback failure", function()
		helpers.with_fresh_modules({ "hs" }, function()
			local alias = {}
			package.loaded["hs"] = alias
			local native = rawget(_G, "hs")
			local open, execute, remove, rename = io.open, os.execute, os.remove, os.rename
			local ok, reason = pcall(with_fixture, {}, function()
				helpers.assert_true(package.loaded["hs"] == _G.hs)
				error("MLX fixture callback failure", 0)
			end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("MLX fixture callback failure", 1, true) ~= nil)
			helpers.assert_true(rawequal(rawget(_G, "hs"), native))
			helpers.assert_true(io.open == open and os.execute == execute)
			helpers.assert_true(os.remove == remove and os.rename == rename)
			helpers.assert_true(package.loaded["hs"] == alias,
				"require('hs') must return the restored native environment")
		end)
	end)

	for _, subject in ipairs({
		{ option = "real_switcher", module = "ui.menu.menu_llm.prediction_lock_registry", api = "new" },
		{ option = "real_window", module = "adapters.shell_runner", api = "spawn" },
	}) do
		helpers.it("(mlx-fixture-scope) releases captured dependencies for " .. subject.option, function()
			helpers.with_fresh_modules({ "hs", subject.module }, function()
				local previous
				for attempt = 1, 2 do
					with_fixture({ [subject.option] = true }, function()
						local consumer = package.loaded[subject.module]
						helpers.assert_type(consumer, "table")
						helpers.assert_type(consumer[subject.api], "function")
						if attempt == 2 then
							helpers.assert_true(consumer ~= previous,
								"a new fixture must not retain the previous dependency captures")
						end
						previous = consumer
					end)
					helpers.assert_nil(package.loaded[subject.module],
						"the real consumer must leave with its fixture dependencies")
				end
			end)
		end)
	end
end)
