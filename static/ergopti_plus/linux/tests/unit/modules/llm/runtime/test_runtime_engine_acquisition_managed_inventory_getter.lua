--- tests/unit/modules/llm/runtime/test_runtime_engine_acquisition_managed_inventory_getter.lua

--- ==============================================================================
--- MODULE: Concrete Linux Runtime Construction Admission
--- DESCRIPTION:
--- Exercises the actual engine around explicit runtime UI and reentrant start
--- constructors. Controlled capabilities do not prove native resource cleanup.
--- ==============================================================================

package.loaded["tests.support.modules.llm.runtime.runtime_engine_acquisition_fixture"] = nil
local Fixture = require("tests.support.modules.llm.runtime.runtime_engine_acquisition_fixture")
local helpers, test, with_managed_responses =
	Fixture.helpers, Fixture.test, Fixture.with_managed_responses




helpers.describe("managed inventory getter retains its original invocation", function()
	local function install_inventory_pipe(world, names)
		world.inventory_opens = 0
		io.popen = function()
			world.inventory_opens = world.inventory_opens + 1
			return {
				read = function()
					if world.inventory_read then world.inventory_read() end
					local model = names[world.inventory_opens] or names[#names]
					return '{"models":[{"name":"' .. model .. '"}]}'
				end,
				close = function() return true end,
			}
		end
	end

	test("(linux-inventory-getter) shutdown refuses retained cache without touching personal selection", function()
		with_managed_responses(function(world, engine)
			install_inventory_pipe(world, { "original:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "original:2b" })
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_true(engine.shutdown_runtime())
			helpers.assert_eq(world.profiles.get_models(), {}, "Refused refresh cannot expose the old cached inventory.")
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_eq(world.profiles.get_current_model(), "model:2b", "Configured selection remains personal state.")
		end)
	end)

	test("(linux-inventory-getter) exited retained service refuses stale cache without cleanup or transport", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "original:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			local cancellations = world.native_cancels or 0
			world.service.exited = true
			helpers.assert_eq(world.profiles.get_models(), {})
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_eq(world.native_cancels or 0, cancellations, "Currency is read-only and grants no retirement.")
		end)
	end)

	test("(linux-inventory-getter) cached native observer cannot recapture a same-origin successor", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "original:2b", "successor:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			world.on_observe = function()
				world.on_observe = nil
				world:replace_app()
			end
			helpers.assert_eq(world.profiles.get_models(), {}, "This getter belongs to the app captured before its observer.")
			helpers.assert_eq(world.inventory_opens, 1, "Only a fresh getter may dispatch to the successor app.")
			helpers.assert_eq(world.profiles.get_models(), { "successor:2b" })
			helpers.assert_eq(world.inventory_opens, 2)
		end)
	end)

	test("(linux-inventory-getter) reentrant newer inventory is preserved for its own fresh getter", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "original:2b", "newer:2b", "unexpected-third:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			world.on_observe = function()
				world.on_observe = nil
				helpers.assert_eq(world.profiles.refresh_models(), { "newer:2b" })
			end
			helpers.assert_eq(world.profiles.get_models(), {}, "A superseded getter cannot publish a newer operation's cache.")
			helpers.assert_eq(world.inventory_opens, 2)
			helpers.assert_eq(world.profiles.get_models(), { "newer:2b" })
			helpers.assert_eq(world.inventory_opens, 2, "The original getter must not erase or refetch its successor's cache.")
		end)
	end)

	test("(linux-inventory-getter) fresh external response after app retirement retains ordinary caching", function()
		with_managed_responses(function(world, engine)
			install_inventory_pipe(world, { "original:2b", "external:2b" })
			helpers.assert_eq(world.profiles.refresh_models(), { "original:2b" })
			helpers.assert_true(engine.stop_runtime())
			helpers.assert_eq(world.profiles.get_models(), { "external:2b" })
			helpers.assert_eq(world.profiles.get_models(), { "external:2b" })
			helpers.assert_eq(world.inventory_opens, 2, "Absence observes the transport response without authenticating an external PID.")
		end)
	end)

	test("(linux-inventory-getter) original empty-cache getter rejects delayed native read after service replacement", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "late:2b", "successor:2b" })
			world.inventory_read = function()
				world.inventory_read = nil
				world:replace_app()
			end
			helpers.assert_eq(world.profiles.get_models(), {})
			helpers.assert_eq(world.inventory_opens, 1)
			helpers.assert_eq(world.profiles.get_models(), { "successor:2b" })
			helpers.assert_eq(world.inventory_opens, 2)
		end)
	end)
	test("(linux-inventory-getter) delayed getter refresh returns refusal while preserving newer inventory", function()
		with_managed_responses(function(world)
			install_inventory_pipe(world, { "old-read:2b", "newer:2b" })
			world.inventory_read = function()
				world.inventory_read = nil
				helpers.assert_eq(world.profiles.refresh_models(), { "newer:2b" })
			end
			helpers.assert_eq(world.profiles.get_models(), {}, "The getter must return its refresh refusal, not the newer global cache.")
			helpers.assert_eq(world.inventory_opens, 2)
			helpers.assert_eq(world.profiles.get_models(), { "newer:2b" })
			helpers.assert_eq(world.inventory_opens, 2)
		end)
	end)

end)

